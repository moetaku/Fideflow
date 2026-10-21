#!/usr/bin/env python3
"""Manifest reader, validator and report generator for the macOS native build.

The bash driver (`tooling/native/macos/build.sh`) never parses JSON itself: it
calls this helper and consumes one value per line, which keeps the shell free of
JSON handling and compatible with the macOS system bash 3.2.

`check` is the documentation and CI gate: it keeps `sources.manifest.json`,
`ffmpeg-components.txt`, the design documents, the media-output build script and the network
mode definitions describing the same pinned versions and component sets.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

NATIVE_DIR = Path(__file__).resolve().parent
REPO_ROOT = NATIVE_DIR.parents[1]
MANIFEST_PATH = NATIVE_DIR / "sources.manifest.json"
COMPONENTS_PATH = NATIVE_DIR / "ffmpeg-components.txt"
BUILD_RS = REPO_ROOT / "native/media_core/crates/media-output/build.rs"

def vendored_tree_sha256(source):
    """Hash original SDK files; ignore only Cargo build output and Git metadata."""
    files = []
    for directory, names, filenames in os.walk(source):
        names[:] = [name for name in names if name not in (".git", "target")]
        files.extend(Path(directory) / name for name in filenames)
    digest = hashlib.sha256()
    for file in sorted(files, key=lambda p: p.relative_to(source).as_posix()):
        digest.update(file.relative_to(source).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(file.read_bytes()).digest())
    return digest.hexdigest()


HEX64 = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_SECTIONS = {
    "demuxer",
    "decoder",
    "parser",
    "protocol-base",
}
LIST_KIND_TO_SECTIONS = {
    "demuxers": ["demuxer"],
    "decoders": ["decoder"],
    "parsers": ["parser"],
    "protocols": ["protocol-base"],
}


def fail(message):
    print(f"manifest: {message}", file=sys.stderr)
    raise SystemExit(1)


def load():
    return json.loads(MANIFEST_PATH.read_text())


def cmd_platform_field(args):
    config = load()["platforms"].get(args.platform)
    if config is None:
        fail(f"unsupported platform {args.platform!r}")
    if args.field not in config:
        fail(f"unknown platform field {args.field!r}")
    value = config[args.field]
    if isinstance(value, list):
        for item in value:
            print(item)
    else:
        print(value)


def platform_errors(manifest):
    """Shared pins remain platform-neutral; legacy fields still serve macOS scripts."""
    errors = []
    platforms = manifest.get("platforms", {})
    if not {"macos", "windows"}.issubset(platforms) or set(platforms) - {"macos", "windows", "android", "ios", "linux"}:
        errors.append("platforms must contain macos and windows and only supported platforms")
    if "linux" in platforms:
        expected_linux = {
            "deploymentTarget": "glibc-2.31",
            "architectures": ["x86_64", "aarch64"],
            "rustTargets": ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"],
            "libraryName": "libff_media_core.so",
            "outputBackend": "portaudio",
            "toolchain": "gcc-or-clang",
            "prefix": "native/build/third_party/linux",
            "networkMode": "off",
        }
        for field, value in expected_linux.items():
            if platforms["linux"].get(field) != value:
                errors.append(f"linux {field} must be {value!r}")
    macos = platforms.get("macos", {})
    for field in ("deploymentTarget", "architectures"):
        if macos.get(field) != manifest.get(field):
            errors.append(f"macos {field} must match the legacy default")
    expected = {
        "deploymentTarget": "10.0.19041",
        "architectures": ["x86_64"],
        "rustTargets": ["x86_64-pc-windows-msvc"],
        "libraryName": "ff_media_core.dll",
        "outputBackend": "wasapi",
        "toolchain": "msvc",
        "prefix": "native/build/third_party/windows",
    }
    for field, value in expected.items():
        if platforms.get("windows", {}).get(field) != value:
            errors.append(f"windows {field} must be {value!r}")
    for platform, minimum, targets in [
        ("android", "24", ["aarch64-linux-android", "x86_64-linux-android"]),
        ("ios", "13.0", ["aarch64-apple-ios", "aarch64-apple-ios-sim"]),
    ]:
        if platform in platforms:
            config = platforms[platform]
            for field, expected_value in {"deploymentTarget": minimum, "rustTargets": targets,
                    "outputBackend": "miniaudio", "networkMode": "off"}.items():
                if config.get(field) != expected_value:
                    errors.append(f"{platform} {field} must be {expected_value!r}")
    return errors


def components():
    sections = {}
    for raw in COMPONENTS_PATH.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            fail(f"ffmpeg-components.txt: expected '<kind>: <names>', got: {raw}")
        kind, names = line.split(":", 1)
        kind = kind.strip()
        if kind not in ALLOWED_SECTIONS:
            fail(f"ffmpeg-components.txt: unknown section {kind!r}")
        sections.setdefault(kind, []).extend(names.split())
    missing = ALLOWED_SECTIONS - set(sections)
    if missing:
        fail(f"ffmpeg-components.txt: missing sections {sorted(missing)}")
    for kind, names in sections.items():
        duplicates = {name for name in names if names.count(name) > 1}
        if duplicates:
            fail(f"ffmpeg-components.txt: duplicate names in {kind}: {sorted(duplicates)}")
    return sections


def mode_config(manifest, mode):
    modes = manifest["networkModes"]
    if mode not in modes:
        fail(f"unknown network mode {mode!r}; known: {sorted(modes)}")
    return modes[mode]


def expected_protocols(manifest, mode, sections):
    listed = set(sections["protocol-base"])
    declared = set(mode_config(manifest, mode)["protocols"])
    if listed != declared:
        fail(
            f"network mode {mode!r}: ffmpeg-components.txt and manifest disagree "
            f"(components {sorted(listed)}, manifest {sorted(declared)})"
        )
    return declared


def display_path(path):
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def first_line(command):
    try:
        output = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )
    except (OSError, ValueError):
        return None
    text = (output.stdout or output.stderr).strip()
    return text.splitlines()[0] if text else None


def toolchain_versions():
    versions = {}
    for key, command in (
        ("clang", ["clang", "--version"]),
        ("xcodebuild", ["xcodebuild", "-version"]),
        ("macosSdk", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        ("cmake", ["cmake", "--version"]),
        ("nasm", ["nasm", "-v"]),
        ("rustc", ["rustc", "-V"]),
    ):
        value = first_line(command)
        if value:
            versions[key] = value
    return versions


def source_files(manifest):
    """Yield (source, display name, expected sha256) for every pinned payload."""
    for name, entry in manifest["sources"].items():
        if entry["archiveFormat"] == "files":
            for item in entry["files"]:
                yield name, item["name"], item["sha256"]
        else:
            yield name, entry["downloadName"], entry["sha256"]


# --------------------------------------------------------------------------- #
# subcommands
# --------------------------------------------------------------------------- #


def cmd_field(args):
    value = load()
    for segment in args.path.split("."):
        if not isinstance(value, dict) or segment not in value:
            fail(f"no manifest field {args.path!r}")
        value = value[segment]
    print(value if isinstance(value, str) else json.dumps(value))


def cmd_source_field(args):
    entry = load()["sources"].get(args.source)
    if entry is None:
        fail(f"unknown source {args.source!r}")
    if args.field not in entry:
        fail(f"source {args.source!r} has no field {args.field!r}")
    value = entry[args.field]
    if isinstance(value, list):
        print("\n".join(str(item) for item in value))
    elif isinstance(value, bool):
        print("true" if value else "false")
    elif value is None:
        print("")
    else:
        print(value)


def cmd_source_list(args):
    manifest = load()
    for name in sorted(manifest["sources"]):
        print(name)


def cmd_tool_field(args):
    entry = load().get("tools", {}).get(args.tool)
    if entry is None:
        fail(f"unknown tool {args.tool!r}")
    if args.field not in entry:
        fail(f"tool {args.tool!r} has no field {args.field!r}")
    value = entry[args.field]
    if isinstance(value, list):
        print("\n".join(str(item) for item in value))
    else:
        print(value)


def cmd_tool_list(args):
    for name in sorted(load().get("tools", {})):
        print(name)


def cmd_architectures(args):
    manifest = load()
    for arch in manifest["architectures"]:
        print(arch)


def cmd_fixup_plan(args):
    """Print `<real path>\t<canonical dylib name>` rows for install-name rewriting."""
    lib_dir = Path(args.prefix) / "lib"
    aliases = {}
    for path in sorted(lib_dir.glob("*.dylib")):
        real = path.resolve()
        if not real.is_file():
            continue
        aliases.setdefault(real, []).append(path.name)
    for real in sorted(aliases):
        names = sorted(aliases[real], key=lambda name: (len(name), name))
        print(f"{real}\t{names[0]}")
    return 0


def cmd_protocols(args):
    manifest = load()
    print(" ".join(mode_config(manifest, args.network)["protocols"]))


def cmd_ca_bundle(args):
    manifest = load()
    value = mode_config(manifest, args.network)["caBundle"]
    print(value or "")


def cmd_network_modes(args):
    manifest = load()
    for name in sorted(manifest["networkModes"]):
        print(name)


def cmd_ffmpeg_configure_args(args):
    manifest = load()
    sections = components()
    protocols = sorted(expected_protocols(manifest, args.network, sections))
    flags = []

    def value_for(flag):
        return flag + "="

    flags.append(value_for("--prefix") + args.prefix)
    flags.append(value_for("--target-os") + "darwin")
    flags.append(value_for("--arch") + args.arch)
    flags.append(value_for("--cc") + "clang")
    if args.cross == "1":
        flags.append("--enable-cross-compile")
    if args.arch == "x86_64":
        flags.append(value_for("--x86asmexe") + "nasm")
    flags.append("--enable-shared")
    flags.append("--disable-static")
    flags.append("--enable-pic")
    if args.install_name_dir == "1":
        flags.append(value_for("--install-name-dir") + "@rpath")
    flags.extend(
        [
            "--disable-programs",
            "--disable-doc",
            "--disable-avdevice",
            "--disable-avfilter",
            "--disable-postproc",
            "--disable-swscale",
            "--disable-everything",
            "--disable-autodetect",
            "--enable-avcodec",
            "--enable-avformat",
            "--enable-avutil",
            "--enable-swresample",
        ]
    )
    if args.with_soxr == "1":
        flags.append("--enable-libsoxr")
    flags.extend(["--disable-network", "--disable-openssl", "--disable-securetransport", "--disable-schannel"])
    flags.extend(["--disable-gpl", "--disable-nonfree", "--disable-version3"])
    for kind in ("demuxer", "decoder", "parser"):
        flags.append(f"--enable-{kind}=" + ",".join(sections[kind]))
    flags.append("--enable-protocol=" + ",".join(protocols))
    # FFmpeg detects libsoxr with a plain require() rather than pkg-config, so the
    # prefix include and lib directories have to be in the compiler flags. They
    # also keep every lookup inside our own prefix instead of Homebrew.
    cflags = (
        f"-arch {args.arch} -mmacosx-version-min={args.deployment_target} -O2 "
        f"-I{args.prefix}/include"
    )
    ldflags = (
        f"-arch {args.arch} -mmacosx-version-min={args.deployment_target} -L{args.prefix}/lib"
    )
    flags.append(f"--extra-cflags={cflags}")
    flags.append(f"--extra-ldflags={ldflags}")

    for forbidden in manifest["forbiddenConfigureFlags"]:
        if any(flag.startswith(forbidden) for flag in flags):
            fail(f"generated configure flags contain forbidden flag {forbidden}")
    print("\n".join(flags))


def cmd_validate_components(args):
    manifest = load()
    sections = components()
    expected_protocols(manifest, args.network, sections)
    kinds = LIST_KIND_TO_SECTIONS.get(args.kind)
    if kinds is None:
        fail(f"unsupported --kind {args.kind!r}")
    available = set()
    for raw in Path(args.available).read_text(errors="replace").split():
        token = raw.strip()
        if token and not token.endswith(":") and ":" not in token:
            available.add(token)
    if not available:
        fail(f"`configure --list-{args.kind}` produced no names ({args.available})")
    wanted = []
    for kind in kinds:
        wanted.extend(sections[kind])
    if args.kind == "protocols":
        wanted = list(expected_protocols(manifest, args.network, sections))
    unknown = sorted(name for name in dict.fromkeys(wanted) if name not in available)
    if unknown:
        fail(f"unknown FFmpeg {args.kind}: {', '.join(unknown)}; check {COMPONENTS_PATH.name}")
    print(f"ffmpeg {args.kind}: {len(set(wanted))} allowlisted components resolved")


def cmd_check(args):
    manifest = load()
    sections = components()
    errors = platform_errors(manifest)
    if manifest["defaultNetworkMode"] != "off" or set(manifest["networkModes"]) != {"off"}:
        errors.append("FFmpeg must only support network mode off")
    if manifest["platforms"]["windows"].get("networkMode") != "off":
        errors.append("Windows FFmpeg must disable networking")
    if manifest["manifestVersion"] != 1:
        errors.append("manifestVersion must be 1")
    if manifest["platform"] != "macos":
        errors.append("platform must be macos")
    if manifest["deploymentTarget"] != "12.0":
        errors.append("deploymentTarget must be 12.0 (docs/design/native-build.md)")
    if manifest["architectures"] != ["arm64", "x86_64"]:
        errors.append("architectures must be [arm64, x86_64] (docs/design/native-build.md)")
    if manifest["sizeBudgetBytesPerArchitecture"] != 40 * 1024 * 1024:
        errors.append("sizeBudgetBytesPerArchitecture must be 40 MiB (docs/design/native-build.md)")
    if manifest["defaultNetworkMode"] not in manifest["networkModes"]:
        errors.append("defaultNetworkMode must exist in networkModes")
    for mode in manifest["networkModes"]:
        try:
            expected_protocols(manifest, mode, sections)
        except SystemExit:
            errors.append(f"network mode {mode!r} protocol sets disagree with ffmpeg-components.txt")
    for mode_name, mode in manifest["networkModes"].items():
        for required in mode["requiredSources"]:
            if required not in manifest["sources"]:
                errors.append(f"network mode {mode_name!r} requires unknown source {required!r}")
        if mode["tlsBackend"] != "none" and "openssl" not in mode["requiredSources"]:
            errors.append(f"network mode {mode_name!r} uses TLS without a pinned TLS source")
    forbidden = set(manifest["forbiddenConfigureFlags"])
    for flag in ("--enable-gpl", "--enable-nonfree"):
        if flag not in forbidden:
            errors.append(f"{flag} must stay forbidden (docs/design/native-build.md)")

    # Executables the app must ship, as opposed to libraries it links (docs/design/provider.md).
    # A tool that is not pinned by an exact crate release cannot be reproduced,
    # and one without a licence cannot be reported.
    tools = manifest.get("tools", {})
    for name, entry in tools.items():
        for field in ("crate", "version", "binary", "license", "pin", "features"):
            if not entry.get(field):
                errors.append(f"tool {name!r}: missing {field}")
        if not re.fullmatch(r"\d+\.\d+\.\d+", str(entry.get("version") or "")):
            errors.append(f"tool {name!r}: version must be an exact release, not a range")
        if entry.get("pin") != "crate-lock":
            errors.append(
                f"tool {name!r}: pin must be crate-lock (cargo install --locked)"
            )

    # Linked SDKs have no executable or server feature. Their upstream archive
    # and local patch evidence are retained alongside the workspace lockfile.
    for name, entry in manifest.get("linkedSdks", {}).items():
        if entry.get("pin") != "vendored-sha256" or not HEX64.fullmatch(entry.get("upstreamSha256", "")):
            errors.append(f"linked SDK {name!r}: missing vendored upstream pin")
        source = REPO_ROOT / entry.get("source", "")
        upstream = source / "UPSTREAM.json"
        if not upstream.is_file():
            errors.append(f"linked SDK {name!r}: missing source evidence")
        else:
            evidence = json.loads(upstream.read_text())
            if (evidence.get("sha256"), evidence.get("version")) != (entry.get("upstreamSha256"), entry.get("version")):
                errors.append(f"linked SDK {name!r}: source evidence differs from manifest")
            vendor = REPO_ROOT / evidence.get("vendorPath", "")
            if not HEX64.fullmatch(evidence.get("treeSha256", "")) or vendored_tree_sha256(vendor) != evidence.get("treeSha256"):
                errors.append(f"linked SDK {name!r}: vendored source differs from its recorded distribution tree")
        for filename in ("Cargo.toml", entry["licenseFile"], "HOST-PATCH.md"):
            if not (source / filename).is_file():
                errors.append(f"linked SDK {name!r}: missing {filename}")
        if entry.get("features") != []:
            errors.append(f"linked SDK {name!r}: must not enable the server feature")

    for name, entry in manifest["sources"].items():
        for field in ("version", "license", "linkage"):
            if not entry.get(field):
                errors.append(f"source {name!r}: missing {field}")
        if entry["archiveFormat"] == "files":
            if not entry.get("files"):
                errors.append(f"source {name!r}: no files listed")
            for item in entry.get("files", []):
                if not args.allow_unpinned and not HEX64.match(item["sha256"] or ""):
                    errors.append(f"source {name!r}: {item['name']} has no pinned sha256")
        else:
            for field in ("downloadName", "topDir", "urls"):
                if not entry.get(field):
                    errors.append(f"source {name!r}: missing {field}")
            if not args.allow_unpinned and not HEX64.match(entry.get("sha256") or ""):
                errors.append(f"source {name!r}: no pinned sha256")

    embed = NATIVE_DIR / "macos/embed.sh"
    if not embed.is_file():
        errors.append("tooling/native/macos/embed.sh is missing")
    elif not os.access(embed, os.X_OK):
        errors.append("tooling/native/macos/embed.sh is not executable")
    else:
        text = embed.read_text()
        for needle in ("Contents/Frameworks", "Contents/Resources/ssl/cert.pem", "@rpath/"):
            if needle not in text:
                errors.append(f"embed.sh does not reference {needle}")

    if not BUILD_RS.is_file():
        errors.append("native/media_core/crates/media-output/build.rs is missing")
    else:
        build_rs = BUILD_RS.read_text()
        version = manifest["sources"]["portaudio"]["version"]
        if f'PORTAUDIO_VERSION: &str = "{version}"' not in build_rs:
            errors.append(f"media-output build.rs does not pin PortAudio {version}")

    if errors:
        for error in errors:
            print(f"manifest: {error}", file=sys.stderr)
        raise SystemExit(1)
    pinned = "pinned" if not args.allow_unpinned else "unpinned-allowed"
    print(
        f"native manifest OK ({pinned}): {len(manifest['sources'])} sources, "
        f"{len(tools)} tools, {len(manifest['networkModes'])} network modes"
    )


def cmd_print_checksums(args):
    manifest = load()
    directory = Path(args.dir)
    report = {}
    for name, display, _pinned in source_files(manifest):
        path = directory / display
        is_files = manifest["sources"][name]["archiveFormat"] == "files"
        entry = report.setdefault(name, {} if not is_files else {"files": {}})
        digest = sha256_file(path) if path.is_file() else None
        if is_files:
            entry["files"][display] = digest
        else:
            entry["sha256"] = digest
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


def cmd_size_report(args):
    prefix = Path(args.prefix)
    lib_dir = prefix / "lib"
    entries = []
    seen = set()
    for path in sorted(lib_dir.glob("*.dylib")):
        real = path.resolve()
        if real in seen:
            continue
        seen.add(real)
        entries.append(
            {
                "name": path.name,
                "bytes": real.stat().st_size,
                "sha256": sha256_file(real),
            }
        )
    for extra in args.extra_artifact or []:
        extra_path = Path(extra)
        if extra_path.is_file():
            entries.append(
                {
                    "name": extra_path.name,
                    "bytes": extra_path.stat().st_size,
                    "sha256": sha256_file(extra_path),
                }
            )
    total = sum(entry["bytes"] for entry in entries)
    exceeded = total > args.budget
    if args.json:
        print(
            json.dumps(
                {
                    "budgetBytes": args.budget,
                    "totalBytes": total,
                    "exceeded": exceeded,
                    "artifacts": entries,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    print(f"native size report for {prefix}")
    for entry in entries:
        print(f"  {entry['bytes']:>10}  {entry['name']}")
    mib = 1024 * 1024
    print(f"  {'-' * 10}")
    print(f"  {total:>10}  total ({total / mib:.1f} MiB) of budget {args.budget / mib:.0f} MiB")
    if exceeded:
        print(
            "  WARNING: over the docs/design/native-build.md review threshold; record a component/size report "
            "and update the budget instead of dropping codecs",
            file=sys.stderr,
        )
    return 0


def dylib_architectures(path):
    value = first_line(["lipo", "-archs", str(path)])
    return value.split() if value else []


def cmd_app_bundle_report(args):
    """Describe what embed.sh packaged into a .app, and check the size budget."""
    manifest = load()
    mode = mode_config(manifest, args.network)
    app = Path(args.app).resolve()
    frameworks = app / "Contents/Frameworks"
    if not frameworks.is_dir():
        fail(f"{frameworks} does not exist; run tooling/native/macos/embed.sh first")
    archs = list(args.archs.split())
    if not archs:
        fail("--archs needs at least one architecture")
    unknown = [arch for arch in archs if arch not in manifest["architectures"]]
    if unknown:
        fail(f"unsupported architectures: {', '.join(unknown)}")
    libraries = []
    for path in sorted(frameworks.glob("*.dylib")):
        found = dylib_architectures(path)
        missing = [arch for arch in archs if arch not in found]
        if missing:
            fail(f"{path.name} lacks {', '.join(missing)} (found: {' '.join(found) or 'none'})")
        libraries.append(
            {
                "name": path.name,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
                "architectures": found,
            }
        )
    if not libraries:
        fail(f"no dynamic libraries in {frameworks}")

    # Executables the bundle carries beside its main binary (docs/design/provider.md). They are
    # not part of the dylib size budget, so they are reported separately rather
    # than folded into a number that docs/design/native-build.md fixes for libraries.
    helpers = []
    for name in args.helper or []:
        path = app / "Contents/MacOS" / name
        if not path.is_file():
            fail(f"{path} is missing; the helper was not embedded")
        found = dylib_architectures(path)
        missing = [arch for arch in archs if arch not in found]
        if missing:
            fail(f"{name} lacks {', '.join(missing)} (found: {' '.join(found) or 'none'})")
        helpers.append(
            {
                "name": name,
                "path": f"Contents/MacOS/{name}",
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
                "architectures": found,
            }
        )

    ca_info = None
    ca_path = app / "Contents/Resources/ssl/cert.pem"
    if ca_path.is_file():
        ca_info = {
            "path": "Contents/Resources/ssl/cert.pem",
            "absolutePath": str(ca_path),
            "source": mode["caBundle"],
            "certificates": ca_path.read_text(errors="replace").count("BEGIN CERTIFICATE"),
            "sha256": sha256_file(ca_path),
        }
    elif mode["caBundle"]:
        fail(f"network mode {args.network!r} packages a CA bundle, but {ca_path} is missing")

    total = sum(entry["bytes"] for entry in libraries)
    budget = args.budget or manifest["sizeBudgetBytesPerArchitecture"] * len(archs)
    document = {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": manifest["platform"],
        "bundle": str(app),
        "architectures": archs,
        "deploymentTarget": manifest["deploymentTarget"],
        "network": {
            "mode": args.network,
            "enabled": args.network != "off",
            "tlsBackend": mode["tlsBackend"],
            "protocols": mode["protocols"],
        },
        "caBundle": ca_info,
        "libraries": libraries,
        "helpers": helpers,
        "rpath": "@executable_path/../Frameworks",
        "sizeTotalBytes": total,
        "sizeBudgetBytes": budget,
        "sizeBudgetExceeded": total > budget,
        "helpersSizeTotalBytes": sum(entry["bytes"] for entry in helpers),
    }
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    mib = 1024 * 1024
    print(
        f"app bundle: {len(libraries)} libraries, {total / mib:.1f} MiB "
        f"of a {budget / mib:.0f} MiB budget for {'+'.join(archs)}"
    )
    for entry in libraries:
        print(f"  {entry['bytes']:>10}  {entry['name']}")
    for entry in helpers:
        print(
            f"  {entry['bytes']:>10}  {entry['path']} "
            f"({' '.join(entry['architectures'])})"
        )
    if ca_info is not None:
        print(f"  {ca_info['certificates']:>10}  CA certificates (Contents/Resources/ssl/cert.pem)")
    if document["sizeBudgetExceeded"]:
        print(
            "  WARNING: over the docs/design/native-build.md review threshold; record a component/size report "
            "and update the budget instead of dropping codecs",
            file=sys.stderr,
        )
    return 0


def cmd_write_build_manifest(args):
    manifest = load()
    sections = components()
    prefix = Path(args.prefix)
    mode = mode_config(manifest, args.network)
    ca_path = prefix / "ssl/cert.pem"
    ca_info = None
    if ca_path.is_file():
        text = ca_path.read_text(errors="replace")
        ca_info = {
            "path": display_path(ca_path),
            "source": mode["caBundle"],
            "certificates": text.count("BEGIN CERTIFICATE"),
            "sha256": sha256_file(ca_path),
        }
    configure_args = []
    if args.configure_args_file:
        configure_args = [
            line.strip()
            for line in Path(args.configure_args_file).read_text().splitlines()
            if line.strip()
        ]
    size_entries = []
    seen = set()
    for path in sorted((prefix / "lib").glob("*.dylib")):
        real = path.resolve()
        if real in seen:
            continue
        seen.add(real)
        size_entries.append(
            {"name": path.name, "bytes": real.stat().st_size, "sha256": sha256_file(real)}
        )
    for extra in args.extra_artifact or []:
        extra_path = Path(extra)
        if extra_path.is_file():
            size_entries.append(
                {
                    "name": extra_path.name,
                    "bytes": extra_path.stat().st_size,
                    "sha256": sha256_file(extra_path),
                }
            )
    total = sum(entry["bytes"] for entry in size_entries)
    licenses = sorted(display_path(path) for path in (prefix / "licenses").glob("*"))
    document = {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": manifest["platform"],
        "arch": args.arch,
        "deploymentTarget": manifest["deploymentTarget"],
        "network": {
            "mode": args.network,
            "enabled": args.network != "off",
            "tlsBackend": mode["tlsBackend"],
            "protocols": mode["protocols"],
        },
        "toolchain": toolchain_versions(),
        "sources": {
            name: {
                key: value
                for key, value in entry.items()
                if key in ("version", "sha256", "commit", "license", "linkage", "urls")
            }
            for name, entry in manifest["sources"].items()
        },
        "components": {kind: names for kind, names in sections.items()},
        "ffmpegConfigureArgs": configure_args,
        "ffmpegConfigureLine": " ".join(configure_args),
        "caBundle": ca_info,
        "artifacts": size_entries,
        "sizeBudgetBytes": manifest["sizeBudgetBytesPerArchitecture"],
        "sizeTotalBytes": total,
        "sizeBudgetExceeded": total > manifest["sizeBudgetBytesPerArchitecture"],
        "licenses": licenses,
        "deviations": args.deviation or [],
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out}")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    platform_field = sub.add_parser("platform-field")
    platform_field.add_argument("platform", choices=["macos", "windows", "android", "ios", "linux"])
    platform_field.add_argument("field")
    platform_field.set_defaults(func=cmd_platform_field)

    field = sub.add_parser("field")
    field.add_argument("path")
    field.set_defaults(func=cmd_field)

    source_field = sub.add_parser("source-field")
    source_field.add_argument("source")
    source_field.add_argument("field")
    source_field.set_defaults(func=cmd_source_field)

    sub.add_parser("source-list").set_defaults(func=cmd_source_list)

    tool_field = sub.add_parser("tool-field")
    tool_field.add_argument("tool")
    tool_field.add_argument("field")
    tool_field.set_defaults(func=cmd_tool_field)

    sub.add_parser("tool-list").set_defaults(func=cmd_tool_list)
    sub.add_parser("network-modes").set_defaults(func=cmd_network_modes)
    sub.add_parser("architectures").set_defaults(func=cmd_architectures)

    fixup = sub.add_parser("fixup-plan")
    fixup.add_argument("--prefix", required=True)
    fixup.set_defaults(func=cmd_fixup_plan)

    protocols = sub.add_parser("protocols")
    protocols.add_argument("--network", required=True)
    protocols.set_defaults(func=cmd_protocols)

    ca_bundle = sub.add_parser("ca-bundle")
    ca_bundle.add_argument("--network", required=True)
    ca_bundle.set_defaults(func=cmd_ca_bundle)

    configure = sub.add_parser("ffmpeg-configure-args")
    configure.add_argument("--arch", required=True)
    configure.add_argument("--prefix", required=True)
    configure.add_argument("--deployment-target", required=True)
    configure.add_argument("--network", required=True)
    configure.add_argument("--install-name-dir", default="1")
    configure.add_argument("--cross", default="0")
    configure.add_argument("--with-soxr", default="1")
    configure.set_defaults(func=cmd_ffmpeg_configure_args)

    validate = sub.add_parser("validate-components")
    validate.add_argument("--kind", required=True)
    validate.add_argument("--available", required=True)
    validate.add_argument("--network", required=True)
    validate.set_defaults(func=cmd_validate_components)

    check = sub.add_parser("check")
    check.add_argument("--allow-unpinned", action="store_true")
    check.set_defaults(func=cmd_check)

    checksums = sub.add_parser("print-checksums")
    checksums.add_argument("--dir", required=True)
    checksums.set_defaults(func=cmd_print_checksums)

    size = sub.add_parser("size-report")
    size.add_argument("--prefix", required=True)
    size.add_argument("--budget", type=int, required=True)
    size.add_argument("--extra-artifact", action="append")
    size.add_argument("--json", action="store_true")
    size.set_defaults(func=cmd_size_report)

    bundle_report = sub.add_parser("app-bundle-report")
    bundle_report.add_argument("--app", required=True)
    bundle_report.add_argument("--archs", required=True)
    bundle_report.add_argument("--network", required=True)
    bundle_report.add_argument("--budget", type=int, default=0)
    bundle_report.add_argument(
        "--helper",
        action="append",
        help="Executable under Contents/MacOS the bundle must carry",
    )
    bundle_report.add_argument("--out")
    bundle_report.set_defaults(func=cmd_app_bundle_report)

    write = sub.add_parser("write-build-manifest")
    write.add_argument("--prefix", required=True)
    write.add_argument("--arch", required=True)
    write.add_argument("--network", required=True)
    write.add_argument("--out", required=True)
    write.add_argument("--configure-args-file")
    write.add_argument("--extra-artifact", action="append")
    write.add_argument("--deviation", action="append")
    write.set_defaults(func=cmd_write_build_manifest)

    return parser


def main():
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
