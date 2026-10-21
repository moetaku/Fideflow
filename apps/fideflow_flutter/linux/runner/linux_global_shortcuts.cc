#include "linux_global_shortcuts.h"
#include "linux_instance_identity.h"

#include <algorithm>
#include <array>
#include <sstream>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#endif

namespace {

// The configuration stores USB HID keyboard usages. Linux input key codes
// follow the same physical positions for the supported keys; Xorg adds 8 to
// the evdev code when exposing a keycode.
guint EvdevCode(gint usage) {
  static const std::map<gint, guint> codes = {
      {4, 30}, {5, 48}, {6, 46}, {7, 32}, {8, 18}, {9, 33},
      {10, 34}, {11, 35}, {12, 23}, {13, 36}, {14, 37}, {15, 38},
      {16, 50}, {17, 49}, {18, 24}, {19, 25}, {20, 16}, {21, 19},
      {22, 31}, {23, 20}, {24, 22}, {25, 47}, {26, 17}, {27, 45},
      {28, 21}, {29, 44}, {30, 2}, {31, 3}, {32, 4}, {33, 5},
      {34, 6}, {35, 7}, {36, 8}, {37, 9}, {38, 10}, {39, 11},
      {40, 28}, {42, 14}, {43, 15}, {44, 57}, {45, 12}, {46, 13},
      {47, 26}, {48, 27}, {49, 43}, {51, 39}, {52, 40}, {53, 41},
      {54, 51}, {55, 52}, {56, 53}, {58, 59}, {59, 60}, {60, 61},
      {61, 62}, {62, 63}, {63, 64}, {64, 65}, {65, 66}, {66, 67},
      {67, 68}, {68, 87}, {69, 88}, {74, 102}, {75, 104}, {76, 111},
      {77, 107}, {78, 109}, {79, 106}, {80, 105}, {81, 108}, {82, 103},
  };
  auto found = codes.find(usage);
  return found == codes.end() ? 0 : found->second;
}

bool ReadBool(FlValue* value, const gchar* key, bool* out) {
  FlValue* field = fl_value_lookup_string(value, key);
  if (field == nullptr || fl_value_get_type(field) != FL_VALUE_TYPE_BOOL) {
    return false;
  }
  *out = fl_value_get_bool(field);
  return true;
}

std::string ReadString(FlValue* value) {
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return {};
  }
  return fl_value_get_string(value);
}

std::string HidKeyName(gint usage) {
  static const std::map<gint, const char*> names = {
      {4,"a"},{5,"b"},{6,"c"},{7,"d"},{8,"e"},{9,"f"},{10,"g"},
      {11,"h"},{12,"i"},{13,"j"},{14,"k"},{15,"l"},{16,"m"},
      {17,"n"},{18,"o"},{19,"p"},{20,"q"},{21,"r"},{22,"s"},
      {23,"t"},{24,"u"},{25,"v"},{26,"w"},{27,"x"},{28,"y"},
      {29,"z"},{30,"1"},{31,"2"},{32,"3"},{33,"4"},{34,"5"},
      {35,"6"},{36,"7"},{37,"8"},{38,"9"},{39,"0"},
      {40,"Return"},{42,"BackSpace"},{43,"Tab"},{44,"space"},
      {45,"minus"},{46,"equal"},{47,"bracketleft"},{48,"bracketright"},
      {49,"backslash"},{51,"semicolon"},{52,"apostrophe"},{53,"grave"},
      {54,"comma"},{55,"period"},{56,"slash"},
      {58,"F1"},{59,"F2"},{60,"F3"},{61,"F4"},{62,"F5"},{63,"F6"},
      {64,"F7"},{65,"F8"},{66,"F9"},{67,"F10"},{68,"F11"},{69,"F12"},
      {74,"Home"},{75,"Page_Up"},{76,"Delete"},{77,"End"},
      {78,"Page_Down"},{79,"Right"},{80,"Left"},{81,"Down"},{82,"Up"},
  };
  auto found = names.find(usage);
  return found == names.end() ? std::string() : found->second;
}

