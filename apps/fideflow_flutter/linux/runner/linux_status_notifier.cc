#include "linux_status_notifier.h"

#include <gio/gio.h>

#include <array>
#include <memory>
#include <string>

namespace {

constexpr char kWatcherName[] = "org.kde.StatusNotifierWatcher";
constexpr char kWatcherPath[] = "/StatusNotifierWatcher";
constexpr char kWatcherInterface[] = "org.kde.StatusNotifierWatcher";
constexpr char kItemPath[] = "/StatusNotifierItem";
constexpr char kMenuPath[] = "/MenuBar";

const char kItemXml[] = R"XML(
<node>
  <interface name="org.kde.StatusNotifierItem">
    <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="u" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
  </interface>
</node>
)XML";

const char kMenuXml[] = R"XML(
<node>
  <interface name="com.canonical.dbusmenu">
    <method name="GetLayout">
      <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
      <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/>
    </method>
    <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
    <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
    <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
  </interface>
</node>
)XML";

using SharedImpl = std::shared_ptr<LinuxStatusNotifier::Impl>;

void delete_shared_impl(gpointer data) {
  delete static_cast<SharedImpl*>(data);
}

GVariant* fallback_pixmaps() {
  constexpr gint32 kSize = 32;
  std::array<guchar, kSize * kSize * 4> pixels{};
  const auto put = [&pixels](gint32 x, gint32 y) {
    const size_t offset = static_cast<size_t>((y * kSize + x) * 4);
    // A cyan music note in ARGB, visible on dark and light tray backgrounds.
    pixels[offset] = 0xff;
    pixels[offset + 1] = 0x20;
    pixels[offset + 2] = 0xc8;
    pixels[offset + 3] = 0xff;
  };
  for (gint32 y = 5; y < 23; ++y) {
    put(20, y);
    put(21, y);
  }
  for (gint32 step = 0; step < 7; ++step) {
    for (gint32 thickness = 0; thickness < 2; ++thickness) {
      put(20 + step, 5 + step / 2 + thickness);
    }
  }
  for (gint32 y = 20; y <= 25; ++y) {
    for (gint32 x = 9; x <= 17; ++x) {
      const gint32 dx = x - 13;
      const gint32 dy = y - 22;
      if (dx * dx + dy * dy <= 16) put(x, y);
    }
  }
  for (gint32 y = 17; y <= 22; ++y) {
    for (gint32 x = 18; x <= 26; ++x) {
      const gint32 dx = x - 22;
      const gint32 dy = y - 19;
      if (dx * dx + dy * dy <= 16) put(x, y);
    }
  }

  GVariantBuilder images;
  GVariantBuilder bytes;
  g_variant_builder_init(&images, G_VARIANT_TYPE("a(iiay)"));
  g_variant_builder_init(&bytes, G_VARIANT_TYPE("ay"));
  for (guchar pixel : pixels) g_variant_builder_add(&bytes, "y", pixel);
  g_variant_builder_add(&images, "(ii@ay)", kSize, kSize,
                        g_variant_builder_end(&bytes));
  return g_variant_builder_end(&images);
}

