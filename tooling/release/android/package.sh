#!/usr/bin/env bash
# Build, verify and stage the Android release artifacts for the two supported ABIs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
APP="$ROOT/apps/fideflow_flutter"
MOBILE="$ROOT/tooling/native/mobile/build.py"
SKIP_NATIVE=0
usage() {
    echo 'Usage: tooling/release/android/package.sh [--skip-native-build]'
    echo 'Outputs: build/release/android/<version>+<build>/ (APK, release-manifest.json, SHA256SUMS)'
    echo 'Both arm64-v8a and x86_64 are packaged; release signing uses the Gradle keystore.'
}
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-native-build) SKIP_NATIVE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done
case "$(uname -s)" in
    Darwin|Linux) ;;
    *) echo 'macOS or Linux is required' >&2; exit 1 ;;
esac
for tool in flutter python3; do
    command -v "$tool" >/dev/null || { echo "Missing $tool; run tooling/bootstrap-macos.sh" >&2; exit 1; }
done
# Resolve relative paths against android/app, matching Gradle's file().
FIDEFLOW_ANDROID_KEYSTORE_PATH="${FIDEFLOW_ANDROID_KEYSTORE_PATH:-../fideflow-android.jks}"
case "$FIDEFLOW_ANDROID_KEYSTORE_PATH" in
    /*) ;;
    *) FIDEFLOW_ANDROID_KEYSTORE_PATH="$APP/android/app/$FIDEFLOW_ANDROID_KEYSTORE_PATH" ;;
esac
export FIDEFLOW_ANDROID_KEYSTORE_PATH
[ -f "$FIDEFLOW_ANDROID_KEYSTORE_PATH" ] || {
    echo 'Missing release keystore; set FIDEFLOW_ANDROID_KEYSTORE_PATH' >&2
    exit 1
}
: "${FIDEFLOW_ANDROID_KEYSTORE_PASSWORD:?Set FIDEFLOW_ANDROID_KEYSTORE_PASSWORD}"
: "${FIDEFLOW_ANDROID_KEY_PASSWORD:?Set FIDEFLOW_ANDROID_KEY_PASSWORD}"
# Never allow developer UI-only switches to produce a release artifact.
unset FF_SKIP_NATIVE_EMBED FF_NETWORK_MODE
if [ "$SKIP_NATIVE" = 0 ]; then
    python3 "$MOBILE" deps
    python3 "$MOBILE" fetch
    python3 "$MOBILE" build --platform android
else
    python3 "$MOBILE" refresh --platform android
fi
# Native assets are packaged by Gradle; collect both target dependency graphs.
for TRIPLE in aarch64-linux-android x86_64-linux-android; do
    python3 "$ROOT/tooling/release/licenses.py" \
        --target "$ROOT/native/build/mobile/android/assets/licenses" --triple "$TRIPLE" --fetch-metadata
done
(cd "$APP" && flutter build apk --release --target-platform android-arm64,android-x64)
APK="$APP/build/app/outputs/flutter-apk/app-release.apk"
python3 "$ROOT/tooling/release/licenses.py" --verify-archive "$APK" --platform android
[ -f "$APK" ] || { echo "Missing $APK" >&2; exit 1; }
python3 "$MOBILE" verify-apk --apk "$APK"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
APKSIGNER="$SDK/build-tools/36.0.0/apksigner"
[ -x "$APKSIGNER" ] || { echo "Missing $APKSIGNER; install Android build-tools 36.0.0" >&2; exit 1; }
"$APKSIGNER" verify --print-certs "$APK" >/dev/null || { echo 'Release APK is not signed by the Gradle keystore' >&2; exit 1; }
VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$APP/pubspec.yaml" | head -n 1 | tr -d '\r')
[[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "Invalid app version: $VERSION" >&2; exit 1; }
OUT="$ROOT/build/release/android/$VERSION"
[ ! -e "$OUT" ] || { echo "Output exists: $OUT; move it aside before rebuilding" >&2; exit 1; }
mkdir -p "$ROOT/build"
WORK=$(mktemp -d "$ROOT/build/release-android.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
python3 "$ROOT/tooling/release/licenses.py" --sources "$WORK/Fideflow-android-universal-$VERSION-sources.tar.xz" --platform android
cp "$APK" "$WORK/Fideflow-android-universal-$VERSION.apk"
# Record artifact hashes next to the package so the build can be re-checked offline.
python3 - "$ROOT/native/build/mobile/android/jniLibs" "$WORK" "$VERSION" <<'PY'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
artifacts = []
for path in sorted(out.iterdir()):
    if path.is_file():
        artifacts.append({'name': path.name, 'bytes': path.stat().st_size,
                          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
libraries = [{'abi': abi, 'name': lib.name, 'sha256': hashlib.sha256(lib.read_bytes()).hexdigest()}
             for abi in ('arm64-v8a', 'x86_64') for lib in sorted((stage / abi).glob('*.so'))]
assert {entry['abi'] for entry in libraries} == {'arm64-v8a', 'x86_64'}, 'Both ABIs must be staged'
record = {'version': sys.argv[3], 'platform': 'android', 'abis': ['arm64-v8a', 'x86_64'],
          'minimumSdk': 24, 'signing': 'gradle-release-keystore',
          'network': 'off', 'artifacts': artifacts, 'nativeLibraries': libraries}
(out / 'release-manifest.json').write_text(json.dumps(record, indent=2) + '\n')
entries = sorted(out.iterdir())
sums = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in entries if path.is_file())
(out / 'SHA256SUMS').write_text(sums)
PY
mkdir -p "$(dirname "$OUT")"
mv "$WORK" "$OUT"
printf 'Android release artifacts: %s\n' "$OUT"
