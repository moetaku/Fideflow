#include "linux_desktop.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#ifdef ButtonPress
#undef ButtonPress
#endif
#endif

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <vector>

#include "linux_status_notifier.h"
#include "linux_player_controls.h"

LinuxDesktop::LinuxDesktop(GtkApplication* application, GtkWindow* window,
                           FlView* view)
    : application_(application), window_(window), view_(view),
      callback_state_(std::make_shared<CallbackState>()) {
  g_object_ref(application_);
  g_object_ref(window_);
  g_object_ref(view_);
  callback_state_->owner = this;
  player_controls_ = std::make_unique<LinuxPlayerControls>(application_, window_, view_);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view_)),
      "fideflow/desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, MethodCall, this, nullptr);

  delete_event_handler_ =
      g_signal_connect(window_, "delete-event", G_CALLBACK(DeleteEvent), this);
  drag_gesture_ = gtk_gesture_multi_press_new(GTK_WIDGET(view_));
  gtk_event_controller_set_propagation_phase(
      GTK_EVENT_CONTROLLER(drag_gesture_), GTK_PHASE_CAPTURE);
  drag_pressed_handler_ =
      g_signal_connect(drag_gesture_, "pressed", G_CALLBACK(PointerPressed), this);
}

LinuxDesktop::~LinuxDesktop() {
  player_controls_.reset();
  callback_state_->owner = nullptr;
  DetachFromWidgets();
  if (status_notifier_ != nullptr) {
    status_notifier_->Stop();
    delete status_notifier_;
    status_notifier_ = nullptr;
  }
  if (channel_ != nullptr) {
    fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
    g_clear_object(&channel_);
  }
  g_clear_object(&view_);
  g_clear_object(&window_);
  g_clear_object(&application_);
}

void LinuxDesktop::DetachFromWidgets() {
  if (widgets_detached_) return;
  widgets_detached_ = true;
  if (delete_event_handler_ != 0 &&
      g_signal_handler_is_connected(window_, delete_event_handler_)) {
    g_signal_handler_disconnect(window_, delete_event_handler_);
  }
  delete_event_handler_ = 0;
  if (drag_pressed_handler_ != 0 && drag_gesture_ != nullptr &&
      g_signal_handler_is_connected(drag_gesture_, drag_pressed_handler_)) {
    g_signal_handler_disconnect(drag_gesture_, drag_pressed_handler_);
  }
  drag_pressed_handler_ = 0;
  if (drag_gesture_ != nullptr) {
    g_object_unref(drag_gesture_);
    drag_gesture_ = nullptr;
  }
  if (drag_pointer_.device != nullptr) {
    g_object_unref(drag_pointer_.device);
    drag_pointer_.device = nullptr;
  }
  drag_pointer_.valid = false;
}

void LinuxDesktop::Present() {
  gtk_widget_show_all(GTK_WIDGET(window_));
  gtk_window_present(window_);
}

void LinuxDesktop::OnFirstFrame() { Present(); }

void LinuxDesktop::RequestClose() {
  if (quitting_ || close_inflight_) return;
  if (!lifecycle_ready_) {
    close_pending_ = true;
    return;
  }
  close_inflight_ = true;
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "canBackground",
                           fl_value_new_bool(background_available_));
  fl_method_channel_invoke_method(channel_, "closeRequested", args, nullptr,
                                  CloseResponse,
                                  new std::shared_ptr<CallbackState>(callback_state_));
}

void LinuxDesktop::RequestQuit() {
  if (quitting_ || !lifecycle_ready_) return;
  quitting_ = true;
  close_inflight_ = false;
  fl_method_channel_invoke_method(channel_, "quit", nullptr, nullptr,
                                  QuitResponse,
                                  new std::shared_ptr<CallbackState>(callback_state_));
}

void LinuxDesktop::CompleteClose(const gchar* action) {
  if (quitting_) return;
  close_inflight_ = false;
  if (g_strcmp0(action, "background") == 0 && background_available_) {
    gtk_widget_hide(GTK_WIDGET(window_));
  } else if (g_strcmp0(action, "quit") == 0) {
    RequestQuit();
  } else {
    Present();
  }
}

void LinuxDesktop::CompleteQuit(bool accepted) {
  if (!accepted) {
    quitting_ = false;
    Present();
    return;
  }
  if (status_notifier_ != nullptr) status_notifier_->Stop();
  DetachFromWidgets();
  gtk_widget_hide(GTK_WIDGET(window_));
  gtk_window_set_application(window_, nullptr);
  g_application_quit(G_APPLICATION(application_));
}

void LinuxDesktop::SetBackgroundCapability(bool available) {
  background_available_ = available;
}

