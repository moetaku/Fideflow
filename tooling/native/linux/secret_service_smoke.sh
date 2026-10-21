#!/usr/bin/env bash
# Exercise only a private D-Bus/keyring/X server, never the desktop keyring.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

if [ "${1:-}" = --session ]; then
  test_root=$2
  test_mode=$3
  keyring_pid=""
  cleanup_keyring() {
    if [ -n "$keyring_pid" ]; then kill "$keyring_pid" 2>/dev/null || true; wait "$keyring_pid" 2>/dev/null || true; fi
  }
  trap cleanup_keyring EXIT
  export GNOME_KEYRING_CONTROL="$test_root/control"
  export GDK_BACKEND=x11
  # These Debug integration tests exercise the real keyring plugin only.
  # Keep their builds independent from the audio backend under development.
  export FF_ALLOW_MISSING_NATIVE=1
  if [ "$test_mode" != probe ]; then
    cd "$ROOT/apps/fideflow_flutter"
    "$FLUTTER_BINARY" test integration_test/linux_secret_service_test.dart -d linux --no-pub \
      --dart-define=FF_SECRET_TEST_ISOLATED=1 --dart-define=FF_SECRET_TEST_PHASE=unavailable
  fi
  # This is an isolated fixture password; no user credential is read or passed.
  printf '%s' 'fideflow-isolated-keyring-fixture' | \
    gnome-keyring-daemon --foreground --components=secrets --unlock \
      --control-directory "$GNOME_KEYRING_CONTROL" > "$test_root/keyring.log" 2>&1 &
  keyring_pid=$!
  if ! gdbus wait --session --timeout=10 org.freedesktop.secrets; then
    echo 'Private Secret Service failed to start.' >&2
    exit 1
  fi
  printf '%s' 'isolated-fixture-value' | secret-tool store --label='Fideflow isolated validation' \
    application com.moetaku.fideflow.validation key smoke
  result=$(secret-tool lookup application com.moetaku.fideflow.validation key smoke)
  if [ "$result" != isolated-fixture-value ]; then
    echo 'Private Secret Service fixture did not persist.' >&2
    exit 1
  fi
  unset result
  secret-tool clear application com.moetaku.fideflow.validation key smoke
  if [ "$test_mode" != probe ]; then
    "$FLUTTER_BINARY" test integration_test/linux_secret_service_test.dart -d linux --no-pub \
      --dart-define=FF_SECRET_TEST_ISOLATED=1 --dart-define=FF_SECRET_TEST_PHASE=write
    "$FLUTTER_BINARY" test integration_test/linux_secret_service_test.dart -d linux --no-pub \
      --dart-define=FF_SECRET_TEST_ISOLATED=1 --dart-define=FF_SECRET_TEST_PHASE=read-delete
  fi
  echo 'Private Secret Service validation passed.'
  exit 0
fi

mode=full
case "${1:-}" in
  '') ;;
  --probe-only) mode=probe ;;
  *) echo "Usage: $0 [--probe-only]" >&2; exit 2 ;;
esac
for tool in dbus-run-session dbus-daemon gdbus gnome-keyring-daemon secret-tool xvfb-run Xvfb xauth; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool; run tooling/bootstrap-linux.sh --with-validation-tools" >&2
    exit 1
  fi
done
if [ "$mode" = full ]; then
  export FLUTTER_BINARY=${FLUTTER_BINARY:-flutter}
  if ! command -v "$FLUTTER_BINARY" >/dev/null 2>&1; then
    echo 'Set FLUTTER_BINARY to your Flutter executable, or put Flutter on PATH.' >&2
    exit 1
  fi
fi
test_root=$(mktemp -d "${TMPDIR:-/tmp}/fideflow-secret-smoke.XXXXXX")
cleanup_root() {
  # test_root is exclusively created by mktemp above.
  if [ -d "$test_root" ]; then python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$test_root"; fi
}
trap cleanup_root EXIT
export XDG_DATA_HOME="$test_root/data"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_CACHE_HOME="$test_root/cache"
export XDG_RUNTIME_DIR="$test_root/runtime"
mkdir -m 700 "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$test_root/control"
# No standard service directories: the unavailable test cannot autoactivate the
# desktop provider. The only Secret Service is the fixture started above.
cat > "$test_root/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$test_root</listen>
  <auth>EXTERNAL</auth>
  <policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/></policy>
</busconfig>
EOF
xvfb-run -a dbus-run-session --config-file="$test_root/bus.conf" -- \
  "$SCRIPT_DIR/secret_service_smoke.sh" --session "$test_root" "$mode"