std::string PortalTrigger(FlValue* binding) {
  FlValue* key = fl_value_lookup_string(binding, "key");
  if (key == nullptr || fl_value_get_type(key) != FL_VALUE_TYPE_INT) return {};
  std::string name = HidKeyName(fl_value_get_int(key));
  if (name.empty()) return {};
  std::string trigger;
  bool meta = false, control = false, alt = false, shift = false;
  if (!ReadBool(binding,"meta",&meta) || !ReadBool(binding,"control",&control) ||
      !ReadBool(binding,"alt",&alt) || !ReadBool(binding,"shift",&shift)) return {};
  if (control) trigger += "CTRL+";
  if (alt) trigger += "ALT+";
  if (shift) trigger += "SHIFT+";
  if (meta) trigger += "LOGO+";
  return trigger + name;
}

}  // namespace

struct LinuxGlobalShortcuts::PortalFlow {
  std::shared_ptr<CallbackState> state;
  ConfigureCallback callback;
  FlValue* configuration = nullptr;
  std::string token;
  std::string request_path;
  std::string session;
  guint signal_id = 0;
  GDBusConnection* bus = nullptr;
  bool binding = false;
  int references = 1;
  std::map<std::string, std::string> failures;
  guint64 generation = 0;
};

LinuxGlobalShortcuts::LinuxGlobalShortcuts(GtkWindow* window,
                                           ActionCallback on_action,
                                           ErrorCallback on_error)
    : window_(window), on_action_(std::move(on_action)),
      on_error_(std::move(on_error)),
      callback_state_(std::make_shared<CallbackState>()) {
  callback_state_->owner = this;
  if (window_ != nullptr) {
    display_ = gtk_widget_get_display(GTK_WIDGET(window_));
    g_object_ref(window_);
  }
#ifdef GDK_WINDOWING_X11
  if (IsX11()) {
    Display* xdisplay = gdk_x11_display_get_xdisplay(display_);
    Bool detectable = False;
    XkbSetDetectableAutoRepeat(xdisplay, True, &detectable);
    XModifierKeymap* modifier_map = XGetModifierMapping(xdisplay);
    const KeyCode num_lock = XKeysymToKeycode(xdisplay, XK_Num_Lock);
    if (modifier_map != nullptr) {
      for (int modifier = 0; modifier < 8; ++modifier) {
        for (int slot = 0; slot < modifier_map->max_keypermod; ++slot) {
          if (modifier_map->modifiermap[modifier * modifier_map->max_keypermod + slot] == num_lock)
            numlock_mask_ = 1u << modifier;
        }
      }
      XFreeModifiermap(modifier_map);
    }
  }
#endif
}

LinuxGlobalShortcuts::~LinuxGlobalShortcuts() { Dispose(); }

bool LinuxGlobalShortcuts::IsX11() const {
#ifdef GDK_WINDOWING_X11
  return display_ != nullptr && GDK_IS_X11_DISPLAY(display_);
#else
  return false;
#endif
}

void LinuxGlobalShortcuts::Configure(FlValue* configuration,
                                     ConfigureCallback callback) {
  if (disposed_) {
    if (callback) callback({});
    return;
  }
  CancelPortalFlow();
  if (portal_activated_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, portal_activated_subscription_);
    portal_activated_subscription_ = 0;
  }
  ClosePortalSession();
  FlValue* retained_configuration =
      configuration != nullptr ? fl_value_ref(configuration) : nullptr;
  if (configuration_ != nullptr) fl_value_unref(configuration_);
  configuration_ = retained_configuration;
  UnregisterAll();
  bool enabled = false;
  if (!ReadBool(configuration, "globalEnabled", &enabled)) {
    if (callback) callback({});
    return;
  }
  suspended_ = false;
  if (!enabled) {
    if (portal_activated_subscription_ != 0) {
      g_dbus_connection_signal_unsubscribe(bus_, portal_activated_subscription_);
      portal_activated_subscription_ = 0;
    }
    ClosePortalSession();
    if (callback) callback({});
    return;
  }
  if (IsX11()) {
    ConfigureX11(configuration, std::move(callback));
  } else {
    BeginPortalConfigure(configuration, std::move(callback));
  }
}

