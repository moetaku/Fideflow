#include "single_instance.h"
#include <sddl.h>
#include <cstdint>
#include <stdexcept>
#include <vector>

SingleInstance::SingleInstance() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) throw std::runtime_error("Cannot read current Windows user");
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> data(size);
  const BOOL read = GetTokenInformation(token, TokenUser, data.data(), size, &size);
  CloseHandle(token);
  if (!read) throw std::runtime_error("Cannot read Windows user identity");
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &sid)) throw std::runtime_error("Cannot encode Windows user identity");
  name_ = L"Local\\Fideflow.Instance." + std::wstring(sid) + L".";
  LocalFree(sid);
  DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  std::vector<wchar_t> path(length ? length : 1, 0);
  if (length) GetEnvironmentVariableW(L"LOCALAPPDATA", path.data(), length);
  std::wstring directory(path.data());
  if (!directory.empty()) {
    const DWORD count = GetFullPathNameW(directory.c_str(), 0, nullptr, nullptr);
    std::vector<wchar_t> resolved(count ? count : 1, 0);
    if (count && GetFullPathNameW(directory.c_str(), count, resolved.data(), nullptr)) directory = resolved.data();
    CharLowerBuffW(directory.data(), static_cast<DWORD>(directory.size()));
    for (auto& character : directory) if (character == L'/') character = L'\\';
    while (!directory.empty() && directory.back() == L'\\') directory.pop_back();
  }
  uint64_t hash = 14695981039346656037ULL;
  for (const auto character : directory) { hash ^= static_cast<uint16_t>(character); hash *= 1099511628211ULL; }
  name_ += std::to_wstring(hash);
  instance_ = CreateMutexW(nullptr, FALSE, name_.c_str());
  const DWORD error = GetLastError();
  if (!instance_) throw std::runtime_error("Cannot create player instance guard");
  primary_ = error != ERROR_ALREADY_EXISTS;
  if (primary_) {
    // Installer uses this session-scoped marker to block upgrade/uninstall while any player is alive.
    running_ = CreateMutexW(nullptr, FALSE, L"Local\\Fideflow.Running");
    if (!running_) { CloseHandle(instance_); instance_ = nullptr; throw std::runtime_error("Cannot create installer guard"); }
  }
}
SingleInstance::~SingleInstance() {
  if (window_ && IsWindow(window_)) RemovePropW(window_, name_.c_str());
  if (running_) CloseHandle(running_);
  if (instance_) CloseHandle(instance_);
}
void SingleInstance::Attach(HWND window) {
  window_ = window;
  SetPropW(window, name_.c_str(), reinterpret_cast<HANDLE>(1));
}
void SingleInstance::RestoreExisting() const {
  for (int attempt = 0; attempt < 20; ++attempt) {
    struct Search { const std::wstring* name; HWND found; } search{&name_, nullptr};
    EnumWindows([](HWND hwnd, LPARAM pointer) -> BOOL {
      auto* state = reinterpret_cast<Search*>(pointer);
      if (GetPropW(hwnd, state->name->c_str())) { state->found = hwnd; return FALSE; }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&search));
    if (search.found) {
      DWORD pid = 0; GetWindowThreadProcessId(search.found, &pid);
      AllowSetForegroundWindow(pid);
      PostMessageW(search.found, WM_COMMAND, 200, 0);
      return;
    }
    Sleep(100);
  }
}
