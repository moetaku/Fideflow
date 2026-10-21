// Isolated X11 acceptance probe. Build against the generated Flutter Linux
// wrapper and run under Xvfb; never sends input to the user's desktop.
#include "linux_global_shortcuts.h"

#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

namespace {
int x_error_code = 0;

int RecordXError(Display*, XErrorEvent* error) {
  x_error_code = error->error_code;
  return 0;
}

FlValue* MakeBinding(gint usage) {
  FlValue* binding = fl_value_new_map();
  fl_value_set_string_take(binding, "key", fl_value_new_int(usage));
  fl_value_set_string_take(binding, "meta", fl_value_new_bool(FALSE));
  fl_value_set_string_take(binding, "control", fl_value_new_bool(TRUE));
  fl_value_set_string_take(binding, "alt", fl_value_new_bool(TRUE));
  fl_value_set_string_take(binding, "shift", fl_value_new_bool(FALSE));
  return binding;
}

FlValue* MakeConfiguration() {
  FlValue* config = fl_value_new_map();
  fl_value_set_string_take(config, "globalEnabled", fl_value_new_bool(TRUE));
  FlValue* global = fl_value_new_map();
  fl_value_set_string_take(global, "toggle", MakeBinding(4));
  fl_value_set_string_take(config, "global", global);
  return config;
}

void Check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}

void PumpFor(gint64 microseconds) {
  const gint64 end = g_get_monotonic_time() + microseconds;
  while (g_get_monotonic_time() < end) {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  }
}

void SendChord(Display* display, int& dispatched, int expected,
               const char* description) {
  XTestFakeKeyEvent(display, 37, True, CurrentTime);   // Control_L
  XTestFakeKeyEvent(display, 64, True, CurrentTime);   // Alt_L
  XTestFakeKeyEvent(display, 38, True, CurrentTime);   // physical A
  XTestFakeKeyEvent(display, 38, False, CurrentTime);
  XTestFakeKeyEvent(display, 64, False, CurrentTime);
  XTestFakeKeyEvent(display, 37, False, CurrentTime);
  XSync(display, False);
  PumpFor(40000);
  Check(dispatched == expected, description);
}

guint NumLockMask(Display* display) {
  const KeyCode num_lock = XKeysymToKeycode(display, XK_Num_Lock);
  XModifierKeymap* map = XGetModifierMapping(display);
  if (map == nullptr) return 0;
  guint mask = 0;
  for (int modifier = 0; modifier < 8; ++modifier) {
    for (int slot = 0; slot < map->max_keypermod; ++slot) {
      if (map->modifiermap[modifier * map->max_keypermod + slot] == num_lock)
        mask |= 1u << modifier;
    }
  }
  XFreeModifiermap(map);
  return mask;
}

bool GrabExternally(Display* display) {
  x_error_code = 0;
  XSetErrorHandler(RecordXError);
  XGrabKey(display, 38, ControlMask | Mod1Mask, DefaultRootWindow(display),
           True, GrabModeAsync, GrabModeAsync);
  XSync(display, False);
  return x_error_code == 0;
}

}  // namespace

