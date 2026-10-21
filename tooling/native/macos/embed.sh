#!/usr/bin/env bash
#
# Fideflow macOS app-bundle embedder.
#
# Takes the libraries that tooling/native/macos/build.sh produced in
# native/build/third_party/macos/<arch>/lib and puts them inside a .app bundle:
#
#   <app>/Contents/Frameworks/<lib>.dylib        one flattened dylib per library
#   <app>/Contents/Resources/native-libraries.json   what was packaged
#
# FFmpeg networking is disabled. HTTP/HTTPS and trust validation belong to the
# Dart host; old OpenSSL libraries and CA resources are removed from the bundle.
# Flattening matters: the build prefix keeps versioned aliases and symlinks
# (`libavcodec.61.dylib` -> `libavcodec.61.19.101.dylib`), and an Xcode copy phase
# or a signing tool may not preserve them. Every embedded dylib is therefore
# rewritten to a single canonical name: id `@rpath/libX.dylib`, and every
# dependency on a packaged library rewritten to `@rpath/libX.dylib` as well. The
# app binary resolves those through its existing `@executable_path/../Frameworks`
# rpath (LD_RUNPATH_SEARCH_PATHS in the Runner target).
#
# The script is used two ways:
#   * from the Runner target's "Embed Native Libraries" Xcode run-script phase,
#     where it reads CODESIGNING_FOLDER_PATH, ARCHS and EXPANDED_CODE_SIGN_IDENTITY
#     and must not re-sign the app bundle itself (Xcode signs it afterwards);
#   * standalone (CI, release tooling, debugging), where it re-seals the app
#     bundle with the same entitlements it already had.
#
# Usage: tooling/native/macos/embed.sh [options]
#
# Written for the macOS system bash 3.2: no associative arrays, no mapfile.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NATIVE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$NATIVE_DIR/../.." && pwd)
MANIFEST_PY="$NATIVE_DIR/manifest.py"
CAPCHECK_SRC="$NATIVE_DIR/checks/capcheck.c"
RUST_SH="$SCRIPT_DIR/rust.sh"
# The Rust media host, built and staged by rust.sh. It is part of the packaged
# set: it links the FFmpeg libraries that land beside it and is what the Dart host
# loads, so it is embedded, verified and reported like every other library.
RUST_LIB_NAME="libff_media_core.dylib"
BASE_DIR="$REPO_ROOT/native/build/third_party"

APP=""
ARCH_FLAG=""
NETWORK_MODE="${FF_NETWORK_MODE:-}"
SIGN_IDENTITY=""
PREFIX_OVERRIDE=""
FROM_XCODE=0
RESEAL="" # empty: decide from the environment
VERIFY=1
VERIFY_ONLY=0
ALLOW_MISSING=0
ALLOW_MISSING_RUST=0
RUST=1
FORCE=0
KEEP_TEMP=0
HOST_ARCH="$(uname -m)"
TMP=""

