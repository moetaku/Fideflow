#!/usr/bin/env bash
# Install/check Linux native and Flutter desktop development dependencies.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scenario=build
arguments=()
while [ $# -gt 0 ]; do
  case "$1" in
    --for)
      [ $# -ge 2 ] || { echo 'bootstrap-linux: --for requires build, package or validation' >&2; exit 2; }
      scenario=$2
      shift 2
      ;;
    *) arguments+=("$1"); shift ;;
  esac
done
case "$scenario" in
  build|package|validation) ;;
  *) echo "bootstrap-linux: unsupported scenario: $scenario (use build, package or validation)" >&2; exit 2 ;;
esac
if [ "$(uname -s)" != Linux ]; then
  echo "bootstrap-linux: Linux is required" >&2
  exit 1
fi
if [ "$scenario" = package ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo 'bootstrap-linux: Python 3.10+ is required for package tools; install it with your system package manager.' >&2
    exit 1
  fi
  exec python3 "$SCRIPT_DIR/release/linux/dependencies.py" "${arguments[@]}"
fi
if ! command -v python3 >/dev/null 2>&1; then
  check_only=false
  for argument in ${arguments[@]+"${arguments[@]}"}; do
    if [ "$argument" = --check-only ]; then check_only=true; fi
  done
  if command -v apt-get >/dev/null 2>&1; then
    install_python=(apt-get install -y python3)
    update_python=(apt-get update)
  elif command -v dnf >/dev/null 2>&1; then
    install_python=(dnf install -y python3)
    update_python=()
  elif command -v pacman >/dev/null 2>&1; then
    install_python=(pacman -S --needed --noconfirm python)
    update_python=()
  else
    echo 'bootstrap-linux: Install Python 3.10+ with your system package manager, then rerun.' >&2
    exit 1
  fi
  privilege=()
  if [ "$check_only" = false ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      privilege=(sudo -n)
    else
      check_only=true
    fi
  fi
  if [ "$check_only" = true ]; then
    echo 'bootstrap-linux: Python 3.10+ is missing. No installation performed; run:' >&2
    if [ "${#update_python[@]}" -gt 0 ]; then printf 'sudo %s\n' "${update_python[*]}" >&2; fi
    printf 'sudo %s\n' "${install_python[*]}" >&2
    exit 1
  fi
  if [ "${#update_python[@]}" -gt 0 ]; then ${privilege[@]+"${privilege[@]}"} "${update_python[@]}"; fi
  ${privilege[@]+"${privilege[@]}"} "${install_python[@]}"
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo 'bootstrap-linux: Python 3.10+ is required. Upgrade Python and rerun.' >&2
  exit 1
fi
if [ "$scenario" = validation ]; then
  exec python3 "$SCRIPT_DIR/native/linux/dependencies.py" --system-only --scope native --with-validation-tools "${arguments[@]}"
fi
exec python3 "$SCRIPT_DIR/native/linux/dependencies.py" "${arguments[@]}"
