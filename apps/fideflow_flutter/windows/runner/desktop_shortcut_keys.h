#ifndef FF_DESKTOP_SHORTCUT_KEYS_H_
#define FF_DESKTOP_SHORTCUT_KEYS_H_
#include <windows.h>

// USB HID usages identify physical positions; virtual keys depend on the HKL.
inline UINT DesktopShortcutVirtualKey(int hid, HKL layout) {
  constexpr UINT letters[] = {0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22,
    0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13,
    0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c};
  UINT scan = 0;
  if (hid >= 4 && hid <= 29) scan = letters[hid - 4];
  else if (hid >= 30 && hid <= 38) scan = 0x02 + hid - 30;
  else if (hid >= 58 && hid <= 67) scan = 0x3b + hid - 58;
  else switch (hid) {
    case 39: scan = 0x0b; break; case 40: scan = 0x1c; break;
    case 42: scan = 0x0e; break; case 43: scan = 0x0f; break;
    case 44: scan = 0x39; break; case 45: scan = 0x0c; break;
    case 46: scan = 0x0d; break; case 47: scan = 0x1a; break;
    case 48: scan = 0x1b; break; case 49: scan = 0x2b; break;
    case 51: scan = 0x27; break; case 52: scan = 0x28; break;
    case 53: scan = 0x29; break; case 54: scan = 0x33; break;
    case 55: scan = 0x34; break; case 56: scan = 0x35; break;
    case 68: scan = 0x57; break; case 69: scan = 0x58; break;
    case 74: scan = 0xe047; break; case 75: scan = 0xe049; break;
    case 76: scan = 0xe053; break; case 77: scan = 0xe04f; break;
    case 78: scan = 0xe051; break; case 79: scan = 0xe04d; break;
    case 80: scan = 0xe04b; break; case 81: scan = 0xe050; break;
    case 82: scan = 0xe048; break;
    default: return 0;
  }
  return MapVirtualKeyExW(scan, MAPVK_VSC_TO_VK_EX, layout);
}
#endif
