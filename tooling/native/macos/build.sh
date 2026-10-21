#!/usr/bin/env bash
#
# Fideflow native macOS dependency builder.
#
# Downloads, verifies, builds and validates the pinned native audio dependencies
# on macOS only: FFmpeg 7.1.5, libsoxr 0.1.3 and PortAudio 19.7.0.
# HTTPS is handled by the host transport; FFmpeg needs no TLS library. Everything lands in
# native/build/third_party, which is git ignored; the repository keeps only this
# script, sources.manifest.json, ffmpeg-components.txt and the ADRs.
#
# Written for the macOS system bash 3.2: no associative arrays, no mapfile, no
# ${var^^}. JSON is handled by tooling/native/manifest.py.
#
# Usage: tooling/native/macos/build.sh [command] [options]
#   commands: deps | fetch | build | verify | env | clean | all (default)
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NATIVE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$NATIVE_DIR/../.." && pwd)
MANIFEST_PY="$NATIVE_DIR/manifest.py"
COMPONENTS_FILE="$NATIVE_DIR/ffmpeg-components.txt"
CAPCHECK_SRC="$NATIVE_DIR/checks/capcheck.c"

BASE_DIR="$REPO_ROOT/native/build/third_party"
DOWNLOADS_DIR="$BASE_DIR/downloads"
SRC_DIR="$BASE_DIR/src"
BUILD_DIR="$BASE_DIR/build"
LOG_DIR="$BASE_DIR/logs"

COMMAND=""
ARCH_FLAG="all"
NETWORK_MODE="${FF_NETWORK_MODE:-}"
PREFIX_OVERRIDE=""
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
INSTALL_TOOLS=0
CHECKSUM_MODE="verify"
WITH_SOXR=1
PRINT_CHECKSUMS=0
TLS_SMOKE_URL=""

log() { printf '[native] %s\n' "$*"; }
warn() { printf '[native] warning: %s\n' "$*" >&2; }
die() {
    printf '[native] error: %s\n' "$*" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Fideflow native macOS dependency builder (docs/design/native-build.md, docs/design/native-build.md)

Commands
  deps     Check the build toolchain (and optionally install it)
  fetch    Download, verify and extract the pinned sources
  build    Build the libraries into native/build/third_party/macos/<arch>
  verify   Check architectures, deployment target, linkage, components and TLS
  env      Print the generated env.sh for an architecture
  clean    Remove everything this script created under native/build/third_party
  all      deps -> fetch -> build -> verify (default)

Options
  --arch arm64|x86_64|all   Architectures to act on (default all)
  --network off     FFmpeg network/TLS mode (default from the manifest)
  --prefix DIR              Override the install prefix (single architecture only)
  --jobs N                  Parallel build jobs (default: hw.ncpu)
  --without-soxr            Build FFmpeg without libsoxr (deviates from docs/design/playback.md、docs/design/native-build.md)
  --install-tools           Let the script run the Homebrew installs it suggests
  --print-checksums         Print computed sha256 values (for manifest pinning)
  --no-checksum-verify      Do not fail on a sha256 mismatch (debugging only)
  --tls-smoke-url URL       Also fetch one HTTPS URL in the capability probe
  -h, --help                This text
EOF
}

m() { python3 "$MANIFEST_PY" "$@"; }

deployment_target() { m field deploymentTarget; }
size_budget() { m field sizeBudgetBytesPerArchitecture; }

arch_list() {
    if [ "$ARCH_FLAG" = "all" ]; then
        m architectures
    else
        printf '%s\n' "$ARCH_FLAG"
    fi
}

prefix_for() {
    if [ -n "$PREFIX_OVERRIDE" ]; then
        printf '%s\n' "$PREFIX_OVERRIDE"
    else
        printf '%s\n' "$BASE_DIR/macos/$1"
    fi
}

