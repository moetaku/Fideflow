#!/usr/bin/env bash
# Build the Linux Rust host against the pinned FFmpeg prefix.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
PROFILE=debug
PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$PROFILE" in debug|release) ;; *) echo "profile must be debug or release" >&2; exit 2 ;; esac
if [ -z "$PREFIX" ]; then
  case "$(uname -m)" in x86_64|aarch64) PREFIX="$ROOT/native/build/third_party/linux/$(uname -m)" ;; *) echo "unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;; esac
fi
"$ROOT/tooling/bootstrap-linux.sh" --scope native
export PATH="$PATH:${CARGO_HOME:-${HOME:?HOME is not set}/.cargo}/bin"
export FF_NATIVE_PREFIX="$PREFIX"
if [ ! -f "$PREFIX/lib/libportaudio.a" ] || [ ! -f "$PREFIX/licenses/portaudio-LICENSE.txt" ]; then
  python3 "$ROOT/tooling/native/linux/build.py" portaudio --arch "$(uname -m)" --prefix "$PREFIX"
fi
args=(build --locked --manifest-path "$ROOT/native/media_core/Cargo.toml" -p fideflow-media-ffi)
if [ "$PROFILE" = release ]; then args+=(--release); fi
cargo "${args[@]}"
