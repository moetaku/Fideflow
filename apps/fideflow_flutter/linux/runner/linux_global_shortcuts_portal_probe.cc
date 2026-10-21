// Fake XDG GlobalShortcuts portal acceptance probe. Run inside a private
// dbus-run-session; GtkWindow=nullptr selects the portal path without a
// compositor. This does not contact or mutate the user's desktop session.
#include "linux_global_shortcuts.h"
#include "linux_instance_identity.h"

#include <gio/gio.h>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace {
constexpr char kPortalName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
constexpr char kGlobalShortcuts[] = "org.freedesktop.portal.GlobalShortcuts";
constexpr char kRequestInterface[] = "org.freedesktop.portal.Request";
constexpr char kSessionInterface[] = "org.freedesktop.portal.Session";
constexpr char kRegistryInterface[] = "org.freedesktop.host.portal.Registry";

const char kXml[] =
    "<node>"
    "<interface name='org.freedesktop.portal.GlobalShortcuts'>"
    "<method name='CreateSession'><arg type='a{sv}' direction='in'/>"
    "<arg type='o' direction='out'/></method>"
    "<method name='BindShortcuts'><arg type='o' direction='in'/>"
    "<arg type='a(sa{sv})' direction='in'/><arg type='s' direction='in'/>"
    "<arg type='a{sv}' direction='in'/><arg type='o' direction='out'/>"
    "</method></interface>"
    "<interface name='org.freedesktop.portal.Session'>"
    "<method name='Close'/><signal name='Closed'><arg type='a{sv}'/></signal>"
    "</interface>"
    "<interface name='org.freedesktop.host.portal.Registry'>"
    "<method name='Register'><arg type='s' direction='in'/>"
    "<arg type='a{sv}' direction='in'/></method>"
    "</interface></node>";

std::string RequestPath(const gchar* sender, const std::string& token) {
  std::string escaped(sender != nullptr ? sender : "");
  if (!escaped.empty() && escaped.front() == ':') escaped.erase(0, 1);
  for (char& c : escaped) {
    if (c == '.') c = '_';
  }
  return std::string("/org/freedesktop/portal/desktop/request/") + escaped +
         "/" + token;
}

std::string OptionString(GVariant* options, const char* name) {
  const gchar* value = nullptr;
  return g_variant_lookup(options, name, "&s", &value) && value != nullptr
             ? value
             : std::string();
}

class FakePortal final {
 public:
  enum class Timing { kResponseBeforeReply, kResponseAfterReply, kManual };

  FakePortal() {
    g_autoptr(GError) error = nullptr;
    connection_ = g_dbus_connection_new_for_address_sync(
        g_getenv("DBUS_SESSION_BUS_ADDRESS"),
        static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, &error);
    if (connection_ == nullptr) Fail("connect to private bus", error);
    node_ = g_dbus_node_info_new_for_xml(kXml, &error);
    if (node_ == nullptr) Fail("parse portal introspection", error);
    static const GDBusInterfaceVTable vtable = {MethodCall, nullptr, nullptr,
                                                {nullptr}};
    registration_ = g_dbus_connection_register_object(
        connection_, kPortalPath, node_->interfaces[0], &vtable, this, nullptr,
        &error);
    if (registration_ == 0) Fail("register fake portal", error);
    registry_registration_ = g_dbus_connection_register_object(
        connection_, kPortalPath, node_->interfaces[2], &vtable, this, nullptr,
        &error);
    if (registry_registration_ == 0) Fail("register fake host registry", error);
    name_id_ = g_bus_own_name_on_connection(connection_, kPortalName,
        G_BUS_NAME_OWNER_FLAGS_NONE, nullptr, nullptr, nullptr, nullptr);
    PumpUntil([this] { return g_dbus_connection_get_unique_name(connection_) != nullptr; },
              "fake bus connection ready");
  }

  ~FakePortal() {
    if (connection_ != nullptr && registration_ != 0)
      g_dbus_connection_unregister_object(connection_, registration_);
    if (registry_registration_ != 0)
      g_dbus_connection_unregister_object(connection_, registry_registration_);
    for (guint id : session_registrations_)
      g_dbus_connection_unregister_object(connection_, id);
    if (name_id_ != 0) g_bus_unown_name(name_id_);
    if (node_ != nullptr) g_dbus_node_info_unref(node_);
    g_clear_object(&connection_);
  }