brew_hint_for() {
    case "$1" in
        cmake | nasm | pkg-config) printf 'brew install %s\n' "$1" ;;
        perl | security) printf '%s ships with the Xcode command line tools: xcode-select --install\n' "$1" ;;
        xcode-select | xcrun | clang | make | tar | xcodebuild | lipo | otool | install_name_tool | codesign | python3)
            printf 'install the Xcode command line tools: xcode-select --install\n'
            ;;
        curl | shasum) printf '%s ships with macOS; check PATH\n' "$1" ;;
        *) printf 'brew install %s\n' "$1" ;;
    esac
}

install_tools() {
    have brew || die "--install-tools needs Homebrew (https://brew.sh); install the tools manually"
    local formulae=""
    local tool
    for tool in $1; do
        case "$tool" in
            cmake | nasm | pkg-config) formulae="$formulae $tool" ;;
            *) warn "cannot install $tool with Homebrew; see the hint above" ;;
        esac
    done
    if [ -n "$formulae" ]; then
        log "running: brew install$formulae"
        brew install $formulae
    fi
}

check_toolchain() {
    if [ "$(uname -s)" != "Darwin" ]; then
        die "this script builds macOS libraries only (uname -s = $(uname -s))"
    fi
    local missing=""
    local tool
    for tool in curl tar shasum clang make xcrun python3; do
        if ! have "$tool"; then
            missing="$missing $tool"
        fi
    done
    if ! xcode-select -p >/dev/null 2>&1; then
        missing="$missing xcode-select"
    fi
    if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
        missing="$missing macos-sdk"
    fi
    if [ "$WITH_SOXR" = 1 ]; then
        have cmake || missing="$missing cmake"
        have pkg-config || missing="$missing pkg-config"
    fi
    local arch
    for arch in $(arch_list); do
        if [ "$arch" = "x86_64" ] && ! have nasm; then
            missing="$missing nasm"
        fi
    done
    for tool in lipo otool install_name_tool codesign xcrun; do
        have "$tool" || warn "$tool is missing; verification will be limited"
    done

    if [ -n "$missing" ]; then
        warn "missing required tools:$missing"
        for tool in $missing; do
            printf '    %-14s %s\n' "$tool" "$(brew_hint_for "$tool")" >&2
        done
        if [ "$INSTALL_TOOLS" = 1 ]; then
            install_tools "$missing"
        else
            die "install the tools listed above, or re-run with --install-tools"
        fi
    fi

    local disk_free
    disk_free=$(df -g "$REPO_ROOT" | awk 'NR==2 {print $4}')
    log "toolchain: $(clang --version | head -1)"
    log "toolchain: sdk $(xcrun --sdk macosx --show-sdk-path) ($(xcrun --sdk macosx --show-sdk-version))"
    log "toolchain: jobs=$JOBS, free disk=${disk_free}GiB, network mode=$NETWORK_MODE, soxr=$WITH_SOXR"
}

command_deps() {
    check_toolchain
    log "architectures: $(arch_list | tr '\n' ' ')"
    log "deployment target: $(deployment_target)"
    log "size budget per architecture: $(size_budget) bytes"
    for tool in cmake nasm pkg-config; do
        if have "$tool"; then
            log "toolchain: $tool $(first_version_line "$tool")"
        fi
    done
}

first_version_line() {
    case "$1" in
        cmake) cmake --version | head -1 ;;
        nasm) nasm -v ;;
        pkg-config) pkg-config --version ;;
        perl) perl -v | sed -n 2p ;;
        *) "$1" --version 2>/dev/null | head -1 ;;
    esac
}

download_file() {
    local url="$1"
    local dest="$2"
    local partial="$dest.part"
    rm -f "$partial"
    log "downloading $url"
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --progress-bar -o "$partial" "$url"; then
        rm -f "$partial"
        return 1
    fi
    mv "$partial" "$dest"
}

# $1 label, $2 file, $3 expected sha256 (may be empty)
verify_sha256() {
    local label="$1"
    local file="$2"
    local expected="$3"
    local actual
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    printf '%s  %s\n' "$actual" "$(basename "$file")" >>"$DOWNLOADS_DIR/checksums.txt"
    if [ -z "$expected" ]; then
        warn "$label: no pinned sha256 in sources.manifest.json (computed $actual)"
        return 0
    fi
    if [ "$CHECKSUM_MODE" = "ignore" ]; then
        warn "$label: checksum verification disabled (--no-checksum-verify)"
        return 0
    fi
    if [ "$actual" != "$expected" ]; then
        die "$label: sha256 mismatch
    expected $expected
    actual   $actual
Only update sources.manifest.json after reviewing the new archive."
    fi
    log "$label: sha256 verified"
}

