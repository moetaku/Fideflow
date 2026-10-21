// Standalone fake StatusNotifierWatcher for isolated D-Bus acceptance tests.
// Build with: c++ linux_status_notifier_probe.cc $(pkg-config --cflags --libs gio-2.0) -o probe
#include <gio/gio.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr char kWatcherName[] = "org.kde.StatusNotifierWatcher";
constexpr char kWatcherPath[] = "/StatusNotifierWatcher";
constexpr char kWatcherInterface[] = "org.kde.StatusNotifierWatcher";
constexpr char kTestInterface[] = "org.fideflow.TestStatusNotifierWatcher";

const char kXml[] = R"XML(
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <method name="UnregisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
    <signal name="StatusNotifierHostUnregistered"/>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
  </interface>
  <interface name="org.fideflow.TestStatusNotifierWatcher">
    <method name="SetHost"><arg type="b" direction="in"/></method>
    <method name="Quit"/>
  </interface>
</node>
)XML";

class Watcher final {
 public:
  explicit Watcher(bool host) : host_registered_(host) {}

  bool Start() {
    GError* error = nullptr;
    connection_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (connection_ == nullptr) {
      PrintError("Could not connect to session bus", error);
      return false;
    }
    node_ = g_dbus_node_info_new_for_xml(kXml, &error);
    if (node_ == nullptr) {
      PrintError("Could not parse watcher interface", error);
      return false;
    }
    for (guint i = 0; node_->interfaces[i] != nullptr; ++i) {
      const guint id = g_dbus_connection_register_object(
          connection_, kWatcherPath, node_->interfaces[i], &VTable(), this,
          nullptr, &error);
      if (id == 0) {
        PrintError("Could not export watcher interface", error);
        return false;
      }
      object_ids_.push_back(id);
    }
    loop_ = g_main_loop_new(nullptr, FALSE);
    name_owner_id_ = g_bus_own_name_on_connection(
        connection_, kWatcherName, G_BUS_NAME_OWNER_FLAGS_NONE, &NameAcquired,
        &NameLost, this, nullptr);
    g_main_loop_run(loop_);
    return true;
  }

  ~Watcher() {
    if (name_owner_id_ != 0) g_bus_unown_name(name_owner_id_);
    for (guint id : object_ids_) {
      g_dbus_connection_unregister_object(connection_, id);
    }
    if (loop_ != nullptr) g_main_loop_unref(loop_);
    if (node_ != nullptr) g_dbus_node_info_unref(node_);
    if (connection_ != nullptr) g_object_unref(connection_);
  }

 private:
  static const GDBusInterfaceVTable& VTable() {
    static const GDBusInterfaceVTable vtable = {
        &MethodCall, &GetProperty, nullptr, {nullptr}};
    return vtable;
  }

  static void PrintError(const char* message, GError* error) {
    std::fprintf(stderr, "%s: %s\n", message,
                 error == nullptr ? "unknown error" : error->message);
    if (error != nullptr) g_error_free(error);
  }

  static void NameAcquired(GDBusConnection*, const gchar*, gpointer) {
    std::fprintf(stdout, "WATCHER_READY name=%s\n", kWatcherName);
    std::fflush(stdout);
  }

  static void NameLost(GDBusConnection*, const gchar*, gpointer data) {
    auto* self = static_cast<Watcher*>(data);
    std::fprintf(stderr, "WATCHER_NAME_LOST name=%s\n", kWatcherName);
    if (self->loop_ != nullptr) g_main_loop_quit(self->loop_);
  }

  static void MethodCall(GDBusConnection*, const gchar* sender, const gchar*,
                         const gchar* interface_name, const gchar* method,
                         GVariant* parameters,
                         GDBusMethodInvocation* invocation, gpointer data) {
    auto* self = static_cast<Watcher*>(data);
    if (g_strcmp0(interface_name, kWatcherInterface) == 0) {
      if (g_strcmp0(method, "RegisterStatusNotifierItem") == 0) {
        const gchar* service = nullptr;
        g_variant_get(parameters, "(&s)", &service);
        // Watchers expose service + object path even when registration only
        // supplies a bus name (the protocol's default object path applies).
        const std::string address = service[0] == '/'
            ? std::string(sender) + service
            : std::string(service) + "/StatusNotifierItem";
        if (std::find(self->items_.begin(), self->items_.end(), address) ==
            self->items_.end()) {
          self->items_.push_back(address);
        }
        g_dbus_method_invocation_return_value(invocation, nullptr);
        self->EmitItemSignal("StatusNotifierItemRegistered", address.c_str());
        self->EmitPropertiesChanged("RegisteredStatusNotifierItems");
        return;
      }
      if (g_strcmp0(method, "RegisterStatusNotifierHost") == 0) {
        self->SetHost(true);
        g_dbus_method_invocation_return_value(invocation, nullptr);
        return;
      }
      if (g_strcmp0(method, "UnregisterStatusNotifierItem") == 0) {
        const gchar* service = nullptr;
        g_variant_get(parameters, "(&s)", &service);
        self->items_.erase(
            std::remove(self->items_.begin(), self->items_.end(), service),
            self->items_.end());
        g_dbus_method_invocation_return_value(invocation, nullptr);
        self->EmitItemSignal("StatusNotifierItemUnregistered", service);
        self->EmitPropertiesChanged("RegisteredStatusNotifierItems");
        return;
      }
    }
    if (g_strcmp0(interface_name, kTestInterface) == 0) {
      if (g_strcmp0(method, "SetHost") == 0) {
        gboolean host = FALSE;
        g_variant_get(parameters, "(b)", &host);
        self->SetHost(host);
        g_dbus_method_invocation_return_value(invocation, nullptr);
        return;
      }
      if (g_strcmp0(method, "Quit") == 0) {
        g_dbus_method_invocation_return_value(invocation, nullptr);
        g_main_loop_quit(self->loop_);
        return;
      }
    }
    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown fake watcher method");
  }

