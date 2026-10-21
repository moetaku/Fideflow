#ifndef RUNNER_WINDOW_GEOMETRY_H_
#define RUNNER_WINDOW_GEOMETRY_H_

#include <windows.h>

// Convert logical Flutter client dimensions to physical outer-window dimensions,
// including the native caption, resize borders and menu at the target DPI.
inline SIZE WindowSizeForClient(HWND window, UINT dpi, int width, int height) {
  if (dpi == 0) dpi = 96;
  RECT bounds{0, 0, MulDiv(width, dpi, 96), MulDiv(height, dpi, 96)};
  AdjustWindowRectExForDpi(
      &bounds, static_cast<DWORD>(GetWindowLongPtr(window, GWL_STYLE)),
      GetMenu(window) != nullptr,
      static_cast<DWORD>(GetWindowLongPtr(window, GWL_EXSTYLE)), dpi);
  return {bounds.right - bounds.left, bounds.bottom - bounds.top};
}

#endif  // RUNNER_WINDOW_GEOMETRY_H_
