#pragma once

#include <gtk/gtk.h>

#include <functional>
#include <memory>

/// Exposes Fideflow as an org.kde.StatusNotifierItem when a desktop tray host
/// is available. All callbacks run on the GLib main-context thread.
class LinuxStatusNotifier final {
 public:
  struct Impl;
  using Callback = std::function<void()>;
  using CapabilityCallback = std::function<void(bool)>;

  LinuxStatusNotifier(GtkWindow* window, Callback on_activate, Callback on_quit,
                     CapabilityCallback on_background_capability_changed);
  ~LinuxStatusNotifier();

  LinuxStatusNotifier(const LinuxStatusNotifier&) = delete;
  LinuxStatusNotifier& operator=(const LinuxStatusNotifier&) = delete;

  void Start();
  void Stop();

 private:
  std::shared_ptr<Impl> impl_;
};
