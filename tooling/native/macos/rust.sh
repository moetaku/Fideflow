#!/usr/bin/env bash
#
# Builds, fixes up and verifies the Rust media host (docs/design/boundaries.md、docs/design/native-build.md).
#
# `cargo build -p fideflow-media-ffi` produces `libff_media_core.dylib`, the one
# library this project ships that is not a third-party dependency. Getting it
# into an app bundle takes three steps that are easy to get wrong by hand, which
# is why they live here:
#
#   1. build one slice per architecture with the matching pinned FFmpeg prefix,
#      so `media-pipeline`'s C shim and link step use that architecture's headers
#      and libraries;
#   2. flatten it: `lipo` the slices into one file, force the install name to
#      `@rpath/libff_media_core.dylib`, and rewrite every dependency that points
#      into a build prefix to `@rpath/<canonical>`, exactly like embed.sh does for
#      the third-party set. A `/Users/...` path in a signed bundle is the failure
#      this prevents;
#   3. re-sign, because `install_name_tool` invalidates the linker's signature and
#      an arm64 process refuses to load an unsigned dynamic library.
#
# Modes:
#   rust.sh build   Build (and fix up) into a staging directory.
#   rust.sh stage   Same, but at the path embed.sh passes: it also prints the
#                   staged name so the caller can register it.
#   rust.sh probe   Compile checks/abi_probe.c against schemas/media_core.h and run
#                   it against a bundle-shaped directory that already contains the
#                   packaged set, so the ABI is verified through `@rpath`.
#
# Usage: tooling/native/macos/rust.sh <mode> [options]
#
# Written for the macOS system bash 3.2: no associative arrays, no mapfile.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NATIVE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$NATIVE_DIR/../.." && pwd)
MANIFEST="$REPO_ROOT/native/media_core/Cargo.toml"
ABI_PROBE_SRC="$NATIVE_DIR/checks/abi_probe.c"
SCHEMA_DIR="$REPO_ROOT/schemas"
PREFIX_BASE="$REPO_ROOT/native/build/third_party/macos"

# Shipped file name. Keep it in step with the crate's `[lib] name` and with the
# `-install_name` in crates/media-ffi/build.rs; tooling/check_contracts.py
# asserts the three agree.
LIB_NAME="libff_media_core.dylib"
CRATE="fideflow-media-ffi"
PROFILE_DIR="release"
RUSTFLAGS_EXTRA="-C link-arg=-mmacosx-version-min=12.0"

ARCHS=""
STAGE_DIR=""
BUNDLE_DIR=""
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
ALLOW_MISSING=0
HOST_ARCH="$(uname -m)"
MODE=""
TMP=""

# Progress goes to stderr so stdout carries only the resulting path, which is what
# a caller (and a runbook) can quote.
log() { printf '[rust] %s\n' "$*" >&2 ; }
warn() { printf '[rust] warning: %s\n' "$*" >&2; }
die() {
    printf '[rust] error: %s\n' "$*" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# rustup's installer places its proxies here. Xcode inherits PATH from the
# process that launched `flutter run`, and that process may not have sourced
# ~/.cargo/env (for example a GUI terminal). Use the standard rustup location as
# a fallback without changing the user's shell profile.
CARGO_BIN_DIR="${CARGO_HOME:-${HOME:?HOME is not set}/.cargo}/bin"
if ! have cargo && [ -x "$CARGO_BIN_DIR/cargo" ]; then
    PATH="$CARGO_BIN_DIR:$PATH"
    export PATH
fi

cleanup() {
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Fideflow Rust media host builder (docs/design/boundaries.md, docs/design/native-build.md)

Modes
  build                 Build the library into --stage (default: a temp dir)
  stage                 Alias of build that prints the staged file name
  probe                 Run the ABI probe against --bundle

Options
  --arch LIST           Architectures to build (default: uname -m)
  --stage DIR           Where to put the rebuilt library
  --bundle DIR          Bundle-shaped directory for probe (needs Contents/Frameworks)
  --sign IDENTITY       Codesign identity for the library (default: ad-hoc "-")
  --allow-missing       Warn and exit 0 when cargo, a Rust target or a prefix is
                        missing; the app then runs without the Rust host
  --host-arch ARCH      Architecture the probe binary is built for (default uname -m)
  -h, --help            This text
EOF
}

map_target() {
    case "$1" in
        arm64) printf 'aarch64-apple-darwin\n' ;;
        x86_64) printf 'x86_64-apple-darwin\n' ;;
        *) die "unsupported architecture '$1' (arm64|x86_64)" ;;
    esac
}