void LinuxGlobalShortcuts::ConfigureX11(FlValue* configuration,
                                         ConfigureCallback callback) {
  std::map<std::string, std::string> failures;

  FlValue* bindings = fl_value_lookup_string(configuration, "global");
  if (bindings == nullptr || fl_value_get_type(bindings) != FL_VALUE_TYPE_MAP) {
    if (callback) callback(std::move(failures));
    return;
  }
  for (size_t i = 0; i < fl_value_get_length(bindings); ++i) {
    FlValue* action_value = fl_value_get_map_key(bindings, i);
    FlValue* binding = fl_value_get_map_value(bindings, i);
    const std::string action = ReadString(action_value);
    if (binding == nullptr || fl_value_get_type(binding) == FL_VALUE_TYPE_NULL) {
      continue;
    }
    FlValue* key_value = fl_value_lookup_string(binding, "key");
    if (key_value == nullptr || fl_value_get_type(key_value) != FL_VALUE_TYPE_INT) {
      failures[action] = "controls.unsupportedBinding";
      continue;
    }
    const guint evdev = EvdevCode(fl_value_get_int(key_value));
    if (evdev == 0) {
      failures[action] = "controls.unsupportedBinding";
      continue;
    }
    bool meta = false, control = false, alt = false, shift = false;
    if (!ReadBool(binding, "meta", &meta) || !ReadBool(binding, "control", &control) ||
        !ReadBool(binding, "alt", &alt) || !ReadBool(binding, "shift", &shift)) {
      failures[action] = "controls.unsupportedBinding";
      continue;
    }
    guint modifiers = (meta ? Mod4Mask : 0) | (control ? ControlMask : 0) |
                      (alt ? Mod1Mask : 0) | (shift ? ShiftMask : 0);
    const guint keycode = evdev + 8;
    if (!Register({keycode, modifiers, action})) {
      failures[action] = "controls.occupied";
    }
  }
  if (callback) callback(std::move(failures));
}

void LinuxGlobalShortcuts::BeginPortalConfigure(
    FlValue* configuration, ConfigureCallback callback) {
  ClosePortalSession();
  if (portal_activated_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, portal_activated_subscription_);
    portal_activated_subscription_ = 0;
  }
  // A fresh connection lets Registry.Register precede every other portal call,
  // even when GTK or another plugin has already used the shared session bus.
  g_clear_object(&bus_);
  g_autofree gchar* address =
      g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (address != nullptr) {
    bus_ = g_dbus_connection_new_for_address_sync(
        address, static_cast<GDBusConnectionFlags>(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, nullptr);
  }
  std::map<std::string, std::string> failures;
  FlValue* bindings = fl_value_lookup_string(configuration, "global");
  if (bus_ == nullptr || bindings == nullptr ||
      fl_value_get_type(bindings) != FL_VALUE_TYPE_MAP) {
    for (size_t i = 0; bindings != nullptr &&
                        fl_value_get_type(bindings) == FL_VALUE_TYPE_MAP &&
                        i < fl_value_get_length(bindings); ++i) {
      FlValue* key = fl_value_get_map_key(bindings, i);
      FlValue* value = fl_value_get_map_value(bindings, i);
      if (value != nullptr && fl_value_get_type(value) != FL_VALUE_TYPE_NULL)
        failures[ReadString(key)] = "controls.unsupportedBinding";
    }
    if (callback) callback(std::move(failures));
    return;
  }
  auto* flow = new PortalFlow();
  flow->generation = ++portal_token_;
  flow->bus = G_DBUS_CONNECTION(g_object_ref(bus_));
  portal_flow_ = flow;
  flow->state = callback_state_;
  flow->callback = std::move(callback);
  flow->configuration = fl_value_ref(configuration);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_dbus_connection_call(bus_, "org.freedesktop.portal.Desktop",
      "/org/freedesktop/portal/desktop", "org.freedesktop.host.portal.Registry",
      "Register", g_variant_new("(s@a{sv})", kFideflowDesktopApplicationId,
                                g_variant_builder_end(&options)),
      G_VARIANT_TYPE("()"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      PortalRegistrationFinished, flow);
}

void LinuxGlobalShortcuts::PortalRegistrationFinished(
    GObject* object, GAsyncResult* result, gpointer data) {
  auto* flow = static_cast<PortalFlow*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(object), result, &error);
  auto* owner = flow->state->owner;
  if (owner == nullptr || owner->portal_flow_ != flow) {
    ReleasePortalFlow(flow);
    return;
  }
  // Older portals lack Registry. Preserve their automatic app detection;
  // registration failures on supporting portals must not bind to a wrong app.
  const bool unsupported = g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD) ||
                           g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_INTERFACE);
  if (reply == nullptr && !unsupported) {
    g_warning("Fideflow: portal application registration failed: %s",
              error != nullptr ? error->message : "unknown error");
    FailPortalFlow(flow);
    ReleasePortalFlow(flow);
    return;
  }
  owner->CreatePortalSession(flow);  // Transfer the async-call reference.
}

