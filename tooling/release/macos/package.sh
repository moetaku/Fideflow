#!/usr/bin/env bash
# Build and package separate architecture-specific, ad-hoc signed macOS Release for testing.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SKIP_NATIVE=0
TARGET=all
usage() {
    echo 'Usage: tooling/release/macos/package.sh [--arch arm64|x86_64|all] [--skip-native-build]'
    echo 'Outputs: build/release/macos/<version>+<build>/<arch>/ (.app, ZIP, DMG, SHA256SUMS)'
    echo 'Ad-hoc signed test artifacts; Developer ID signing and notarization are separate.'
}
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) shift; TARGET="${1:?--arch needs arm64, x86_64 or all}" ;;
        --skip-native-build) SKIP_NATIVE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done
case "$TARGET" in
    all) TARGETS="arm64 x86_64" ;;
    arm64|x86_64) TARGETS="$TARGET" ;;
    *) echo "Invalid architecture: $TARGET" >&2; exit 1 ;;
esac
[ "$(uname -s)" = Darwin ] || { echo 'macOS is required' >&2; exit 1; }
for tool in flutter python3 xcodebuild ditto hdiutil shasum codesign lipo; do
    command -v "$tool" >/dev/null || { echo "Missing $tool; run tooling/bootstrap-macos.sh" >&2; exit 1; }
done
# Never allow developer UI-only switches to produce a release artifact.
unset FF_SKIP_NATIVE_EMBED FF_NETWORK_MODE
for ARCH in $TARGETS; do
if [ "$SKIP_NATIVE" = 0 ]; then
    "$ROOT/tooling/native/macos/build.sh" --arch "$ARCH"
else
    "$ROOT/tooling/native/macos/build.sh" verify --arch "$ARCH"
fi
(cd "$ROOT/apps/fideflow_flutter" && FLUTTER_XCODE_ARCHS="$ARCH" FLUTTER_XCODE_ONLY_ACTIVE_ARCH=NO flutter build macos --release)
SOURCE="$ROOT/apps/fideflow_flutter/build/macos/Build/Products/Release/fideflow.app"
[ -d "$SOURCE" ] || { echo "Missing $SOURCE" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Contents/Info.plist")
case "$VERSION+$NUMBER" in *[!0-9.+]*) echo 'Invalid bundle version' >&2; exit 1 ;; esac
OUT="$ROOT/build/release/macos/$VERSION+$NUMBER/$ARCH"
[ ! -e "$OUT" ] || { echo "Output exists: $OUT; move it aside before rebuilding" >&2; exit 1; }
WORK=$(mktemp -d "$ROOT/build/release-macos.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/fideflow.app"
ditto "$SOURCE" "$APP"
# Ship all collected native notices, not only the PortAudio notice embedded by Xcode.
mkdir -p "$APP/Contents/Resources/licenses"
# Remove the legacy spelling before ditto; APFS may otherwise preserve its case.
python3 - "$APP/Contents/Resources/licenses" <<'PYLICENSE'
from pathlib import Path
import sys
(Path(sys.argv[1]) / "PortAudio-LICENSE.txt").unlink(missing_ok=True)
PYLICENSE
ditto "$ROOT/native/build/third_party/macos/$ARCH/licenses" "$APP/Contents/Resources/licenses"
case "$ARCH" in
    arm64) TRIPLE=aarch64-apple-darwin ;;
    x86_64) TRIPLE=x86_64-apple-darwin ;;
esac
python3 "$ROOT/tooling/release/licenses.py" \
    --target "$APP/Contents/Resources/licenses" --triple "$TRIPLE" --fetch-metadata \
    --notices "$APP/Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z"
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP"
"$ROOT/tooling/native/macos/embed.sh" --app "$APP" --arch "$ARCH" --host-arch "$ARCH" --verify-only
# Check every Mach-O, including Flutter frameworks and the main executable.
python3 - "$APP" "$ARCH" <<'PY'
import pathlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
assert (app / 'Contents/Frameworks/libff_media_core.dylib').is_file()
magics = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
count = 0
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic in magics:
        archs = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
        if set(archs) != {sys.argv[2]}:
            raise SystemExit(f'Wrong architecture: {path}: {archs}')
        count += 1
assert count > 0
print(f'Verified {count} {sys.argv[2]} Mach-O files')
PY
NAME="Fideflow-macos-$ARCH-$VERSION+$NUMBER"
python3 "$ROOT/tooling/release/licenses.py" --sources "$WORK/$NAME-sources.tar.xz" --platform macos
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/$NAME.zip"
python3 "$ROOT/tooling/release/licenses.py" --verify-archive "$WORK/$NAME.zip" --platform macos
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/fideflow.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname Fideflow -srcfolder "$WORK/dmg" -format UDZO "$WORK/$NAME.dmg"
hdiutil verify "$WORK/$NAME.dmg"
# Verify ZIP restoration preserves the app signature.
ditto -x -k "$WORK/$NAME.zip" "$WORK/unpacked"
codesign --verify --deep --strict "$WORK/unpacked/fideflow.app"
mkdir -p "$OUT"
mv "$APP" "$WORK/$NAME.zip" "$WORK/$NAME.dmg" "$WORK/$NAME-sources.tar.xz" "$OUT/"
(cd "$OUT" && shasum -a 256 "$NAME.zip" "$NAME.dmg" "$NAME-sources.tar.xz" > SHA256SUMS)
rm -rf "$WORK"
printf 'Release test artifacts (ad-hoc signed, not notarized): %s\n' "$OUT"
done