GVariant* application_pixmaps() {
  g_autofree gchar* executable_path =
      g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path == nullptr) return fallback_pixmaps();

  g_autofree gchar* executable_dir = g_path_get_dirname(executable_path);
  g_autofree gchar* icon_path =
      g_build_filename(executable_dir, "fideflow.png", nullptr);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkPixbuf) source = gdk_pixbuf_new_from_file(icon_path, &error);
  if (source == nullptr) {
    g_debug("Unable to load Fideflow tray icon from %s: %s", icon_path,
            error != nullptr ? error->message : "unknown error");
    return fallback_pixmaps();
  }

  constexpr gint32 kSize = 32;
  g_autoptr(GdkPixbuf) scaled =
      gdk_pixbuf_scale_simple(source, kSize, kSize, GDK_INTERP_BILINEAR);
  if (scaled == nullptr) return fallback_pixmaps();

  const guchar* pixels = gdk_pixbuf_read_pixels(scaled);
  const gint rowstride = gdk_pixbuf_get_rowstride(scaled);
  const gint channels = gdk_pixbuf_get_n_channels(scaled);
  const gboolean has_alpha = gdk_pixbuf_get_has_alpha(scaled);

  GVariantBuilder images;
  GVariantBuilder bytes;
  g_variant_builder_init(&images, G_VARIANT_TYPE("a(iiay)"));
  g_variant_builder_init(&bytes, G_VARIANT_TYPE("ay"));
  for (gint32 y = 0; y < kSize; ++y) {
    for (gint32 x = 0; x < kSize; ++x) {
      const guchar* pixel = pixels + y * rowstride + x * channels;
      const guchar alpha = has_alpha ? pixel[3] : 0xff;
      // StatusNotifierItem pixmaps use ARGB byte order.
      g_variant_builder_add(&bytes, "y", alpha);
      g_variant_builder_add(&bytes, "y", pixel[0]);
      g_variant_builder_add(&bytes, "y", pixel[1]);
      g_variant_builder_add(&bytes, "y", pixel[2]);
    }
  }
  g_variant_builder_add(&images, "(ii@ay)", kSize, kSize,
                        g_variant_builder_end(&bytes));
  return g_variant_builder_end(&images);
}

GVariant* empty_pixmaps() {
  return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0);
}

GVariant* menu_properties(const char* label) {
  GVariantBuilder properties;
  g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(label));
  g_variant_builder_add(&properties, "{sv}", "enabled", g_variant_new_boolean(TRUE));
  g_variant_builder_add(&properties, "{sv}", "visible", g_variant_new_boolean(TRUE));
  g_variant_builder_add(&properties, "{sv}", "children-display",
                        g_variant_new_string(label[0] == '\0' ? "submenu" : ""));
  return g_variant_builder_end(&properties);
}

GVariant* create_menu_node(gint32 id, const char* label) {
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  return g_variant_new("(i@a{sv}@av)", id, menu_properties(label),
                       g_variant_builder_end(&children));
}

}  // namespace

struct LinuxStatusNotifier::Impl final {
  explicit Impl(GtkWindow* native_window, Callback activate, Callback quit,
                CapabilityCallback capability)
      : window(native_window == nullptr
                   ? nullptr
                   : GTK_WINDOW(g_object_ref(native_window))),
        on_activate(std::move(activate)),
        on_quit(std::move(quit)),
        on_capability(std::move(capability)) {}

  ~Impl() {
    Stop();
    if (window != nullptr) g_object_unref(window);
  }

  GtkWindow* window = nullptr;
  Callback on_activate;
  Callback on_quit;
  CapabilityCallback on_capability;
  GDBusConnection* connection = nullptr;
  GCancellable* cancellable = nullptr;
  GDBusNodeInfo* item_node = nullptr;
  GDBusNodeInfo* menu_node = nullptr;
  guint item_object_id = 0;
  guint menu_object_id = 0;
  guint owner_watch_id = 0;
  guint properties_signal_id = 0;
  guint host_registered_signal_id = 0;
  guint host_unregistered_signal_id = 0;
  bool started = false;
  bool stopped = false;
  bool watcher_available = false;
  bool host_registered = false;
  bool item_registered = false;
  bool can_background = false;
  std::string unique_name;
  std::string watcher_owner;
  guint64 watcher_generation = 0;

  struct PendingCall {
    SharedImpl self;
    guint64 generation;
    std::string owner;
  };

  static const GDBusInterfaceVTable& ItemVTable() {
    static const GDBusInterfaceVTable vtable = {
        &HandleItemMethod, &GetItemProperty, nullptr, {nullptr}};
    return vtable;
  }

  static const GDBusInterfaceVTable& MenuVTable() {
    static const GDBusInterfaceVTable vtable = {
        &HandleMenuMethod, &GetMenuProperty, nullptr, {nullptr}};
    return vtable;
  }

  static Impl* From(gpointer data) { return static_cast<Impl*>(data); }

  void SetCapability(bool value, bool restore_window) {
    if (value == can_background) return;
    can_background = value;
    if (restore_window && !value && on_activate) on_activate();
    if (on_capability) on_capability(value);
  }