void LinuxGlobalShortcuts::CreatePortalSession(PortalFlow* flow) {
  flow->token = "fideflow_" + std::to_string(flow->generation);
  const gchar* unique_name = g_dbus_connection_get_unique_name(bus_);
  gchar* sender = g_strdup(unique_name != nullptr ? unique_name + 1 : "");
  for (gchar* c = sender; *c != '\0'; ++c) {
    if (*c == '.') *c = '_';
  }
  flow->request_path = std::string("/org/freedesktop/portal/desktop/request/") +
                       sender + "/" + flow->token;
  g_free(sender);
  flow->signal_id = g_dbus_connection_signal_subscribe(
      bus_, "org.freedesktop.portal.Desktop",
      "org.freedesktop.portal.Request", "Response", flow->request_path.c_str(),
      nullptr, G_DBUS_SIGNAL_FLAGS_NONE, PortalRequestSignal, flow, nullptr);
  ++flow->references;  // The response signal and method reply each own one.
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(flow->token.c_str()));
  const std::string session_token = flow->token + "_session";
  g_variant_builder_add(&options, "{sv}", "session_handle_token",
                        g_variant_new_string(session_token.c_str()));
  g_dbus_connection_call(bus_, "org.freedesktop.portal.Desktop",
      "/org/freedesktop/portal/desktop", "org.freedesktop.portal.GlobalShortcuts",
      "CreateSession", g_variant_new("(@a{sv})", g_variant_builder_end(&options)), G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, PortalCallFinished, flow);
}

void LinuxGlobalShortcuts::PortalCallFinished(GObject* object,
                                               GAsyncResult* result,
                                               gpointer data) {
  auto* flow = static_cast<PortalFlow*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(object), result, &error);
  if (reply != nullptr) {
    ReleasePortalFlow(flow);
    return;  // Request.Response completes the operation.
  }
  auto* owner = flow->state->owner;
  if (owner != nullptr) {
    if (flow->signal_id != 0) {
      g_dbus_connection_signal_unsubscribe(owner->bus_, flow->signal_id);
      flow->signal_id = 0;
      ReleasePortalFlow(flow);  // The response signal will not arrive now.
    }
    FailPortalFlow(flow);
  }
  ReleasePortalFlow(flow);
}

void LinuxGlobalShortcuts::FailPortalFlow(PortalFlow* flow) {
  auto* owner = flow->state->owner;
  if (owner == nullptr || owner->portal_flow_ != flow || !flow->callback) return;
  std::map<std::string, std::string> failures;
  FlValue* bindings = fl_value_lookup_string(flow->configuration, "global");
  for (size_t i = 0; bindings != nullptr &&
                      fl_value_get_type(bindings) == FL_VALUE_TYPE_MAP &&
                      i < fl_value_get_length(bindings); ++i) {
    FlValue* key = fl_value_get_map_key(bindings, i);
    FlValue* value = fl_value_get_map_value(bindings, i);
    if (value != nullptr && fl_value_get_type(value) != FL_VALUE_TYPE_NULL)
      failures[ReadString(key)] = "controls.registration";
  }
  auto callback = std::move(flow->callback);
  owner->portal_flow_ = nullptr;
  callback(std::move(failures));
}

void LinuxGlobalShortcuts::ReleasePortalFlow(PortalFlow* flow) {
  if (--flow->references != 0) return;
  if (flow->configuration != nullptr) fl_value_unref(flow->configuration);
  g_clear_object(&flow->bus);
  delete flow;
}

