#include "win32_window.h"

#include <algorithm>
#include <array>
#include <cstdint>

#include <dwmapi.h>
#include <windowsx.h>
#include <flutter_windows.h>

#include "resource.h"
#include "window_geometry.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
void RestoreWindowSizeAndCenter(HWND hwnd);

int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
  if (caption_icon_) DestroyIcon(caption_icon_);
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // A null small icon falls back to the registered class icon. Supply an
  // explicit transparent monochrome icon for the caption instead.
  if (!caption_icon_) {
    std::array<BYTE, 32> and_mask;
    and_mask.fill(0xff);
    const std::array<BYTE, 32> xor_mask{};
    caption_icon_ = CreateIcon(GetModuleHandle(nullptr), 16, 16, 1, 1,
                               and_mask.data(), xor_mask.data());
    if (!caption_icon_) return false;
  }
  HWND window = CreateWindowEx(
      0, window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  SetWindowTextW(window, L"");
  SendMessageW(window, WM_SETICON, ICON_SMALL,
               reinterpret_cast<LPARAM>(caption_icon_));
  // Keep the application icon for Alt+Tab and the taskbar.
  SendMessageW(window, WM_SETICON, ICON_BIG,
               GetClassLongPtrW(window, GCLP_HICON));
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  RestoreWindowSizeAndCenter(window);
  UpdateTheme(window);

  return OnCreate();
}

static const wchar_t kRegistryKey[] = L"Software\\Fideflow";
static const wchar_t kWindowPlacementVal[] = L"WindowPlacement";

static void SaveWindowPlacement(HWND hwnd) {
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(WINDOWPLACEMENT);
  if (GetWindowPlacement(hwnd, &wp)) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
      RegSetValueExW(key, kWindowPlacementVal, 0, REG_BINARY,
                     reinterpret_cast<const BYTE*>(&wp), sizeof(wp));
      RegCloseKey(key);
    }
  }
}

namespace {

void RestoreWindowSizeAndCenter(HWND hwnd) {
  RECT bounds{};
  if (!GetWindowRect(hwnd, &bounds)) return;
  std::int64_t width = bounds.right - bounds.left;
  std::int64_t height = bounds.bottom - bounds.top;
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, KEY_READ, &key) ==
      ERROR_SUCCESS) {
    WINDOWPLACEMENT placement{};
    DWORD size = sizeof(placement);
    DWORD type = 0;
    const auto result = RegQueryValueExW(
        key, kWindowPlacementVal, nullptr, &type,
        reinterpret_cast<BYTE*>(&placement), &size);
    RegCloseKey(key);
    if (result == ERROR_SUCCESS && type == REG_BINARY &&
        size == sizeof(placement) && placement.length == sizeof(placement)) {
      const auto saved_width = static_cast<std::int64_t>(
          placement.rcNormalPosition.right) - placement.rcNormalPosition.left;
      const auto saved_height = static_cast<std::int64_t>(
          placement.rcNormalPosition.bottom) - placement.rcNormalPosition.top;
      if (saved_width > 0 && saved_height > 0) {
        width = saved_width;
        height = saved_height;
      }
    }
  }

  MONITORINFO info{};
  info.cbSize = sizeof(info);
  const auto monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfoW(monitor, &info)) return;
  const LONG work_width = info.rcWork.right - info.rcWork.left;
  const LONG work_height = info.rcWork.bottom - info.rcWork.top;
  const UINT monitor_dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const UINT dpi = monitor_dpi > 0 ? monitor_dpi : 96;
  const SIZE minimum = WindowSizeForClient(hwnd, dpi, 440, 560);
  // Keep the window usable after a change of monitor or screen resolution.
  const int restored_width = static_cast<int>(std::clamp<std::int64_t>(
      width, std::min<LONG>(minimum.cx, work_width), work_width));
  const int restored_height = static_cast<int>(std::clamp<std::int64_t>(
      height, std::min<LONG>(minimum.cy, work_height), work_height));
  SetWindowPos(hwnd, nullptr,
               info.rcWork.left + (work_width - restored_width) / 2,
               info.rcWork.top + (work_height - restored_height) / 2,
               restored_width, restored_height,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

}  // namespace

bool Win32Window::Show() {
  ShowWindow(window_handle_, SW_SHOWNORMAL);
  return IsWindowVisible(window_handle_) != FALSE;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_SYSCOMMAND:
      // Block the mouse system-menu command itself, including commands issued
      // by DWM without going through our non-client hit test. Keep keyboard
      // access (Alt+Space), caption buttons and native move/resize commands.
      if ((wparam & 0xfff0) == SC_MOUSEMENU) return 0;
      break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTSYSMENU) {
        return DefWindowProcW(hwnd, message, HTCAPTION, lparam);
      }
      break;
    case WM_NCHITTEST: {
      // The transparent caption icon still has a native system-menu hit area.
      // Make it behave like the rest of the blank titlebar instead: dragging
      // moves the window and double-clicking toggles maximization.
      const LRESULT hit = DefWindowProcW(hwnd, message, wparam, lparam);
      return hit == HTSYSMENU ? HTCAPTION : hit;
    }
    case WM_NCRBUTTONDOWN:
    case WM_NCRBUTTONUP:
      // Do not open a menu from the hidden icon's former hit area, including
      // right-clicks (whose reported hit is now HTCAPTION).
      if (DefWindowProcW(hwnd, WM_NCHITTEST, 0, lparam) == HTSYSMENU) {
        return 0;
      }
      break;
    case WM_GETICON:
      if (wparam == ICON_SMALL || wparam == ICON_SMALL2) {
        return reinterpret_cast<LRESULT>(caption_icon_);
      }
      break;
    case WM_SETTEXT:
      // Flutter updates the native title from MaterialApp.title. Keep the
      // caption blank even after locale or theme rebuilds.
      return DefWindowProcW(hwnd, message, wparam,
                            reinterpret_cast<LPARAM>(L""));
    case WM_EXITSIZEMOVE:
      SaveWindowPlacement(hwnd);
      return 0;

    case WM_DESTROY:
      SaveWindowPlacement(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETMINMAXINFO: {
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      const UINT monitor_dpi = FlutterDesktopGetDpiForMonitor(monitor);
      const UINT dpi = monitor_dpi > 0 ? monitor_dpi : 96;
      const SIZE minimum = WindowSizeForClient(hwnd, dpi, 440, 560);
      MONITORINFO monitor_info{};
      monitor_info.cbSize = sizeof(monitor_info);
      if (GetMonitorInfoW(monitor, &monitor_info)) {
        info->ptMinTrackSize.x = std::min<LONG>(
            minimum.cx,
            monitor_info.rcWork.right - monitor_info.rcWork.left);
        info->ptMinTrackSize.y = std::min<LONG>(
            minimum.cy,
            monitor_info.rcWork.bottom - monitor_info.rcWork.top);
      }
      return 0;
    }

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    SaveWindowPlacement(window_handle_);
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
