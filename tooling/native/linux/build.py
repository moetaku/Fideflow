#!/usr/bin/env python3
"""Pinned, offline FFmpeg/libsoxr Linux build for Fideflow (x86_64/aarch64)."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "native/build/third_party"
MANIFEST = ROOT / "tooling/native/sources.manifest.json"
COMPONENTS = ROOT / "tooling/native/ffmpeg-components.txt"


def manifest():
    return json.loads(MANIFEST.read_text())


def host_arch(machine: str | None = None) -> str:
    machine = machine or platform.machine()
    aliases = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}
    if machine not in aliases:
        raise ValueError(f"unsupported Linux architecture: {machine}")
    return aliases[machine]


def validate_build_arch(arch: str, machine: str | None = None) -> None:
    host = host_arch(machine)
    if arch != host:
        raise ValueError(f"cross-building {arch} on {host} is not configured; run this command on a native {arch} Linux runner")


def component_sections(path: Path = COMPONENTS) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        kind, sep, values = line.partition(":")
        if not sep or kind not in {"demuxer", "decoder", "parser", "protocol-base"}:
            raise ValueError(f"invalid FFmpeg allowlist line: {raw}")
        sections.setdefault(kind, []).extend(values.split())
    expected = {"demuxer", "decoder", "parser", "protocol-base"}
    if sections.keys() != expected:
        raise ValueError(f"FFmpeg allowlist sections must be {sorted(expected)}")
    for kind, values in sections.items():
        if len(values) != len(set(values)):
            raise ValueError(f"duplicate FFmpeg {kind} component")
    return sections


def run(command: list[str], **kwargs) -> None:
    print("[linux-native]", " ".join(map(str, command)), flush=True)
    subprocess.run(command, check=True, **kwargs)


def source_paths(name: str) -> tuple[dict, Path, Path]:
    entry = manifest()["sources"][name]
    archive = NATIVE / "downloads" / entry["downloadName"]
    source = NATIVE / "src" / entry["topDir"]
    return entry, archive, source


def fetch_source(name: str) -> Path:
    entry, archive, source = source_paths(name)
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        error = None
        for url in entry["urls"]:
            try:
                print(f"[linux-native] downloading {url}", flush=True)
                with urllib.request.urlopen(url, timeout=45) as response, archive.open("wb") as out:
                    shutil.copyfileobj(response, out)
                break
            except Exception as exc:  # noqa: BLE001 - try pinned mirrors in order
                error = exc
                archive.unlink(missing_ok=True)
        else:
            raise RuntimeError(f"failed to download {entry['downloadName']}: {error}")
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != entry["sha256"]:
        raise RuntimeError(f"{archive.name}: SHA-256 mismatch (expected {entry['sha256']}, got {actual})")
    if not source.is_dir():
        source.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, "r:*") as tf:
            # Validate path and link targets before extraction. This works on Python 3.10.
            root = source.parent.resolve()
            members = tf.getmembers()
            for member in members:
                target = (root / member.name).resolve()
                if target != root and not target.is_relative_to(root):
                    raise RuntimeError(f"unsafe path in {archive.name}: {member.name}")
                if member.issym() or member.islnk():
                    link_target = (target.parent / member.linkname).resolve()
                    if link_target != root and not link_target.is_relative_to(root):
                        raise RuntimeError(f"unsafe link in {archive.name}: {member.name}")
            tf.extractall(source.parent)
        if not source.is_dir():
            raise RuntimeError(f"archive did not contain expected directory {source}")
    return source


def dependency_checker():
    spec = importlib.util.spec_from_file_location("fideflow_linux_dependencies", Path(__file__).with_name("dependencies.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_tools() -> None:
    dependencies = dependency_checker()
    dependencies.discover_toolchains()
    missing = dependencies.missing_system("native")
    missing.extend(name for name in ("rustc", "cargo") if not dependencies.succeeds([name, "--version"]))
    if missing:
        raise RuntimeError("missing required Linux build tools: " + ", ".join(missing) +
                           "; run tooling/bootstrap-linux.sh --scope native")


def prefix_for(arch: str) -> Path:
    return NATIVE / "linux" / arch


def fetch(arch: str) -> None:
    for source in ("ffmpeg", "libsoxr", "portaudio"):
        path = fetch_source(source)
        print(f"[linux-native] verified {source} {manifest()['sources'][source]['version']} at {path}")


def build_portaudio(arch: str, prefix: Path, jobs: int) -> None:
    src = fetch_source("portaudio")
    build = NATIVE / "build" / f"portaudio-{arch}"
    run(["cmake", "-S", str(src), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
         "-DPA_BUILD_STATIC=ON", "-DPA_BUILD_SHARED=OFF", "-DPA_USE_ALSA=ON",
         "-DPA_ALSA_DYNAMIC=OFF", "-DPA_USE_JACK=OFF", "-DPA_BUILD_TESTS=OFF",
         "-DPA_BUILD_EXAMPLES=OFF", f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_INSTALL_LIBDIR=lib"])
    run(["cmake", "--build", str(build), "--parallel", str(jobs)])
    run(["cmake", "--install", str(build)])
    licenses = prefix / "licenses"
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src / "LICENSE.txt", licenses / "portaudio-LICENSE.txt")
    inventory = licenses / "THIRD-PARTY.txt"
    if inventory.is_file() and "PortAudio 19.7.0" not in inventory.read_text():
        inventory.write_text(inventory.read_text() + "PortAudio 19.7.0: MIT (statically linked; ALSA host API)\n")


def build_soxr(arch: str, prefix: Path, jobs: int) -> None:
    src = NATIVE / "src" / manifest()["sources"]["libsoxr"]["topDir"]
    build = NATIVE / "build" / f"soxr-{arch}"
    run(["cmake", "-S", str(src), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
         f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DBUILD_SHARED_LIBS=ON", "-DBUILD_TESTS=OFF",
         "-DBUILD_EXAMPLES=OFF", "-DWITH_OPENMP=OFF", "-DWITH_AVFFT=OFF",
         "-DWITH_LSR_BINDINGS=OFF", "-DWITH_DEV_TRACE=OFF", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
         "-DCMAKE_INSTALL_RPATH=$ORIGIN"])
    run(["cmake", "--build", str(build), "--parallel", str(jobs)])
    run(["cmake", "--install", str(build)])


def build_ffmpeg(arch: str, prefix: Path, jobs: int) -> None:
    src = NATIVE / "src" / manifest()["sources"]["ffmpeg"]["topDir"]
    build = NATIVE / "build" / f"ffmpeg-{arch}"
    if build.exists():
        shutil.rmtree(build)
    shutil.copytree(src, build, ignore=shutil.ignore_patterns(".git"))
    sections = component_sections()
    cmd = [str(build / "configure"), f"--prefix={prefix}", f"--arch={arch}", "--target-os=linux",
           "--enable-shared", "--disable-static", "--enable-pic", "--disable-everything",
           "--disable-autodetect", "--disable-programs", "--disable-doc", "--disable-debug",
           "--disable-avdevice", "--disable-avfilter", "--disable-postproc", "--disable-swscale",
           "--enable-avcodec", "--enable-avformat", "--enable-avutil", "--enable-swresample",
           "--enable-libsoxr", "--disable-network", "--disable-openssl", "--disable-gpl",
           "--disable-securetransport", "--disable-schannel", "--disable-gnutls",
           "--disable-libtls", "--disable-mbedtls", "--disable-nonfree", "--disable-version3",
           f"--extra-cflags=-I{prefix}/include",
           f"--extra-ldflags=-L{prefix}/lib"]
    for kind, names in sections.items():
        configure_kind = "protocol" if kind == "protocol-base" else kind
        for name in names:
            cmd.append(f"--enable-{configure_kind}={name}")
    for kind in ("demuxers", "decoders", "parsers", "protocols"):
        listing = subprocess.run([str(build / "configure"), f"--list-{kind}"], cwd=build,
                                 capture_output=True, text=True, check=True).stdout
        listing_file = NATIVE / "build" / f"ffmpeg-{arch}-available-{kind}.txt"
        listing_file.parent.mkdir(parents=True, exist_ok=True)
        listing_file.write_text(listing)
        run(["python3", str(ROOT / "tooling/native/manifest.py"), "validate-components",
             "--kind", kind, "--network", "off", "--available", str(listing_file)])
    run(cmd, cwd=build)
    run(["make", "-j", str(jobs)], cwd=build)
    run(["make", "install"], cwd=build)


def fixup_rpaths(prefix: Path) -> None:
    # The linker command string passes through FFmpeg's configure and make shell
    # layers, which can expand $ORIGIN. Rewrite the installed ELF tags directly.
    for path in sorted((prefix / "lib").glob("*.so*")):
        if path.is_file() and not path.is_symlink():
            run(["patchelf", "--set-rpath", "$ORIGIN", str(path)])


def run_capcheck(arch: str, prefix: Path) -> None:
    build_dir = NATIVE / "build"
    binary = build_dir / f"capcheck-{arch}"
    pkgconfig = prefix / "lib/pkgconfig"
    env = os.environ.copy()
    env["PKG_CONFIG_LIBDIR"] = str(pkgconfig)
    env["PKG_CONFIG_PATH"] = ""
    flags = subprocess.run(["pkg-config", "--cflags", "--libs", "libavformat", "libavcodec",
                            "libavutil", "libswresample"], env=env, capture_output=True, text=True, check=True)
    run(["cc", str(ROOT / "tooling/native/checks/capcheck.c"), "-o", str(binary),
         *flags.stdout.split(), "-lm"])
    env["LD_LIBRARY_PATH"] = str(prefix / "lib")
    log = build_dir / f"capcheck-{arch}.log"
    result = subprocess.run([str(binary), "--arch", arch, "--network", "off"], env=env,
                            capture_output=True, text=True)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"capability probe failed; see {log}\n{result.stdout[-1200:]}\n{result.stderr[-1200:]}")
    config_line = next((line for line in result.stdout.splitlines() if line.startswith("configuration: ")), "")
    sections = component_sections()
    for kind, names in sections.items():
        configure_kind = "protocol" if kind == "protocol-base" else kind
        missing = [name for name in names if f"--enable-{configure_kind}={name}" not in config_line]
        if missing:
            raise RuntimeError(f"FFmpeg config is missing allowlisted {kind}: {', '.join(missing)}")


def stage_licenses(prefix: Path) -> None:
    licenses = prefix / "licenses"
    licenses.mkdir(parents=True, exist_ok=True)
    for name in ("ffmpeg", "libsoxr", "portaudio"):
        entry, _, source = source_paths(name)
        license_files = [source / item for item in entry["licenseFiles"] if (source / item).is_file()]
        if not license_files:
            raise RuntimeError(f"no listed license file found for {name}")
        for license_file in license_files:
            shutil.copy2(license_file, licenses / f"{name}-{license_file.name}")
    shutil.copy2(ROOT / "native/media_core/crates/ncm-api-compat/UPSTREAM.json", licenses / "ncm-host-UPSTREAM.json")
    shutil.copy2(ROOT / "native/media_core/crates/ncm-api-compat/HOST-PATCH.md", licenses / "ncm-host-PATCH.md")
    shutil.copy2(ROOT / "native/media_core/vendor/ncm-api-rs/LICENSE", licenses / "ncm-api-rs-LICENSE")
    vendor_evidence = licenses / "ncm-api-rs-source-evidence"
    vendor_evidence.mkdir(exist_ok=True)
    for name in ("Cargo.toml", "README.md"):
        candidate = ROOT / "native/media_core/vendor/ncm-api-rs" / name
        if candidate.is_file():
            shutil.copy2(candidate, vendor_evidence / name)
    (licenses / "THIRD-PARTY.txt").write_text(
        "FFmpeg: LGPL-2.1-or-later (offline build; no GPL/nonfree components)\n"
        "libsoxr: LGPL-2.1-or-later\n"
        "PortAudio 19.7.0: MIT (statically linked; ALSA host API)\n"
        "Fideflow media core: MIT; NCM compatibility layer: Apache-2.0; upstream ncm-api-rs: WTFPL.\n"
    )


def verify(arch: str, prefix: Path) -> None:
    required = ["lib/libavformat.so", "lib/libavcodec.so", "lib/libavutil.so", "lib/libswresample.so", "lib/libsoxr.so",
                "include/libavformat/avformat.h", "include/soxr.h"]
    missing = [rel for rel in required if not (prefix / rel).exists()]
    if missing:
        raise RuntimeError(f"{arch} prefix is incomplete; missing: {', '.join(missing)}")
    expected_machine = {"x86_64": "Advanced Micro Devices X86-64", "aarch64": "AArch64"}[arch]
    library_paths = [path for path in sorted((prefix / "lib").glob("*.so*")) if path.is_file() and not path.is_symlink()]
    total_size = sum(path.stat().st_size for path in library_paths)
    size_budget = manifest()["sizeBudgetBytesPerArchitecture"]
    if total_size > size_budget:
        raise RuntimeError(f"native shared libraries use {total_size} bytes, exceeding the {size_budget}-byte architecture budget")
    system_sonames = ("libc.so", "libm.so", "libdl.so", "libpthread.so", "librt.so", "libgcc_s.so", "libstdc++.so", "ld-linux")
    for path in library_paths:
        result = subprocess.run(["readelf", "-h", str(path)], capture_output=True, text=True, check=True)
        if expected_machine not in result.stdout:
            raise RuntimeError(f"{path.name} has wrong ELF architecture; expected {expected_machine}")
        dynamic = subprocess.run(["readelf", "-d", str(path)], capture_output=True, text=True, check=True).stdout
        runpath = next((line.split("[", 1)[1].split("]", 1)[0] for line in dynamic.splitlines() if "(RUNPATH)" in line), "")
        if runpath != "$ORIGIN":
            raise RuntimeError(f"{path.name} must use relocatable DT_RUNPATH=$ORIGIN")
        for needed in ("libsoxr.so", "libavcodec.so", "libavformat.so", "libavutil.so", "libswresample.so"):
            if f"Shared library: [{needed}" in dynamic and "$ORIGIN" not in dynamic:
                raise RuntimeError(f"{path.name} depends on sibling {needed} without $ORIGIN RPATH")
        ldd = subprocess.run(["ldd", str(path)], capture_output=True, text=True, check=True).stdout
        if "not found" in ldd:
            raise RuntimeError(f"{path.name} has unresolved runtime dependencies:\n{ldd}")
        for line in ldd.splitlines():
            soname = line.strip().split(" ", 1)[0]
            if soname and not soname.startswith(system_sonames) and "=>" in line:
                resolved = line.split("=>", 1)[1].strip().split(" ", 1)[0]
                if not resolved.startswith(str(prefix / "lib")):
                    raise RuntimeError(f"{path.name} depends on unbundled library {soname} at {resolved}")
    if not (prefix / "licenses/THIRD-PARTY.txt").is_file():
        raise RuntimeError("license inventory is missing; run build first")
    for required_audio in ("lib/libportaudio.a", "include/portaudio.h", "include/pa_linux_alsa.h", "licenses/portaudio-LICENSE.txt"):
        if not (prefix / required_audio).is_file():
            raise RuntimeError("PortAudio prefix is incomplete: " + required_audio)
    capcheck_log = NATIVE / "build" / f"capcheck-{arch}.log"
    if not capcheck_log.is_file() or "capability probe passed" not in capcheck_log.read_text(errors="replace"):
        raise RuntimeError("offline FFmpeg capability probe evidence is missing; run build first")
    print(f"[linux-native] verified {arch} ELF libraries and license inventory at {prefix}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("deps", "fetch", "build", "verify", "all", "portaudio"), nargs="?", default="all")
    parser.add_argument("--arch", choices=("host", "x86_64", "aarch64"), default="host")
    parser.add_argument("--prefix", type=Path, help="Override the native build prefix")
    parser.add_argument("--jobs", type=int, default=max(1, os.cpu_count() or 1))
    parser.add_argument("--check-only", action="store_true", help="With deps, report missing tools without installing")
    args = parser.parse_args()
    if args.check_only and args.command != "deps":
        parser.error("--check-only is only supported with deps")
    try:
        arch = host_arch() if args.arch == "host" else args.arch
        prefix = args.prefix.resolve() if args.prefix else prefix_for(arch)
        if args.command == "deps":
            if not dependency_checker().ensure("native", check_only=args.check_only, target=args.arch):
                return 1
            print(f"[linux-native] tools ready; host={host_arch()}, requested={arch}, prefix={prefix}")
            return 0
        if args.command in ("build", "all", "portaudio"):
            validate_build_arch(arch)
        if args.command in ("build", "all", "portaudio"):
            if not dependency_checker().ensure("native"):
                return 1
        if args.command == "portaudio":
            build_portaudio(arch, prefix, args.jobs)
            return 0
        if args.command == "verify":
            check_tools()
        if args.command in ("fetch", "all"):
            fetch(arch)
        if args.command in ("build", "all", "portaudio"):
            fetch(arch)
            build_portaudio(arch, prefix, args.jobs)
            build_soxr(arch, prefix, args.jobs)
            build_ffmpeg(arch, prefix, args.jobs)
            fixup_rpaths(prefix)
            stage_licenses(prefix)
            run_capcheck(arch, prefix)
        if args.command == "verify":
            run_capcheck(arch, prefix)
        if args.command in ("verify", "all"):
            verify(arch, prefix)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"[linux-native] error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
