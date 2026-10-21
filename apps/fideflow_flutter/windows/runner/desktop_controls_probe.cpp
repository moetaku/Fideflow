#include "desktop_controls.h"
#include "desktop_shortcut_keys.h"
#include "localization.h"
#include "window_geometry.h"
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Media.h>
#include <iostream>
#include <algorithm>
#include <map>
#include <stdexcept>
#include <vector>

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Media;
namespace {
DesktopControls* bridge = nullptr;
void Check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (bridge) { auto result = bridge->Handle(message, wparam, lparam); if (result) return *result; }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
void Pump() {
  MSG message;
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message); DispatchMessageW(&message);
  }
}
struct ProbeLayouts {
  HKL original = GetKeyboardLayout(0);
  std::vector<HKL> existing, loaded;
  ProbeLayouts() {
    existing.resize(GetKeyboardLayoutList(0, nullptr));
    GetKeyboardLayoutList(static_cast<int>(existing.size()), existing.data());
  }
  HKL Load(const wchar_t* name) {
    const HKL layout = LoadKeyboardLayoutW(name, 0);
    if (layout && std::find(existing.begin(), existing.end(), layout) == existing.end()) loaded.push_back(layout);
    return layout;
  }
  ~ProbeLayouts() {
    if (GetKeyboardLayout(0) != original) ActivateKeyboardLayout(original, 0);
    for (const auto layout : loaded) UnloadKeyboardLayout(layout);
  }
};
class Messenger : public flutter::BinaryMessenger {
 public:
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
  mutable std::vector<std::string> actions;
  mutable std::vector<bool> interruptions;
  mutable std::vector<EncodableValue> hotkey_errors;
  mutable flutter::BinaryReply quit_reply;
  mutable flutter::BinaryReply close_reply;
  mutable int close_calls = 0;
  void SetMessageHandler(const std::string& channel, flutter::BinaryMessageHandler handler) override {
    handlers[channel] = std::move(handler);
  }
  void Send(const std::string& channel, const uint8_t* data, size_t size, flutter::BinaryReply reply) const override {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    auto call = codec.DecodeMethodCall(data, size);
    Check(call != nullptr, "decode outbound channel");
    if (channel == "fideflow/desktop" && call->method_name() == "quit") { quit_reply = reply; return; }
    if (channel == "fideflow/desktop" && call->method_name() == "closeRequested") { close_calls++; close_reply = reply; return; }
    if (channel == "fideflow/player_controls" && call->method_name() == "hotkeyError") {
      hotkey_errors.push_back(*call->arguments());
      return;
    }
    const auto& args = std::get<EncodableMap>(*call->arguments());
    if (channel == "fideflow/player_controls") actions.push_back(std::get<std::string>(args.at(EncodableValue("action"))));
    if (channel == "fideflow/playback_lifecycle") interruptions.push_back(std::get<bool>(args.at(EncodableValue("active"))));
    if (reply) { EncodableValue value(true); auto bytes = codec.EncodeSuccessEnvelope(&value); reply(bytes->data(), bytes->size()); }
  }
  EncodableValue Call(const std::string& channel, const char* method, EncodableValue arguments = {}) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    flutter::MethodCall<EncodableValue> call(method, std::make_unique<EncodableValue>(arguments));
    auto bytes = codec.EncodeMethodCall(call);
    bool success = false;
    std::string failure;
    EncodableValue output;
    handlers.at(channel)(bytes->data(), bytes->size(), [&](const uint8_t* data, size_t size) {
      flutter::MethodResultFunctions<EncodableValue> result(
        [&](const EncodableValue* value) { success = true; if (value) output = *value; },
        [&](const std::string& code, const std::string& message, const EncodableValue*) {
          failure = code + ": " + message;
        }, [&]() { failure = "missing method"; });
      codec.DecodeAndProcessResponseEnvelope(data, size, &result);
    });
    if (!failure.empty()) throw std::runtime_error(failure);
    Check(success, "synchronous native method reply");
    return output;
  }
  void CompleteQuit(bool accepted) {
    Check(static_cast<bool>(quit_reply), "quit callback exists");
    EncodableValue value(accepted);
    auto bytes = flutter::StandardMethodCodec::GetInstance().EncodeSuccessEnvelope(&value);
    auto reply = std::move(quit_reply); quit_reply = nullptr;
    reply(bytes->data(), bytes->size()); Pump();
  }
  void CompleteClose(const std::string& action) {
    Check(static_cast<bool>(close_reply), "close callback exists");
    EncodableValue value(action);
    auto bytes = flutter::StandardMethodCodec::GetInstance().EncodeSuccessEnvelope(&value);
    auto reply = std::move(close_reply); close_reply = nullptr;
    reply(bytes->data(), bytes->size()); Pump();
  }
};
}

