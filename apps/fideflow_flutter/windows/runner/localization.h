#pragma once
#include <windows.h>
#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>
#include "localization_resources.h"

inline std::optional<UiLanguage> MatchUiLanguage(std::wstring tag) {
  std::transform(tag.begin(), tag.end(), tag.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(towlower(c));
  });
  std::replace(tag.begin(), tag.end(), L'_', L'-');
  if (tag == L"en" || tag.rfind(L"en-", 0) == 0) return UiLanguage::english;
  if (tag != L"zh" && tag.rfind(L"zh-", 0) != 0) return std::nullopt;
  if (tag.find(L"-hans") != std::wstring::npos) return UiLanguage::simplified;
  return UiLanguage::simplified;
}

inline UiLanguage SystemUiLanguage() {
  ULONG count = 0, length = 0;
  GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &length);
  if (length > 0 && length < 65536) {
    std::vector<wchar_t> languages(length);
    if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, languages.data(), &length)) {
      for (const wchar_t* p = languages.data(); *p; p += wcslen(p) + 1) {
        if (const auto language = MatchUiLanguage(p)) return *language;
      }
    }
  }
  return UiLanguage::simplified;
}

// Shared with FileLanguageStore: %LOCALAPPDATA%/Fideflow/settings/language.json.
// Invalid, missing or unrecognized settings retain the default system mode.
inline UiLanguage SavedUiLanguage() {
  try {
    const DWORD required = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (required == 0 || required > 32768) return SystemUiLanguage();
    std::vector<wchar_t> directory(required);
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", directory.data(), required) == 0) return SystemUiLanguage();
    const auto path = std::filesystem::path(directory.data()) / L"Fideflow" / L"settings" / L"language.json";
    std::ifstream file(path, std::ios::binary);
    if (!file) return SystemUiLanguage();
    file.seekg(0, std::ios::end);
    if (file.tellg() < 0 || file.tellg() > 4096) return SystemUiLanguage();
    file.seekg(0);
    std::ostringstream buffer;
    buffer << file.rdbuf();
    const std::regex format(R"json(^\s*\{\s*"mode"\s*:\s*"(system|en|zh_Hans|zh_Hant)"\s*\}\s*$)json");
    std::smatch match;
    const auto json = buffer.str();
    if (!std::regex_match(json, match, format)) return SystemUiLanguage();
    const auto mode = match[1].str();
    if (mode == "en") return UiLanguage::english;
    if (mode == "zh_Hans" || mode == "zh_Hant") return UiLanguage::simplified;
  } catch (...) { /* Startup error reporting must remain available. */ }
  return SystemUiLanguage();
}
