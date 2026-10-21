#include "desktop_controls.h"
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shcore.h>
#include <dwmapi.h>
#include <shlwapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include "resource.h"
#include "desktop_shortcut_keys.h"
#include "localization.h"
#include "window_geometry.h"

using flutter::EncodableValue;
using flutter::EncodableMap;
using Channel = flutter::MethodChannel<EncodableValue>;
using namespace winrt::Windows::Media;
using namespace winrt::Windows::Storage::Streams;
namespace {
constexpr UINT kTray = WM_APP + 41;
constexpr UINT kAction = WM_APP + 42;
constexpr UINT kExit = WM_APP + 43;
constexpr UINT kCloseResult = WM_APP + 44;
constexpr UINT kShow = 200;
constexpr UINT kQuit = 201;
constexpr UINT_PTR kLayoutTimer = 0x5841;
const char* const kActions[] = {"toggle", "previous", "next", "volumeUp",
  "volumeDown", "favorite", "play", "pause", "stop", "seek"};
const EncodableValue* Get(const EncodableMap& map, const char* key) {
  auto found = map.find(EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}
bool Bool(const EncodableMap& map, const char* key) {
  auto value = Get(map, key);
  auto result = value ? std::get_if<bool>(value) : nullptr;
  return result && *result;
}
std::string Text(const EncodableMap& map, const char* key) {
  auto value = Get(map, key);
  auto result = value ? std::get_if<std::string>(value) : nullptr;
  return result ? *result : "";
}
double Number(const EncodableMap& map, const char* key) {
  auto value = Get(map, key);
  if (!value) return 0;
  if (auto n = std::get_if<double>(value)) return std::isfinite(*n) ? *n : 0;
  if (auto n = std::get_if<int32_t>(value)) return *n;
  if (auto n = std::get_if<int64_t>(value)) return static_cast<double>(*n);
  return 0;
}
COLORREF WindowColor(const EncodableMap& map, const char* key) {
  const auto argb = static_cast<uint32_t>(Number(map, key));
  return RGB((argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff);
}
HKL ForegroundLayout() {
  const HWND foreground = GetForegroundWindow();
  return GetKeyboardLayout(foreground ? GetWindowThreadProcessId(foreground, nullptr) : 0);
}
}

struct DesktopControls::Impl {
  HWND window;
  std::unique_ptr<Channel> controls, desktop, lifecycle;
  NOTIFYICONDATAW tray{};
  UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  bool tray_added = false, ready = false, quitting = false;
  bool close_pending = false, close_inflight = false;
  bool lifecycle_ready = false, suspended = false, has_track = false;
  bool playing = false, media_enabled = true, closed = false, tray_has_track = false;
  std::string artwork_token;
  EncodableMap hotkeys;
  HKL keyboard_layout = nullptr;
  bool layout_error = false;
  std::map<std::string, std::wstring> labels;
  std::map<int, std::pair<UINT, UINT>> registered;
  SystemMediaTransportControls smtc{nullptr};
  winrt::event_token button{}, seek{};
  bool button_registered = false, seek_registered = false;

  Impl(HWND hwnd, flutter::BinaryMessenger* messenger) : window(hwnd) {
    const auto initial = NativeLabels(SavedUiLanguage());
    labels = {{"show", initial.show}, {"play", initial.play}, {"pause", initial.pause},
      {"previous", initial.previous}, {"next", initial.next}, {"quit", initial.quit}};
    controls = std::make_unique<Channel>(messenger, "fideflow/player_controls",
      &flutter::StandardMethodCodec::GetInstance());
    desktop = std::make_unique<Channel>(messenger, "fideflow/desktop",
      &flutter::StandardMethodCodec::GetInstance());
    lifecycle = std::make_unique<Channel>(messenger, "fideflow/playback_lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
    controls->SetMethodCallHandler([this](const auto& call, auto result) {
      try {
        const auto* map = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
        if (call.method_name() == "localize" && map) {
          for (const char* key : {"show", "play", "pause", "previous", "next", "quit"}) {
            const auto text = Text(*map, key);
            if (!text.empty()) labels[key] = winrt::to_hstring(text).c_str();
          }
          result->Success();
        } else if (call.method_name() == "configure" && map) {
          EnableSmtc();
          const auto* value = Get(*map, "global");
          const auto* bindings = value ? std::get_if<EncodableMap>(value) : nullptr;
          auto failures = RegisterHotkeys(Bool(*map, "globalEnabled") && bindings ? *bindings : EncodableMap{});
          if (failures.empty()) {
            media_enabled = Bool(*map, "mediaEnabled");
            if (!media_enabled) ClearMedia();
          }
          result->Success(EncodableValue(failures));
        } else if (call.method_name() == "publish" && map) {
          Publish(*map);
          result->Success();
        } else if (call.method_name() == "artwork" && map) {
          Artwork(*map);
          result->Success();
        } else if (call.method_name() == "suspend") {
          const auto* value = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
          suspended = value && *value;
          UnregisterHotkeys();
          if (!suspended && !RegisterHotkeys(hotkeys).empty()) {
            result->Error("controls.registration", "controls.occupied");
            return;
          }
          result->Success();
        } else if (call.method_name() == "dispose") {
          CloseMedia();
          result->Success();
        } else { result->NotImplemented(); }
      } catch (const winrt::hresult_error& error) {
        result->Error("windowsMedia", winrt::to_string(error.message()));
      } catch (...) { result->Error("windowsMedia", "Windows media operation failed"); }
    });
    desktop->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "initialize") {
        ready = true;
        const bool added = AddTray();
        if (!added) result->Error("trayUnavailable", "Windows notification area unavailable");
        else result->Success();
        if (close_pending) { close_pending = false; RequestClose(); }
      } else if (call.method_name() == "setWindowTheme") {
        const auto* map = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
        if (!map || !Get(*map, "background") || !Get(*map, "foreground")) {
          result->Error("invalidTheme", "Window theme colors are required");
          return;
        }
        const BOOL dark = Bool(*map, "dark");
        const COLORREF background = WindowColor(*map, "background");
        const COLORREF foreground = WindowColor(*map, "foreground");
        DwmSetWindowAttribute(window, static_cast<DWMWINDOWATTRIBUTE>(20), &dark, sizeof(dark));
        // Windows 11 border, caption and text colors. Earlier Windows versions
        // ignore unsupported attributes and retain their native decorations.
        DwmSetWindowAttribute(window, static_cast<DWMWINDOWATTRIBUTE>(34), &background, sizeof(background));
        DwmSetWindowAttribute(window, static_cast<DWMWINDOWATTRIBUTE>(35), &background, sizeof(background));
        DwmSetWindowAttribute(window, static_cast<DWMWINDOWATTRIBUTE>(36), &foreground, sizeof(foreground));
        result->Success();
      } else if (call.method_name() == "expandForSidebar") {
        if (IsZoomed(window)) { result->Success(EncodableValue(true)); return; }
        RECT rect{}; GetWindowRect(window, &rect);
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
          result->Success(EncodableValue(false)); return;
        }
        const SIZE expanded = WindowSizeForClient(window, GetDpiForWindow(window), 840, 0);
        const int width = std::max<int>(rect.right - rect.left, expanded.cx);
        if (width > monitor.rcWork.right - monitor.rcWork.left) {
          result->Success(EncodableValue(false)); return;
        }
        const int x = std::max<int>(monitor.rcWork.left, std::min<int>(rect.left, monitor.rcWork.right - width));
        const bool resized = SetWindowPos(window, nullptr, x, rect.top, width,
          rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE) != FALSE;
        result->Success(EncodableValue(resized));
      } else if (call.method_name() == "isMaximized") {
        result->Success(EncodableValue(IsZoomed(window) != FALSE));
      } else if (call.method_name() == "minimize") {
        ShowWindow(window, SW_MINIMIZE); result->Success(EncodableValue(true));
      } else if (call.method_name() == "toggleMaximize" ||
                 call.method_name() == "titlebarDoubleClick") {
        ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
        result->Success(EncodableValue(true));
      } else if (call.method_name() == "closeWindow") {
        RequestClose(); result->Success(EncodableValue(true));
      } else if (call.method_name() == "startDragging") {
        result->Success(EncodableValue(true));
        ReleaseCapture();
        PostMessageW(window, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
      } else { result->NotImplemented(); }
    });
    lifecycle->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "initialize") { lifecycle_ready = true; result->Success(); }
      else if (call.method_name() == "dispose") { lifecycle_ready = false; result->Success(); }
      else result->NotImplemented();
    });
    // Layout changes in Flutter's child HWND or another foreground application
    // do not reach this top-level HWND, especially while it is hidden in tray.
    SetTimer(window, kLayoutTimer, 250, nullptr);
  }

  bool AddTray() {
    tray.cbSize = sizeof(tray);
    tray.hWnd = window;
    tray.uID = 1;
    tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    tray.uCallbackMessage = kTray;
    tray.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
    if (!tray.hIcon) tray.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(tray.szTip, L"Fideflow");
    tray_added = Shell_NotifyIconW(NIM_ADD, &tray) != FALSE;
    if (tray_added) { tray.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &tray); }
    return tray_added;
  }
  void Show() { ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW); SetForegroundWindow(window); }
  void Action(int action, double position = 0) {
    if (closed || quitting || suspended || action < 0 || action >= 10) return;
    EncodableMap args{{EncodableValue("action"), EncodableValue(kActions[action])}};
    if (action == 9) args[EncodableValue("position")] = EncodableValue(position);
    controls->InvokeMethod("action", std::make_unique<EncodableValue>(args));
  }
  void Quit() {
    if (quitting) return;
    if (!ready) { DestroyWindow(window); return; }
    quitting = true;
    const HWND hwnd = window;
    desktop->InvokeMethod("quit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
        [hwnd](const EncodableValue* value) {
          const auto* accepted = value ? std::get_if<bool>(value) : nullptr;
          PostMessageW(hwnd, kExit, accepted && *accepted ? 1 : 0, 0);
        },
        [hwnd](const std::string&, const std::string&, const EncodableValue*) { PostMessageW(hwnd, kExit, 0, 0); },
        [hwnd]() { PostMessageW(hwnd, kExit, 0, 0); }));
  }
  void RequestClose() {
    if (!ready) { close_pending = true; return; }
    if (quitting || close_inflight) return;
    close_inflight = true;
    Show();
    const HWND hwnd = window;
    EncodableMap args{{EncodableValue("canBackground"), EncodableValue(tray_added)}};
    desktop->InvokeMethod("closeRequested", std::make_unique<EncodableValue>(args),
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
        [hwnd](const EncodableValue* value) {
          const auto* action = value ? std::get_if<std::string>(value) : nullptr;
          PostMessageW(hwnd, kCloseResult, action && *action == "background" ? 1 :
            action && *action == "quit" ? 2 : 0, 0);
        },
        [hwnd](const std::string&, const std::string&, const EncodableValue*) { PostMessageW(hwnd, kCloseResult, 0, 0); },
        [hwnd]() { PostMessageW(hwnd, kCloseResult, 0, 0); }));
  }
  void Menu() {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, kShow, labels["show"].c_str());
    AppendMenuW(menu, MF_STRING | (tray_has_track ? 0 : MF_GRAYED), 100, labels[playing ? "pause" : "play"].c_str());
    AppendMenuW(menu, MF_STRING | (tray_has_track ? 0 : MF_GRAYED), 101, labels["previous"].c_str());
    AppendMenuW(menu, MF_STRING | (tray_has_track ? 0 : MF_GRAYED), 102, labels["next"].c_str());
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kQuit, labels["quit"].c_str());
    POINT point{}; GetCursorPos(&point); SetForegroundWindow(window);
    const auto selection = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
      point.x, point.y, 0, window, nullptr);
    DestroyMenu(menu);
    PostMessageW(window, WM_NULL, 0, 0);
    if (selection == kShow) Show();
    else if (selection == kQuit) Quit();
    else if (selection >= 100 && selection <= 102) Action(selection - 100);
  }
  void UnregisterHotkeys() {
    for (const auto& entry : registered) UnregisterHotKey(window, entry.first);
    registered.clear();
  }
  EncodableMap RegisterHotkeys(const EncodableMap& bindings, HKL layout = nullptr,
                              bool rollback = true) {
    if (!layout) layout = ForegroundLayout();
    const auto old = registered;
    UnregisterHotkeys();
    EncodableMap failures;
    if (!suspended) for (int i = 0; i < 6; ++i) {
      const auto* value = Get(bindings, kActions[i]);
      const auto* binding = value ? std::get_if<EncodableMap>(value) : nullptr;
      if (!binding) continue;
      UINT modifiers = MOD_NOREPEAT;
      if (Bool(*binding, "meta")) modifiers |= MOD_WIN;
      if (Bool(*binding, "control")) modifiers |= MOD_CONTROL;
      if (Bool(*binding, "alt")) modifiers |= MOD_ALT;
      if (Bool(*binding, "shift")) modifiers |= MOD_SHIFT;
      const UINT key = DesktopShortcutVirtualKey(static_cast<int>(Number(*binding, "key")), layout);
      if (!key || !RegisterHotKey(window, i + 1, modifiers, key)) {
        failures[EncodableValue(kActions[i])] = EncodableValue("controls.occupied");
      } else registered[i + 1] = {modifiers, key};
    }
    if (!failures.empty()) {
      UnregisterHotkeys();
      if (rollback) for (const auto& entry : old) {
        if (RegisterHotKey(window, entry.first, entry.second.first, entry.second.second)) registered.insert(entry);
      }
    } else {
      hotkeys = bindings;
      keyboard_layout = layout;
      if (rollback) layout_error = false;
    }
    return failures;
  }
  void RefreshLayout(HKL layout) {
    if (closed || suspended || hotkeys.empty() || layout == keyboard_layout) return;
    // Old virtual keys would trigger different physical keys in the new layout.
    // Keep the desired HID bindings, but leave registrations empty on conflict.
    const auto failures = RegisterHotkeys(hotkeys, layout, false);
    keyboard_layout = layout;
    const bool failed = !failures.empty();
    if (failed || layout_error) {
      controls->InvokeMethod("hotkeyError", std::make_unique<EncodableValue>(failed
        ? EncodableValue("controls.layoutChanged") : EncodableValue()));
    }
    layout_error = failed;
  }
  void EnableSmtc() {
    if (smtc) return;
    auto factory = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(factory->GetForWindow(window, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(smtc)));
    const HWND hwnd = window;
    button = smtc.ButtonPressed([hwnd](auto const&, auto const& args) {
      int action = -1;
      switch (args.Button()) {
        case SystemMediaTransportControlsButton::Play: action = 6; break;
        case SystemMediaTransportControlsButton::Pause: action = 7; break;
        case SystemMediaTransportControlsButton::Stop: action = 8; break;
        case SystemMediaTransportControlsButton::Previous: action = 1; break;
        case SystemMediaTransportControlsButton::Next: action = 2; break;
        default: break;
      }
      if (action >= 0) PostMessageW(hwnd, kAction, action, 0);
    });
    button_registered = true;
    seek = smtc.PlaybackPositionChangeRequested([hwnd](auto const&, auto const& args) {
      PostMessageW(hwnd, kAction, 9, static_cast<LPARAM>(args.RequestedPlaybackPosition().count() / 10000));
    });
    seek_registered = true;
  }
  void ClearMedia() {
    if (!smtc) return;
    smtc.IsEnabled(false);
    smtc.PlaybackStatus(MediaPlaybackStatus::Closed);
    smtc.DisplayUpdater().ClearAll();
    smtc.DisplayUpdater().Update();
  }
  void Publish(const EncodableMap& state) {
    if (closed) return;
    has_track = Bool(state, "hasTrack"); playing = Bool(state, "playing");
    tray_has_track = Get(state, "trayHasTrack") ? Bool(state, "trayHasTrack") : has_track;
    const auto token = Text(state, "token");
    if (!smtc) return;
    if (!media_enabled || !has_track) { artwork_token = token; ClearMedia(); return; }
    smtc.IsEnabled(true);
    smtc.IsPlayEnabled(true); smtc.IsPauseEnabled(true); smtc.IsStopEnabled(true);
    smtc.IsPreviousEnabled(true); smtc.IsNextEnabled(true);
    const auto status = Text(state, "status");
    smtc.PlaybackStatus(playing ? MediaPlaybackStatus::Playing :
      status == "buffering" ? MediaPlaybackStatus::Changing :
      status == "error" || status == "idle" ? MediaPlaybackStatus::Stopped : MediaPlaybackStatus::Paused);
    auto updater = smtc.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    if (token != artwork_token) { updater.Thumbnail(nullptr); artwork_token = token; }
    auto properties = updater.MusicProperties();
    properties.Title(winrt::to_hstring(Text(state, "title")));
    properties.Artist(winrt::to_hstring(Text(state, "artist")));
    properties.AlbumTitle(winrt::to_hstring(Text(state, "album")));
    updater.Update();
    const double duration = std::clamp(Number(state, "duration"), 0.0, 1e10);
    const double position = std::clamp(Number(state, "position"), 0.0, duration);
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.EndTime(winrt::Windows::Foundation::TimeSpan{static_cast<int64_t>(duration * 1e7)});
    timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.MaxSeekTime(winrt::Windows::Foundation::TimeSpan{static_cast<int64_t>((Bool(state, "canSeek") ? duration : 0) * 1e7)});
    timeline.Position(winrt::Windows::Foundation::TimeSpan{static_cast<int64_t>(position * 1e7)});
    smtc.UpdateTimelineProperties(timeline);
  }
  void Artwork(const EncodableMap& state) {
    if (!smtc || closed || !media_enabled || !has_track || Text(state, "token") != artwork_token) return;
    auto value = Get(state, "bytes");
    auto bytes = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
    if (!bytes || bytes->empty() || bytes->size() > 8 * 1024 * 1024) return;
    // In-memory stream avoids an artwork file carrying account metadata.
    winrt::com_ptr<IStream> source;
    source.attach(SHCreateMemStream(bytes->data(), static_cast<UINT>(bytes->size())));
    if (!source) throw winrt::hresult_error(E_OUTOFMEMORY);
    IRandomAccessStream stream{nullptr};
    winrt::check_hresult(CreateRandomAccessStreamOverStream(source.get(), BSOS_DEFAULT,
      winrt::guid_of<IRandomAccessStream>(), winrt::put_abi(stream)));
    smtc.DisplayUpdater().Thumbnail(RandomAccessStreamReference::CreateFromStream(stream));
    smtc.DisplayUpdater().Update();
  }
  void CloseMedia() {
    if (closed) return;
    closed = true;
    KillTimer(window, kLayoutTimer);
    UnregisterHotkeys();
    if (smtc) {
      try {
        if (button_registered) smtc.ButtonPressed(button);
        if (seek_registered) smtc.PlaybackPositionChangeRequested(seek);
        ClearMedia();
      } catch (...) {}
      smtc = nullptr;
    }
  }
  ~Impl() {
    controls->SetMethodCallHandler(nullptr);
    desktop->SetMethodCallHandler(nullptr);
    lifecycle->SetMethodCallHandler(nullptr);
    CloseMedia();
    if (tray_added) Shell_NotifyIconW(NIM_DELETE, &tray);
  }
};