  void Start() {
    if (started || stopped) return;
    started = true;
    GError* error = nullptr;
    connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (connection == nullptr) {
      if (error != nullptr) g_error_free(error);
      SetCapability(false, false);
      return;
    }
    unique_name = g_dbus_connection_get_unique_name(connection);
    cancellable = g_cancellable_new();
    item_node = g_dbus_node_info_new_for_xml(kItemXml, &error);
    if (item_node == nullptr) {
      if (error != nullptr) g_error_free(error);
      Stop();
      return;
    }
    menu_node = g_dbus_node_info_new_for_xml(kMenuXml, &error);
    if (menu_node == nullptr) {
      if (error != nullptr) g_error_free(error);
      Stop();
      return;
    }
    item_object_id = g_dbus_connection_register_object(
        connection, kItemPath, item_node->interfaces[0], &ItemVTable(), this,
        nullptr, &error);
    if (item_object_id == 0) {
      if (error != nullptr) g_error_free(error);
      Stop();
      return;
    }
    menu_object_id = g_dbus_connection_register_object(
        connection, kMenuPath, menu_node->interfaces[0], &MenuVTable(), this,
        nullptr, &error);
    if (menu_object_id == 0) {
      if (error != nullptr) g_error_free(error);
      Stop();
      return;
    }

    properties_signal_id = g_dbus_connection_signal_subscribe(
        connection, kWatcherName, "org.freedesktop.DBus.Properties",
        "PropertiesChanged", kWatcherPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        &WatcherPropertiesChanged, new SharedImpl(shared_from_this()),
        delete_shared_impl);
    host_registered_signal_id = g_dbus_connection_signal_subscribe(
        connection, kWatcherName, kWatcherInterface,
        "StatusNotifierHostRegistered", kWatcherPath, nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE, &WatcherHostRegistered,
        new SharedImpl(shared_from_this()), delete_shared_impl);
    host_unregistered_signal_id = g_dbus_connection_signal_subscribe(
        connection, kWatcherName, kWatcherInterface,
        "StatusNotifierHostUnregistered", kWatcherPath, nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE, &WatcherHostUnregistered,
        new SharedImpl(shared_from_this()), delete_shared_impl);
    owner_watch_id = g_bus_watch_name_on_connection(
        connection, kWatcherName, G_BUS_NAME_WATCHER_FLAGS_NONE,
        &WatcherAppeared, &WatcherVanished,
        new SharedImpl(shared_from_this()), delete_shared_impl);
  }

  void Stop() {
    if (stopped) return;
    stopped = true;
    if (cancellable != nullptr) g_cancellable_cancel(cancellable);
    SetCapability(false, false);
    if (connection != nullptr) {
      if (owner_watch_id != 0) g_bus_unwatch_name(owner_watch_id);
      if (properties_signal_id != 0)
        g_dbus_connection_signal_unsubscribe(connection, properties_signal_id);
      if (host_registered_signal_id != 0)
        g_dbus_connection_signal_unsubscribe(connection, host_registered_signal_id);
      if (host_unregistered_signal_id != 0)
        g_dbus_connection_signal_unsubscribe(connection, host_unregistered_signal_id);
      if (item_object_id != 0)
        g_dbus_connection_unregister_object(connection, item_object_id);
      if (menu_object_id != 0)
        g_dbus_connection_unregister_object(connection, menu_object_id);
      g_object_unref(connection);
      connection = nullptr;
    }
    if (cancellable != nullptr) {
      g_object_unref(cancellable);
      cancellable = nullptr;
    }
    if (item_node != nullptr) {
      g_dbus_node_info_unref(item_node);
      item_node = nullptr;
    }
    if (menu_node != nullptr) {
      g_dbus_node_info_unref(menu_node);
      menu_node = nullptr;
    }
  }

  void SetHostRegistered(bool value) {
    if (stopped || !watcher_available || host_registered == value) return;
    host_registered = value;
    ++watcher_generation;
    if (!value) {
      item_registered = false;
      SetCapability(false, true);
      return;
    }
    RegisterItem();
  }