  static GVariant* GetProperty(GDBusConnection*, const gchar*, const gchar*,
                               const gchar* interface_name,
                               const gchar* property, GError** error,
                               gpointer data) {
    auto* self = static_cast<Watcher*>(data);
    if (g_strcmp0(interface_name, kWatcherInterface) == 0 &&
        g_strcmp0(property, "IsStatusNotifierHostRegistered") == 0) {
      return g_variant_new_boolean(self->host_registered_);
    }
    if (g_strcmp0(interface_name, kWatcherInterface) == 0 &&
        g_strcmp0(property, "ProtocolVersion") == 0) {
      return g_variant_new_int32(0);
    }
    if (g_strcmp0(interface_name, kWatcherInterface) == 0 &&
        g_strcmp0(property, "RegisteredStatusNotifierItems") == 0) {
      GVariantBuilder items;
      g_variant_builder_init(&items, G_VARIANT_TYPE("as"));
      for (const auto& item : self->items_) {
        g_variant_builder_add(&items, "s", item.c_str());
      }
      return g_variant_builder_end(&items);
    }
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                "Unknown fake watcher property");
    return nullptr;
  }

  void SetHost(bool value) {
    if (value == host_registered_) return;
    host_registered_ = value;
    EmitPropertiesChanged("IsStatusNotifierHostRegistered");
    g_dbus_connection_emit_signal(
        connection_, nullptr, kWatcherPath, kWatcherInterface,
        host_registered_ ? "StatusNotifierHostRegistered"
                         : "StatusNotifierHostUnregistered",
        nullptr, nullptr);
  }

  void EmitPropertiesChanged(const char* property) {
    GVariantBuilder changed;
    GVariantBuilder invalidated;
    g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_init(&invalidated, G_VARIANT_TYPE("as"));
    if (g_strcmp0(property, "RegisteredStatusNotifierItems") == 0) {
      GVariantBuilder items;
      g_variant_builder_init(&items, G_VARIANT_TYPE("as"));
      for (const auto& item : items_) {
        g_variant_builder_add(&items, "s", item.c_str());
      }
      g_variant_builder_add(&changed, "{sv}", property,
                            g_variant_builder_end(&items));
    } else {
      g_variant_builder_add(&changed, "{sv}", property,
                            g_variant_new_boolean(host_registered_));
    }
    g_dbus_connection_emit_signal(
        connection_, nullptr, kWatcherPath, "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        g_variant_new("(s@a{sv}@as)", kWatcherInterface,
                      g_variant_builder_end(&changed),
                      g_variant_builder_end(&invalidated)),
        nullptr);
  }

  void EmitItemSignal(const char* signal, const char* service) {
    g_dbus_connection_emit_signal(
        connection_, nullptr, kWatcherPath, kWatcherInterface, signal,
        g_variant_new("(s)", service), nullptr);
  }

  GDBusConnection* connection_ = nullptr;
  GDBusNodeInfo* node_ = nullptr;
  GMainLoop* loop_ = nullptr;
  guint name_owner_id_ = 0;
  std::vector<guint> object_ids_;
  std::vector<std::string> items_;
  bool host_registered_;
};

}  // namespace

int main(int argc, char** argv) {
  bool watcher_only = false;
  bool start_without_host = false;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--watcher-only") == 0) watcher_only = true;
    if (std::strcmp(argv[i], "--no-host") == 0) start_without_host = true;
  }
  if (!watcher_only) {
    std::fprintf(stderr, "Usage: %s --watcher-only [--no-host]\n", argv[0]);
    return 2;
  }
  Watcher watcher(!start_without_host);
  return watcher.Start() ? 0 : 1;
}