download_source_archive() {
    local name="$1"
    local dest="$2"
    local url
    if [ -n "${FF_SOURCE_MIRROR:-}" ]; then
        url="$(m source-field "$name" urls | head -1)"
        if download_file "${FF_SOURCE_MIRROR%/}/$(basename "$url")" "$dest"; then
            log "$name: fetched from mirror $FF_SOURCE_MIRROR"
            return 0
        fi
        warn "$name: mirror $FF_SOURCE_MIRROR failed; falling back to upstream"
    fi
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        if download_file "$url" "$dest"; then
            return 0
        fi
        warn "$name: download failed from $url"
    done < <(m source-field "$name" urls)
    return 1
}

extract_source() {
    local name="$1"
    local archive="$2"
    local topdir
    topdir=$(m source-field "$name" topDir)
    if [ -d "$SRC_DIR/$topdir" ]; then
        log "$name: source already extracted ($topdir)"
        return 0
    fi
    log "$name: extracting $(basename "$archive")"
    mkdir -p "$SRC_DIR"
    tar -xf "$archive" -C "$SRC_DIR"
    if [ ! -d "$SRC_DIR/$topdir" ]; then
        die "$name: expected $SRC_DIR/$topdir after extraction"
    fi
}

fetch_archive_source() {
    local name="$1"
    local download_name
    download_name=$(m source-field "$name" downloadName)
    local dest="$DOWNLOADS_DIR/$download_name"
    if [ -f "$dest" ]; then
        log "$name: using cached $download_name"
    else
        download_source_archive "$name" "$dest" ||
            die "$name: could not download $download_name from any pinned URL"
    fi
    verify_sha256 "$name" "$dest" "$(m source-field "$name" sha256)"
    extract_source "$name" "$dest"
}

command_fetch() {
    mkdir -p "$DOWNLOADS_DIR" "$LOG_DIR"
    if [ "$PRINT_CHECKSUMS" = 1 ]; then
        command_fetch_sources
        log "computed checksums for $DOWNLOADS_DIR"
        m print-checksums --dir "$DOWNLOADS_DIR"
        return 0
    fi
    command_fetch_sources
}

command_fetch_sources() {
    local name
    for name in $(m source-list); do
        local format
        format=$(m source-field "$name" archiveFormat)
        fetch_archive_source "$name"
        if [ "$name" = "portaudio" ]; then
            mkdir -p "$BASE_DIR/portaudio"
            if [ ! -d "$BASE_DIR/portaudio/$(m source-field portaudio version)" ]; then
                cp -R "$SRC_DIR/portaudio" "$BASE_DIR/portaudio/$(m source-field portaudio version)"
            fi
        fi
    done
    log "all sources downloaded, verified and extracted"
}

prepare_arch_source() {
    local name="$1"
    local dest="$2"
    local marker="$3"
    if [ -e "$dest/$marker" ]; then
        log "$name: per-architecture source ready ($(basename "$dest"))"
        return 0
    fi
    local archive="$DOWNLOADS_DIR/$(m source-field "$name" downloadName)"
    [ -f "$archive" ] || die "$name: $archive is missing; run the fetch command first"
    log "$name: extracting per-architecture copy $(basename "$dest")"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xf "$archive" -C "$dest" --strip-components=1
}

stage_licenses() {
    local name="$1"
    local prefix="$2"
    local srcdir="$3"
    mkdir -p "$prefix/licenses"
    local file found=0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if [ -f "$srcdir/$file" ]; then
            cp -f "$srcdir/$file" "$prefix/licenses/$name-$(basename "$file")"
            found=1
            break
        fi
    done < <(m source-field "$name" licenseFiles 2>/dev/null || true)
    if [ "$found" != 1 ]; then
        die "licenses: no license file listed for $name was found in $srcdir"
    fi
}