int main() {
  HWND hwnd = nullptr;
  try {
    Check(MatchUiLanguage(L"en-GB") == UiLanguage::english, "English locale resolution");
    Check(MatchUiLanguage(L"zh-Hans-TW") == UiLanguage::simplified, "script overrides traditional region");
    Check(MatchUiLanguage(L"zh-Hant-CN") == UiLanguage::simplified, "traditional script falls back to simplified");
    Check(MatchUiLanguage(L"zh-HK") == UiLanguage::simplified, "Hong Kong locale resolution");
    Check(MatchUiLanguage(L"fr-FR") == std::nullopt, "unsupported locale permits next preference");
    Check(std::wstring(NativeLabels(UiLanguage::english).show) == L"Show Fideflow", "English native resources");
    Check(std::wstring(NativeLabels(UiLanguage::simplified).play) == L"播放", "Chinese native resources");
    winrt::check_hresult(RoInitialize(RO_INIT_SINGLETHREADED));
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW cls{}; cls.lpfnWndProc = WndProc; cls.hInstance = GetModuleHandleW(nullptr); cls.lpszClassName = L"FideflowDesktopProbe";
    RegisterClassW(&cls);
    hwnd = CreateWindowW(cls.lpszClassName, L"Fideflow desktop probe", WS_OVERLAPPEDWINDOW,
      -20000, -20000, 100, 100, nullptr, nullptr, cls.hInstance, nullptr);
    Check(hwnd != nullptr, "create probe window");
    const UINT dpi = GetDpiForWindow(hwnd);
    const SIZE minimum = WindowSizeForClient(hwnd, dpi, 440, 560);
    Check(SetWindowPos(hwnd, nullptr, 0, 0, minimum.cx, minimum.cy,
                       SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE) != FALSE,
          "resize framed window to minimum client dimensions");
    RECT client{};
    Check(GetClientRect(hwnd, &client) != FALSE, "read minimum client dimensions");
    Check(client.right == MulDiv(440, dpi, 96) && client.bottom == MulDiv(560, dpi, 96),
          "native frame preserves 440 by 560 logical client area");
    Messenger messenger;
    {
      DesktopControls controls(hwnd, &messenger); bridge = &controls;
      MONITORINFO monitor{sizeof(MONITORINFO)};
      Check(GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor) != FALSE,
            "read sidebar expansion work area");
      const bool fits = WindowSizeForClient(hwnd, dpi, 840, 0).cx <=
                        monitor.rcWork.right - monitor.rcWork.left;
      const auto expanded = messenger.Call("fideflow/desktop", "expandForSidebar");
      Check(std::get<bool>(expanded) == fits, "sidebar expansion checks outer width against work area");
      Check(GetClientRect(hwnd, &client) != FALSE, "read expanded client dimensions");
      Check(client.right == MulDiv(fits ? 840 : 440, dpi, 96),
            "sidebar expansion provides 840 logical client pixels or keeps original width");
      Check(client.bottom == MulDiv(560, dpi, 96), "sidebar expansion preserves client height");
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      Check(IsWindow(hwnd) && messenger.close_calls == 0, "close defers until bridge initialized");
      messenger.Call("fideflow/desktop", "initialize");
      Check(messenger.close_calls == 1, "initialized bridge resumes pending close");
      messenger.CompleteClose("cancel");
      messenger.Call("fideflow/playback_lifecycle", "initialize");
      EncodableMap config{{EncodableValue("mediaEnabled"), EncodableValue(true)},
        {EncodableValue("globalEnabled"), EncodableValue(false)}};
      messenger.Call("fideflow/player_controls", "configure", EncodableValue(config));
      messenger.Call("fideflow/player_controls", "localize", EncodableValue(EncodableMap{
        {EncodableValue("show"), EncodableValue("Show Fideflow")},
        {EncodableValue("play"), EncodableValue("Play")},
        {EncodableValue("pause"), EncodableValue("Pause")},
        {EncodableValue("previous"), EncodableValue("Previous track")},
        {EncodableValue("next"), EncodableValue("Next track")},
        {EncodableValue("quit"), EncodableValue("Quit Fideflow")}}));
      auto factory = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
      SystemMediaTransportControls smtc{nullptr};
      winrt::check_hresult(factory->GetForWindow(hwnd, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(smtc)));
      EncodableMap state{{EncodableValue("hasTrack"), EncodableValue(true)},
        {EncodableValue("playing"), EncodableValue(true)}, {EncodableValue("canSeek"), EncodableValue(true)},
        {EncodableValue("title"), EncodableValue("中文歌曲")}, {EncodableValue("artist"), EncodableValue("测试歌手")},
        {EncodableValue("album"), EncodableValue("测试专辑")}, {EncodableValue("token"), EncodableValue("one")},
        {EncodableValue("duration"), EncodableValue(120.0)}, {EncodableValue("position"), EncodableValue(15.0)}};
      messenger.Call("fideflow/player_controls", "publish", EncodableValue(state));
      Check(smtc.IsEnabled(), "SMTC enabled");
      Check(smtc.PlaybackStatus() == MediaPlaybackStatus::Playing, "SMTC playing");
      Check(smtc.DisplayUpdater().MusicProperties().Title() == L"中文歌曲", "Unicode metadata");
      const std::vector<uint8_t> png{137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,
        0,0,0,1,0,0,0,1,8,6,0,0,0,31,21,196,137,0,0,0,11,73,68,65,84,120,156,
        99,0,1,0,0,5,0,1,13,10,45,180,0,0,0,0,73,69,78,68,174,66,96,130};
      EncodableMap artwork{{EncodableValue("token"), EncodableValue("one")},
        {EncodableValue("bytes"), EncodableValue(png)}};
      messenger.Call("fideflow/player_controls", "artwork", EncodableValue(artwork));
      Check(smtc.DisplayUpdater().Thumbnail() != nullptr, "in-memory artwork");
      state[EncodableValue("token")] = EncodableValue("two");
      messenger.Call("fideflow/player_controls", "publish", EncodableValue(state));
      Check(smtc.DisplayUpdater().Thumbnail() == nullptr, "new track clears old artwork");
      messenger.Call("fideflow/player_controls", "artwork", EncodableValue(artwork));
      Check(smtc.DisplayUpdater().Thumbnail() == nullptr, "late artwork ignored");
      EncodableMap binding{{EncodableValue("key"), EncodableValue(66)},
        {EncodableValue("control"), EncodableValue(true)}, {EncodableValue("alt"), EncodableValue(true)},
        {EncodableValue("shift"), EncodableValue(true)}};
      EncodableMap global{{EncodableValue("next"), EncodableValue(binding)}};
      config[EncodableValue("globalEnabled")] = EncodableValue(true);
      config[EncodableValue("global")] = EncodableValue(global);
      auto registrations = messenger.Call("fideflow/player_controls", "configure", EncodableValue(config));
      Check(std::get<EncodableMap>(registrations).empty(), "register global hotkey");
      SendMessageW(hwnd, WM_HOTKEY, 3, 0);
      Check(messenger.actions.back() == "next", "hotkey action forwarding");
      Check(RegisterHotKey(hwnd, 99, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F10) != FALSE, "reserve conflict hotkey");
      binding[EncodableValue("key")] = EncodableValue(67);
      global[EncodableValue("next")] = EncodableValue(binding);
      config[EncodableValue("global")] = EncodableValue(global);
      config[EncodableValue("mediaEnabled")] = EncodableValue(false);
      auto failures = messenger.Call("fideflow/player_controls", "configure", EncodableValue(config));
      Check(!std::get<EncodableMap>(failures).empty(), "report hotkey conflict");
      Check(smtc.IsEnabled(), "failed configuration preserves media controls");
      Check(!RegisterHotKey(hwnd, 98, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F9), "failed configuration restores old hotkey");
      UnregisterHotKey(hwnd, 99);
      messenger.Call("fideflow/player_controls", "suspend", EncodableValue(true));
      const auto count = messenger.actions.size();
      SendMessageW(hwnd, WM_HOTKEY, 3, 0);
      Check(messenger.actions.size() == count, "recording suppresses hotkeys");
      Check(RegisterHotKey(hwnd, 97, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F9) != FALSE, "reserve suspended hotkey");
      bool resume_failed = false;
      try { messenger.Call("fideflow/player_controls", "suspend", EncodableValue(false)); }
      catch (const std::runtime_error&) { resume_failed = true; }
      Check(resume_failed, "report conflict when recording ends");
      UnregisterHotKey(hwnd, 97);
      messenger.Call("fideflow/player_controls", "suspend", EncodableValue(false));
      // Load mappings without activating them or changing the user's input language.
      ProbeLayouts layouts;
      const HKL french = layouts.Load(L"0000040C");
      const HKL german = layouts.Load(L"00000407");
      Check(french && german, "load non-US keyboard mappings");
      Check(DesktopShortcutVirtualKey(4, french) == 'Q', "AZERTY physical A maps to VK_Q");
      Check(DesktopShortcutVirtualKey(20, french) == 'A', "AZERTY physical Q maps to VK_A");
      Check(DesktopShortcutVirtualKey(28, german) == 'Z', "QWERTZ physical Y maps to VK_Z");
      Check(DesktopShortcutVirtualKey(29, german) == 'Y', "QWERTZ physical Z maps to VK_Y");
      Check(DesktopShortcutVirtualKey(79, french) == VK_RIGHT, "extended arrow scan code");
      binding[EncodableValue("key")] = EncodableValue(4);
      global[EncodableValue("next")] = EncodableValue(binding);
      config[EncodableValue("global")] = EncodableValue(global);
      config[EncodableValue("mediaEnabled")] = EncodableValue(true);
      messenger.Call("fideflow/player_controls", "configure", EncodableValue(config));
      SendMessageW(hwnd, WM_INPUTLANGCHANGE, 0, reinterpret_cast<LPARAM>(french));
      Check(!RegisterHotKey(hwnd, 96, MOD_CONTROL | MOD_ALT | MOD_SHIFT, 'Q'), "layout change registers physical key");
      Check(RegisterHotKey(hwnd, 95, MOD_CONTROL | MOD_ALT | MOD_SHIFT, 'A') != FALSE, "old virtual key released");
      SendMessageW(hwnd, WM_INPUTLANGCHANGE, 0, reinterpret_cast<LPARAM>(german));
      Check(!messenger.hotkey_errors.empty() && std::get_if<std::string>(&messenger.hotkey_errors.back()), "layout conflict reported");
      Check(RegisterHotKey(hwnd, 94, MOD_CONTROL | MOD_ALT | MOD_SHIFT, 'Q') != FALSE, "layout conflict does not restore wrong physical key");
      UnregisterHotKey(hwnd, 94); UnregisterHotKey(hwnd, 95);
      SendMessageW(hwnd, WM_INPUTLANGCHANGE, 0, reinterpret_cast<LPARAM>(french));
      Check(std::holds_alternative<std::monostate>(messenger.hotkey_errors.back()), "layout recovery clears error");
      // The timer also follows the foreground layout while the window is hidden.
      ShowWindow(hwnd, SW_HIDE);
      SendMessageW(hwnd, WM_TIMER, 0x5841, 0);
      const HWND foreground = GetForegroundWindow();
      const HKL foreground_layout = GetKeyboardLayout(foreground ? GetWindowThreadProcessId(foreground, nullptr) : 0);
      Check(!RegisterHotKey(hwnd, 93, MOD_CONTROL | MOD_ALT | MOD_SHIFT, DesktopShortcutVirtualKey(4, foreground_layout)), "hidden window follows foreground layout");
      Check(GetKeyboardLayout(0) == layouts.original, "probe preserves input language");
      ShowWindow(hwnd, SW_SHOWNOACTIVATE);
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      Check(messenger.close_calls == 2 && IsWindowVisible(hwnd), "close coalesces while decision pending");
      messenger.CompleteClose("cancel");
      Check(IsWindowVisible(hwnd), "cancel preserves visible window");
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      messenger.CompleteClose("background");
      Check(IsWindow(hwnd) && !IsWindowVisible(hwnd), "close hides live window");
      SendMessageW(hwnd, WM_COMMAND, 200, 0);
      Check(IsWindowVisible(hwnd), "tray restore");
      ShowWindow(hwnd, SW_HIDE);
      SendMessageW(hwnd, WM_POWERBROADCAST, PBT_APMSUSPEND, 0);
      SendMessageW(hwnd, WM_POWERBROADCAST, PBT_APMRESUMEAUTOMATIC, 0);
      Check(messenger.interruptions == std::vector<bool>({true, false}), "sleep/wake forwarding");
      SendMessageW(hwnd, WM_APP + 42, 7, 0);
      Check(messenger.actions.back() == "pause", "media action forwarding");
      state[EncodableValue("playing")] = EncodableValue(false);
      messenger.Call("fideflow/player_controls", "publish", EncodableValue(state));
      Check(smtc.PlaybackStatus() == MediaPlaybackStatus::Paused, "SMTC pause");
      state[EncodableValue("hasTrack")] = EncodableValue(false);
      messenger.Call("fideflow/player_controls", "publish", EncodableValue(state));
      Check(!smtc.IsEnabled(), "empty queue clears SMTC");
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      messenger.CompleteClose("quit");
      Check(IsWindow(hwnd), "quit waits for Dart cleanup");
      messenger.CompleteQuit(false);
      Check(IsWindow(hwnd) && IsWindowVisible(hwnd), "failed cleanup preserves window");
      ShowWindow(hwnd, SW_HIDE);
      SendMessageW(hwnd, WM_COMMAND, 201, 0);
      messenger.CompleteQuit(true);
      Check(!IsWindow(hwnd), "successful cleanup destroys window");
      bridge = nullptr;
    }
    RoUninitialize();
    std::cout << "{\"probe\":\"windows-desktop\",\"failures\":[]}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
  } catch (const winrt::hresult_error& error) {
    std::cerr << winrt::to_string(error.message()) << '\n';
  }
  bridge = nullptr;
  if (hwnd && IsWindow(hwnd)) DestroyWindow(hwnd);
  return 1;
}
