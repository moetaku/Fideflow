// Verify stable identity and duplicate activation on a private session bus.
#include "linux_instance_identity.h"
#include <gio/gio.h>
#include <cstdio>

int main(int argc, char** argv) {
#if GLIB_CHECK_VERSION(2, 74, 0)
  constexpr auto flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  constexpr auto flags = G_APPLICATION_FLAGS_NONE;
#endif
  if (argc > 1) {
    g_autoptr(GApplication) peer = g_application_new(
        kFideflowDesktopApplicationId, flags);
    g_autoptr(GError) error = nullptr;
    if (!g_application_register(peer, nullptr, &error) ||
        !g_application_get_is_remote(peer)) return 1;
    g_application_activate(peer);
    return 0;
  }
  g_autoptr(GTestDBus) bus = g_test_dbus_new(G_TEST_DBUS_NONE);
  g_test_dbus_up(bus);
  g_autoptr(GApplication) app = g_application_new(
      kFideflowDesktopApplicationId, flags);
  int activations = 0;
  g_signal_connect(app, "activate", G_CALLBACK(+[](GApplication*, gpointer data) {
    ++*static_cast<int*>(data);
  }), &activations);
  g_autoptr(GError) error = nullptr;
  if (!g_application_register(app, nullptr, &error)) return 1;
  g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(
      G_SUBPROCESS_FLAGS_NONE);
  // A different profile must still activate the existing application.
  g_subprocess_launcher_setenv(launcher, "XDG_DATA_HOME", "/tmp/fideflow-other-profile", TRUE);
  g_autoptr(GSubprocess) peer = g_subprocess_launcher_spawn(
      launcher, &error, argv[0], "--peer", nullptr);
  if (!peer) return 1;
  struct Result { GMainLoop* loop; bool success; } result{g_main_loop_new(nullptr, FALSE), false};
  g_subprocess_wait_check_async(peer, nullptr,
      +[](GObject* object, GAsyncResult* finished, gpointer data) {
        auto* result = static_cast<Result*>(data);
        result->success = g_subprocess_wait_check_finish(G_SUBPROCESS(object), finished, nullptr);
        g_main_loop_quit(result->loop);
      }, &result);
  guint timeout = g_timeout_add_seconds(10, +[](gpointer data) -> gboolean {
    g_main_loop_quit(static_cast<Result*>(data)->loop);
    return G_SOURCE_CONTINUE;
  }, &result);
  g_main_loop_run(result.loop);
  g_source_remove(timeout);
  g_main_loop_unref(result.loop);
  if (!result.success) g_subprocess_force_exit(peer);
  const bool ok = result.success && activations == 1;
  if (!ok) std::fprintf(stderr, "FAIL: duplicate must activate existing stable application\n");
  else std::puts("Linux stable application identity and single-instance checks passed.");
  return ok ? 0 : 1;
}