  void QueryHost() {
    if (stopped || !watcher_available || connection == nullptr ||
        watcher_owner.empty()) return;
    g_dbus_connection_call(
        connection, watcher_owner.c_str(), kWatcherPath,
        "org.freedesktop.DBus.Properties", "GetAll",
        g_variant_new("(s)", kWatcherInterface), G_VARIANT_TYPE("(a{sv})"),
        G_DBUS_CALL_FLAGS_NONE, 5000, cancellable, &GotWatcherProperties,
        new PendingCall{shared_from_this(), watcher_generation, watcher_owner});
  }

  void RegisterItem() {
    if (stopped || !watcher_available || !host_registered || item_registered ||
        connection == nullptr) {
      return;
    }
    g_dbus_connection_call(
        connection, watcher_owner.c_str(), kWatcherPath, kWatcherInterface,
        "RegisterStatusNotifierItem", g_variant_new("(s)", unique_name.c_str()),
        G_VARIANT_TYPE("()"), G_DBUS_CALL_FLAGS_NONE, 5000, cancellable,
        &ItemRegistered,
        new PendingCall{shared_from_this(), watcher_generation, watcher_owner});
  }

  static void WatcherAppeared(GDBusConnection*, const gchar*, const gchar* owner,
                              gpointer data) {
    auto self = *static_cast<SharedImpl*>(data);
    if (self->stopped) return;
    self->watcher_available = true;
    self->host_registered = false;
    self->item_registered = false;
    self->watcher_owner = owner == nullptr ? "" : owner;
    ++self->watcher_generation;
    self->QueryHost();
  }

  static void WatcherVanished(GDBusConnection*, const gchar*, gpointer data) {
    auto self = *static_cast<SharedImpl*>(data);
    if (self->stopped) return;
    self->watcher_available = false;
    self->host_registered = false;
    self->item_registered = false;
    self->watcher_owner.clear();
    ++self->watcher_generation;
    self->SetCapability(false, true);
  }

  static void GotWatcherProperties(GObject* source, GAsyncResult* result,
                                   gpointer data) {
    std::unique_ptr<PendingCall> pending(static_cast<PendingCall*>(data));
    auto self = pending->self;
    GError* error = nullptr;
    GVariant* reply = g_dbus_connection_call_finish(
        G_DBUS_CONNECTION(source), result, &error);
    if (self->stopped || pending->generation != self->watcher_generation ||
        pending->owner != self->watcher_owner) {
      if (reply != nullptr) g_variant_unref(reply);
      if (error != nullptr) g_error_free(error);
      return;
    }
    if (reply == nullptr) {
      if (error != nullptr) g_error_free(error);
      self->SetHostRegistered(false);
      return;
    }
    GVariant* properties = g_variant_get_child_value(reply, 0);
    gboolean host = FALSE;
    const gboolean found = g_variant_lookup(properties,
                                             "IsStatusNotifierHostRegistered",
                                             "b", &host);
    g_variant_unref(properties);
    g_variant_unref(reply);
    self->SetHostRegistered(found && host);
  }

  static void ItemRegistered(GObject* source, GAsyncResult* result,
                             gpointer data) {
    std::unique_ptr<PendingCall> pending(static_cast<PendingCall*>(data));
    auto self = pending->self;
    GError* error = nullptr;
    GVariant* reply = g_dbus_connection_call_finish(
        G_DBUS_CONNECTION(source), result, &error);
    if (self->stopped || pending->generation != self->watcher_generation ||
        pending->owner != self->watcher_owner) {
      if (reply != nullptr) g_variant_unref(reply);
      if (error != nullptr) g_error_free(error);
      return;
    }
    const bool registered = reply != nullptr && self->watcher_available &&
                            self->host_registered;
    if (reply != nullptr) g_variant_unref(reply);
    if (error != nullptr) g_error_free(error);
    self->item_registered = registered;
    self->SetCapability(registered, false);
  }

