#ifndef FIDEFLOW_LINUX_GLOBAL_SHORTCUTS_H_
#define FIDEFLOW_LINUX_GLOBAL_SHORTCUTS_H_

#include <gtk/gtk.h>
#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>

#include <functional>
#include <map>
#include <memory>
#include <set>
#include <utility>
#include <string>
#include <vector>

// Native global keyboard grabs for Linux. Media keys remain owned by the
// MPRIS layer so they cannot be dispatched twice.
class LinuxGlobalShortcuts final {
 public:
  using ActionCallback = std::function<void(const std::string&)>;
  using ErrorCallback = std::function<void(const std::string&)>;
  using ConfigureCallback =
      std::function<void(std::map<std::string, std::string>)>;

  LinuxGlobalShortcuts(GtkWindow* window, ActionCallback on_action,
                       ErrorCallback on_error);
  ~LinuxGlobalShortcuts();

  LinuxGlobalShortcuts(const LinuxGlobalShortcuts&) = delete;
  LinuxGlobalShortcuts& operator=(const LinuxGlobalShortcuts&) = delete;

  // Completes after X11 grabs or the compositor portal response. Returns
  // action name -> controls.* error code for rejected bindings.
  void Configure(FlValue* configuration, ConfigureCallback callback);
  void Suspend(bool suspended);
  void Dispose();

 private:
  struct CallbackState {
    LinuxGlobalShortcuts* owner = nullptr;
  };
  struct PortalFlow;
  struct Grab {
    guint keycode;
    guint modifiers;
    std::string action;
  };

  static GdkFilterReturn Filter(GdkXEvent* xevent, GdkEvent* event,
                                gpointer user_data);
  bool Register(const Grab& grab);
  void UnregisterAll();
  bool IsX11() const;
  void ConfigureX11(FlValue* configuration, ConfigureCallback callback);
  void BeginPortalConfigure(FlValue* configuration,
                            ConfigureCallback callback);
  void CreatePortalSession(PortalFlow* flow);
  void BindPortalShortcuts(std::string session, FlValue* configuration,
                           ConfigureCallback callback);
  static void PortalRequestSignal(GDBusConnection*, const gchar*, const gchar*,
                                  const gchar*, const gchar*, GVariant*,
                                  gpointer);
  static void PortalCallFinished(GObject*, GAsyncResult*, gpointer);
  static void PortalRegistrationFinished(GObject*, GAsyncResult*, gpointer);
  static void FailPortalFlow(PortalFlow*);
  static void ReleasePortalFlow(PortalFlow*);
  void CancelPortalFlow();
  void ClosePortalSession();
  static void PortalActivated(GDBusConnection*, const gchar*, const gchar*,
                              const gchar*, const gchar*, GVariant*,
                              gpointer);
  static void PortalSessionClosed(GDBusConnection*, const gchar*,
                                  const gchar*, const gchar*, const gchar*,
                                  GVariant*, gpointer);

  GtkWindow* window_;
  GdkDisplay* display_ = nullptr;
  ActionCallback on_action_;
  ErrorCallback on_error_;
  std::vector<Grab> grabs_;
  FlValue* configuration_ = nullptr;
  bool filter_installed_ = false;
  guint portal_activated_subscription_ = 0;
  guint portal_session_closed_subscription_ = 0;
  GDBusConnection* bus_ = nullptr;
  std::string portal_session_;
  guint portal_token_ = 0;
  std::set<std::string> portal_actions_;
  std::set<guint> pressed_keycodes_;
  guint numlock_mask_ = 0;
  PortalFlow* portal_flow_ = nullptr;
  std::shared_ptr<CallbackState> callback_state_;
  bool suspended_ = false;
  bool disposed_ = false;
};

#endif  // FIDEFLOW_LINUX_GLOBAL_SHORTCUTS_H_