int main() {
  gtk_init(nullptr, nullptr);
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_widget_show(window);

  int dispatched = 0;
  LinuxGlobalShortcuts shortcuts(GTK_WINDOW(window),
      [&dispatched](const std::string& action) {
        if (action == "toggle") ++dispatched;
      }, [](const std::string&) {});
  FlValue* config = MakeConfiguration();
  std::map<std::string, std::string> errors;
  shortcuts.Configure(config, [&errors](std::map<std::string, std::string> result) {
    errors = std::move(result);
  });
  if (!errors.empty()) {
    std::fprintf(stderr, "initial registration failed: %s\n",
                 errors.begin()->second.c_str());
    return 2;
  }

  Display* display = XOpenDisplay(nullptr);
  Display* external = XOpenDisplay(nullptr);
  Check(display != nullptr && external != nullptr,
        "XOpenDisplay should connect to the isolated Xvfb server");
  int event_base = 0, error_base = 0, major = 0, minor = 0;
  Check(XTestQueryExtension(display, &event_base, &error_base, &major, &minor),
        "XTest extension is required");

  // Caps Lock and Num Lock must not prevent a registered shortcut from
  // matching. Save and restore the isolated server's original lock state.
  XkbStateRec state;
  Check(XkbGetState(display, XkbUseCoreKbd, &state) == Success,
        "read initial XKB lock state");
  const guint num_lock_mask = NumLockMask(display);
  const guint lock_mask = LockMask | num_lock_mask;
  const guint saved_locks = state.locked_mods & lock_mask;
  Check(XkbLockModifiers(display, XkbUseCoreKbd, lock_mask, lock_mask),
        "enable Caps Lock and Num Lock modifiers");
  XSync(display, False);
  SendChord(display, dispatched, 1,
            "Ctrl+Alt+A should work with Caps Lock and Num Lock enabled");
  Check(XkbLockModifiers(display, XkbUseCoreKbd, lock_mask, saved_locks),
        "restore XKB lock state");
  XSync(display, False);

  // Hold A long enough for X server auto-repeat. Repeats must not toggle the
  // player more than once until the user releases the key.
  XKeyboardState keyboard_state;
  XGetKeyboardControl(display, &keyboard_state);
  const bool restore_repeat = keyboard_state.global_auto_repeat == AutoRepeatModeOff;
  if (restore_repeat) XAutoRepeatOn(display);
  const int before_repeat = dispatched;
  XTestFakeKeyEvent(display, 37, True, CurrentTime);
  XTestFakeKeyEvent(display, 64, True, CurrentTime);
  XTestFakeKeyEvent(display, 38, True, CurrentTime);
  XSync(display, False);
  PumpFor(1200000);
  XTestFakeKeyEvent(display, 38, False, CurrentTime);
  XTestFakeKeyEvent(display, 64, False, CurrentTime);
  XTestFakeKeyEvent(display, 37, False, CurrentTime);
  XSync(display, False);
  PumpFor(40000);
  if (restore_repeat) XAutoRepeatOff(display);
  Check(dispatched == before_repeat + 1,
        "held-key auto-repeat should dispatch exactly once");

  // Suspending releases this client's grab so another X client can acquire it.
  // A failed registration during the conflict must be reported as occupied.
  shortcuts.Suspend(true);
  PumpFor(20000);
  Check(GrabExternally(external),
        "another X client should grab Ctrl+Alt+A after suspend");
  errors.clear();
  shortcuts.Configure(config, [&errors](std::map<std::string, std::string> result) {
    errors = std::move(result);
  });
  Check(errors.size() == 1 && errors.count("toggle") == 1 &&
            errors.at("toggle") == "controls.occupied",
        "conflicting external grab should report controls.occupied");
  const int while_conflicted = dispatched;
  SendChord(display, dispatched, while_conflicted,
            "failed external conflict must not dispatch");

  XUngrabKey(external, 38, ControlMask | Mod1Mask, DefaultRootWindow(external));
  XSync(external, False);
  errors.clear();
  shortcuts.Configure(config, [&errors](std::map<std::string, std::string> result) {
    errors = std::move(result);
  });
  Check(errors.empty(), "registration should succeed after conflict is released");
  SendChord(display, dispatched, while_conflicted + 1,
            "Ctrl+Alt+A should dispatch again after successful registration");

  // Verify Suspend removes a live grab and Resume restores it from the stored
  // config. This also covers the aliasing/refcount path on resume.
  shortcuts.Suspend(true);
  const int while_suspended = dispatched;
  SendChord(display, dispatched, while_suspended,
            "suspended shortcut should not dispatch");
  shortcuts.Suspend(false);
  errors.clear();
  // Resume registration is asynchronous only in the portal path; X11 invokes
  // the callback synchronously, so the event pump drains it here.
  PumpFor(20000);
  SendChord(display, dispatched, while_suspended + 1,
            "resumed shortcut should dispatch again");

  shortcuts.Dispose();
  fl_value_unref(config);
  XCloseDisplay(external);
  XCloseDisplay(display);
  gtk_widget_destroy(window);
  std::puts("PASS: X11 conflict, lock masks, repeat, suspend, and resume");
  return 0;
}
