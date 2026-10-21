#!/usr/bin/env python3
"""Check/install Linux native and Flutter desktop build dependencies."""
from __future__ import annotations

import argparse
import importlib.util
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
# Each entry maps an executable or pkg-config module to distro package names.
PACKAGES = {
    "apt": {
        "cc": "build-essential", "c++": "build-essential", "ar": "binutils",
        "make": "make", "cmake": "cmake", "pkg-config": "pkg-config",
        "readelf": "binutils", "ldd": "libc-bin", "patchelf": "patchelf",
        "tar": "tar", "xz": "xz-utils", "sha256sum": "coreutils",
        "curl": "curl", "git": "git", "nasm": "nasm", "clang++": "clang",
        "ninja": "ninja-build", "gtk+-3.0": "libgtk-3-dev", "x11": "libx11-dev",
        "libsecret-1": "libsecret-1-dev", "lzma.h": "liblzma-dev",
        "pactl": "pulseaudio-utils", "alsa": "libasound2-dev", "alsa-desktop-plugin": "libasound2-plugins",
    },
    "dnf": {
        "cc": "gcc", "c++": "gcc-c++", "ar": "binutils", "make": "make",
        "cmake": "cmake", "pkg-config": "pkgconf-pkg-config", "readelf": "binutils",
        "ldd": "glibc-common", "patchelf": "patchelf", "tar": "tar", "xz": "xz",
        "sha256sum": "coreutils", "curl": "curl", "git": "git", "nasm": "nasm",
        "clang++": "clang", "ninja": "ninja-build", "gtk+-3.0": "gtk3-devel", "x11": "libX11-devel",
        "libsecret-1": "libsecret-devel", "lzma.h": "xz-devel",
        "pactl": "pulseaudio-utils", "alsa": "alsa-lib-devel", "alsa-desktop-plugin": "alsa-plugins-pulseaudio",
    },
    "pacman": {
        "cc": "gcc", "c++": "gcc", "ar": "binutils", "make": "make",
        "cmake": "cmake", "pkg-config": "pkgconf", "readelf": "binutils",
        "ldd": "glibc", "patchelf": "patchelf", "tar": "tar", "xz": "xz",
        "sha256sum": "coreutils", "curl": "curl", "git": "git", "nasm": "nasm",
        "clang++": "clang", "ninja": "ninja", "gtk+-3.0": "gtk3", "x11": "libx11",
        "libsecret-1": "libsecret", "lzma.h": "xz",
        "pactl": "libpulse", "alsa": "alsa-lib", "alsa-desktop-plugin": "alsa-plugins",
    },
}
NATIVE_TOOLS = ("cc", "c++", "ar", "make", "cmake", "pkg-config", "readelf",
                "ldd", "patchelf", "tar", "xz", "sha256sum", "curl", "git")

def normalize_arch(machine: str) -> str:
    aliases = {"amd64": "x86_64", "x64": "x86_64", "arm64": "aarch64"}
    result = aliases.get(machine, machine)
    if result not in ("x86_64", "aarch64"):
        raise ValueError(f"Unsupported Linux CPU architecture: {machine}")
    return result


def validate_target(target: str, machine: str | None = None) -> str:
    host = normalize_arch(machine or platform.machine())
    if target != "host" and normalize_arch(target) != host:
        raise ValueError(f"Linux builds require a native runner: host={host}, target={target}. "
                         "Run dependency preparation and builds on the target architecture.")
    return host


def log(message: str) -> None:
    print(f"[linux-deps] {message}", flush=True)


def succeeds(command: list[str], **kwargs) -> bool:
    try:
        return subprocess.run(command, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, **kwargs).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def discover_toolchains() -> None:
    """Only update this process' PATH; never rewrite the user's shell config."""
    home = Path.home()
    paths = [Path(os.environ.get("CARGO_HOME", str(home / ".cargo"))) / "bin"]
    flutter_root = os.environ.get("FLUTTER_ROOT")
    if flutter_root:
        paths.append(Path(flutter_root) / "bin")
    paths.extend([home / ".local/share/fideflow/toolchains/flutter/bin",
                  home / "Public/flutter/bin", home / "flutter/bin",
                  home / "development/flutter/bin", Path("/opt/flutter/bin")])
    current = os.environ.get("PATH", "").split(os.pathsep)
    # Existing PATH choices take precedence over discovered SDKs.
    os.environ["PATH"] = os.pathsep.join(current + [str(p) for p in paths if p.is_dir() and str(p) not in current])