void LinuxGlobalShortcuts::PortalRequestSignal(
    GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
    GVariant* parameters, gpointer data) {
  auto* flow = static_cast<PortalFlow*>(data);
  auto* owner = flow->state->owner;
  if (owner == nullptr) {
    if (flow->signal_id != 0)
      g_dbus_connection_signal_unsubscribe(flow->bus, flow->signal_id);
    flow->signal_id = 0;
    ReleasePortalFlow(flow);
    return;
  }
  if (owner->portal_flow_ != flow || flow->generation != owner->portal_token_) {
    if (flow->signal_id != 0) {
      g_dbus_connection_signal_unsubscribe(owner->bus_, flow->signal_id);
      flow->signal_id = 0;
    }
    ReleasePortalFlow(flow);
    return;
  }
  guint32 status = 1;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &status, &results);
  if (flow->signal_id != 0) {
    g_dbus_connection_signal_unsubscribe(owner->bus_, flow->signal_id);
    flow->signal_id = 0;
  }
  if (!flow->binding && status == 0) {
    // The portal specification keeps this result as a string for backwards
    // compatibility, even though it contains an object path. Accept an object
    // path value too for older portal implementations that use the input type.
    GVariant* session_value =
        g_variant_lookup_value(results, "session_handle", nullptr);
    const GVariantType* session_type =
        session_value != nullptr ? g_variant_get_type(session_value) : nullptr;
    if (session_type != nullptr &&
        (g_variant_type_equal(session_type, G_VARIANT_TYPE_STRING) ||
         g_variant_type_equal(session_type, G_VARIANT_TYPE_OBJECT_PATH))) {
      const gchar* session = g_variant_get_string(session_value, nullptr);
      if (g_variant_is_object_path(session)) {
        owner->portal_session_ = session;
        owner->portal_session_closed_subscription_ =
            g_dbus_connection_signal_subscribe(
                owner->bus_, "org.freedesktop.portal.Desktop",
                "org.freedesktop.portal.Session", "Closed", session, nullptr,
                G_DBUS_SIGNAL_FLAGS_NONE, PortalSessionClosed,
                owner->callback_state_.get(), nullptr);
        owner->BindPortalShortcuts(flow->session = session,
                                   flow->configuration,
                                   std::move(flow->callback));
        flow->callback = nullptr;
        flow->binding = true;
        g_variant_unref(results);
        g_variant_unref(session_value);
        ReleasePortalFlow(flow);
        return;
      }
    }
    if (session_value != nullptr) g_variant_unref(session_value);
  }
  std::map<std::string, std::string> failures;
  FlValue* bindings = fl_value_lookup_string(flow->configuration, "global");
  if (!(flow->binding && status == 0)) {
    for (size_t i = 0; bindings != nullptr &&
                        fl_value_get_type(bindings) == FL_VALUE_TYPE_MAP &&
                        i < fl_value_get_length(bindings); ++i) {
      FlValue* key = fl_value_get_map_key(bindings, i);
      FlValue* value = fl_value_get_map_value(bindings, i);
      if (value != nullptr && fl_value_get_type(value) != FL_VALUE_TYPE_NULL)
        failures[ReadString(key)] = "controls.registration";
    }
  } else {
    GVariant* accepted = nullptr;
    std::set<std::string> accepted_actions;
    if (g_variant_lookup(results, "shortcuts", "@a(sa{sv})", &accepted)) {
      GVariantIter iter;
      const gchar* action = nullptr;
      GVariant* properties = nullptr;
      g_variant_iter_init(&iter, accepted);
      while (g_variant_iter_next(&iter, "(&s@a{sv})", &action, &properties)) {
        FlValue* binding = fl_value_lookup_string(bindings, action);
        // The portal returns the bound subset and a human-readable
        // trigger_description. The requested preferred_trigger is only a
        // suggestion, so its display string cannot be compared to a machine
        // trigger or used to reject a compositor-selected assignment.
        if (binding != nullptr &&
            fl_value_get_type(binding) != FL_VALUE_TYPE_NULL &&
            flow->failures.count(action) == 0) {
          accepted_actions.insert(action);
          owner->portal_actions_.insert(action);
        }
        g_variant_unref(properties);
      }
      g_variant_unref(accepted);
    }
    for (size_t i = 0; bindings != nullptr &&
                        fl_value_get_type(bindings) == FL_VALUE_TYPE_MAP &&
                        i < fl_value_get_length(bindings); ++i) {
      FlValue* key = fl_value_get_map_key(bindings, i);
      FlValue* binding = fl_value_get_map_value(bindings, i);
      const std::string action = ReadString(key);
      if (binding != nullptr && fl_value_get_type(binding) != FL_VALUE_TYPE_NULL &&
          accepted_actions.count(action) == 0 &&
          flow->failures.count(action) == 0) {
        failures[action] = "controls.registration";
      }
    }
  }
  auto callback = std::move(flow->callback);
  for (const auto& failure : flow->failures)
    failures[failure.first] = failure.second;
  owner->portal_flow_ = nullptr;
  if (callback) callback(std::move(failures));
  g_variant_unref(results);
  ReleasePortalFlow(flow);
}

