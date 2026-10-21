#!/usr/bin/env bash
# Build a release bundle on this Linux host and register it for the current user.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
APP="$ROOT/apps/fideflow_flutter"

"$ROOT/tooling/bootstrap-linux.sh" --for build
tooling_flutter=$(command -v flutter || true)
if [ -z "$tooling_flutter" ]; then
  for candidate in \
    "${FLUTTER_ROOT:-}/bin/flutter" \
    "${HOME:?HOME must be set}/.local/share/fideflow/toolchains/flutter/bin/flutter" \
    "$HOME/Public/flutter/bin/flutter" "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" /opt/flutter/bin/flutter; do
    if [ -x "$candidate" ]; then tooling_flutter=$candidate; break; fi
  done
fi
[ -x "$tooling_flutter" ] || { echo "Flutter SDK is unavailable after dependency preparation: $tooling_flutter" >&2; exit 1; }
"$ROOT/tooling/native/linux/build.sh" all --arch host
(
  cd "$APP"
  "$tooling_flutter" pub get
  "$tooling_flutter" build linux --release
)

version=$(sed -n 's/^version:[[:space:]]*//p' "$APP/pubspec.yaml" | head -n 1 | tr -d '\r')
[[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "Invalid app version: $version" >&2; exit 1; }
case "$(uname -m)" in
  x86_64|aarch64) flutter_arch=$( [ "$(uname -m)" = aarch64 ] && printf arm64 || printf x64 ) ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac
bundle="$APP/build/linux/$flutter_arch/release/bundle"
python3 "$ROOT/tooling/native/linux/verify_bundle.py" "$bundle"

install_root="${HOME:?HOME must be set}/.local/opt/fideflow"
destination="$install_root/$version"
mkdir -p "$install_root"
if [ -e "$destination" ]; then
  echo "Version $version is already installed at $destination; update pubspec.yaml before reinstalling." >&2
  exit 1
fi
staging=$(mktemp -d "$install_root/.install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
cp -a "$bundle" "$staging/bundle"
mv "$staging/bundle" "$destination"
python3 "$APP/linux/runner/resources/install-desktop-entry.py" --bundle "$destination"
printf 'Installed Fideflow %s for this user at %s\n' "$version" "$destination"