def package_manager(os_release: str | None = None) -> str | None:
    if os_release is None:
        os_release = Path("/etc/os-release").read_text()
    fields = {}
    for line in os_release.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields[key] = value.strip().strip('"\'')
    for name in [fields.get("ID", ""), *fields.get("ID_LIKE", "").split()]:
        if name in ("debian", "ubuntu", "linuxmint", "pop"):
            return "apt"
        if name in ("fedora", "rhel", "centos", "rocky", "almalinux"):
            return "dnf"
        if name in ("arch", "manjaro", "endeavouros"):
            return "pacman"
    return None


def missing_system(scope: str, machine: str | None = None, target: str = "host") -> list[str]:
    required = list(NATIVE_TOOLS)
    host = validate_target(target, machine)
    if host == "x86_64":
        required.append("nasm")
    if scope == "desktop":
        required.extend(("clang++", "ninja", "pactl"))
    missing = [name for name in required if shutil.which(name) is None]
    if not succeeds(["pkg-config", "--atleast-version=1.2", "alsa"]):
        missing.append("alsa")
    if scope == "desktop":
        try:
            libdir = subprocess.run(["pkg-config", "--variable=libdir", "alsa"], check=True, capture_output=True, text=True).stdout.strip()
            plugin_dir = Path(os.environ.get("ALSA_PLUGIN_DIR", str(Path(libdir) / "alsa-lib")))
            if not any((plugin_dir / name).is_file() for name in ("libasound_module_pcm_pipewire.so", "libasound_module_pcm_pulse.so")):
                missing.append("alsa-desktop-plugin")
        except (OSError, subprocess.CalledProcessError):
            # A clean container may not have pkg-config or ALSA metadata yet.
            # Include the plugin in the same installation transaction instead
            # of discovering it only during the post-install recheck.
            missing.append("alsa-desktop-plugin")
        for module, version in (("gtk+-3.0", "3.22"), ("libsecret-1", "0.18.4"), ("x11", "1.6")):
            if not succeeds(["pkg-config", f"--atleast-version={version}", module]):
                missing.append(module)
        # Compile a header probe instead of assuming a distro-specific include path.
        if not succeeds(["cc", "-x", "c", "-fsyntax-only", "-"],
                        input=b"#include <lzma.h>\nint main(void) { return 0; }\n"):
            missing.append("lzma.h")
    return missing


def install_commands(manager: str, missing: list[str]) -> list[list[str]]:
    packages = set()
    for name in missing:
        mapped = PACKAGES[manager].get(name, ())
        packages.update([mapped] if isinstance(mapped, str) else mapped)
    packages = sorted(packages)
    if not packages:
        return []
    if manager == "apt":
        return [["apt-get", "update"], ["apt-get", "install", "-y", *packages]]
    if manager == "dnf":
        return [["dnf", "install", "-y", *packages]]
    # Use existing sync databases; do not upgrade the entire OS or perform -Sy.
    return [["pacman", "-S", "--needed", "--noconfirm", *packages]]


def install_system(missing: list[str], check_only: bool) -> bool:
    if not missing:
        return True
    log("Missing system dependencies: " + ", ".join(missing))
    manager = package_manager()
    if manager is None:
        log("Unsupported distribution; install these tools/development libraries with your system package manager.")
        return False
    commands = install_commands(manager, missing)
    manual = [name for name in missing if name not in PACKAGES[manager]]
    if manual:
        log("No automatic package mapping for: " + ", ".join(manual))
    if not commands:
        return False
    root = os.geteuid() == 0
    privileged = False
    if not check_only:
        privileged = root or (shutil.which("sudo") is not None and succeeds(["sudo", "-n", "true"]))
    if check_only or not privileged:
        log("Check-only mode; no installation performed." if check_only else
            "No installation permission. Run these commands with sudo, then rerun this script:")
        for command in commands:
            print(shlex.join(["sudo", *command]))
        return False
    prefix = [] if root else ["sudo", "-n"]
    for command in commands:
        log("Installing: " + shlex.join([*prefix, *command]))
        result = subprocess.run([*prefix, *command])
        if result.returncode:
            log("Package installation failed. Resolve the package-manager error and rerun; remaining commands:")
            for retry in commands:
                print(shlex.join(["sudo", *retry]))
            return False
    return True


def flutter_version() -> str:
    workflow = (ROOT / ".github/workflows/check.yml").read_text()
    match = re.search(r"flutter-version:\s*['\"]?([0-9]+\.[0-9]+\.[0-9]+)", workflow)
    if not match:
        raise RuntimeError("Cannot resolve the project's Flutter version from CI")
    return match.group(1)