void LinuxGlobalShortcuts::BindPortalShortcuts(
    std::string session, FlValue* configuration, ConfigureCallback callback) {
  auto* flow = new PortalFlow();
  flow->generation = ++portal_token_;
  flow->bus = G_DBUS_CONNECTION(g_object_ref(bus_));
  portal_flow_ = flow;
  flow->state = callback_state_;
  flow->callback = std::move(callback);
  flow->configuration = fl_value_ref(configuration);
  flow->session = session;
  flow->binding = true;
  flow->token = "fideflow_bind_" + std::to_string(flow->generation);
  const gchar* unique_name = g_dbus_connection_get_unique_name(bus_);
  gchar* sender = g_strdup(unique_name != nullptr ? unique_name + 1 : "");
  for (gchar* c = sender; *c != '\0'; ++c) {
    if (*c == '.') *c = '_';
  }
  flow->request_path = std::string("/org/freedesktop/portal/desktop/request/") +
                       sender + "/" + flow->token;
  g_free(sender);
  flow->signal_id = g_dbus_connection_signal_subscribe(
      bus_, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
      "Response", flow->request_path.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      PortalRequestSignal, flow, nullptr);
  ++flow->references;
  if (portal_activated_subscription_ != 0)
    g_dbus_connection_signal_unsubscribe(bus_, portal_activated_subscription_);
  portal_activated_subscription_ = g_dbus_connection_signal_subscribe(
      bus_, "org.freedesktop.portal.Desktop",
      "org.freedesktop.portal.GlobalShortcuts", "Activated",
      "/org/freedesktop/portal/desktop", nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      PortalActivated, callback_state_.get(), nullptr);
  portal_actions_.clear();
  GVariantBuilder shortcut_list;
  g_variant_builder_init(&shortcut_list, G_VARIANT_TYPE("a(sa{sv})"));
  FlValue* bindings = fl_value_lookup_string(configuration, "global");
  for (size_t i = 0; bindings != nullptr &&
                      fl_value_get_type(bindings) == FL_VALUE_TYPE_MAP &&
                      i < fl_value_get_length(bindings); ++i) {
    FlValue* key = fl_value_get_map_key(bindings, i);
    FlValue* binding = fl_value_get_map_value(bindings, i);
    if (binding == nullptr || fl_value_get_type(binding) == FL_VALUE_TYPE_NULL) continue;
    const std::string action = ReadString(key);
    const std::string trigger = PortalTrigger(binding);
    if (trigger.empty()) {
      flow->failures[action] = "controls.unsupportedBinding";
      continue;
    }
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    const std::string description = "Fideflow " + action;
    g_variant_builder_add(&properties, "{sv}", "description",
                          g_variant_new_string(description.c_str()));
    g_variant_builder_add(&properties, "{sv}", "preferred_trigger",
                          g_variant_new_string(trigger.c_str()));
    g_variant_builder_add(&shortcut_list, "(s@a{sv})", action.c_str(),
                          g_variant_builder_end(&properties));
  }
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(flow->token.c_str()));
  g_dbus_connection_call(bus_, "org.freedesktop.portal.Desktop",
      "/org/freedesktop/portal/desktop", "org.freedesktop.portal.GlobalShortcuts",
      "BindShortcuts",
      g_variant_new("(o@a(sa{sv})s@a{sv})", session.c_str(),
          g_variant_builder_end(&shortcut_list), "",
          g_variant_builder_end(&options)), G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, PortalCallFinished, flow);
}