bool LinuxDesktop::StartDragging() {
  if (!drag_pointer_.valid || drag_pointer_.button != GDK_BUTTON_PRIMARY ||
      drag_pointer_.device == nullptr ||
      g_get_monotonic_time() - drag_recorded_at_ > G_TIME_SPAN_SECOND * 2) {
    return false;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (gdk_window == nullptr) return false;
  gdk_window_begin_move_drag_for_device(
      gdk_window, drag_pointer_.device, drag_pointer_.button,
      drag_pointer_.root_x, drag_pointer_.root_y, drag_pointer_.timestamp);
  drag_pointer_.valid = false;
  return true;
}

bool LinuxDesktop::ExpandForSidebar() {
  if (gtk_window_is_maximized(window_)) return true;

  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  GdkDisplay* display = gdk_window != nullptr ? gdk_window_get_display(gdk_window)
                                              : gdk_display_get_default();
  GdkMonitor* monitor = display != nullptr && gdk_window != nullptr
                            ? gdk_display_get_monitor_at_window(display, gdk_window)
                            : nullptr;
  if (monitor == nullptr) return false;

  GdkRectangle workarea;
  gdk_monitor_get_workarea(monitor, &workarea);
  gint x = 0;
  gint y = 0;
  gint width = 0;
  gint height = 0;
  gtk_window_get_position(window_, &x, &y);
  gtk_window_get_size(window_, &width, &height);
  const gint expanded_width = std::max(width, 840);
  if (expanded_width > workarea.width) return false;
  x = std::max(workarea.x, std::min(x, workarea.x + workarea.width - expanded_width));
  gtk_window_resize(window_, expanded_width, height);

#ifdef GDK_WINDOWING_X11
  if (display != nullptr && GDK_IS_X11_DISPLAY(display)) {
    gtk_window_move(window_, x, y);
  }
#else
  (void)x;
  (void)y;
#endif
  return true;
}

void LinuxDesktop::HandleMethod(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "initialize") == 0) {
    if (status_notifier_ == nullptr) {
      status_notifier_ = new LinuxStatusNotifier(
          window_, [this]() { Present(); }, [this]() { RequestQuit(); },
          [this](bool available) { SetBackgroundCapability(available); });
      status_notifier_->Start();
    }
    lifecycle_ready_ = true;
    player_controls_->SetQuitHandler([this] { RequestQuit(); });
    g_autoptr(FlValue) result = fl_value_new_bool(background_available_);
    fl_method_call_respond_success(call, result, nullptr);
    if (close_pending_) {
      close_pending_ = false;
      RequestClose();
    }
  } else if (g_strcmp0(method, "startDragging") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(StartDragging());
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "titlebarDoubleClick") == 0 ||
             g_strcmp0(method, "toggleMaximize") == 0) {
    if (gtk_window_is_maximized(window_)) {
      gtk_window_unmaximize(window_);
    } else {
      gtk_window_maximize(window_);
    }
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "maximize") == 0) {
    gtk_window_maximize(window_);
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "restore") == 0) {
    gtk_window_unmaximize(window_);
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "isMaximized") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_bool(gtk_window_is_maximized(window_));
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "minimize") == 0) {
    gtk_window_iconify(window_);
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "closeWindow") == 0) {
    RequestClose();
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "expandForSidebar") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(ExpandForSidebar());
    fl_method_call_respond_success(call, result, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

void LinuxDesktop::MethodCall(FlMethodChannel*, FlMethodCall* call,
                              gpointer user_data) {
  static_cast<LinuxDesktop*>(user_data)->HandleMethod(call);
}

gboolean LinuxDesktop::DeleteEvent(GtkWidget*, GdkEvent*, gpointer user_data) {
  static_cast<LinuxDesktop*>(user_data)->RequestClose();
  return TRUE;
}

void LinuxDesktop::PointerPressed(GtkGestureMultiPress* gesture, gint,
                                  gdouble, gdouble, gpointer user_data) {
  LinuxDesktop* self = static_cast<LinuxDesktop*>(user_data);
  const GdkEvent* event = gtk_gesture_get_last_event(GTK_GESTURE(gesture), nullptr);
  if (event == nullptr || gdk_event_get_event_type(event) != GDK_BUTTON_PRESS) return;
  guint button = 0;
  gdouble root_x = 0;
  gdouble root_y = 0;
  if (!gdk_event_get_button(event, &button) || button != GDK_BUTTON_PRIMARY ||
      !gdk_event_get_root_coords(event, &root_x, &root_y)) {
    return;
  }
  GdkDevice* device = gdk_event_get_device(event);
  if (device == nullptr) device = gtk_gesture_get_device(GTK_GESTURE(gesture));
  if (device == nullptr) return;
  if (self->drag_pointer_.device != nullptr) {
    g_object_unref(self->drag_pointer_.device);
  }
  self->drag_pointer_.device = GDK_DEVICE(g_object_ref(device));
  self->drag_pointer_.valid = true;
  self->drag_pointer_.button = static_cast<gint>(button);
  self->drag_pointer_.root_x = static_cast<gint>(std::lround(root_x));
  self->drag_pointer_.root_y = static_cast<gint>(std::lround(root_y));
  self->drag_pointer_.timestamp = gdk_event_get_time(event);
  self->drag_recorded_at_ = g_get_monotonic_time();
}

void LinuxDesktop::CloseResponse(GObject* object, GAsyncResult* result,
                                 gpointer user_data) {
  std::unique_ptr<std::shared_ptr<CallbackState>> state_holder(
      static_cast<std::shared_ptr<CallbackState>*>(user_data));
  LinuxDesktop* self = (*state_holder)->owner;
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object), result,
                                             &error);
  if (self == nullptr) return;
  if (response == nullptr || error != nullptr) {
    self->CompleteClose("cancel");
    return;
  }
  FlValue* value = fl_method_response_get_result(response, &error);
  const gchar* action = value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
                            ? fl_value_get_string(value)
                            : "cancel";
  self->CompleteClose(action);
}

void LinuxDesktop::QuitResponse(GObject* object, GAsyncResult* result,
                                gpointer user_data) {
  std::unique_ptr<std::shared_ptr<CallbackState>> state_holder(
      static_cast<std::shared_ptr<CallbackState>*>(user_data));
  LinuxDesktop* self = (*state_holder)->owner;
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object), result,
                                             &error);
  if (self == nullptr) return;
  if (response == nullptr || error != nullptr) {
    self->CompleteQuit(false);
    return;
  }
  FlValue* value = fl_method_response_get_result(response, &error);
  const bool accepted = value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
                        fl_value_get_bool(value);
  self->CompleteQuit(accepted);
}
