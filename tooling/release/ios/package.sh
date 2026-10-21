#!/usr/bin/env bash
# Build and stage an unsigned iOS release payload (IPA); signing is left to the distributor.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
APP="$ROOT/apps/fideflow_flutter"
MOBILE="$ROOT/tooling/native/mobile/build.py"
SKIP_NATIVE=0
usage() {
    echo 'Usage: tooling/release/ios/package.sh [--skip-native-build]'
    echo 'Outputs: build/release/ios/<version>+<build>/ (unsigned IPA, Payload, release-manifest.json, SHA256SUMS)'
    echo 'No signing identity, provisioning profile or notarization is applied.'
}
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-native-build) SKIP_NATIVE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done
[ "$(uname -s)" = Darwin ] || { echo 'macOS with Xcode is required' >&2; exit 1; }
for tool in flutter python3 xcodebuild ditto lipo codesign; do
    command -v "$tool" >/dev/null || { echo "Missing $tool; run tooling/bootstrap-macos.sh" >&2; exit 1; }
done
# Never allow developer UI-only switches to produce a release artifact.
unset FF_SKIP_NATIVE_EMBED FF_NETWORK_MODE
if [ "$SKIP_NATIVE" = 0 ]; then
    python3 "$MOBILE" deps
    python3 "$MOBILE" fetch
    python3 "$MOBILE" build --platform ios
else
    python3 "$MOBILE" refresh --platform ios
fi
# Build without any signing identity; the result must stay installable only after re-signing.
(cd "$APP" && flutter build ios --release --no-codesign)
SOURCE="$APP/build/ios/iphoneos/Runner.app"
[ -d "$SOURCE" ] || { echo "Missing $SOURCE" >&2; exit 1; }
# Assert the payload is genuinely unsigned instead of trusting the build flag.
[ ! -e "$SOURCE/_CodeSignature" ] || { echo 'Expected an unsigned app, found _CodeSignature' >&2; exit 1; }
[ ! -e "$SOURCE/embedded.mobileprovision" ] || { echo 'Expected an unsigned app, found a provisioning profile' >&2; exit 1; }
if codesign --verify --strict "$SOURCE" >/dev/null 2>&1; then
    echo 'Expected an unsigned app, but codesign verification succeeded' >&2
    exit 1
fi
[ "$(lipo -archs "$SOURCE/Runner")" = arm64 ] || { echo 'Expected an arm64 device binary' >&2; exit 1; }
for framework in FFMediaCore AVFormat AVCodec AVUtil SWResample SoXR; do
    [ -d "$SOURCE/Frameworks/$framework.framework" ] || { echo "Missing $framework.framework" >&2; exit 1; }
done
[ -f "$SOURCE/native-audio/build-manifest.json" ] || { echo 'Missing embedded native audio evidence' >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Info.plist")
case "$VERSION+$NUMBER" in *[!0-9.+]*) echo 'Invalid bundle version' >&2; exit 1 ;; esac
OUT="$ROOT/build/release/ios/$VERSION+$NUMBER"
[ ! -e "$OUT" ] || { echo "Output exists: $OUT; move it aside before rebuilding" >&2; exit 1; }
mkdir -p "$ROOT/build"
WORK=$(mktemp -d "$ROOT/build/release-ios.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
ditto "$SOURCE" "$WORK/Payload/Runner.app"
NAME="Fideflow-ios-arm64-$VERSION+$NUMBER"
python3 "$ROOT/tooling/release/licenses.py" \
    --target "$WORK/Payload/Runner.app/native-audio/licenses" --triple aarch64-apple-ios --fetch-metadata \
    --notices "$WORK/Payload/Runner.app/Frameworks/App.framework/flutter_assets/NOTICES.Z"
python3 "$ROOT/tooling/release/licenses.py" --sources "$WORK/$NAME-sources.tar.xz" --platform ios
ditto -c -k --sequesterRsrc --keepParent "$WORK/Payload" "$WORK/$NAME.ipa"
python3 "$ROOT/tooling/release/licenses.py" --verify-archive "$WORK/$NAME.ipa" --platform ios
# The IPA must carry the whole Payload directory and stay free of signatures.
python3 - "$WORK/$NAME.ipa" "$NAME" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = {entry.filename for entry in archive.infolist()}
required = {'Payload/Runner.app/Runner', 'Payload/Runner.app/Info.plist'}
missing = required - names
assert not missing, f'IPA is missing {sorted(missing)}'
assert not any(name.startswith(('Payload/Runner.app/_CodeSignature/', 'Payload/Runner.app/embedded.mobileprovision')) for name in names), 'IPA must stay unsigned'
PY
cat > "$WORK/INSTALL.txt" <<'TXT'
This IPA is unsigned and cannot be installed as-is.
Re-sign it with your own development identity before installing, for example:
  unzip the IPA, run `codesign --force --deep --sign "Apple Development: ..." Payload/Runner.app`,
  re-create the Payload ZIP, then install with Xcode or a deployment tool.
TXT
python3 - "$WORK" "$VERSION+$NUMBER" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
artifacts = [{'name': path.name, 'bytes': path.stat().st_size,
              'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
             for path in sorted(out.iterdir()) if path.is_file() and path.suffix in {'.ipa', '.txt', '.xz'}]
record = {'version': sys.argv[2], 'platform': 'ios', 'architecture': 'arm64',
          'minimumIos': '15.0', 'signing': 'unsigned', 'notarized': False,
          'network': 'off', 'artifacts': artifacts}
(out / 'release-manifest.json').write_text(json.dumps(record, indent=2) + '\n')
sums = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n'
               for path in sorted(out.iterdir()) if path.is_file())
(out / 'SHA256SUMS').write_text(sums)
PY
mkdir -p "$(dirname "$OUT")"
mv "$WORK" "$OUT"
printf 'Unsigned iOS release artifacts: %s\n' "$OUT"