void LinuxGlobalShortcuts::PortalActivated(
    GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
    GVariant* parameters, gpointer data) {
  auto* state = static_cast<CallbackState*>(data);
  if (state == nullptr || state->owner == nullptr) return;
  const gchar* session = nullptr;
  const gchar* shortcut = nullptr;
  guint64 timestamp = 0;
  GVariant* options = nullptr;
  g_variant_get(parameters, "(&o&st@a{sv})", &session, &shortcut, &timestamp,
                &options);
  if (options != nullptr) g_variant_unref(options);
  (void)timestamp;
  if (state->owner->portal_session_ == session && !state->owner->suspended_ &&
      state->owner->portal_actions_.count(shortcut) != 0 &&
      state->owner->on_action_)
    state->owner->on_action_(shortcut);
}

void LinuxGlobalShortcuts::PortalSessionClosed(
    GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
    GVariant*, gpointer data) {
  auto* state = static_cast<CallbackState*>(data);
  if (state == nullptr || state->owner == nullptr) return;
  auto* owner = state->owner;
  owner->portal_session_.clear();
  owner->portal_actions_.clear();
  if (owner->portal_activated_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(owner->bus_,
                                         owner->portal_activated_subscription_);
    owner->portal_activated_subscription_ = 0;
  }
  if (owner->portal_session_closed_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(
        owner->bus_, owner->portal_session_closed_subscription_);
    owner->portal_session_closed_subscription_ = 0;
  }
  if (owner->on_error_) owner->on_error_("controls.registration");
}

bool LinuxGlobalShortcuts::Register(const Grab& grab) {
#ifdef GDK_WINDOWING_X11
  if (!IsX11() || suspended_) return false;
  Display* xdisplay = gdk_x11_display_get_xdisplay(display_);
  Window root = DefaultRootWindow(xdisplay);
  const guint lock_masks[] = {0, LockMask, numlock_mask_, LockMask | numlock_mask_};
  bool success = true;
  for (guint lock : lock_masks) {
    gdk_x11_display_error_trap_push(display_);
    XGrabKey(xdisplay, grab.keycode, grab.modifiers | lock, root, True,
             GrabModeAsync, GrabModeAsync);
    XSync(xdisplay, False);
    const gint error = gdk_x11_display_error_trap_pop(display_);
    if (error != 0) {
      success = false;
      break;
    }
  }
  if (!success) {
    for (guint lock : lock_masks) {
      XUngrabKey(xdisplay, grab.keycode, grab.modifiers | lock, root);
    }
    XSync(xdisplay, False);
    return false;
  }
  grabs_.push_back(grab);
  if (!filter_installed_) {
    gdk_window_add_filter(nullptr, Filter, this);
    filter_installed_ = true;
  }
  return true;
#else
  (void)grab;
  return false;
#endif
}

GdkFilterReturn LinuxGlobalShortcuts::Filter(GdkXEvent* xevent, GdkEvent*,
                                             gpointer user_data) {
#ifdef GDK_WINDOWING_X11
  auto* self = static_cast<LinuxGlobalShortcuts*>(user_data);
  if (self == nullptr || self->disposed_ || self->suspended_ || xevent == nullptr) {
    return GDK_FILTER_CONTINUE;
  }
  auto* event = static_cast<XEvent*>(xevent);
  if (event->type == KeyRelease) {
    self->pressed_keycodes_.erase(event->xkey.keycode);
    return GDK_FILTER_CONTINUE;
  }
  if (event->type != KeyPress) return GDK_FILTER_CONTINUE;
  const guint state = event->xkey.state & ~(LockMask | self->numlock_mask_);
  for (const Grab& grab : self->grabs_) {
    if (event->xkey.keycode == grab.keycode && state == grab.modifiers) {
      if (!self->pressed_keycodes_.insert(grab.keycode).second)
        return GDK_FILTER_REMOVE;
      if (self->on_action_) self->on_action_(grab.action);
      return GDK_FILTER_REMOVE;
    }
  }
#else
  (void)xevent;
  (void)user_data;
#endif
  return GDK_FILTER_CONTINUE;
}