prefix_for() {
    printf '%s/%s\n' "$PREFIX_BASE" "$1"
}

deployment_target() {
    python3 - "$REPO_ROOT/tooling/native/sources.manifest.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    print(json.load(handle)["deploymentTarget"])
PY
}

resolve_archs() {
    if [ -n "$ARCHS" ]; then
        printf '%s\n' "$ARCHS"
        return 0
    fi
    printf '%s\n' "$HOST_ARCH"
}

# Sorted, space-separated architecture list without duplicates.
clean_archs() {
    local arch cleaned=""
    for arch in $1; do
        case "$arch" in
            undefined_arch | "") continue ;;
        esac
        case " $cleaned " in
            *" $arch "*) continue ;;
        esac
        cleaned="$cleaned $arch"
    done
    printf '%s\n' "${cleaned# }"
}

require_tools() {
    for tool in cargo lipo install_name_tool otool codesign; do
        have "$tool" || missing_tool "$tool"
    done
}

missing_tool() {
    if [ "$ALLOW_MISSING" = 1 ]; then
        warn "$1 is not installed; skipping the Rust media host"
        warn "install the Rust toolchain (cargo) to build it"
        exit 0
    fi
    die "$1 is required to build the Rust media host"
}

require_prefix() {
    local arch="$1" prefix
    prefix=$(prefix_for "$arch")
    if [ ! -f "$prefix/lib/libavformat.dylib" ]; then
        if [ "$ALLOW_MISSING" = 1 ]; then
            warn "no pinned FFmpeg prefix for $arch at $prefix"
            warn "run: tooling/native/macos/build.sh build --arch $arch"
            exit 0
        fi
        die "no pinned FFmpeg prefix for $arch at $prefix; run tooling/native/macos/build.sh build --arch $arch"
    fi
}

require_target() {
    local triple="$1"
    if ! rustup target list --installed 2>/dev/null | grep -qx "$triple"; then
        if rustup target list --installed >/dev/null 2>&1; then
            if [ "$ALLOW_MISSING" = 1 ]; then
                warn "the Rust target $triple is not installed; skipping the Rust media host"
                exit 0
            fi
            die "the Rust target $triple is not installed; run: rustup target add $triple"
        fi
    fi
}

# Builds one architecture slice and prints the path to the freshly built dylib.
build_slice() {
    local arch="$1" triple prefix
    triple=$(map_target "$arch")
    prefix=$(prefix_for "$arch")
    log "building $CRATE for $triple (prefix: $prefix)"
    if ! FF_NATIVE_PREFIX="$prefix" \
        MACOSX_DEPLOYMENT_TARGET="$(deployment_target)" \
        RUSTFLAGS="${RUSTFLAGS:-} $RUSTFLAGS_EXTRA" \
        cargo build --manifest-path "$MANIFEST" -p "$CRATE" --profile release \
        --target "$triple" >"$TMP/cargo-$arch.log" 2>&1; then
        tail -25 "$TMP/cargo-$arch.log" >&2
        die "cargo failed for $triple (full log: $TMP/cargo-$arch.log)"
    fi
    local artifact="$REPO_ROOT/native/media_core/target/$triple/$PROFILE_DIR/$LIB_NAME"
    [ -f "$artifact" ] || die "cargo produced no $LIB_NAME for $triple"
    printf '%s\n' "$artifact"
}

