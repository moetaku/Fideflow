#ifndef FF_DESKTOP_CONTROLS_H_
#define FF_DESKTOP_CONTROLS_H_
#include <flutter/binary_messenger.h>
#include <windows.h>
#include <memory>
#include <optional>

class DesktopControls {
 public:
  DesktopControls(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopControls();
  std::optional<LRESULT> Handle(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
