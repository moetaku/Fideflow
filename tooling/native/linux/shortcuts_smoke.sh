#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
app_root="$repo_root/apps/fideflow_flutter"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

mkdir -m 700 "$build_dir/runtime" "$build_dir/config" "$build_dir/data" "$build_dir/cache"
export XDG_RUNTIME_DIR="$build_dir/runtime" XDG_CONFIG_HOME="$build_dir/config"
export XDG_DATA_HOME="$build_dir/data" XDG_CACHE_HOME="$build_dir/cache"
export NO_AT_BRIDGE=1 GTK_USE_PORTAL=0 GSETTINGS_BACKEND=memory

cxx="${CXX:-c++}"
pkg_config="${PKG_CONFIG:-pkg-config}"
read -r -a gtk_cflags <<<"$($pkg_config --cflags gtk+-3.0 xtst)"
read -r -a gtk_libs <<<"$($pkg_config --libs gtk+-3.0 xtst x11)"

"$cxx" -std=c++14 -Wall -Wextra -Werror \
  "${gtk_cflags[@]}" \
  -I"$app_root/linux/flutter/ephemeral" \
  "$app_root/linux/runner/linux_global_shortcuts_probe.cc" \
  "$app_root/linux/runner/linux_global_shortcuts.cc" \
  -L"$app_root/linux/flutter/ephemeral" \
  -Wl,-rpath,"$app_root/linux/flutter/ephemeral" \
  -lflutter_linux_gtk "${gtk_libs[@]}" \
  -o "$build_dir/linux_global_shortcuts_probe"

dbus-run-session -- xvfb-run -a "$build_dir/linux_global_shortcuts_probe"

"$cxx" -std=c++14 -Wall -Wextra -Werror \
  "${gtk_cflags[@]}" \
  -I"$app_root/linux/flutter/ephemeral" \
  "$app_root/linux/runner/linux_global_shortcuts_portal_probe.cc" \
  "$app_root/linux/runner/linux_global_shortcuts.cc" \
  -L"$app_root/linux/flutter/ephemeral" \
  -Wl,-rpath,"$app_root/linux/flutter/ephemeral" \
  -lflutter_linux_gtk "${gtk_libs[@]}" \
  -o "$build_dir/linux_global_shortcuts_portal_probe"

dbus-run-session -- "$build_dir/linux_global_shortcuts_portal_probe"
