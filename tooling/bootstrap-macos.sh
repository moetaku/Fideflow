#!/usr/bin/env bash
# Check and install the macOS development environment needed by Fideflow.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CARGO_BIN_DIR="${CARGO_HOME:-${HOME:?HOME is not set}/.cargo}/bin"
BREW=""

die() {
    printf 'bootstrap: error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf 'bootstrap: %s\n' "$*"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

configure_brew() {
    if have brew; then
        BREW=$(command -v brew)
        return
    fi
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then
            BREW="$candidate"
            eval "$("$BREW" shellenv)"
            return
        fi
    done

    log "Homebrew is missing; installing it"
    local installer
    installer=$(mktemp "${TMPDIR:-/tmp}/fideflow-homebrew.XXXXXX")
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
    NONINTERACTIVE=1 /bin/bash "$installer"
    rm -f "$installer"
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then
            BREW="$candidate"
            eval "$("$BREW" shellenv)"
            return
        fi
    done
    die "Homebrew installation completed but brew could not be located"
}

install_brew_formulae() {
    local missing=""
    local tool
    for tool in cmake nasm pkg-config; do
        have "$tool" || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        log "installing missing native build tools:$missing"
        # Formula names intentionally match the command names.
        "$BREW" install $missing
    fi
}

[ "$(uname -s)" = "Darwin" ] || die "this bootstrap supports macOS only"
have curl || die "curl is missing from macOS"

if ! xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools are missing; opening the macOS installer"
    xcode-select --install
    die "finish the Command Line Tools installation, then run this script again"
fi

# Flutter desktop releases require full Xcode, not only Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
    die "install full Xcode, launch it to finish setup, then select it with sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
fi
for tool in ditto hdiutil shasum codesign lipo python3; do
    have "$tool" || die "macOS release tool $tool is missing; repair Xcode/macOS tools before continuing"
done

configure_brew
install_brew_formulae

if ! have flutter; then
    log "Flutter is missing; installing the Homebrew Flutter cask"
    "$BREW" install --cask flutter
fi
have flutter || die "Flutter installation completed but flutter is not in PATH"

flutter_version=$(flutter --version 2>/dev/null | sed -n '1s/^Flutter \([^ ]*\).*/\1/p')
if [ "$flutter_version" != "3.47.5" ]; then
    log "warning: project/CI use Flutter 3.47.5; current Flutter is ${flutter_version:-unknown}"
fi

# rustup installs proxies in ~/.cargo/bin, but GUI terminals and newly created
# shells do not necessarily source ~/.cargo/env. Discover the standard install
# directly so bootstrap and the Xcode build it prepares agree on the toolchain.
if ! command -v rustup >/dev/null 2>&1 && [ -x "$CARGO_BIN_DIR/rustup" ]; then
    PATH="$CARGO_BIN_DIR:$PATH"
    export PATH
fi
if ! command -v rustup >/dev/null 2>&1; then
    log "Rust is missing; installing rustup with the minimal profile"
    rustup_installer=$(mktemp "${TMPDIR:-/tmp}/fideflow-rustup.XXXXXX")
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$rustup_installer"
    /bin/sh "$rustup_installer" -y --profile minimal
    rm -f "$rustup_installer"
    PATH="$CARGO_BIN_DIR:$PATH"
    export PATH
fi


command -v cargo >/dev/null 2>&1 ||
    die "Cargo is missing from the rustup installation at $CARGO_BIN_DIR"

cd "$REPO_ROOT"
flutter pub get
rustup component add rustfmt clippy

# The pinned native build defaults to a universal macOS library. Install both
# targets up front so flutter run (host slice) and release packaging (both
# slices) cannot diverge later.
rustup target add aarch64-apple-darwin x86_64-apple-darwin

printf 'bootstrap: macOS, Flutter, native build, and Rust dependencies are ready\n'
printf 'bootstrap: Cargo: %s\n' "$(command -v cargo)"
printf 'bootstrap: Cargo PATH is persistent for new terminals; for this parent shell run: source "$HOME/.cargo/env"\n'
printf 'bootstrap: next: cd apps/fideflow_flutter && flutter run -d macos\n'