build_soxr() {
    local arch="$1"
    local prefix="$2"
    local version srcdir bdir
    version=$(m source-field libsoxr version)
    srcdir="$SRC_DIR/soxr-$version"
    bdir="$BUILD_DIR/soxr-$version.$arch"
    [ -d "$srcdir" ] || die "libsoxr: sources are missing; run the fetch command first"
    rm -rf "$bdir"
    log "libsoxr: cmake build (log: $LOG_DIR/$arch-soxr.log)"
    : >"$LOG_DIR/$arch-soxr.log"
    (
        set -x
        cmake -S "$srcdir" -B "$bdir" -G "Unix Makefiles" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$prefix" \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$(deployment_target)" \
            -DCMAKE_INSTALL_NAME_DIR=@rpath \
            -DBUILD_SHARED_LIBS=ON \
            -DBUILD_TESTS=OFF \
            -DBUILD_EXAMPLES=OFF \
            -DWITH_OPENMP=OFF \
            -DWITH_AVFFT=OFF \
            -DWITH_LSR_BINDINGS=OFF \
            -DWITH_DEV_TRACE=OFF \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        cmake --build "$bdir" --parallel "$JOBS"
        cmake --install "$bdir"
    ) >>"$LOG_DIR/$arch-soxr.log" 2>&1 ||
        {
            tail -30 "$LOG_DIR/$arch-soxr.log" >&2
            die "libsoxr: build failed; see $LOG_DIR/$arch-soxr.log"
        }
}

validate_components() {
    local srcdir="$1"
    local kind
    for kind in demuxers decoders parsers protocols; do
        if ! (cd "$srcdir" && ./configure "--list-$kind" >"$LOG_DIR/available-$kind.txt" 2>/dev/null); then
            die "ffmpeg: 'configure --list-$kind' failed"
        fi
        m validate-components --kind "$kind" --available "$LOG_DIR/available-$kind.txt" \
            --network "$NETWORK_MODE"
    done
}

build_ffmpeg() {
    local arch="$1"
    local prefix="$2"
    local version srcdir install_name_dir cross args_file
    version=$(m source-field ffmpeg version)
    srcdir="$BUILD_DIR/ffmpeg-$version.$arch"
    prepare_arch_source ffmpeg "$srcdir" configure

    install_name_dir=1
    if ! (cd "$srcdir" && ./configure --help 2>/dev/null | grep -q -- '--install-name-dir'); then
        install_name_dir=0
        warn "ffmpeg: configure has no --install-name-dir; install names are rewritten after install"
    fi

    validate_components "$srcdir"

    cross=0
    if [ "$arch" != "$(uname -m)" ]; then
        cross=1
    fi

    args_file="$LOG_DIR/$arch-ffmpeg-configure-args.txt"
    m ffmpeg-configure-args --arch "$arch" --prefix "$prefix" \
        --deployment-target "$(deployment_target)" --network "$NETWORK_MODE" \
        --install-name-dir "$install_name_dir" --cross "$cross" --with-soxr "$WITH_SOXR" \
        >"$args_file"

    local args
    local arg
    args=()
    while IFS= read -r arg; do
        if [ -n "$arg" ]; then
            args+=("$arg")
        fi
    done <"$args_file"

    log "ffmpeg: configure with ${#args[@]} arguments (log: $LOG_DIR/$arch-ffmpeg.log)"
    log "ffmpeg configure: ./configure ${args[*]}"
    : >"$LOG_DIR/$arch-ffmpeg.log"
    (
        set -x
        cd "$srcdir"
        export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
        ./configure "${args[@]}"
        make -j"$JOBS"
        make install
    ) >>"$LOG_DIR/$arch-ffmpeg.log" 2>&1 ||
        {
            tail -30 "$LOG_DIR/$arch-ffmpeg.log" >&2
            die "ffmpeg: build failed; see $LOG_DIR/$arch-ffmpeg.log"
        }
}