  void set_timing(Timing timing) { timing_ = timing; }
  void set_bind_status(guint32 status) { bind_status_ = status; }
  void set_omit_binding_id(bool omit) { omit_binding_id_ = omit; }
  void set_registry_supported(bool supported) { registry_supported_ = supported; }
  void set_registry_rejected(bool rejected) { registry_rejected_ = rejected; }
  void set_registry_delayed(bool delayed) { registry_delayed_ = delayed; }
  bool registration_pending() const { return pending_registration_ != nullptr; }
  void FinishRegistration() {
    if (pending_registration_ == nullptr) Fail("no pending registration");
    g_dbus_method_invocation_return_value(pending_registration_, nullptr);
    g_clear_object(&pending_registration_);
  }
  std::string last_app_id() const { return last_app_id_; }
  int creates() const { return creates_; }
  int binds() const { return binds_; }
  int closes() const { return closes_; }
  int pending_responses() const { return static_cast<int>(pending_.size()); }
  std::string last_session() const { return last_session_; }
  const std::map<std::string, std::string>& last_triggers() const {
    return last_triggers_;
  }

  void RespondNext(guint32 status) {
    RespondAt(0, status);
  }

  void RespondAt(size_t index, guint32 status) {
    if (index >= pending_.size()) Fail("no pending portal response at index");
    auto response = std::move(pending_[index]);
    pending_.erase(pending_.begin() + index);
    EmitResponse(response.path, status, response.session,
                 response.create_session);
  }

  void Activate(const std::string& session, const char* action) {
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_dbus_connection_emit_signal(connection_, nullptr, kPortalPath,
        kGlobalShortcuts, "Activated",
        g_variant_new("(ost@a{sv})", session.c_str(), action,
                      static_cast<guint64>(7), g_variant_builder_end(&options)),
        nullptr);
  }

  static void Pump() {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  }

  template <typename Predicate>
  static void PumpUntil(Predicate predicate, const char* what) {
    const gint64 until = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    while (!predicate() && g_get_monotonic_time() < until) Pump();
    if (!predicate()) {
      std::fprintf(stderr, "timeout waiting for %s\n", what);
      std::exit(10);
    }
  }

  [[noreturn]] static void Fail(const char* what, GError* error = nullptr) {
    std::fprintf(stderr, "%s%s%s\n", what, error ? ": " : "",
                 error ? error->message : "");
    std::exit(11);
  }

 private:
  struct Pending {
    std::string path;
    std::string session;
    bool create_session;
  };

  static gboolean EmitLater(gpointer data) {
    auto* payload = static_cast<std::pair<FakePortal*, Pending>*>(data);
    payload->first->EmitResponse(payload->second.path,
        payload->second.create_session ? 0 : payload->first->bind_status_,
        payload->second.session, payload->second.create_session);
    delete payload;
    return G_SOURCE_REMOVE;
  }