  static void WatcherPropertiesChanged(GDBusConnection*, const gchar* sender,
                                      const gchar*, const gchar*,
                                      const gchar*, GVariant* parameters,
                                      gpointer data) {
    auto self = *static_cast<SharedImpl*>(data);
    if (self->stopped || self->watcher_owner != sender) return;
    const gchar* interface_name = nullptr;
    GVariant* changed = nullptr;
    GVariant* invalidated = nullptr;
    g_variant_get(parameters, "(&s@a{sv}@as)", &interface_name, &changed,
                  &invalidated);
    gboolean host = FALSE;
    if (g_strcmp0(interface_name, kWatcherInterface) == 0 &&
        g_variant_lookup(changed, "IsStatusNotifierHostRegistered", "b",
                         &host)) {
      self->SetHostRegistered(host);
    } else if (g_strcmp0(interface_name, kWatcherInterface) == 0) {
      for (gsize i = 0; i < g_variant_n_children(invalidated); ++i) {
        GVariant* child = g_variant_get_child_value(invalidated, i);
        const gchar* name = g_variant_get_string(child, nullptr);
        const bool matches = g_strcmp0(name, "IsStatusNotifierHostRegistered") == 0;
        g_variant_unref(child);
        if (matches) {
          self->SetHostRegistered(false);
          self->QueryHost();
        }
      }
    }
    g_variant_unref(changed);
    g_variant_unref(invalidated);
  }

  static void WatcherHostRegistered(GDBusConnection*, const gchar* sender,
                                   const gchar*, const gchar*, const gchar*,
                                   GVariant*, gpointer data) {
    auto self = *static_cast<SharedImpl*>(data);
    if (!self->stopped && self->watcher_owner == sender)
      self->SetHostRegistered(true);
  }

  static void WatcherHostUnregistered(GDBusConnection*, const gchar* sender,
                                     const gchar*, const gchar*, const gchar*,
                                     GVariant*, gpointer data) {
    auto self = *static_cast<SharedImpl*>(data);
    if (!self->stopped && self->watcher_owner == sender)
      self->SetHostRegistered(false);
  }

