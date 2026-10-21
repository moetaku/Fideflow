#include "my_application.h"
#include "linux_desktop.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  LinuxDesktop* desktop;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  (void)view;
  if (self->desktop != nullptr) self->desktop->OnFirstFrame();
}

static void window_destroyed_cb(GtkWidget* widget, MyApplication* self) {
  if (self->window == GTK_WINDOW(widget)) self->window = nullptr;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    if (self->desktop != nullptr) {
      self->desktop->Present();
    } else {
      gtk_window_present(self->window);
    }
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Flutter's Linux runner does not wire an application icon by default.
  // Keep the PNG beside the bundled executable so it works from the relocatable
  // bundle as well as from the build output used by `flutter run`.
  g_autofree gchar* executable_path = g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path != nullptr) {
    g_autofree gchar* executable_dir = g_path_get_dirname(executable_path);
    g_autofree gchar* icon_path =
        g_build_filename(executable_dir, "fideflow.png", nullptr);
    g_autoptr(GError) icon_error = nullptr;
    if (!gtk_window_set_icon_from_file(window, icon_path, &icon_error)) {
      g_debug("Unable to load Fideflow window icon from %s: %s", icon_path,
              icon_error != nullptr ? icon_error->message : "unknown error");
    }
  }

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Fideflow");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Fideflow");
  }

  gtk_window_set_default_size(window, 1280, 720);
  GdkGeometry geometry;
  geometry.min_width = 1020;
  geometry.min_height = 700;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  // FlView connects its own delete-event handler from its realize callback.
  // Connect ours first so background-close can stop GTK's default quit path
  // before the Flutter handler requests an unconditional app exit.
  self->desktop = new LinuxDesktop(GTK_APPLICATION(application), window, view);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroyed_cb), self);

  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) bus_error = nullptr;
  g_autoptr(GDBusConnection) session_bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
  if (session_bus == nullptr) {
    g_printerr("Fideflow requires a session bus for single-instance safety: %s\n",
               bus_error != nullptr ? bus_error->message : "session bus unavailable");
    *exit_status = 1;
    return TRUE;
  }

  // One application per session bus, independent of the data directory.
  // GTK, desktop integration and portals must all see the same stable ID.
  g_application_set_application_id(application, kFideflowDesktopApplicationId);
  g_set_prgname(kFideflowDesktopApplicationId);
  gdk_set_program_class(kFideflowDesktopApplicationId);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  delete self->desktop;
  self->desktop = nullptr;

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->desktop = nullptr;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

#if GLIB_CHECK_VERSION(2, 74, 0)
  constexpr auto flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  constexpr auto flags = G_APPLICATION_FLAGS_NONE;
#endif
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