  static void MethodCall(GDBusConnection*, const gchar* sender,
      const gchar* object_path, const gchar* interface_name,
      const gchar* method_name, GVariant* parameters,
      GDBusMethodInvocation* invocation, gpointer data) {
    auto* self = static_cast<FakePortal*>(data);
    if (g_str_equal(interface_name, kRegistryInterface)) {
      if (!self->registry_supported_) {
        g_dbus_method_invocation_return_error_literal(invocation, G_DBUS_ERROR,
            G_DBUS_ERROR_UNKNOWN_METHOD, "Registry is unavailable");
      } else if (self->registry_rejected_ || self->registered_apps_.count(sender)) {
        g_dbus_method_invocation_return_dbus_error(invocation,
            "org.freedesktop.portal.Error.Failed", "Registration rejected");
      } else {
        const gchar* app_id = nullptr;
        GVariant* options = nullptr;
        g_variant_get(parameters, "(&s@a{sv})", &app_id, &options);
        self->last_app_id_ = app_id;
        self->registered_apps_[sender] = app_id;
        g_variant_unref(options);
        if (self->registry_delayed_) {
          self->pending_registration_ =
              G_DBUS_METHOD_INVOCATION(g_object_ref(invocation));
        } else {
          g_dbus_method_invocation_return_value(invocation, nullptr);
        }
      }
      return;
    }
    if (g_str_equal(interface_name, kSessionInterface) &&
        g_str_equal(method_name, "Close")) {
      ++self->closes_;
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (!g_str_equal(interface_name, kGlobalShortcuts)) {
      g_dbus_method_invocation_return_error_literal(invocation,
          G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown fake portal method");
      return;
    }
    if (self->registry_supported_ && !self->registered_apps_.count(sender)) {
      g_dbus_method_invocation_return_dbus_error(invocation,
          "org.freedesktop.portal.Error.Failed",
          "Portal caller must register its own connection first");
      return;
    }

    const bool create = g_str_equal(method_name, "CreateSession");
    GVariant* options = nullptr;
    if (create) {
      g_variant_get(parameters, "(@a{sv})", &options);
      ++self->creates_;
    } else if (g_str_equal(method_name, "BindShortcuts")) {
      const gchar* session = nullptr;
      GVariant* shortcuts = nullptr;
      const gchar* parent = nullptr;
      g_variant_get(parameters, "(&o@a(sa{sv})&s@a{sv})", &session,
                    &shortcuts, &parent, &options);
      self->last_triggers_.clear();
      GVariantIter iter;
      g_variant_iter_init(&iter, shortcuts);
      const gchar* action = nullptr;
      GVariant* properties = nullptr;
      while (g_variant_iter_next(&iter, "(&s@a{sv})", &action, &properties)) {
        self->last_triggers_[action] = OptionString(properties, "preferred_trigger");
        g_variant_unref(properties);
      }
      g_variant_unref(shortcuts);
      (void)session;
      (void)parent;
      ++self->binds_;
    } else {
      g_dbus_method_invocation_return_error_literal(invocation,
          G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown fake portal method");
      return;
    }
    const std::string token = OptionString(options, "handle_token");
    g_variant_unref(options);
    const std::string request = RequestPath(sender, token);
    std::string session;
    if (create) {
      session = "/org/freedesktop/portal/desktop/session/fideflow/session" +
                std::to_string(self->creates_);
      self->RegisterSession(session);
      self->last_session_ = session;
    }
    Pending pending{request, session, create};
    if (self->timing_ == Timing::kResponseBeforeReply) {
      self->EmitResponse(pending.path, create ? 0 : self->bind_status_, session,
                         create);
    } else if (self->timing_ == Timing::kManual) {
      self->pending_.push_back(pending);
    } else {
      auto* later = new std::pair<FakePortal*, Pending>(self, pending);
      g_idle_add(EmitLater, later);
    }
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(o)", request.c_str()));
    (void)object_path;
  }

  void RegisterSession(const std::string& path) {
    static const GDBusInterfaceVTable vtable = {MethodCall, nullptr, nullptr,
                                                {nullptr}};
    g_autoptr(GError) error = nullptr;
    const guint id = g_dbus_connection_register_object(connection_, path.c_str(),
        node_->interfaces[1], &vtable, this, nullptr, &error);
    if (id == 0) Fail("register fake portal session", error);
    session_registrations_.push_back(id);
  }

  void EmitResponse(const std::string& path, guint32 status,
                    const std::string& session, bool create_session) {
    GVariantBuilder results;
    g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
    if (create_session && !session.empty()) {
      g_variant_builder_add(&results, "{sv}", "session_handle",
                            g_variant_new_string(session.c_str()));
    } else if (!create_session && status == 0) {
      GVariantBuilder accepted;
      g_variant_builder_init(&accepted, G_VARIANT_TYPE("a(sa{sv})"));
      for (const auto& binding : last_triggers_) {
        if (omit_binding_id_) continue;
        GVariantBuilder properties;
        g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
        g_variant_builder_add(&properties, "{sv}", "description",
                              g_variant_new_string("Toggle playback"));
        g_variant_builder_add(&properties, "{sv}", "trigger_description",
                              g_variant_new_string("Ctrl+Alt+A"));
        g_variant_builder_add(&accepted, "(s@a{sv})", binding.first.c_str(),
                              g_variant_builder_end(&properties));
      }
      g_variant_builder_add(&results, "{sv}", "shortcuts",
                            g_variant_builder_end(&accepted));
    }
    g_dbus_connection_emit_signal(connection_, nullptr, path.c_str(),
        kRequestInterface, "Response",
        g_variant_new("(u@a{sv})", status, g_variant_builder_end(&results)),
        nullptr);
  }

  GDBusConnection* connection_ = nullptr;
  GDBusNodeInfo* node_ = nullptr;
  guint registration_ = 0;
  guint registry_registration_ = 0;
  guint name_id_ = 0;
  std::vector<guint> session_registrations_;
  std::vector<Pending> pending_;
  Timing timing_ = Timing::kResponseAfterReply;
  guint32 bind_status_ = 0;
  bool omit_binding_id_ = false;
  int creates_ = 0, binds_ = 0, closes_ = 0;
  std::string last_session_;
  std::map<std::string, std::string> last_triggers_;
  std::map<std::string, std::string> registered_apps_;
  std::string last_app_id_;
  bool registry_supported_ = true, registry_rejected_ = false;
  bool registry_delayed_ = false;
  GDBusMethodInvocation* pending_registration_ = nullptr;
};

FlValue* MakeConfiguration(bool enabled = true, gint key = 4) {
  FlValue* config = fl_value_new_map();
  fl_value_set_string_take(config, "globalEnabled", fl_value_new_bool(enabled));
  FlValue* global = fl_value_new_map();
  if (enabled) {
    FlValue* binding = fl_value_new_map();
    fl_value_set_string_take(binding, "key", fl_value_new_int(key));
    fl_value_set_string_take(binding, "meta", fl_value_new_bool(FALSE));
    fl_value_set_string_take(binding, "control", fl_value_new_bool(TRUE));
    fl_value_set_string_take(binding, "alt", fl_value_new_bool(TRUE));
    fl_value_set_string_take(binding, "shift", fl_value_new_bool(FALSE));
    fl_value_set_string_take(global, "toggle", binding);
  }
  fl_value_set_string_take(config, "global", global);
  return config;
}

void Expect(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(12);
  }
}

void Await(const std::function<bool()>& predicate, const char* message) {
  FakePortal::PumpUntil(predicate, message);
  FakePortal::Pump();
}

void VerifyPortalKeys(FakePortal& portal) {
  portal.set_timing(FakePortal::Timing::kResponseAfterReply);
  LinuxGlobalShortcuts shortcuts(nullptr, [](const std::string&) {},
                                 [](const std::string&) {});
  // Exercise the actual portal payload, including every Linux default key
  // and the non-alphanumeric keys accepted by the settings recorder.
  const std::map<gint, std::string> cases = {
      {4,"a"},{15,"l"},{40,"Return"},{42,"BackSpace"},{43,"Tab"},
      {44,"space"},{45,"minus"},{46,"equal"},{47,"bracketleft"},
      {48,"bracketright"},{49,"backslash"},{51,"semicolon"},
      {52,"apostrophe"},{53,"grave"},{54,"comma"},{55,"period"},
      {56,"slash"},{74,"Home"},{75,"Page_Up"},{76,"Delete"},{77,"End"},
      {78,"Page_Down"},{79,"Right"},{80,"Left"},{81,"Down"},{82,"Up"},
  };
  for (const auto& test : cases) {
    FlValue* config = MakeConfiguration(true, test.first);
    FlValue* binding = fl_value_lookup_string(
        fl_value_lookup_string(config, "global"), "toggle");
    fl_value_set_string_take(binding, "meta", fl_value_new_bool(TRUE));
    fl_value_set_string_take(binding, "shift", fl_value_new_bool(TRUE));
    bool completed = false;
    shortcuts.Configure(config, [&](std::map<std::string, std::string> errors) {
      Expect(errors.empty(), "supported key must be accepted by the portal");
      completed = true;
    });
    fl_value_unref(config);
    Await([&] { return completed; }, "supported portal key binding");
    Expect(portal.last_triggers().at("toggle") ==
               "CTRL+ALT+SHIFT+LOGO+" + test.second,
           "preferred_trigger must use XDG modifier and keysym names");
  }
}

void VerifyPendingBindingCancellation(FakePortal& portal) {
  portal.set_timing(FakePortal::Timing::kManual);
  for (int operation = 0; operation < 3; ++operation) {
    LinuxGlobalShortcuts shortcuts(nullptr, [](const std::string&) {},
                                   [](const std::string&) {});
    int completions = 0;
    const int creates = portal.creates(), binds = portal.binds();
    FlValue* config = MakeConfiguration();
    shortcuts.Configure(config, [&](std::map<std::string, std::string> errors) {
      ++completions;
      Expect(errors.count("toggle") == 1,
             "cancelled pending binding must report failure");
      FakePortal::Pump();  // Completion callbacks may reenter the event loop.
    });
    fl_value_unref(config);
    Await([&] { return portal.creates() > creates; }, "pending CreateSession");
    portal.RespondNext(0);
    Await([&] { return portal.binds() > binds; }, "pending BindShortcuts");
    // Ensure the method reply has released its reference while the approval
    // Response is still pending: cancellation must retain the flow itself.
    for (int i = 0; i < 40; ++i) FakePortal::Pump();
    if (operation == 0) {
      shortcuts.Suspend(true);
    } else if (operation == 1) {
      config = MakeConfiguration(false);
      shortcuts.Configure(config, [](std::map<std::string, std::string> errors) {
        Expect(errors.empty(), "disabling must succeed");
      });
      fl_value_unref(config);
    } else {
      shortcuts.Dispose();
    }
    Expect(completions == 1, "cancellation must complete exactly once");
    portal.RespondNext(0);
    for (int i = 0; i < 40; ++i) FakePortal::Pump();
    Expect(completions == 1, "late approval must not repeat completion");
  }
}

void VerifyRegistryCompatibility(FakePortal& portal) {
  portal.set_timing(FakePortal::Timing::kResponseAfterReply);
  for (bool supported : {true, false}) {
    portal.set_registry_supported(supported);
    portal.set_registry_rejected(supported);
    LinuxGlobalShortcuts shortcuts(nullptr, [](const std::string&) {},
                                   [](const std::string&) {});
    const int creates = portal.creates();
    bool completed = false;
    FlValue* config = MakeConfiguration();
    shortcuts.Configure(config, [&](std::map<std::string, std::string> errors) {
      Expect(supported ? errors.count("toggle") == 1 : errors.empty(),
             "registration rejection must fail; older portals may fall back");
      completed = true;
    });
    fl_value_unref(config);
    Await([&] { return completed; }, "host registry compatibility");
    Expect(portal.creates() == creates + (supported ? 0 : 1),
           "rejected registration must not create a misidentified session");
  }
  portal.set_registry_supported(true);
  portal.set_registry_rejected(false);

  portal.set_registry_delayed(true);
  for (bool dispose : {true, false}) {
    LinuxGlobalShortcuts shortcuts(nullptr, [](const std::string&) {},
                                   [](const std::string&) {});
    int completions = 0;
    const int creates = portal.creates();
    FlValue* config = MakeConfiguration();
    shortcuts.Configure(config, [&](std::map<std::string, std::string> errors) {
      Expect(errors.count("toggle") == 1, "cancel pending registration");
      ++completions;
    });
    fl_value_unref(config);
    Await([&] { return portal.registration_pending(); }, "pending registration");
    if (dispose) shortcuts.Dispose();
    else shortcuts.Suspend(true);
    Expect(completions == 1, "registration cancellation completes exactly once");
    portal.FinishRegistration();
    for (int i = 0; i < 40; ++i) FakePortal::Pump();
    Expect(completions == 1 && portal.creates() == creates,
           "late registration must not create a cancelled session");
  }
  portal.set_registry_delayed(false);
}

}  // namespace

int main() {
  FakePortal portal;
  portal.set_timing(FakePortal::Timing::kResponseBeforeReply);
  int dispatched = 0;
  int callback_count = 0;
  std::map<std::string, std::string> last_result;
  LinuxGlobalShortcuts shortcuts(nullptr,
      [&dispatched](const std::string& action) {
        if (action == "toggle") ++dispatched;
      }, [](const std::string&) {});

  FlValue* config = MakeConfiguration();
  shortcuts.Configure(config, [&](std::map<std::string, std::string> result) {
    ++callback_count;
    last_result = std::move(result);
  });
  fl_value_unref(config);
  Await([&] { return callback_count == 1; }, "response-before/after-reply flow");
  Expect(last_result.empty(), "successful portal binding should have no errors");
  Expect(portal.creates() == 1 && portal.binds() == 1,
         "CreateSession and BindShortcuts should both run");
  Expect(portal.last_app_id() == "com.moetaku.fideflow",
         "portal app ID must be stable and have no data-root suffix");
  const std::string first_session = portal.last_session();
  portal.Activate(first_session, "toggle");
  Await([&] { return dispatched == 1; }, "matching Activated signal");
  portal.Activate("/org/freedesktop/portal/session/wrong", "toggle");
  FakePortal::Pump();
  Expect(dispatched == 1, "signals from another portal session must be ignored");

  portal.set_timing(FakePortal::Timing::kResponseAfterReply);
  portal.set_bind_status(2);
  config = MakeConfiguration();
  shortcuts.Configure(config, [&](std::map<std::string, std::string> result) {
    ++callback_count;
    last_result = std::move(result);
  });
  fl_value_unref(config);
  Await([&] { return callback_count == 2; }, "BindShortcuts rejection");
  Expect(last_result.size() == 1 && last_result.count("toggle") == 1,
         "portal rejection should identify the failed action");

  portal.set_bind_status(0);
  portal.set_omit_binding_id(true);
  config = MakeConfiguration();
  shortcuts.Configure(config, [&](std::map<std::string, std::string> result) {
    ++callback_count;
    last_result = std::move(result);
  });
  fl_value_unref(config);
  Await([&] { return callback_count == 3; },
        "BindShortcuts response omitting requested ID");
  Expect(last_result.count("toggle") == 1 &&
             last_result.at("toggle") == "controls.registration",
         "omitted requested shortcut ID should report registration failure");
  portal.set_omit_binding_id(false);

  portal.set_bind_status(0);
  config = MakeConfiguration();
  shortcuts.Configure(config, [&](std::map<std::string, std::string> result) {
    ++callback_count;
    last_result = std::move(result);
  });
  fl_value_unref(config);
  Await([&] { return callback_count == 4; }, "rebind after rejection");

  // Reconfigure while the old portal request is waiting for user approval.
  // The newer config must win even if the old Response arrives afterward.
  portal.set_timing(FakePortal::Timing::kManual);
  const int creates_before_race = portal.creates();
  int old_callback_count = 0;
  int new_callback_count = 0;
  config = MakeConfiguration();
  shortcuts.Configure(config, [&](std::map<std::string, std::string>) {
    ++old_callback_count;
    ++callback_count;
  });
  fl_value_unref(config);
  Await([&] { return portal.creates() == creates_before_race + 1; },
        "superseded CreateSession request");
  config = MakeConfiguration();
  shortcuts.Configure(config, [&](std::map<std::string, std::string>) {
    ++new_callback_count;
    ++callback_count;
  });
  fl_value_unref(config);
  Expect(old_callback_count == 1,
         "superseded portal request must complete its callback once");
  Await([&] { return portal.creates() == creates_before_race + 2; },
        "current CreateSession request");
  const int binds_before_stale_response = portal.binds();
  const std::string expected_session = portal.last_session();
  portal.RespondAt(1, 0);  // Current response first.
  Await([&] { return portal.binds() > binds_before_stale_response; },
        "current configuration starts BindShortcuts");
  portal.RespondAt(0, 0);  // Superseded response must be discarded.
  Expect(portal.binds() == binds_before_stale_response + 1,
         "stale CreateSession must not start another BindShortcuts");
  Expect(portal.pending_responses() == 1,
         "only the current BindShortcuts response should remain pending");
  portal.RespondNext(0);
  Await([&] { return new_callback_count == 1; },
        "current configuration completes once");
  Expect(old_callback_count == 1 && new_callback_count == 1,
         "superseded and current config callbacks should each complete once");
  portal.set_timing(FakePortal::Timing::kResponseAfterReply);
  const int before_current_activation = dispatched;
  portal.Activate(expected_session, "toggle");
  Await([&] { return dispatched == before_current_activation + 1; },
        "stale response must not replace current portal session");

  const std::string active_before_suspend = portal.last_session();
  const int closes_before_suspend = portal.closes();
  const int binds_before_resume = portal.binds();
  shortcuts.Suspend(true);
  Await([&] { return portal.closes() > closes_before_suspend; },
        "suspend closes portal session");
  const int before_suspended_activation = dispatched;
  portal.Activate(active_before_suspend, "toggle");
  FakePortal::Pump();
  Expect(dispatched == before_suspended_activation,
         "suspended portal shortcuts must not dispatch");
  shortcuts.Suspend(false);
  Await([&] { return portal.binds() > binds_before_resume; },
        "resume re-registers portal shortcuts");
  const std::string active_after_resume = portal.last_session();
  for (int i = 0; i < 40; ++i) FakePortal::Pump();
  portal.Activate(active_after_resume, "toggle");
  Await([&] { return dispatched == before_suspended_activation + 1; },
        "resumed portal shortcuts dispatch");

  const int closed_before_disable = portal.closes();
  config = MakeConfiguration(false);
  shortcuts.Configure(config, [&](std::map<std::string, std::string> result) {
    ++callback_count;
    last_result = std::move(result);
  });
  fl_value_unref(config);
  Await([&] { return callback_count == 7; }, "disable configuration");
  Await([&] { return portal.closes() > closed_before_disable; },
        "disable closes portal session");
  const int before_disabled_activation = dispatched;
  portal.Activate(portal.last_session(), "toggle");
  FakePortal::Pump();
  Expect(dispatched == before_disabled_activation,
         "disabled portal shortcuts must not dispatch");

  shortcuts.Dispose();

  // Dispose a fresh instance while approval is pending, then construct another
  // instance on the same bus. Its request token must not alias the stale one.
  portal.set_timing(FakePortal::Timing::kManual);
  int disposed_callback_count = 0;
  LinuxGlobalShortcuts short_lived(nullptr, [](const std::string&) {},
                                   [](const std::string&) {});
  config = MakeConfiguration();
  short_lived.Configure(config, [&](std::map<std::string, std::string>) {
    ++disposed_callback_count;
  });
  fl_value_unref(config);
  const int creates_before_dispose = portal.creates();
  Await([&] { return portal.creates() == creates_before_dispose + 1; },
        "pending CreateSession before dispose");
  short_lived.Dispose();
  Expect(disposed_callback_count == 1,
         "disposing a pending configuration must complete it exactly once");

  int replacement_callback_count = 0;
  LinuxGlobalShortcuts replacement(nullptr, [](const std::string&) {},
                                   [](const std::string&) {});
  config = MakeConfiguration();
  replacement.Configure(config, [&](std::map<std::string, std::string>) {
    ++replacement_callback_count;
  });
  fl_value_unref(config);
  Await([&] { return portal.creates() == creates_before_dispose + 2; },
        "replacement CreateSession after dispose");
  const int binds_before_old_response = portal.binds();
  portal.RespondAt(0, 0);  // Old disposed instance's late response.
  FakePortal::Pump();
  Expect(portal.binds() == binds_before_old_response,
         "late response from disposed instance must not bind stale config");
  portal.RespondAt(0, 0);  // Replacement response.
  Await([&] { return portal.binds() == binds_before_old_response + 1; },
        "replacement BindShortcuts");
  portal.RespondNext(0);
  Await([&] { return replacement_callback_count == 1; },
        "replacement configuration should complete once");
  replacement.Dispose();
  Expect(disposed_callback_count == 1 && replacement_callback_count == 1,
         "disposed and replacement configuration callbacks must not repeat");
  VerifyPendingBindingCancellation(portal);
  VerifyPortalKeys(portal);
  VerifyRegistryCompatibility(portal);
  std::puts("PASS: fake portal identity, compatibility, timing, routing, rejection, cancellation, keys, and lifetimes");
  return 0;
}
