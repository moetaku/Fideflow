#!/usr/bin/env python3
"""Fix up and verify the installed Linux Flutter bundle's native ELF closure."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SYSTEM_LIBRARIES = ("libc.so", "libm.so", "libdl.so", "libpthread.so", "librt.so", "libgcc_s.so", "libstdc++.so", "ld-linux")
ROOT = Path(__file__).resolve().parents[3]


def run(*args):
    environment = os.environ.copy()
    environment.pop("LD_LIBRARY_PATH", None)
    return subprocess.run(args, check=True, capture_output=True, text=True, env=environment).stdout


def runpath(dynamic: str) -> str:
    for line in dynamic.splitlines():
        if "(RUNPATH)" in line:
            return line.split("[", 1)[1].split("]", 1)[0]
    return ""


def resolved_dependencies(path: Path) -> list[tuple[str, Path]]:
    output = run("ldd", str(path))
    if "not found" in output:
        raise RuntimeError(f"{path.name} has unresolved dependencies:\n{output}")
    dependencies = []
    for line in output.splitlines():
        if "=>" not in line:
            continue
        soname, resolved = line.strip().split("=>", 1)
        resolved = resolved.strip().split(" ", 1)[0]
        if resolved.startswith("/"):
            dependencies.append((soname.strip(), Path(resolved).resolve()))
    return dependencies


def alsa_runtime_closure(paths: list[Path]) -> set[Path]:
    """Allow the distro's libasound runtime and its exact transitive closure."""
    pending = []
    for path in paths:
        pending.extend(resolved for soname, resolved in resolved_dependencies(path)
                       if soname.startswith("libasound.so"))
    closure = set()
    while pending:
        library = pending.pop()
        if library in closure:
            continue
        closure.add(library)
        pending.extend(resolved for _, resolved in resolved_dependencies(library)
                       if resolved not in closure)
    return closure


def verify_size(native_size: int, budget: int, build_mode: str):
    # Debug/Profile currently bundle the unstripped Cargo debug library.
    if build_mode == "release" and native_size > budget:
        raise RuntimeError(f"bundle native audio libraries use {native_size} bytes, exceeding the {budget}-byte architecture budget")


def verify(bundle: Path, fixup: bool, build_mode: str = "release"):
    library_dir = bundle / "lib"
    core = library_dir / "libff_media_core.so"
    if not core.is_file():
        raise RuntimeError(f"bundle is missing {core}")
    if fixup:
        run("patchelf", "--set-rpath", "$ORIGIN", str(core))
    required = ["libavformat.so", "libavcodec.so", "libavutil.so", "libswresample.so", "libsoxr.so"]
    for name in required:
        if not list(library_dir.glob(name + "*")):
            raise RuntimeError(f"bundle is missing {name}")
    licenses = bundle / "data/licenses"
    for name in ("THIRD-PARTY.txt", "ffmpeg-COPYING.LGPLv2.1", "libsoxr-LICENCE", "ncm-api-rs-LICENSE", "portaudio-LICENSE.txt"):
        if not (licenses / name).is_file():
            raise RuntimeError(f"bundle is missing license evidence {licenses / name}")
    native_names = ["libavformat.so", "libavcodec.so", "libavutil.so", "libswresample.so", "libsoxr.so"]
    native_libraries = [core]
    for name in native_names:
        candidate = library_dir / name
        native_libraries.append(candidate.resolve())
    native_libraries = list(dict.fromkeys(native_libraries))
    alsa_system_libraries = alsa_runtime_closure(native_libraries)
    expected_machine = run("readelf", "-h", str(bundle / "fideflow"))
    machine_line = next((line.split(":", 1)[1].strip() for line in expected_machine.splitlines() if "Machine:" in line), "")
    native_size = 0
    for path in native_libraries:
        if not path.is_file():
            raise RuntimeError(f"bundle is missing native library {path}")
        elf_header = run("readelf", "-h", str(path))
        library_machine = next((line.split(":", 1)[1].strip() for line in elf_header.splitlines() if "Machine:" in line), "")
        if library_machine != machine_line:
            raise RuntimeError(f"{path.name} architecture {library_machine!r} does not match app {machine_line!r}")
        native_size += path.stat().st_size
        dynamic = run("readelf", "-d", str(path))
        if runpath(dynamic) != "$ORIGIN":
            raise RuntimeError(f"{path.name} does not use relocatable DT_RUNPATH=$ORIGIN")
        for soname, resolved in resolved_dependencies(path):
            if resolved in alsa_system_libraries:
                continue
            if resolved.is_relative_to(library_dir.resolve()):
                continue
            if not soname.startswith(SYSTEM_LIBRARIES):
                raise RuntimeError(f"{path.name} uses unbundled {soname} at {resolved}")
    budget = json.loads((ROOT / "tooling/native/sources.manifest.json").read_text())["sizeBudgetBytesPerArchitecture"]
    verify_size(native_size, budget, build_mode)
    # Flutter and desktop plugins can use distribution GTK/GLib libraries. Check
    # their loader closure for missing files, while keeping bundle ownership
    # requirements limited to the native audio stack above.
    for path in [bundle / "fideflow", *library_dir.glob("*.so*")]:
        if path.exists() and path not in native_libraries:
            dependencies = run("ldd", str(path))
            if "not found" in dependencies:
                raise RuntimeError(f"{path.name} has unresolved runtime dependencies:\n{dependencies}")
    print(f"Linux bundle dependencies and licenses verified: {bundle}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--fixup", action="store_true")
    parser.add_argument("--build-mode", choices=("debug", "profile", "release"), default="release",
                        help="release enforces the native library size budget (default: release)")
    args = parser.parse_args()
    try:
        verify(args.bundle.resolve(), args.fixup, args.build_mode)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"linux-bundle: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