# The libraries are the only deliverables: an empty bin/ directory left behind by
# an install step is removed, and any actual program in it fails the build.
prune_empty_bin() {
    local prefix="$1"
    if [ ! -d "$prefix/bin" ]; then
        return 0
    fi
    if [ -n "$(ls -A "$prefix/bin")" ]; then
        die "$prefix/bin contains command line programs; the packaged set must be libraries only"
    fi
    rmdir "$prefix/bin"
}

fixup_install_names() {
    local prefix="$1"
    local plan="$LOG_DIR/fixup-$(basename "$prefix").txt"
    python3 "$MANIFEST_PY" fixup-plan --prefix "$prefix" >"$plan"
    local real idname dep want changed
    while IFS=$'\t' read -r real idname; do
        [ -n "${real:-}" ] || continue
        want="@rpath/$idname"
        changed=0
        if [ "$(otool -D "$real" | sed -n '2p')" != "$want" ]; then
            install_name_tool -id "$want" "$real"
            changed=1
        fi
        for dep in $(otool -L "$real" | tail -n +2 | awk '{print $1}'); do
            case "$dep" in
                "$prefix"/*)
                    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$real"
                    changed=1
                    ;;
            esac
        done
        if [ "$changed" = 1 ]; then
            # install_name_tool invalidates the linker's ad-hoc signature, and
            # arm64 refuses to load unsigned dynamic libraries.
            codesign --force --sign - "$real" >/dev/null 2>&1
        fi
    done <"$plan"
}

write_env_sh() {
    local prefix="$1"
    local arch="$2"
    local target
    target=$(deployment_target)
    {
        printf '# Generated by tooling/native/macos/build.sh - source it to build against the pinned libraries.\n'
        printf 'export FF_NATIVE_PREFIX="%s"\n' "$prefix"
        printf 'export FF_NATIVE_ARCH="%s"\n' "$arch"
        printf 'export FF_NATIVE_NETWORK_MODE="%s"\n' "$NETWORK_MODE"
        printf 'export PKG_CONFIG_LIBDIR="%s/lib/pkgconfig"\n' "$prefix"
        printf 'export PKG_CONFIG_PATH="%s/lib/pkgconfig"\n' "$prefix"
        printf 'export CFLAGS="-arch %s -mmacosx-version-min=%s -I%s/include"\n' "$arch" "$target" "$prefix"
        printf 'export LDFLAGS="-arch %s -mmacosx-version-min=%s -L%s/lib -Wl,-rpath,%s/lib"\n' \
            "$arch" "$target" "$prefix" "$prefix"
    } >"$prefix/env.sh"
    log "wrote $prefix/env.sh"
}

command_build_one() {
    local arch="$1"
    local prefix
    prefix=$(prefix_for "$arch")

    # The prefix is a pure build output. Rebuilding from a clean tree keeps a
    # changed component set (network mode switched, libsoxr disabled, a library
    # added later) from silently shipping leftovers of the previous run. A prefix
    # outside this build directory is only cleaned when it carries our marker.
    case "$prefix" in
        "$BASE_DIR"/*) rm -rf "$prefix" ;;
        *)
            if [ -f "$prefix/env.sh" ] || [ -f "$prefix/build-manifest.json" ]; then
                rm -rf "$prefix"
            else
                warn "keeping existing $prefix: it was not written by this script"
            fi
            ;;
    esac
    mkdir -p "$prefix" "$LOG_DIR"

    if [ "$WITH_SOXR" = 1 ]; then
        build_soxr "$arch" "$prefix"
        stage_licenses libsoxr "$prefix" "$SRC_DIR/soxr-$(m source-field libsoxr version)"
    fi
    build_ffmpeg "$arch" "$prefix"
    stage_licenses ffmpeg "$prefix" "$SRC_DIR/ffmpeg-$(m source-field ffmpeg version)"
    stage_licenses portaudio "$prefix" "$BASE_DIR/portaudio/$(m source-field portaudio version)"
    fixup_install_names "$prefix"
    prune_empty_bin "$prefix"
    write_env_sh "$prefix" "$arch"

    local deviations=""
    if [ "$WITH_SOXR" != 1 ]; then
        deviations="libsoxr disabled: FFmpeg uses its internal resampler, deviating from docs/design/playback.md、docs/design/native-build.md"
    fi
    m write-build-manifest --prefix "$prefix" --arch "$arch" --network "$NETWORK_MODE" \
        --out "$prefix/build-manifest.json" \
        --configure-args-file "$LOG_DIR/$arch-ffmpeg-configure-args.txt" \
        ${deviations:+--deviation "$deviations"} >/dev/null
    log "build complete: $prefix"
}

command_build() {
    check_toolchain
    local arch
    for arch in $(arch_list); do
        command_build_one "$arch"
    done
}

verify_libraries() {
    local prefix="$1"
    local arch="$2"
    local target
    target=$(deployment_target)
    local libs="libavcodec libavformat libavutil libswresample"
    if [ "$WITH_SOXR" = 1 ]; then
        libs="$libs libsoxr"
    fi
    local lib
    for lib in $libs; do
        if [ -z "$(ls "$prefix"/lib/"$lib"*.dylib 2>/dev/null || true)" ]; then
            die "verify[$arch]: missing $lib*.dylib in $prefix/lib"
        fi
    done

    if [ -n "$(ls -A "$prefix/bin" 2>/dev/null)" ]; then
        die "verify[$arch]: $prefix/bin contains programs; only libraries may be packaged"
    fi

    local file archs minos dep
    for file in "$prefix"/lib/*.dylib; do
        [ -e "$file" ] || continue
        archs=$(lipo -archs "$file")
        if [ "$archs" != "$arch" ]; then
            die "verify[$arch]: $(basename "$file") is '$archs', expected $arch"
        fi
        minos=$(otool -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
        if [ "$minos" != "$target" ]; then
            die "verify[$arch]: $(basename "$file") has minos '$minos', expected $target"
        fi
        codesign --verify --strict "$file" >/dev/null 2>&1 ||
            die "verify[$arch]: codesign verification failed for $(basename "$file")"
        for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}'); do
            case "$dep" in
                @rpath/* | /usr/lib/* | /System/Library/*) ;;
                "$prefix"/*) die "verify[$arch]: $(basename "$file") still links $dep" ;;
                *) die "verify[$arch]: $(basename "$file") links unexpected $dep" ;;
            esac
        done
    done

    local format_lib
    format_lib=$(ls "$prefix"/lib/libavformat.*.dylib 2>/dev/null | head -1)
    if otool -L "$format_lib" | grep -qE 'libssl|libcrypto'; then
        die "verify[$arch]: libavformat still links OpenSSL libraries"
    fi
    log "verify[$arch]: architectures, minos $target, install names, linkage and signatures OK"
}

run_capcheck() {
    local prefix="$1"
    local arch="$2"
    local binary="$BUILD_DIR/capcheck-$arch"
    local logfile="$LOG_DIR/$arch-capcheck.log"
    local defines="-DFF_CAPCHECK_EXPECT_NETWORK=0"
    local libs="-lavformat -lavcodec -lavutil -lswresample"
    if [ "$WITH_SOXR" = 1 ]; then
        libs="$libs -lsoxr"
    fi
    mkdir -p "$BUILD_DIR"
    local smoke=""
    if [ -n "$TLS_SMOKE_URL" ]; then
        smoke="--tls-smoke-url $TLS_SMOKE_URL"
    fi
    log "capcheck[$arch]: building and running the capability probe"
    : >"$logfile"
    (
        set -x
        clang -arch "$arch" -mmacosx-version-min="$(deployment_target)" -O1 -Wall -Wextra \
            -I"$prefix/include" "$defines" "$CAPCHECK_SRC" \
            -L"$prefix/lib" -Wl,-rpath,"$prefix/lib" $libs -o "$binary"
        "$binary" --arch "$arch" --network "$NETWORK_MODE" \
            --ca-bundle "$prefix/ssl/cert.pem" $smoke
    ) >>"$logfile" 2>&1 ||
        {
            tail -40 "$logfile" >&2
            die "capcheck[$arch]: failed; see $logfile"
        }
    cat "$logfile"
}

command_verify() {
    check_toolchain
    [ -f "$CAPCHECK_SRC" ] || die "capcheck source is missing: $CAPCHECK_SRC"
    local arch prefix
    for arch in $(arch_list); do
        prefix=$(prefix_for "$arch")
        [ -d "$prefix/lib" ] || die "nothing built for $arch; run the build command first"
        verify_libraries "$prefix" "$arch"
        run_capcheck "$prefix" "$arch"
        log "size report for $arch"
        m size-report --prefix "$prefix" --budget "$(size_budget)" ||
            warn "size report found an issue"
    done
    log "verification complete"
}

command_env() {
    local arch
    for arch in $(arch_list); do
        local prefix
        prefix=$(prefix_for "$arch")
        if [ -f "$prefix/env.sh" ]; then
            printf '# --- %s ---\n' "$arch"
            cat "$prefix/env.sh"
        else
            warn "no env.sh for $arch yet; run the build command first"
        fi
    done
}

command_clean() {
    local dir
    for dir in "$DOWNLOADS_DIR" "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR"; do
        if [ -e "$dir" ]; then
            log "removing $dir"
            rm -rf "$dir"
        fi
    done
    for dir in "$BASE_DIR"/macos/*; do
        if [ -e "$dir" ]; then
            log "removing $dir"
            rm -rf "$dir"
        fi
    done
    log "clean complete"
}

while [ $# -gt 0 ]; do
    case "$1" in
        deps | fetch | build | verify | env | clean | all) COMMAND="$1" ;;
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
        --prefix=*) PREFIX_OVERRIDE="${1#*=}" ;;
        --prefix)
            [ $# -ge 2 ] || die "--prefix needs a value"
            PREFIX_OVERRIDE="$2"
            shift
            ;;
        --jobs=*) JOBS="${1#*=}" ;;
        --jobs)
            [ $# -ge 2 ] || die "--jobs needs a value"
            JOBS="$2"
            shift
            ;;
        --tls-smoke-url=*) TLS_SMOKE_URL="${1#*=}" ;;
        --tls-smoke-url)
            [ $# -ge 2 ] || die "--tls-smoke-url needs a value"
            TLS_SMOKE_URL="$2"
            shift
            ;;
        --install-tools) INSTALL_TOOLS=1 ;;
        --without-soxr) WITH_SOXR=0 ;;
        --print-checksums) PRINT_CHECKSUMS=1 ;;
        --no-checksum-verify) CHECKSUM_MODE="ignore" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done
COMMAND="${COMMAND:-all}"

have python3 || die "python3 is required (ships with the Xcode command line tools)"

case "$ARCH_FLAG" in
    all | arm64 | x86_64) ;;
    *) die "unsupported --arch '$ARCH_FLAG' (arm64, x86_64 or all)" ;;
esac

if [ -z "$NETWORK_MODE" ]; then
    NETWORK_MODE=$(m field defaultNetworkMode)
fi
case "$NETWORK_MODE" in
    off) ;;
    *) die "unsupported --network '$NETWORK_MODE' (available: off)" ;;
esac
if [ -n "$TLS_SMOKE_URL" ]; then
    die "--tls-smoke-url requires native TLS; HTTPS is handled by the host transport"
fi
if [ -n "$PREFIX_OVERRIDE" ] && [ "$ARCH_FLAG" = "all" ]; then
    die "--prefix needs a single --arch selection"
fi

# Configure and make run inside the source tree, so a relative prefix would
# install the libraries somewhere else entirely: always resolve it first.
if [ -n "$PREFIX_OVERRIDE" ]; then
    case "$PREFIX_OVERRIDE" in
        /*) ;;
        *) PREFIX_OVERRIDE="$REPO_ROOT/$PREFIX_OVERRIDE" ;;
    esac
fi

m check --allow-unpinned >/dev/null

case "$COMMAND" in
    deps) command_deps ;;
    fetch) command_fetch ;;
    build) command_build ;;
    verify) command_verify ;;
    env) command_env ;;
    clean) command_clean ;;
    all)
        command_deps
        command_fetch
        command_build
        command_verify
        ;;
esac