log() { printf '[embed] %s\n' "$*"; }
warn() { printf '[embed] warning: %s\n' "$*" >&2; }
die() {
    printf '[embed] error: %s\n' "$*" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    if [ -n "$TMP" ] && [ -d "$TMP" ] && [ "$KEEP_TEMP" != 1 ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Fideflow macOS app-bundle embedder (docs/design/native-build.md, docs/design/native-build.md)

Options
  --app PATH             The .app bundle to write into (default: $CODESIGNING_FOLDER_PATH)
  --arch LIST            Architectures to embed (default: $ARCHS, $CURRENT_ARCH, uname -m)
  --network off  Which library set to package (default from the manifest)
  --sign IDENTITY        Codesign identity for the embedded libraries
                         (default: $EXPANDED_CODE_SIGN_IDENTITY, else ad-hoc "-")
  --prefix DIR           Read libraries from DIR instead of native/build/third_party
                         (single architecture only; for build-tree experiments)
  --allow-missing-prefix Warn and exit 0 when a prefix was never built
  --rust / --no-rust     Build and embed the Rust media host (default: embed it)
  --allow-missing-rust   Warn and continue when cargo or a Rust target is missing
  --force                Force full embedding and verification, bypassing cache
  --verify-only          Check an existing bundle, do not change it
  --no-verify            Skip the verification pass
  --reseal               Always re-sign the app bundle after embedding
  --no-reseal            Never re-sign the app bundle (Xcode signs it)
  --host-arch ARCH       Architecture to build the runtime probe for (default uname -m)
  --keep-temp            Keep the staging directory for inspection
  -h, --help             This text
EOF
}

m() { python3 "$MANIFEST_PY" "$@"; }

deployment_target() { m field deploymentTarget; }


prefix_for() {
    if [ -n "$PREFIX_OVERRIDE" ]; then
        printf '%s\n' "$PREFIX_OVERRIDE"
    else
        printf '%s\n' "$BASE_DIR/macos/$1"
    fi
}

# Sorted canonical library names (no path, no version) for one prefix.
library_names() {
    m fixup-plan --prefix "$1" | awk -F'\t' 'NF == 2 { print $2 }'
}

# `otool` prints one header line per architecture for universal files, so load
# commands are parsed from the lines themselves (they end in "(compatibility
# version ...") and deduplicated instead of being counted by line number.
dylib_ids() {
    otool -D "$1" | grep -v ':$' | grep -v '^$' | awk '!seen[$0]++'
}

dylib_dependencies() {
    # $1: file, $2: its own id (omitted for an executable, which has no LC_ID_DYLIB)
    local deps
    deps=$(otool -L "$1" | sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*(compatibility version.*/\1/p' | awk '!seen[$0]++')
    if [ -n "${2:-}" ]; then
        deps=$(printf '%s\n' "$deps" | grep -vxF "$2" || true)
    fi
    printf '%s\n' "$deps"
}

# Membership test without `cmd | grep -q`: under `set -o pipefail` an early grep exit
# turns a match into SIGPIPE and inverts the result.
contains_word() {
    local list word
    list=$(printf '%s' "$1" | tr '\n' ' ')
    word="$2"
    case " $list " in
        *" $word "*) return 0 ;;
    esac
    return 1
}

canonical_name() {
    # $1: list of canonical names, $2: dependency basename; prints the canonical name
    local name
    for name in $1; do
        if [ "$2" = "$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi
        case "$2" in
            "${name%.dylib}".*)
                printf '%s\n' "$name"
                return 0
                ;;
        esac
    done
    return 1
}

first_arch() {
    # $1: space separated architecture list
    printf '%s\n' $1 | head -1
}

arch_count() {
    local count=0
    local arch
    for arch in $1; do
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

resolve_app() {
    if [ -z "$APP" ]; then
        if [ -n "${CODESIGNING_FOLDER_PATH:-}" ]; then
            APP="$CODESIGNING_FOLDER_PATH"
        else
            die "--app is required when not running inside an Xcode build phase"
        fi
    fi
    case "$APP" in
        /*) ;;
        *) APP="$PWD/$APP" ;;
    esac
    case "$APP" in
        *.app) ;;
        *) die "--app must point at a .app bundle: $APP" ;;
    esac
    [ -d "$APP" ] || die "no such app bundle: $APP"
    if [ -n "${CODESIGNING_FOLDER_PATH:-}" ]; then
        FROM_XCODE=1
    fi
    if [ -z "$RESEAL" ]; then
        if [ "$FROM_XCODE" = 1 ]; then
            RESEAL=0
        else
            RESEAL=1
        fi
    fi
    if [ -z "$SIGN_IDENTITY" ]; then
        if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            SIGN_IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY"
        elif [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
            SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
        else
            SIGN_IDENTITY="-"
        fi
    fi
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
}

resolve_archs() {
    local raw="$ARCH_FLAG"
    if [ -z "$raw" ]; then
        if [ -n "${ARCHS:-}" ]; then
            raw="$ARCHS"
        elif [ -n "${CURRENT_ARCH:-}" ]; then
            raw="$CURRENT_ARCH"
        else
            raw="$(uname -m)"
        fi
    fi
    local arch cleaned=""
    for arch in $raw; do
        case "$arch" in
            undefined_arch | "") continue ;;
        esac
        case " $cleaned " in
            *" $arch "*) continue ;;
        esac
        cleaned="$cleaned $arch"
    done
    cleaned="${cleaned# }"
    [ -n "$cleaned" ] || die "could not determine an architecture (--arch arm64|x86_64)"
    local supported
    supported=$(m architectures)
    for arch in $cleaned; do
        if ! contains_word "$supported" "$arch"; then
            die "unsupported architecture '$arch' (manifest: $(printf '%s' "$supported" | tr '\n' ' '))"
        fi
    done
    printf '%s\n' "$cleaned"
}

check_prefixes() {
    local archs="$1"
    local arch prefix missing=""
    for arch in $archs; do
        prefix=$(prefix_for "$arch")
        if [ ! -d "$prefix/lib" ]; then
            missing="$missing $arch"
        fi
    done
    if [ -z "$missing" ]; then
        return 0
    fi
    if [ "$ALLOW_MISSING" = 1 ]; then
        warn "no native libraries built for:$missing"
        warn "the app will start without the audio stack; run: tooling/native/macos/build.sh build --arch $archs"
        exit 0
    fi
    die "no native libraries built for:$missing; run: tooling/native/macos/build.sh build --arch $archs"
}

stage_libraries() {
    local archs="$1" stage="$2"
    local first_prefix
    first_prefix=$(prefix_for "$(first_arch "$archs")")
    local names
    names=$(library_names "$first_prefix")
    [ -n "$names" ] || die "no dynamic libraries found in $first_prefix/lib"

    local arch prefix arch_plan
    for arch in $archs; do
        prefix=$(prefix_for "$arch")
        arch_plan=$(library_names "$prefix")
        local name
        for name in $names; do
            if ! contains_word "$arch_plan" "$name"; then
                die "$prefix/lib is missing $name; prefixes were built with different component sets"
            fi
        done
    done

    # The network mode is a property of the packaged set, not of the developer's
    # shell: assert it in both directions so a mode cannot silently drift.
    local has_ssl=0
    if contains_word "$names" libssl.dylib; then
        has_ssl=1
    fi
    if [ "$NETWORK_MODE" = "openssl" ]; then
        [ "$has_ssl" = 1 ] || die "network mode openssl needs libssl.dylib/libcrypto.dylib in $first_prefix/lib"
    else
        [ "$has_ssl" = 0 ] || die "network mode off must not package OpenSSL libraries"
    fi
    if ! contains_word "$names" libsoxr.dylib; then
        warn "libsoxr is not in this build; resampling falls back to FFmpeg's internal resampler"
    fi

    mkdir -p "$stage"
    local cache_tag
    cache_tag="$(printf '%s' "$archs" | tr ' ' '_')_${NETWORK_MODE}"
    local cache_dir="$REPO_ROOT/native/build/cache/macos/staged_libs/$cache_tag"
    local target
    target=$(deployment_target)

    local stamp_input
    stamp_input=$(
        printf 'sign:%s\ntarget:%s\nnames:%s\n' "$SIGN_IDENTITY" "$target" "$names"
        shasum -a 256 "$SCRIPT_DIR/embed.sh"
        for arch in $archs; do
            stat -f '%N:%m:%z' "$(prefix_for "$arch")"/lib/*.dylib 2>/dev/null || true
        done
    )
    local current_stamp
    current_stamp=$(printf '%s' "$stamp_input" | shasum -a 256 | awk '{print $1}')

    local can_reuse_cache=1
    if [ "$FORCE" = 1 ] || [ ! -f "$cache_dir/.stamp" ]; then
        can_reuse_cache=0
    elif [ "$(cat "$cache_dir/.stamp" 2>/dev/null)" != "$current_stamp" ]; then
        can_reuse_cache=0
    else
        local chk
        for chk in $names; do
            if [ ! -f "$cache_dir/$chk" ]; then
                can_reuse_cache=0
                break
            fi
        done
    fi

    if [ "$can_reuse_cache" = 1 ]; then
        log "reusing cached third-party libraries for: $archs"
        for name in $names; do
            cp -p "$cache_dir/$name" "$stage/$name"
        done
        printf '%s\n' "$names" >"$TMP/library-names.txt"
        return 0
    fi

    local count
    count=$(arch_count "$archs")
    for name in $names; do
        if [ "$count" -gt 1 ]; then
            local slices="" slice
            for arch in $archs; do
                slice="$(prefix_for "$arch")/lib/$name"
                [ -f "$slice" ] || die "missing $slice"
                slices="$slices $slice"
            done
            log "merging $name from:$slices"
            lipo -create $slices -output "$stage/$name" ||
                die "lipo failed for $name"
        else
            cp -f "$(prefix_for "$(first_arch "$archs")")/lib/$name" "$stage/$name"
        fi
        chmod u+w "$stage/$name"

        local want="@rpath/$name"
        if [ "$(dylib_ids "$stage/$name")" != "$want" ]; then
            install_name_tool -id "$want" "$stage/$name" 2>/dev/null
        fi
        local dep base canonical
        for dep in $(dylib_dependencies "$stage/$name" "$want"); do
            case "$dep" in
                @rpath/*)
                    base="${dep#@rpath/}"
                    canonical=$(canonical_name "$names" "$base") ||
                        die "$name depends on $dep, which is not part of the packaged set"
                    if [ "$dep" != "@rpath/$canonical" ]; then
                        install_name_tool -change "$dep" "@rpath/$canonical" "$stage/$name" 2>/dev/null
                    fi
                    ;;
                /usr/lib/* | /System/Library/*) ;;
                "$BASE_DIR"/* | "$first_prefix"/*)
                    die "$name still links the build prefix: $dep"
                    ;;
                *) die "$name links unexpected $dep" ;;
            esac
        done
    done
    # Sign the staged copy last: install_name_tool invalidates any earlier
    # signature, and the signature survives the byte-for-byte copy into the
    # bundle. Xcode re-signs the bundle around it.
    for name in $names; do
        sign_file "$stage/$name"
    done
    mkdir -p "$cache_dir"
    for name in $names; do
        cp -p "$stage/$name" "$cache_dir/$name"
    done
    printf '%s' "$current_stamp" >"$cache_dir/.stamp"
    printf '%s\n' "$names" >"$TMP/library-names.txt"
}

# Registers one more packaged library so embedding, verification, stale-file
# cleanup and the bundle report all treat it like the third-party set.
add_library_name() {
    printf '%s\n' "$1" >>"$TMP/library-names.txt"
}

# Builds the Rust media host (docs/design/boundaries.md) and stages it beside the FFmpeg set.
#
# It is skipped, with a warning, when cargo or an architecture's Rust target is
# missing: a Debug build on a machine without Rust still has to produce a
# runnable app, exactly like one without a native prefix.
stage_rust_library() {
    local archs="$1" stage="$2" allow=""
    [ -x "$RUST_SH" ] || die "$RUST_SH is missing or not executable"
    if [ "$ALLOW_MISSING_RUST" = 1 ]; then
        allow="--allow-missing"
    fi
    log "staging the Rust media host for: $archs"
    "$RUST_SH" stage --stage "$stage" --arch "$archs" --sign "$SIGN_IDENTITY" $allow ||
        die "the Rust media host could not be built"
    if [ -f "$stage/$RUST_LIB_NAME" ]; then
        add_library_name "$RUST_LIB_NAME"
        return 0
    fi
    if [ "$ALLOW_MISSING_RUST" = 1 ]; then
        warn "no $RUST_LIB_NAME was staged; the app will start without native playback"
        return 0
    fi
    die "rust.sh did not stage $RUST_LIB_NAME"
}

# Registers one packaged executable, so embedding, verification, stale-file
# cleanup and the bundle report all treat it like the packaged libraries.
add_helper_name() {
    printf '%s\n' "$1" >>"$TMP/helper-names.txt"
}

# Names of the packaged libraries/helpers a previous run recorded in the bundle,
# so a component-set change can remove its own leftovers without touching another
# tool's files.
previous_report_names() {
    local app="$1" section="$2"
    local report="$app/Contents/Resources/native-libraries.json"
    [ -f "$report" ] || return 0
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as handle:
        for entry in json.load(handle).get(sys.argv[2], []):
            print(entry.get("name", ""))
except Exception:
    pass
' "$report" "$section"
}

previous_library_names() { previous_report_names "$1" libraries; }
previous_helper_names() { previous_report_names "$1" helpers; }

sign_file() {
    local file="$1"
    local options=""
    if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
        options="--options runtime"
    fi
    # install_name_tool invalidates the linker's ad-hoc signature, and arm64
    # refuses to load unsigned dynamic libraries.
    codesign --force --sign "$SIGN_IDENTITY" $options "$file" >/dev/null 2>&1 ||
        die "codesign failed for $file (identity: $SIGN_IDENTITY)"
}

# Signed images must get a new inode: overwriting a mapped image can invalidate
# macOS's cached code pages. A unique sibling keeps rename on the same volume.
replace_packaged_file() {
    local source="$1" destination="$2" temporary
    temporary=$(mktemp "${destination}.embed.XXXXXX") ||
        die "could not create a temporary file for $destination"
    if ! cp -f "$source" "$temporary" || ! chmod 755 "$temporary" ||
        ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        die "could not replace $destination"
    fi
}

# Copies the packaged executables into Contents/MacOS, where codesign expects a
# bundle's sub-executables, and removes only the copies this script manages.
embed_helpers() {
    local app="$1" stage="$2"
    local macos="$app/Contents/MacOS"
    local names managed
    names=$(cat "$TMP/helper-names.txt")
    managed=$(previous_helper_names "$app")
    local stale base replaced=0
    for stale in "$macos"/*; do
        [ -f "$stale" ] || continue
        base=$(basename "$stale")
        if contains_word "$names" "$base"; then
            continue
        elif contains_word "$managed" "$base"; then
            rm -f "$stale"
            replaced=$((replaced + 1))
        fi
    done
    if [ "$replaced" -gt 0 ]; then
        log "cleaned up $replaced obsolete helper executable(s)"
    fi
    local name
    for name in $names; do
        [ -f "$stage/$name" ] || die "staging lost $name"
        if [ ! -f "$macos/$name" ] || ! cmp -s "$stage/$name" "$macos/$name"; then
            replace_packaged_file "$stage/$name" "$macos/$name"
            log "embedded $name into Contents/MacOS"
        fi
    done
}

embed_into_bundle() {
    local app="$1" stage="$2" archs="$3"
    local frameworks="$app/Contents/Frameworks"
    mkdir -p "$frameworks"

    # Only dynamic libraries directly inside Contents/Frameworks belong to this
    # script; Flutter's own code is in .framework bundles. Removing them first
    # keeps a component-set change from leaving a stale library behind.
    local names managed
    names=$(cat "$TMP/library-names.txt")
    managed=$(previous_library_names "$app")

    # Only this script's own libraries are removed: the ones it is about to write,
    # plus whatever the previous run recorded. A dynamic library another tool put
    # in Frameworks is reported, never deleted.
    local stale base replaced=0 foreign=""
    for stale in "$frameworks"/*.dylib; do
        [ -e "$stale" ] || continue
        base=$(basename "$stale")
        if contains_word "$names" "$base"; then
            continue
        elif contains_word "$managed" "$base"; then
            rm -f "$stale"
            replaced=$((replaced + 1))
        else
            foreign="$foreign $base"
        fi
    done
    if [ -n "$foreign" ]; then
        warn "leaving unmanaged dynamic libraries in place:$foreign"
    fi
    if [ "$replaced" -gt 0 ]; then
        log "cleaned up $replaced obsolete dynamic libraries"
    fi

    local name
    for name in $names; do
        if [ ! -f "$frameworks/$name" ] || ! cmp -s "$stage/$name" "$frameworks/$name"; then
            replace_packaged_file "$stage/$name" "$frameworks/$name"
        fi
    done

    local ca_source ca_dest
    ca_source="$(prefix_for "$(first_arch "$archs")")/ssl/cert.pem"
    ca_dest="$app/Contents/Resources/ssl/cert.pem"
    if [ "$NETWORK_MODE" = "openssl" ]; then
        [ -f "$ca_source" ] || die "the build prefix has no CA bundle at $ca_source"
        mkdir -p "$app/Contents/Resources/ssl"
        if [ ! -f "$ca_dest" ] || ! cmp -s "$ca_source" "$ca_dest"; then
            cp -f "$ca_source" "$ca_dest"
            chmod 644 "$ca_dest"
            log "packaged CA bundle ($(grep -c 'BEGIN CERTIFICATE' "$ca_dest" || true) certificates)"
        fi
    elif [ -e "$app/Contents/Resources/ssl" ]; then
        log "removing Contents/Resources/ssl: the offline mode packages no CA bundle"
        rm -rf "$app/Contents/Resources/ssl"
    fi
    # An earlier layout kept the bundle under Frameworks, where codesign treats it
    # as nested code and rejects the app signature.
    if [ -e "$frameworks/ssl" ]; then
        log "removing stale $frameworks/ssl"
        rm -rf "$frameworks/ssl"
    fi
}

point_app_binary_at_frameworks() {
    local app="$1"
    local exe name
    exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)
    if [ -n "$exe" ]; then
        exe="$app/Contents/MacOS/$exe"
    fi
    [ -n "$exe" ] && [ -x "$exe" ] || {
        warn "no main executable found in $app/Contents/MacOS; skipping rpath check"
        return 0
    }

    local rpaths
    rpaths=$(otool -l "$exe" | grep -A2 'LC_RPATH' | grep 'path ')
    case "$rpaths" in
        *@executable_path/../Frameworks* | *@loader_path/../Frameworks*) ;;
        *)
            log "adding @executable_path/../Frameworks rpath to $(basename "$exe")"
            install_name_tool -add_rpath @executable_path/../Frameworks "$exe" 2>/dev/null ||
                die "could not add the Frameworks rpath to $exe"
            ;;
    esac

    # Nothing in the bundle may point back at the build prefix.
    local dep base canonical names
    if [ -n "$TMP" ] && [ -f "$TMP/library-names.txt" ]; then
        names=$(cat "$TMP/library-names.txt")
    else
        names=$(previous_library_names "$app")
    fi
    for dep in $(dylib_dependencies "$exe"); do
        case "$dep" in
            @rpath/*)
                base="${dep#@rpath/}"
                if canonical=$(canonical_name "$names" "$base"); then
                    if [ "$dep" != "@rpath/$canonical" ]; then
                        log "rewriting $dep to @rpath/$canonical in $(basename "$exe")"
                        install_name_tool -change "$dep" "@rpath/$canonical" "$exe" 2>/dev/null
                    fi
                fi
                ;;
            "$BASE_DIR"/* | "$NATIVE_DIR"/*)
                die "the app binary links the build prefix: $dep"
                ;;
        esac
    done
}

verify_bundle() {
    local app="$1" archs="$2"
    local frameworks="$app/Contents/Frameworks"
    local target
    target=$(deployment_target)
    local names
    names=$(cat "$TMP/library-names.txt")

    local name file
    for name in $names; do
        file="$frameworks/$name"
        [ -f "$file" ] || die "verify: $name is missing from $frameworks"

        local archs_found slices_found
        archs_found=$(lipo -archs "$file")
        slices_found=$(printf '%s\n' $archs_found | wc -w | tr -d ' ')
        [ "$slices_found" = "$(arch_count "$archs")" ] ||
            die "verify: $name has $slices_found architectures ($archs_found), expected $(arch_count "$archs")"
        local arch
        for arch in $archs; do
            case " $archs_found " in
                *" $arch "*) ;;
                *) die "verify: $name lacks the $arch slice ($archs_found)" ;;
            esac
        done

        local minos
        minos=$(otool -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
        [ "$minos" = "$target" ] || die "verify: $name has minos '$minos', expected $target"

        local id
        id=$(dylib_ids "$file")
        [ "$id" = "@rpath/$name" ] || die "verify: $name has install name(s): $id"

        codesign --verify --strict "$file" >/dev/null 2>&1 ||
            die "verify: codesign verification failed for $name"

        local dep base canonical
        for dep in $(dylib_dependencies "$file" "@rpath/$name"); do
            case "$dep" in
                @rpath/*)
                    base="${dep#@rpath/}"
                    canonical=$(canonical_name "$names" "$base") ||
                        die "verify: $name depends on unpackaged $dep"
                    [ -f "$frameworks/$canonical" ] ||
                        die "verify: $name depends on $dep but $canonical is not packaged"
                    ;;
                /usr/lib/* | /System/Library/*) ;;
                *) die "verify: $name has a non-relocatable dependency $dep" ;;
            esac
        done
    done

    if [ "$NETWORK_MODE" = "openssl" ]; then
        local ca="$app/Contents/Resources/ssl/cert.pem"
        [ -f "$ca" ] || die "verify: the CA bundle is missing from $app/Contents/Resources/ssl"
        local certs
        certs=$(grep -c 'BEGIN CERTIFICATE' "$ca" || true)
        [ "$certs" -ge 100 ] || die "verify: the packaged CA bundle has only ${certs:-0} certificates"
        local source_ca
        source_ca="$(prefix_for "$(first_arch "$archs")")/ssl/cert.pem"
        if [ -f "$source_ca" ] && [ "$(shasum -a 256 "$ca" | awk '{print $1}')" != "$(shasum -a 256 "$source_ca" | awk '{print $1}')" ]; then
            warn "the packaged CA bundle differs from $source_ca (the prefixes were built at different times)"
        fi
    fi

    local stale base
    for stale in "$frameworks"/*.dylib; do
        [ -e "$stale" ] || continue
        base=$(basename "$stale")
        if ! contains_word "$names" "$base"; then
            warn "verify: $frameworks contains $base, which this script does not manage"
        fi
    done
    verify_helpers "$app" "$archs" "$target"
    log "verify: $archs dylib set, install names, deployment target and signatures OK"
}

# The packaged executables live in Contents/MacOS, must run on the deployment
# target, and must be signed: an unsigned helper fails to launch from a signed
# bundle rather than reporting anything useful.
verify_helpers() {
    local app="$1" archs="$2" target="$3"
    local macos="$app/Contents/MacOS"
    local name file
    for name in $(cat "$TMP/helper-names.txt"); do
        file="$macos/$name"
        [ -f "$file" ] || die "verify: $name is missing from $macos"
        [ -x "$file" ] || die "verify: $name is not executable"
        local found arch
        found=$(lipo -archs "$file")
        for arch in $archs; do
            case " $found " in
                *" $arch "*) ;;
                *) die "verify: $name lacks the $arch slice ($found)" ;;
            esac
        done
        local minos
        minos=$(otool -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
        [ "$minos" = "$target" ] || die "verify: $name has minos '$minos', expected $target"
        codesign --verify --strict "$file" >/dev/null 2>&1 ||
            die "verify: codesign verification failed for $name"
        # An executable in Contents/Frameworks is a packaging mistake: codesign
        # reports the bundle as unusable code.
        [ ! -e "$app/Contents/Frameworks/$name" ] ||
            die "verify: $name must not be under Contents/Frameworks"
        log "verify: helper $name ($found, minos $minos) is signed and placed correctly"
    done
}

# Proves that the packaged copies really load through @rpath and still satisfy the
# docs/design/native-build.md capability assertions. The probe is compiled against the packaged
# libraries and run from a throwaway directory shaped like the app bundle, so the
# real bundle is never modified.
run_bundle_probe() {
    local app="$1" archs="$2"
    local frameworks="$app/Contents/Frameworks"

    if ! contains_word "$archs" "$HOST_ARCH"; then
        warn "skipping the runtime probe: $HOST_ARCH is not among the packaged architectures ($archs)"
        return 0
    fi

    local prefix
    prefix=$(prefix_for "$HOST_ARCH")
    [ -d "$prefix/include" ] || {
        warn "skipping the runtime probe: no headers in $prefix/include"
        return 0
    }

    local probe_root="$TMP/probe"
    mkdir -p "$probe_root/Contents/MacOS"
    ln -s "$frameworks" "$probe_root/Contents/Frameworks"

    local defines="-DFF_CAPCHECK_EXPECT_NETWORK=0"
    local libs="-lavformat -lavcodec -lavutil -lswresample"
    if [ "$NETWORK_MODE" = "openssl" ]; then
        defines="-DFF_CAPCHECK_EXPECT_NETWORK=1"
        libs="$libs -lssl -lcrypto"
    fi
    if contains_word "$(cat "$TMP/library-names.txt")" libsoxr.dylib; then
        libs="$libs -lsoxr"
    fi

    local probe_cache="$REPO_ROOT/native/build/cache/macos/probes"
    mkdir -p "$probe_cache"
    local cached_capcheck="$probe_cache/bundle-capcheck-${HOST_ARCH}-${NETWORK_MODE}"

    local binary="$probe_root/Contents/MacOS/bundle-capcheck"
    log "probe: linking the capability probe against the packaged libraries"
    if [ "$FORCE" != 1 ] && [ -x "$cached_capcheck" ] && [ "$cached_capcheck" -nt "$CAPCHECK_SRC" ]; then
        cp -f "$cached_capcheck" "$binary"
    else
        if ! clang -arch "$HOST_ARCH" -mmacosx-version-min="$(deployment_target)" -O1 -Wall -Wextra \
            -I"$prefix/include" "$defines" "$CAPCHECK_SRC" \
            -L"$frameworks" -Wl,-rpath,@executable_path/../Frameworks $libs -o "$cached_capcheck" \
            >>"$TMP/probe.log" 2>&1; then
            tail -20 "$TMP/probe.log" >&2
            die "the packaged libraries could not be linked"
        fi
        codesign --force --sign - "$cached_capcheck" >/dev/null 2>&1
        cp -f "$cached_capcheck" "$binary"
    fi

    local ca_args=""
    if [ "$NETWORK_MODE" = "openssl" ]; then
        ca_args="--ca-bundle $app/Contents/Resources/ssl/cert.pem"
    fi
    log "probe: running the packaged libraries through their @rpath"
    if ! (
        if [ "$NETWORK_MODE" = "openssl" ]; then
            export SSL_CERT_FILE="$app/Contents/Resources/ssl/cert.pem"
            export SSL_CERT_DIR="$app/Contents/Resources/ssl"
        fi
        "$binary" --arch "$HOST_ARCH" --network "$NETWORK_MODE" $ca_args
    ) >>"$TMP/probe.log" 2>&1; then
        tail -30 "$TMP/probe.log" >&2
        die "the packaged libraries failed the capability probe"
    fi
    # Each probe prints its own last line as it finishes, in the order it ran:
    # the capcheck summary, then the ABI call, then the ABI result.
    tail -1 "$TMP/probe.log"
    # The Rust host is loaded by the Dart VM rather than linked into the app, so
    # it gets its own probe: it must dlopen through the same @rpath and answer the
    # documented ABI calls.
    if [ "$RUST" = 1 ] && [ -f "$frameworks/$RUST_LIB_NAME" ]; then
        log "probe: calling the packaged media host through the C ABI"
        if ! "$RUST_SH" probe --bundle "$app" --host-arch "$HOST_ARCH" >>"$TMP/probe.log" 2>&1; then
            tail -30 "$TMP/probe.log" >&2
            die "the packaged $RUST_LIB_NAME failed the ABI probe"
        fi
        tail -1 "$TMP/probe.log"
    fi
}

reseal_app() {
    local app="$1"
    if [ "$RESEAL" != 1 ]; then
        log "leaving the app bundle signature to Xcode ($app)"
        return 0
    fi
    # Preserve what the bundle already had: the sandbox and network client
    # entitlements are required for the app to work at all, and the runtime flag
    # matters if hardened runtime is enabled later.
    if codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements,flags,runtime \
        "$app" >/dev/null 2>&1; then
        log "re-sealed the app bundle, preserving its entitlements, flags and runtime setting"
    else
        local entitlements="$TMP/entitlements.plist"
        local ent_args=""
        if codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null &&
            [ -s "$entitlements" ] && grep -q '<key>' "$entitlements"; then
            ent_args="--entitlements $entitlements"
        fi
        log "re-sealing the app bundle with explicit entitlements"
        codesign --force --sign "$SIGN_IDENTITY" $ent_args "$app" >/dev/null 2>&1 ||
            die "could not re-seal $app with identity '$SIGN_IDENTITY'"
    fi
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 ||
        die "the resealed app bundle fails codesign verification"
    log "app bundle signature verified"
}

write_report() {
    local app="$1" archs="$2"
    local out="$app/Contents/Resources/native-libraries.json"
    local helper_args=""
    local name
    for name in $(cat "$TMP/helper-names.txt"); do
        helper_args="$helper_args --helper $name"
    done
    # shellcheck disable=SC2086
    m app-bundle-report --app "$app" --archs "$archs" --network "$NETWORK_MODE" \
        $helper_args --out "$out" ||
        die "could not write $out"
}

bundle_fingerprint() {
    local app="$1" archs="$2"
    printf 'archs:%s\nnetwork:%s\nsign:%s\nrust:%s\ntarget:%s\n' \
        "$archs" "$NETWORK_MODE" "$SIGN_IDENTITY" "$RUST" "$(deployment_target)"
    shasum -a 256 "$REPO_ROOT/tooling/native/macos/embed.sh"
    local arch prefix
    for arch in $archs; do
        prefix=$(prefix_for "$arch")
        if [ -d "$prefix/lib" ]; then
            stat -f 'prefix:%N:%m:%z' "$prefix"/lib/*.dylib 2>/dev/null || true
        fi
        if [ -f "$prefix/ssl/cert.pem" ]; then
            stat -f 'cert:%N:%m:%z' "$prefix/ssl/cert.pem" 2>/dev/null || true
        fi
    done
    if [ "$RUST" = 1 ]; then
        printf 'rustflags:%s\ncc:%s\nar:%s\nportaudio:%s\n' \
            "${RUSTFLAGS:-}" "${CC:-}" "${AR:-}" "${FF_PORTAUDIO_DIR:-}"
        # Cargo must get a chance to rebuild after a source change. Fingerprinting
        # only its previous output lets this cache bypass Cargo indefinitely.
        # Hash contents so edits within one second, additions and deletions all
        # invalidate the bundle, including build scripts and workspace manifests.
        find "$REPO_ROOT/native/media_core/crates" \
            "$REPO_ROOT/native/media_core/vendor" \
            "$REPO_ROOT/native/media_core/build-support" \
            -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.c' -o -name '*.h' \) \
            -exec shasum -a 256 {} + | LC_ALL=C sort
        shasum -a 256 "$REPO_ROOT/native/media_core/Cargo.toml" \
            "$REPO_ROOT/tooling/native/macos/rust.sh"
        for arch in $archs; do
            local triple
            case "$arch" in
                arm64) triple="aarch64-apple-darwin" ;;
                x86_64) triple="x86_64-apple-darwin" ;;
            esac
            local rbin="$REPO_ROOT/native/media_core/target/$triple/release/$RUST_LIB_NAME"
            if [ -f "$rbin" ]; then
                stat -f 'rust:%N:%m:%z' "$rbin" 2>/dev/null || true
            fi
        done
        if [ -f "$REPO_ROOT/native/media_core/Cargo.lock" ]; then
            shasum -a 256 "$REPO_ROOT/native/media_core/Cargo.lock"
        fi
    fi
}

check_bundle_up_to_date() {
    local app="$1" archs="$2"
    local stamp_file="$app/Contents/Resources/.embed-stamp"
    [ -f "$stamp_file" ] || return 1
    [ -f "$app/Contents/Resources/native-libraries.json" ] || return 1

    if [ "$NETWORK_MODE" = "openssl" ]; then
        [ -f "$app/Contents/Resources/ssl/cert.pem" ] || return 1
    fi

    local first_prefix
    first_prefix=$(prefix_for "$(first_arch "$archs")")
    local names
    names=$(library_names "$first_prefix")
    local name
    for name in $names; do
        [ -f "$app/Contents/Frameworks/$name" ] || return 1
    done

    if [ "$RUST" = 1 ]; then
        [ -f "$app/Contents/Frameworks/$RUST_LIB_NAME" ] || return 1
        [ -f "$app/Contents/Resources/licenses/portaudio-LICENSE.txt" ] || return 1
    fi

    local current_fp saved_fp
    current_fp=$(bundle_fingerprint "$app" "$archs" | shasum -a 256 | awk '{print $1}')
    saved_fp=$(cat "$stamp_file" 2>/dev/null || true)
    [ "$current_fp" = "$saved_fp" ] || return 1

    # A failed standalone signing run must not leave a reusable cache stamp.
    # Xcode owns the enclosing signature during its build phase.
    if [ "$RESEAL" = 1 ]; then
        codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
    fi
    point_app_binary_at_frameworks "$app"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app=*) APP="${1#*=}" ;;
        --app)
            [ $# -ge 2 ] || die "--app needs a value"
            APP="$2"
            shift
            ;;
        --arch=*) ARCH_FLAG="${1#*=}" ;;
        --arch)
            [ $# -ge 2 ] || die "--arch needs a value"
            ARCH_FLAG="$2"
            shift
            ;;
        --network=*) NETWORK_MODE="${1#*=}" ;;
        --network)
            [ $# -ge 2 ] || die "--network needs a value"
            NETWORK_MODE="$2"
            shift
            ;;
        --sign=*) SIGN_IDENTITY="${1#*=}" ;;
        --sign)
            [ $# -ge 2 ] || die "--sign needs a value"
            SIGN_IDENTITY="$2"
            shift
            ;;
        --force) FORCE=1 ;;
        --prefix=*) PREFIX_OVERRIDE="${1#*=}" ;;
        --prefix)
            [ $# -ge 2 ] || die "--prefix needs a value"
            PREFIX_OVERRIDE="$2"
            shift
            ;;
        --host-arch=*) HOST_ARCH="${1#*=}" ;;
        --host-arch)
            [ $# -ge 2 ] || die "--host-arch needs a value"
            HOST_ARCH="$2"
            shift
            ;;
        --verify-only) VERIFY_ONLY=1 ;;
        --no-verify) VERIFY=0 ;;
        --allow-missing-prefix) ALLOW_MISSING=1 ;;
        --allow-missing-rust) ALLOW_MISSING_RUST=1 ;;
        --rust) RUST=1 ;;
        --no-rust) RUST=0 ;;
        --reseal) RESEAL=1 ;;
        --no-reseal) RESEAL=0 ;;
        --keep-temp) KEEP_TEMP=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

if [ "${FF_SKIP_NATIVE_EMBED:-}" = "1" ]; then
    log "FF_SKIP_NATIVE_EMBED=1: not embedding the native libraries"
    exit 0
fi

have python3 || die "python3 is required (ships with the Xcode command line tools)"
for tool in install_name_tool otool codesign lipo clang; do
    have "$tool" || die "$tool is required"
done

resolve_app
ARCH_FLAG_RESOLVED=$(resolve_archs)
if [ -n "$PREFIX_OVERRIDE" ]; then
    [ "$(arch_count "$ARCH_FLAG_RESOLVED")" = 1 ] ||
        die "--prefix needs a single --arch selection"
    case "$PREFIX_OVERRIDE" in
        /*) ;;
        *) PREFIX_OVERRIDE="$REPO_ROOT/$PREFIX_OVERRIDE" ;;
    esac
fi
if [ -z "$NETWORK_MODE" ]; then
    NETWORK_MODE=$(m field defaultNetworkMode)
fi
case "$NETWORK_MODE" in
    off) ;;
    *) die "unsupported --network '$NETWORK_MODE' (available: off)" ;;
esac
m check --allow-unpinned >/dev/null

check_prefixes "$ARCH_FLAG_RESOLVED"

if [ "$VERIFY_ONLY" != 1 ] && [ "$FORCE" != 1 ] && check_bundle_up_to_date "$APP" "$ARCH_FLAG_RESOLVED"; then
    log "app bundle native libraries and helpers are up to date (cached: $ARCH_FLAG_RESOLVED, $NETWORK_MODE)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ff-embed.XXXXXX")"
: >"$TMP/helper-names.txt"

log "app: $APP"
log "architectures: $ARCH_FLAG_RESOLVED"
log "network mode: $NETWORK_MODE"
log "codesign identity: $SIGN_IDENTITY"
for arch in $ARCH_FLAG_RESOLVED; do
    log "prefix[$arch]: $(prefix_for "$arch")"
done

stage_libraries "$ARCH_FLAG_RESOLVED" "$TMP/stage"

if [ "$VERIFY_ONLY" = 1 ]; then
    # Verification checks what the bundle actually carries; nothing is rebuilt.
    if [ "$RUST" = 1 ] && [ -f "$APP/Contents/Frameworks/$RUST_LIB_NAME" ]; then
        add_library_name "$RUST_LIB_NAME"
    fi
else
    if [ "$RUST" = 1 ]; then
        stage_rust_library "$ARCH_FLAG_RESOLVED" "$TMP/stage"
    fi
fi

if [ "$VERIFY_ONLY" = 1 ]; then
    verify_bundle "$APP" "$ARCH_FLAG_RESOLVED"
    run_bundle_probe "$APP" "$ARCH_FLAG_RESOLVED"
    # Only meaningful on a finished bundle: while embedding, Xcode signs the app
    # after this script, so the expectation is inverted there. A failure here
    # means the embedded files are newer than the app's seal, which is exactly
    # what happens when the build phase's declared outputs stop ordering it
    # before Xcode's CodeSign step.
    if codesign -dv "$APP" >/dev/null 2>&1; then
        codesign --verify --deep --strict "$APP" >/dev/null 2>&1 ||
            die "the app's signature does not cover the embedded libraries; check the Embed Native Libraries phase outputs"
        log "app bundle signature covers the embedded libraries"
    else
        warn "$APP is not signed; skipping the app signature check"
    fi
    log "verification complete"
    exit 0
fi

embed_into_bundle "$APP" "$TMP/stage" "$ARCH_FLAG_RESOLVED"
embed_helpers "$APP" "$TMP/stage"
if [ "$RUST" = 1 ]; then
    pa_source="${FF_PORTAUDIO_DIR:-$REPO_ROOT/native/build/third_party/portaudio/19.7.0}"
    [ -f "$pa_source/LICENSE.txt" ] || die "PortAudio LICENSE.txt is missing; stage the pinned source first"
    mkdir -p "$APP/Contents/Resources/licenses"
    # Recreate the entry so case-insensitive volumes discard the legacy spelling.
    cp -f "$pa_source/LICENSE.txt" "$APP/Contents/Resources/licenses/.portaudio-license.tmp"
    python3 - "$APP/Contents/Resources/licenses" <<'PYLICENSE'
from pathlib import Path
import sys
licenses = Path(sys.argv[1])
for name in ("PortAudio-LICENSE.txt", "portaudio-LICENSE.txt"):
    (licenses / name).unlink(missing_ok=True)
(licenses / ".portaudio-license.tmp").rename(licenses / "portaudio-LICENSE.txt")
PYLICENSE
    ncm_vendor="$REPO_ROOT/native/media_core/crates/ncm-api-compat"
    cp -f "$REPO_ROOT/native/media_core/vendor/ncm-api-rs/LICENSE" "$APP/Contents/Resources/licenses/ncm-api-rs-LICENSE"
    cp -f "$ncm_vendor/UPSTREAM.json" "$APP/Contents/Resources/licenses/ncm-host-UPSTREAM.json"
    cp -f "$ncm_vendor/HOST-PATCH.md" "$APP/Contents/Resources/licenses/ncm-host-PATCH.md"
fi
point_app_binary_at_frameworks "$APP"

if [ "$VERIFY" = 1 ]; then
    verify_bundle "$APP" "$ARCH_FLAG_RESOLVED"
    run_bundle_probe "$APP" "$ARCH_FLAG_RESOLVED"
fi

write_report "$APP" "$ARCH_FLAG_RESOLVED"
bundle_fingerprint "$APP" "$ARCH_FLAG_RESOLVED" | shasum -a 256 | awk '{print $1}' >"$TMP/embed-stamp"
mv -f "$TMP/embed-stamp" "$APP/Contents/Resources/.embed-stamp"
reseal_app "$APP"
log "embedded $(wc -w <"$TMP/library-names.txt" | tr -d ' ') libraries into $APP/Contents/Frameworks"
if [ -s "$TMP/helper-names.txt" ]; then
    log "embedded $(wc -w <"$TMP/helper-names.txt" | tr -d ' ') helper executable(s) into $APP/Contents/MacOS"
fi
