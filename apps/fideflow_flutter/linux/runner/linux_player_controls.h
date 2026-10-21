#ifndef FIDEFLOW_LINUX_PLAYER_CONTROLS_H_
#define FIDEFLOW_LINUX_PLAYER_CONTROLS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <memory>
#include <functional>

/// Implements fideflow/player_controls and the MPRIS session-bus interfaces.
class LinuxPlayerControls final {
 public:
  LinuxPlayerControls(GtkApplication* application, GtkWindow* window,
                      FlView* view);
  ~LinuxPlayerControls();
  void SetQuitHandler(std::function<void()> handler);

  LinuxPlayerControls(const LinuxPlayerControls&) = delete;
  LinuxPlayerControls& operator=(const LinuxPlayerControls&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // FIDEFLOW_LINUX_PLAYER_CONTROLS_H_