def ensure_toolchains(scope: str, check_only: bool) -> bool:
    rust_ready = all(succeeds([name, "--version"]) for name in ("rustc", "cargo"))
    flutter_ready = scope != "desktop" or shutil.which("flutter") is not None
    if rust_ready and flutter_ready:
        return True
    if check_only:
        log("Missing user toolchains: " + ", ".join(
            [name for name, ready in (("Rust/Cargo", rust_ready), ("Flutter", flutter_ready)) if not ready]))
        return False
    if os.geteuid() == 0:
        log("System dependencies are ready. Rerun without sudo to install Rust/Flutter for your own account.")
        return False
    if not rust_ready:
        rustup = shutil.which("rustup")
        if rustup is None:
            with tempfile.TemporaryDirectory(prefix="fideflow-rustup-") as temp:
                installer = Path(temp) / "rustup-init.sh"
                subprocess.run(["curl", "--proto", "=https", "--tlsv1.2", "-fsSL",
                                "https://sh.rustup.rs", "-o", str(installer)], check=True)
                subprocess.run(["sh", str(installer), "-y", "--profile", "minimal",
                                "--default-toolchain", "stable"], check=True)
            discover_toolchains()
        else:
            subprocess.run([rustup, "toolchain", "install", "stable", "--profile", "minimal"], check=True)
            subprocess.run([rustup, "default", "stable"], check=True)
        subprocess.run(["rustup", "component", "add", "rustfmt", "clippy"], check=True)
    if not flutter_ready:
        destination = Path.home() / ".local/share/fideflow/toolchains/flutter"
        if destination.exists():
            raise RuntimeError(f"Incomplete Flutter SDK at {destination}; repair or move it before retrying")
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", flutter_version(),
                        "https://github.com/flutter/flutter.git", str(destination)], check=True)
        discover_toolchains()
        subprocess.run([str(destination / "bin/flutter"), "precache", "--linux"], check=True)
    return all(succeeds([name, "--version"]) for name in ("rustc", "cargo")) and (
        scope != "desktop" or shutil.which("flutter") is not None)


def ensure(scope: str = "desktop", check_only: bool = False, system_only: bool = False, target: str = "host") -> bool:
    host = validate_target(target)
    discover_toolchains()
    log("Host architecture: " + host)
    missing = missing_system(scope, target=target)
    system_ready = install_system(missing, check_only)
    if system_ready and missing:
        remaining = missing_system(scope, target=target)
        if remaining:
            log("Dependencies still unavailable after installation: " + ", ".join(remaining))
            return False
    if system_only:
        if system_ready:
            log(f"All {scope} system dependencies are ready.")
        return system_ready
    # In check-only mode report user-toolchain problems alongside system problems.
    tools_ready = ensure_toolchains(scope, check_only) if (system_ready or check_only) else False
    if not system_ready or not tools_ready:
        return False
    log(f"All {scope} dependencies are ready.")
    if scope == "desktop":
        flutter = shutil.which("flutter")
        cargo = shutil.which("cargo")
        log("For builds in another shell, add SDK directories to PATH:")
        print("export PATH=" + shlex.quote(str(Path(cargo).parent) + ":" + str(Path(flutter).parent)) + ':"$PATH"')
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("host", "x86_64", "aarch64", "arm64"), default="host",
                        help="Check host dependencies; an explicit architecture must match the host")
    parser.add_argument("--scope", choices=("native", "desktop"), default="desktop")
    parser.add_argument("--check-only", action="store_true", help="Report missing dependencies without installing")
    parser.add_argument("--system-only", action="store_true", help="Only install/check distro packages; suitable for sudo")
    parser.add_argument("--with-validation-tools", action="store_true",
                        help="Also prepare optional headless GUI, keyring and audio validation tools")
    args = parser.parse_args()
    try:
        ready = ensure(args.scope, args.check_only, args.system_only, args.arch)
        if args.with_validation_tools and (ready or args.check_only):
            spec = importlib.util.spec_from_file_location(
                "fideflow_validation_dependencies", Path(__file__).with_name("validation_dependencies.py"))
            validation = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(validation)
            checks = SimpleNamespace(PACKAGES=PACKAGES, install_system=install_system, log=log)
            ready = validation.ensure(checks, args.check_only) and ready
        return 0 if ready else 1
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        log(f"Error: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