dylib_id() {
    otool -D "$1" | grep -v ':$' | grep -v '^$' | awk '!seen[$0]++'
}

# Load commands only: `otool -L` prints one header line per architecture, and the
# dependency lines are the ones carrying a compatibility version.
dylib_dependencies() {
    otool -L "$1" |
        sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*(compatibility version.*/\1/p' |
        awk '!seen[$0]++'
}

mins_of() {
    otool -l "$1" | awk '/LC_BUILD_VERSION/{found=1} found&&/minos/{print $2; exit}'
}

# Canonical name of a packaged library from a dependency path.
canonical_name() {
    local base
    base=$(basename "$1")
    case "$base" in
        lib*.dylib) printf '%s\n' "$base" ;;
        lib*) printf '%s\n' "${base%%.dylib*}.dylib" ;;
        *) return 1 ;;
    esac
}

fixup_library() {
    local library="$1" target="$2" dep base canonical
    local want="@rpath/$LIB_NAME"
    if [ "$(dylib_id "$library")" != "$want" ]; then
        install_name_tool -id "$want" "$library" 2>/dev/null ||
            die "could not set the install name of $library"
    fi
    for dep in $(dylib_dependencies "$library" | grep -vF "$want"); do
        case "$dep" in
            @rpath/*)
                base="${dep#@rpath/}"
                canonical=$(canonical_name "$base") ||
                    die "$LIB_NAME depends on unrecognised $dep"
                if [ "$dep" != "@rpath/$canonical" ]; then
                    install_name_tool -change "$dep" "@rpath/$canonical" "$library" 2>/dev/null
                fi
                ;;
            /usr/lib/* | /System/Library/*) ;;
            "$PREFIX_BASE"/* | "$REPO_ROOT"/*)
                # The link step found FFmpeg in the pinned prefix; in the bundle
                # every library is a sibling, so rewrite it to @rpath.
                canonical=$(canonical_name "$dep") ||
                    die "$LIB_NAME links a build-tree path that is not a library: $dep"
                log "rewriting $canonical to @rpath/$canonical"
                install_name_tool -change "$dep" "@rpath/$canonical" "$library" 2>/dev/null
                ;;
            *) die "$LIB_NAME links unexpected $dep" ;;
        esac
    done
    # A shipped library must not carry a developer's build path as an rpath.
    local rpath
    for rpath in $(otool -l "$library" | awk '/LC_RPATH/{found=1} found&&/path /{print $2; found=0}'); do
        case "$rpath" in
            @loader_path | @executable_path/* | /usr/lib/* | /System/Library/*) ;;
            *)
                warn "removing build-tree rpath $rpath from $LIB_NAME"
                install_name_tool -delete_rpath "$rpath" "$library" 2>/dev/null || true
                ;;
        esac
    done
    [ "$target" = "$(mins_of "$library")" ] ||
        die "$LIB_NAME has minos $(mins_of "$library"), expected $target"
    codesign --force --sign "$SIGN_IDENTITY" "$library" >/dev/null 2>&1 ||
        die "codesign failed for $library (identity: $SIGN_IDENTITY)"
}

do_build() {
    local archs stage
    archs=$(clean_archs "$(resolve_archs)")
    [ -n "$archs" ] || die "no architecture to build"
    require_tools
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/ff-rust.XXXXXX")
    stage="${STAGE_DIR:-$TMP/stage}"
    mkdir -p "$stage"

    local slices="" slice
    for arch in $archs; do
        require_prefix "$arch"
        require_target "$(map_target "$arch")"
        slice=$(build_slice "$arch")
        slices="$slices $slice"
    done

    local staged="$stage/$LIB_NAME"
    local count=0
    for _ in $slices; do count=$((count + 1)); done
    if [ "$count" -gt 1 ]; then
        log "merging $count slices into $LIB_NAME"
        lipo -create $slices -output "$staged" || die "lipo failed for $LIB_NAME"
    else
        cp -f "$(printf '%s\n' $slices | head -1)" "$staged"
    fi
    chmod u+w "$staged"
    fixup_library "$staged" "$(deployment_target)"

    local found
    found=$(lipo -archs "$staged")
    for arch in $archs; do
        case " $found " in
            *" $arch "*) ;;
            *) die "$LIB_NAME lacks the $arch slice (has: $found)" ;;
        esac
    done
    log "built $LIB_NAME for $found: $(basename "$staged")"
    printf '%s\n' "$staged"
}

do_probe() {
    [ -n "$BUNDLE_DIR" ] || die "probe needs --bundle DIR"
    [ -d "$BUNDLE_DIR/Contents/Frameworks" ] ||
        die "$BUNDLE_DIR/Contents/Frameworks does not exist; run embed.sh first"
    [ -f "$ABI_PROBE_SRC" ] || die "missing $ABI_PROBE_SRC"
    have clang || die "clang is required for the ABI probe"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/ff-abi.XXXXXX")
    mkdir -p "$TMP/bundle/Contents/MacOS"
    ln -s "$BUNDLE_DIR/Contents/Frameworks" "$TMP/bundle/Contents/Frameworks"
    local binary="$TMP/bundle/Contents/MacOS/abi-probe"
    local target
    target=$(deployment_target)
    log "compiling the ABI probe against schemas/media_core.h"
    # The rpath makes the probe resolve `@rpath/libff_media_core.dylib` through
    # its own bundle layout, which is exactly how the app loads it.
    if ! clang -arch "$HOST_ARCH" "-mmacosx-version-min=$target" -O1 -Wall -Wextra \
        -I"$SCHEMA_DIR" -Wl,-rpath,@executable_path/../Frameworks \
        "$ABI_PROBE_SRC" -o "$binary" >"$TMP/probe.log" 2>&1; then
        tail -20 "$TMP/probe.log" >&2
        die "the ABI probe did not compile"
    fi
    codesign --force --sign - "$binary" >/dev/null 2>&1 || true
    log "running the ABI probe through @executable_path/../Frameworks"
    if ! "$binary" >>"$TMP/probe.log" 2>&1; then
        tail -30 "$TMP/probe.log" >&2
        die "the ABI probe failed"
    fi
    tail -1 "$TMP/probe.log"
}

while [ $# -gt 0 ]; do
    case "$1" in
        build | stage | probe) MODE="$1" ;;
        --arch=*) ARCHS="${1#*=}" ;;
        --arch)
            [ $# -ge 2 ] || die "--arch needs a value"
            ARCHS="$2"
            shift
            ;;
        --stage=*) STAGE_DIR="${1#*=}" ;;
        --stage)
            [ $# -ge 2 ] || die "--stage needs a value"
            STAGE_DIR="$2"
            shift
            ;;
        --bundle=*) BUNDLE_DIR="${1#*=}" ;;
        --bundle)
            [ $# -ge 2 ] || die "--bundle needs a value"
            BUNDLE_DIR="$2"
            shift
            ;;
        --sign=*) SIGN_IDENTITY="${1#*=}" ;;
        --sign)
            [ $# -ge 2 ] || die "--sign needs a value"
            SIGN_IDENTITY="$2"
            shift
            ;;
        --allow-missing) ALLOW_MISSING=1 ;;
        --host-arch=*) HOST_ARCH="${1#*=}" ;;
        --host-arch)
            [ $# -ge 2 ] || die "--host-arch needs a value"
            HOST_ARCH="$2"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

case "$MODE" in
    build | stage) do_build ;;
    probe) do_probe ;;
    "") usage && exit 2 ;;
esac