  static void HandleItemMethod(GDBusConnection*, const gchar*, const gchar*,
                               const gchar*, const gchar* method,
                               GVariant*, GDBusMethodInvocation* invocation,
                               gpointer data) {
    auto* self = From(data);
    if (g_strcmp0(method, "Activate") == 0 ||
        g_strcmp0(method, "SecondaryActivate") == 0) {
      if (self->on_activate) self->on_activate();
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    // The tray host opens our exported /MenuBar for ContextMenu. Do not show
    // the main window on right-click, especially after it was hidden.
    if (g_strcmp0(method, "ContextMenu") == 0) {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (g_strcmp0(method, "Scroll") == 0) {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown StatusNotifierItem method");
  }

  static GVariant* GetItemProperty(GDBusConnection*, const gchar*,
                                   const gchar*, const gchar*,
                                   const gchar* property, GError** error,
                                   gpointer) {
    if (g_strcmp0(property, "Category") == 0)
      return g_variant_new_string("ApplicationStatus");
    if (g_strcmp0(property, "Id") == 0) return g_variant_new_string("fideflow");
    if (g_strcmp0(property, "Title") == 0) return g_variant_new_string("Fideflow");
    if (g_strcmp0(property, "Status") == 0)
      return g_variant_new_string("Active");
    if (g_strcmp0(property, "WindowId") == 0) return g_variant_new_uint32(0);
    if (g_strcmp0(property, "IconName") == 0)
      return g_variant_new_string("");
    if (g_strcmp0(property, "IconPixmap") == 0) {
      return application_pixmaps();
    }
    if (g_strcmp0(property, "OverlayIconPixmap") == 0 ||
        g_strcmp0(property, "AttentionIconPixmap") == 0) {
      return empty_pixmaps();
    }
    if (g_strcmp0(property, "OverlayIconName") == 0 ||
        g_strcmp0(property, "AttentionIconName") == 0 ||
        g_strcmp0(property, "AttentionMovieName") == 0) {
      return g_variant_new_string("");
    }
    if (g_strcmp0(property, "ToolTip") == 0) {
      return g_variant_new("(s@a(iiay)ss)", "", application_pixmaps(),
                           "Fideflow", "Music player");
    }
    if (g_strcmp0(property, "ItemIsMenu") == 0)
      return g_variant_new_boolean(FALSE);
    if (g_strcmp0(property, "Menu") == 0) return g_variant_new_object_path(kMenuPath);
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                "Unknown StatusNotifierItem property");
    return nullptr;
  }

  static void HandleMenuMethod(GDBusConnection*, const gchar*, const gchar*,
                               const gchar*, const gchar* method,
                               GVariant* parameters,
                               GDBusMethodInvocation* invocation,
                               gpointer data) {
    auto* self = From(data);
    if (g_strcmp0(method, "GetLayout") == 0) {
      gint32 parent = 0;
      gint32 depth = 0;
      GVariant* requested_properties = nullptr;
      g_variant_get(parameters, "(ii@as)", &parent, &depth,
                    &requested_properties);
      g_variant_unref(requested_properties);
      GVariantBuilder children;
      g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
      const bool include_children = parent == 0 && depth != 0;
      if (include_children) {
        g_variant_builder_add_value(
            &children, g_variant_new_variant(create_menu_node(1, "Restore window")));
        g_variant_builder_add_value(
            &children, g_variant_new_variant(create_menu_node(2, "Quit")));
      }
      const char* label = parent == 1 ? "Restore window" :
                          parent == 2 ? "Quit" : "";
      GVariant* root = g_variant_new("(i@a{sv}@av)", parent,
                                     menu_properties(label),
                                     g_variant_builder_end(&children));
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(u@(ia{sv}av))", 1u, root));
      return;
    }
    if (g_strcmp0(method, "GetGroupProperties") == 0) {
      GVariant* ids = nullptr;
      GVariant* names = nullptr;
      g_variant_get(parameters, "(@ai@as)", &ids, &names);
      GVariantBuilder result;
      g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
      for (gsize i = 0; i < g_variant_n_children(ids); ++i) {
        GVariant* child = g_variant_get_child_value(ids, i);
        const gint32 id = g_variant_get_int32(child);
        g_variant_unref(child);
        if (id < 0 || id > 2) continue;
        GVariantBuilder props;
        g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
        const char* label = id == 1 ? "Restore window" : id == 2 ? "Quit" : "";
        const bool all = g_variant_n_children(names) == 0;
        for (gsize j = 0; j < (all ? 4 : g_variant_n_children(names)); ++j) {
          const char* name = nullptr;
          GVariant* requested = nullptr;
          if (all) {
            static const char* kPropertyNames[] = {"label", "enabled", "visible", "children-display"};
            name = kPropertyNames[j];
          } else {
            requested = g_variant_get_child_value(names, j);
            name = g_variant_get_string(requested, nullptr);
          }
          if (g_strcmp0(name, "label") == 0) {
            g_variant_builder_add(&props, "{sv}", name,
                                  g_variant_new_string(label));
          } else if (g_strcmp0(name, "enabled") == 0 ||
                     g_strcmp0(name, "visible") == 0) {
            g_variant_builder_add(&props, "{sv}", name,
                                  g_variant_new_boolean(TRUE));
          } else if (g_strcmp0(name, "children-display") == 0) {
            g_variant_builder_add(&props, "{sv}", name,
                                  g_variant_new_string(id == 0 ? "submenu" : ""));
          }
          if (requested != nullptr) g_variant_unref(requested);
        }
        g_variant_builder_add(&result, "(i@a{sv})", id,
                              g_variant_builder_end(&props));
      }
      g_variant_unref(ids);
      g_variant_unref(names);
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(@a(ia{sv}))",
                                    g_variant_builder_end(&result)));
      return;
    }
    if (g_strcmp0(method, "GetProperty") == 0) {
      gint32 id = 0;
      const gchar* property = nullptr;
      g_variant_get(parameters, "(i&s)", &id, &property);
      const char* label = id == 1 ? "Restore window" : "Quit";
      if (id < 0 || id > 2) {
        g_dbus_method_invocation_return_error(
            invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
            "Unknown DBusMenu item");
      } else if (g_strcmp0(property, "label") == 0) {
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(v)",
                                      g_variant_new_string(id == 0 ? "" : label)));
      } else if (g_strcmp0(property, "enabled") == 0 ||
                 g_strcmp0(property, "visible") == 0) {
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(v)", g_variant_new_boolean(TRUE)));
      } else if (g_strcmp0(property, "children-display") == 0) {
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(v)",
                                      g_variant_new_string(id == 0 ? "submenu" : "")));
      } else {
        g_dbus_method_invocation_return_error(
            invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
            "Unknown DBusMenu property");
      }
      return;
    }
    if (g_strcmp0(method, "Event") == 0) {
      gint32 id = 0;
      const gchar* event = nullptr;
      GVariant* value = nullptr;
      guint32 timestamp = 0;
      g_variant_get(parameters, "(i&svu)", &id, &event, &value, &timestamp);
      if (value != nullptr) g_variant_unref(value);
      (void)timestamp;
      if (g_strcmp0(event, "clicked") == 0) {
        if (id == 1 && self->on_activate) self->on_activate();
        if (id == 2 && self->on_quit) self->on_quit();
      }
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (g_strcmp0(method, "EventGroup") == 0) {
      GVariant* events = g_variant_get_child_value(parameters, 0);
      GVariantIter iter;
      gint32 id = 0;
      const gchar* event = nullptr;
      GVariant* value = nullptr;
      guint32 timestamp = 0;
      GVariantBuilder errors;
      g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
      g_variant_iter_init(&iter, events);
      while (g_variant_iter_next(&iter, "(i&svu)", &id, &event, &value,
                                 &timestamp)) {
        (void)timestamp;
        if (id < 0 || id > 2) {
          g_variant_builder_add(&errors, "i", id);
        } else if (g_strcmp0(event, "clicked") == 0) {
          if (id == 1 && self->on_activate) self->on_activate();
          if (id == 2 && self->on_quit) self->on_quit();
        }
        if (value != nullptr) g_variant_unref(value);
      }
      g_variant_unref(events);
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(@ai)", g_variant_builder_end(&errors)));
      return;
    }
    if (g_strcmp0(method, "AboutToShow") == 0) {
      g_dbus_method_invocation_return_value(invocation,
                                            g_variant_new("(b)", FALSE));
      return;
    }
    if (g_strcmp0(method, "AboutToShowGroup") == 0) {
      GVariant* ids = g_variant_get_child_value(parameters, 0);
      GVariantBuilder updates;
      GVariantBuilder errors;
      g_variant_builder_init(&updates, G_VARIANT_TYPE("ai"));
      g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
      for (gsize i = 0; i < g_variant_n_children(ids); ++i) {
        GVariant* child = g_variant_get_child_value(ids, i);
        const gint32 id = g_variant_get_int32(child);
        g_variant_unref(child);
        if (id < 0 || id > 2) g_variant_builder_add(&errors, "i", id);
      }
      g_variant_unref(ids);
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(@ai@ai)", g_variant_builder_end(&updates),
                                    g_variant_builder_end(&errors)));
      return;
    }
    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown DBusMenu method");
  }

  static GVariant* GetMenuProperty(GDBusConnection*, const gchar*,
                                   const gchar*, const gchar*,
                                   const gchar* property, GError** error,
                                   gpointer) {
    if (g_strcmp0(property, "Version") == 0) return g_variant_new_uint32(3);
    if (g_strcmp0(property, "TextDirection") == 0)
      return g_variant_new_string("ltr");
    if (g_strcmp0(property, "Status") == 0)
      return g_variant_new_string("normal");
    if (g_strcmp0(property, "IconThemePath") == 0)
      return g_variant_new_strv(nullptr, 0);
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                "Unknown DBusMenu property");
    return nullptr;
  }

  std::shared_ptr<Impl> shared_from_this() { return owner.lock(); }
  std::weak_ptr<Impl> owner;
};

LinuxStatusNotifier::LinuxStatusNotifier(
    GtkWindow* window, Callback on_activate, Callback on_quit,
    CapabilityCallback on_background_capability_changed)
    : impl_(std::make_shared<Impl>(window, std::move(on_activate),
                                   std::move(on_quit),
                                   std::move(on_background_capability_changed))) {
  impl_->owner = impl_;
}

LinuxStatusNotifier::~LinuxStatusNotifier() { Stop(); }

void LinuxStatusNotifier::Start() {
  if (impl_) impl_->Start();
}

void LinuxStatusNotifier::Stop() {
  if (impl_) impl_->Stop();
}