void LinuxGlobalShortcuts::UnregisterAll() {
#ifdef GDK_WINDOWING_X11
  if (IsX11() && !grabs_.empty()) {
    Display* xdisplay = gdk_x11_display_get_xdisplay(display_);
    Window root = DefaultRootWindow(xdisplay);
    for (const Grab& grab : grabs_) {
      for (guint lock : {0u, static_cast<guint>(LockMask),
                         numlock_mask_, static_cast<guint>(LockMask | numlock_mask_)}) {
        XUngrabKey(xdisplay, grab.keycode, grab.modifiers | lock, root);
      }
    }
    XSync(xdisplay, False);
  }
#endif
  grabs_.clear();
  pressed_keycodes_.clear();
  if (filter_installed_) {
    gdk_window_remove_filter(nullptr, Filter, this);
    filter_installed_ = false;
  }
}

void LinuxGlobalShortcuts::Suspend(bool suspended) {
  if (disposed_ || suspended_ == suspended) return;
  suspended_ = suspended;
  if (suspended_) {
    CancelPortalFlow();
    UnregisterAll();
    if (portal_activated_subscription_ != 0 && bus_ != nullptr) {
      g_dbus_connection_signal_unsubscribe(bus_, portal_activated_subscription_);
      portal_activated_subscription_ = 0;
    }
    ClosePortalSession();
  } else if (configuration_ != nullptr) {
    Configure(configuration_, [this](std::map<std::string, std::string> failures) {
      if (!failures.empty() && on_error_) on_error_("controls.registration");
    });
  }
  // Re-grabbing requires the latest configuration. The owning controls layer
  // calls Configure after resume so it can surface individual failures.
}

void LinuxGlobalShortcuts::Dispose() {
  if (disposed_) return;
  disposed_ = true;
  callback_state_->owner = nullptr;
  UnregisterAll();
  if (bus_ != nullptr && portal_activated_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, portal_activated_subscription_);
    portal_activated_subscription_ = 0;
  }
  ClosePortalSession();
  CancelPortalFlow();
  if (configuration_ != nullptr) {
    fl_value_unref(configuration_);
    configuration_ = nullptr;
  }
  if (window_ != nullptr) {
    g_object_unref(window_);
    window_ = nullptr;
  }
  g_clear_object(&bus_);
}

void LinuxGlobalShortcuts::CancelPortalFlow() {
  if (portal_flow_ == nullptr) return;
  PortalFlow* flow = portal_flow_;
  portal_flow_ = nullptr;
  // Keep the flow alive through the completion callback, even if the method
  // reply has already released its reference or the callback pumps the loop.
  ++flow->references;
  if (flow->signal_id != 0) {
    g_dbus_connection_signal_unsubscribe(flow->bus, flow->signal_id);
    flow->signal_id = 0;
    ReleasePortalFlow(flow);  // Drop the response-signal reference.
  }
  if (flow->callback) {
    std::map<std::string, std::string> failures;
    FlValue* bindings = fl_value_lookup_string(flow->configuration, "global");
    for (size_t i = 0; bindings != nullptr &&
                        fl_value_get_type(bindings) == FL_VALUE_TYPE_MAP &&
                        i < fl_value_get_length(bindings); ++i) {
      FlValue* key = fl_value_get_map_key(bindings, i);
      FlValue* value = fl_value_get_map_value(bindings, i);
      if (value != nullptr && fl_value_get_type(value) != FL_VALUE_TYPE_NULL)
        failures[ReadString(key)] = "controls.registration";
    }
    auto callback = std::move(flow->callback);
    callback(std::move(failures));
  }
  ReleasePortalFlow(flow);
}

void LinuxGlobalShortcuts::ClosePortalSession() {
  if (portal_session_closed_subscription_ != 0 && bus_ != nullptr) {
    g_dbus_connection_signal_unsubscribe(bus_,
                                         portal_session_closed_subscription_);
    portal_session_closed_subscription_ = 0;
  }
  if (bus_ != nullptr && !portal_session_.empty()) {
    const std::string session = portal_session_;
    g_dbus_connection_call(bus_, "org.freedesktop.portal.Desktop",
        session.c_str(), "org.freedesktop.portal.Session",
        "Close", g_variant_new("()"), nullptr, G_DBUS_CALL_FLAGS_NONE, -1,
        nullptr, nullptr, nullptr);
    portal_session_.clear();
  }
  portal_actions_.clear();
}