DesktopControls::DesktopControls(HWND window, flutter::BinaryMessenger* messenger)
  : impl_(std::make_unique<Impl>(window, messenger)) {}
DesktopControls::~DesktopControls() = default;
std::optional<LRESULT> DesktopControls::Handle(UINT message, WPARAM wparam, LPARAM lparam) {
  auto& s = *impl_;
  if (message == WM_INPUTLANGCHANGE) {
    s.RefreshLayout(reinterpret_cast<HKL>(lparam));
    // DefWindowProc propagates the change to Flutter's child window.
    return std::nullopt;
  }
  if (message == WM_TIMER && wparam == kLayoutTimer) {
    s.RefreshLayout(ForegroundLayout());
    return 0;
  }
  if (message == s.taskbar_created) {
    s.tray_added = false;
    if (s.ready && !s.AddTray()) s.Show();
    return 0;
  }
  if (message == WM_CLOSE) {
    s.RequestClose();
    return 0;
  }
  if (message == kCloseResult) {
    s.close_inflight = false;
    if (!s.quitting) {
      if (wparam == 1 && s.tray_added) ShowWindow(s.window, SW_HIDE);
      else if (wparam == 2) s.Quit();
      else if (wparam == 1) s.RequestClose();
    }
    return 0;
  }
  if (message == kTray) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK) s.Show();
    else if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) s.Menu();
    return 0;
  }
  if (message == WM_COMMAND) {
    if (LOWORD(wparam) == kQuit) { s.Quit(); return 0; }
    if (LOWORD(wparam) == kShow) { s.Show(); return 0; }
  }
  if (message == WM_HOTKEY) {
    if (s.registered.count(static_cast<int>(wparam))) s.Action(static_cast<int>(wparam) - 1);
    return 0;
  }
  if (message == kAction) { if (s.media_enabled) s.Action(static_cast<int>(wparam), static_cast<double>(lparam) / 1000); return 0; }
  if (message == kExit) {
    if (wparam) DestroyWindow(s.window);
    else { s.quitting = false; s.Show(); }
    return 0;
  }
  if (message == WM_POWERBROADCAST && s.lifecycle_ready) {
    if (wparam == PBT_APMSUSPEND || wparam == PBT_APMRESUMEAUTOMATIC) {
      EncodableMap args{{EncodableValue("interruptionId"), EncodableValue("windows-sleep")},
        {EncodableValue("active"), EncodableValue(wparam == PBT_APMSUSPEND)}};
      s.lifecycle->InvokeMethod("interruption", std::make_unique<EncodableValue>(args));
    }
  }
  return std::nullopt;
}
