#ifndef FIDEFLOW_LINUX_DESKTOP_H_
#define FIDEFLOW_LINUX_DESKTOP_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <string>
#include <memory>

#include "linux_instance_identity.h"

class LinuxStatusNotifier;
class LinuxPlayerControls;

class LinuxDesktop final {
 public:
  LinuxDesktop(GtkApplication* application, GtkWindow* window, FlView* view);
  ~LinuxDesktop();

  LinuxDesktop(const LinuxDesktop&) = delete;
  LinuxDesktop& operator=(const LinuxDesktop&) = delete;

  void Present();
  void RequestClose();
  void OnFirstFrame();

 private:
  struct CallbackState {
    LinuxDesktop* owner = nullptr;
  };

  struct DragPointer {
    bool valid = false;
    gint button = 0;
    gint root_x = 0;
    gint root_y = 0;
    guint32 timestamp = 0;
    GdkDevice* device = nullptr;
  };

  static void MethodCall(FlMethodChannel*, FlMethodCall*, gpointer);
  static gboolean DeleteEvent(GtkWidget*, GdkEvent*, gpointer);
  static void PointerPressed(GtkGestureMultiPress*, gint, gdouble, gdouble,
                             gpointer);
  static void CloseResponse(GObject*, GAsyncResult*, gpointer);
  static void QuitResponse(GObject*, GAsyncResult*, gpointer);

  void HandleMethod(FlMethodCall* call);
  void DetachFromWidgets();
  void RequestQuit();
  void CompleteClose(const gchar* action);
  void CompleteQuit(bool accepted);
  bool StartDragging();
  bool ExpandForSidebar();
  void SetBackgroundCapability(bool available);

  GtkApplication* application_;
  GtkWindow* window_;
  FlView* view_;
  FlMethodChannel* channel_ = nullptr;
  LinuxStatusNotifier* status_notifier_ = nullptr;
  std::unique_ptr<LinuxPlayerControls> player_controls_;
  DragPointer drag_pointer_;
  gint64 drag_recorded_at_ = 0;
  bool lifecycle_ready_ = false;
  bool close_pending_ = false;
  bool close_inflight_ = false;
  bool quitting_ = false;
  bool background_available_ = false;
  bool widgets_detached_ = false;
  std::shared_ptr<CallbackState> callback_state_;
  gulong delete_event_handler_ = 0;
  GtkGesture* drag_gesture_ = nullptr;
  gulong drag_pressed_handler_ = 0;
};

#endif  // FIDEFLOW_LINUX_DESKTOP_H_
