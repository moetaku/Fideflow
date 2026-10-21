#!/usr/bin/env python3
"""Dependency and wire-fixture gate, using only the Python standard library."""

import json
import os
import re
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEDIA = json.loads((ROOT / "schemas/media-control.v1.schema.json").read_text())
EXAMPLES = json.loads((ROOT / "schemas/media-control.v1.examples.json").read_text())
PROVIDER = json.loads((ROOT / "schemas/provider-service.v1.schema.json").read_text())


def validate(value, rule, root, location="$" ):
    if "$ref" in rule:
        path = rule["$ref"].removeprefix("#/").split("/")
        target = root
        for segment in path:
            target = target[segment]
        return validate(value, target, root, location)
    if "anyOf" in rule:
        errors = []
        for branch in rule["anyOf"]:
            try:
                validate(value, branch, root, location)
                return
            except AssertionError as error:
                errors.append(str(error))
        raise AssertionError(f"{location}: no anyOf branch matched: {errors}")
    for branch in rule.get("allOf", []):
        validate(value, branch, root, location)
    if "if" in rule:
        try:
            validate(value, rule["if"], root, location)
        except AssertionError:
            pass
        else:
            validate(value, rule["then"], root, location)
    if "const" in rule:
        assert value == rule["const"], f"{location}: expected {rule['const']}"
    if "enum" in rule:
        assert value in rule["enum"], f"{location}: unknown enum value {value}"
    if "type" in rule:
        types = rule["type"] if isinstance(rule["type"], list) else [rule["type"]]
        matching = {
            "object": lambda: isinstance(value, dict),
            "array": lambda: isinstance(value, list),
            "string": lambda: isinstance(value, str),
            "boolean": lambda: type(value) is bool,
            "number": lambda: type(value) in (int, float),
            "integer": lambda: type(value) is int,
            "null": lambda: value is None,
        }
        assert any(matching[k]() for k in types), f"{location}: wrong type"
    if isinstance(value, str):
        if "minLength" in rule:
            assert len(value) >= rule["minLength"], f"{location}: too short"
        if "maxLength" in rule:
            assert len(value) <= rule["maxLength"], f"{location}: too long"
        if "pattern" in rule:
            assert re.fullmatch(rule["pattern"], value), f"{location}: invalid format"
    if isinstance(value, dict):
        if "maxProperties" in rule:
            assert len(value) <= rule["maxProperties"], f"{location}: too many properties"
        for key in rule.get("required", []):
            assert key in value, f"{location}: missing {key}"
        for key, item in value.items():
            child = rule.get("properties", {}).get(key)
            if child is None:
                child = rule.get("additionalProperties", True)
                assert child is not False, f"{location}: unknown {key}"
            if isinstance(child, dict):
                validate(item, child, root, f"{location}.{key}")
    if isinstance(value, list):
        if "minItems" in rule:
            assert len(value) >= rule["minItems"], f"{location}: too few items"
        if "maxItems" in rule:
            assert len(value) <= rule["maxItems"], f"{location}: too many items"
        if rule.get("uniqueItems"):
            assert len({json.dumps(item, sort_keys=True) for item in value}) == len(value)
        for index, item in enumerate(value):
            validate(item, rule["items"], root, f"{location}[{index}]")


for kind, example in EXAMPLES.items():
    if kind == "commands":
        # One fixture per command kind, all validated against the shared `command`
        # definition, so a payload shape cannot drift from its fixture.
        for name, command in example.items():
            validate(command, MEDIA["$defs"]["command"], MEDIA, f"commands.{name}")
        continue
    assert kind in MEDIA["$defs"]
    validate(example, MEDIA["$defs"][kind], MEDIA, kind)
invalid = dict(EXAMPLES["command"])
invalid["payload"] = {"items": [], "startItemId": "item-1", "autoplay": True}
try:
    validate(invalid, MEDIA["$defs"]["command"], MEDIA)
except AssertionError:
    pass
else:
    raise AssertionError("Invalid empty queue unexpectedly matched the command schema")
assert MEDIA["$defs"]["command"]["properties"]["schemaVersion"]["const"] == 1
assert PROVIDER["properties"]["protocolVersion"]["const"] == 1
# The queue is rendered from the session's own order (docs/design/boundaries.md): a snapshot that
# could omit `mode` or `effectiveOrder` would force every client to re-derive
# shuffle locally, which is exactly what the single-owner rule forbids.
assert {"mode", "effectiveOrder"} <= set(MEDIA["$defs"]["snapshot"]["required"])
assert MEDIA["$defs"]["snapshot"]["properties"]["effectiveOrder"]["items"]["$ref"].endswith(
    "id"
)
for kind in ("setMode", "playItem", "setVolume", "editQueue", "intelligence"):
    assert kind in EXAMPLES["commands"], kind
    assert EXAMPLES["commands"][kind]["kind"] == kind, kind
# `editQueue` addresses an entry by identity so a duplicated track can be removed
# one entry at a time, and only `playNext`/`append` carry new items.
remove_without_target = dict(EXAMPLES["commands"]["editQueue"])
remove_without_target["payload"] = {"operation": "remove"}
try:
    validate(remove_without_target, MEDIA["$defs"]["command"], MEDIA)
except AssertionError:
    pass
else:
    raise AssertionError("editQueue remove without targetQueueItemId unexpectedly matched")
insert_without_items = dict(EXAMPLES["commands"]["editQueue"])
insert_without_items["payload"] = {"operation": "playNext"}
try:
    validate(insert_without_items, MEDIA["$defs"]["command"], MEDIA)
except AssertionError:
    pass
else:
    raise AssertionError("editQueue playNext without items unexpectedly matched")
# A seeded load is reproducible (docs/design/playback.md): the seed decides both the shuffle
# order and the track it opens on, so a restore replays the same first song.
# `startItemId` stays required because every non-seeded load starts on a name.
load_queue = MEDIA["$defs"]["loadQueuePayload"]
assert "seed" in load_queue["properties"], "a shuffle load must be seedable"
assert load_queue["properties"]["seed"]["$ref"].endswith("uint64")
assert {"items", "startItemId", "autoplay"} <= set(load_queue["required"])
seeded = dict(EXAMPLES["command"])
seeded["payload"] = dict(seeded["payload"], seed="42")
validate(seeded, MEDIA["$defs"]["command"], MEDIA)
non_decimal_seed = dict(seeded)
non_decimal_seed["payload"] = dict(seeded["payload"], seed=42)
try:
    validate(non_decimal_seed, MEDIA["$defs"]["command"], MEDIA)
except AssertionError:
    pass
else:
    raise AssertionError("an integer seed unexpectedly matched the uint64 rule")
# A queue a client did not load is still renderable: the snapshot publishes every
# item's identity in the queue's own load order, which is what a session-side
# restore needs, and never a source (docs/design/restore.md).
assert "queueItems" in MEDIA["$defs"]["snapshot"]["required"]
identity = MEDIA["$defs"]["queueIdentity"]
assert identity["additionalProperties"] is False
assert identity["required"] == ["queueItemId", "trackId"]
queue_items_rule = MEDIA["$defs"]["snapshot"]["properties"]["queueItems"]
assert queue_items_rule["items"]["$ref"] == "#/$defs/queueIdentity"
assert "sourceUri" not in identity["properties"], "a snapshot must not publish a source"

# The order's provenance is published rather than left for a client to guess:
# an optional seed would let a session hide the permutation it is walking.
assert "shuffleSeed" in MEDIA["$defs"]["snapshot"]["required"]
seed_rule = MEDIA["$defs"]["snapshot"]["properties"]["shuffleSeed"]["anyOf"]
assert [branch.get("$ref") or branch.get("type") for branch in seed_rule] == [
    "#/$defs/uint64",
    "null",
], seed_rule

# Volume crosses as an integer permille, not a float, and the session owns it:
# a snapshot without it would let a client guess its own gain (docs/design/boundaries.md).
assert "volume" in MEDIA["$defs"]["snapshot"]["required"]
volume = MEDIA["$defs"]["snapshot"]["properties"]["volume"]
assert volume["type"] == "integer" and volume["minimum"] == 0 and volume["maximum"] == 1000

dart_codes = (ROOT / "packages/media_sdk/lib/src/wire_codes.dart").read_text()
assert "const mediaSchemaVersion = 1;" in dart_codes
for enum_name, schema_codes in (
    ("WireCommandKind", MEDIA["$defs"]["command"]["properties"]["kind"]["enum"]),
    ("WirePhase", MEDIA["$defs"]["snapshot"]["properties"]["phase"]["enum"]),
    ("WireOperationStatus", MEDIA["$defs"]["operation"]["properties"]["status"]["enum"]),
    ("WirePlaybackMode", MEDIA["$defs"]["playbackMode"]["enum"]),
):
    body = re.search(rf"enum {enum_name} \{{(.*?);", dart_codes, re.S)
    assert body, enum_name
    actual = re.findall(r"\b\w+\('([^']+)'\)", body.group(1))
    assert actual == schema_codes, (enum_name, actual, schema_codes)

header = (ROOT / "schemas/media_core.h").read_text()
rust = (ROOT / "native/media_core/crates/media-ffi/src/lib.rs").read_text()
assert "#define FF_MEDIA_CORE_ABI_VERSION 3u" in header
assert "pub const ABI_VERSION: u32 = 3;" in rust
abi_probe = (ROOT / "tooling/native/checks/abi_probe.c").read_text()
assert r'\"abiVersion\":3' in abi_probe
windows_probe = (ROOT / "tooling/native/checks/windows_runtime_probe.py").read_text()
assert "library.ff_media_core_abi_version() == 3" in windows_probe
play_example = (ROOT / "native/media_core/crates/media-ffi/examples/play_file.rs").read_text()
assert "abi_version != 3" in play_example

# Both hosts that load the library carry their own copy of the version they
# accept; a mismatch makes a freshly built library unusable (issue 1). Keep them
# pinned to the header and the Rust constant above.
dart_ffi = (ROOT / "packages/media_host/lib/src/media_core_ffi.dart").read_text()
assert "const supportedAbiVersion = 3;" in dart_ffi, "the Dart host must speak ABI 3"
macos_runner = (ROOT / "apps/fideflow_flutter/macos/Runner/NativeLibraries.swift").read_text()
assert "static let supportedAbiVersion: UInt32 = 3" in macos_runner, (
    "the macOS loader must speak ABI 3"
)

# Result codes, argument limits and the byte-buffer layout are one contract: a
# host compiles against the header and links the library, so a mismatch is a
# memory-safety bug rather than a cosmetic drift.
for code, value in re.findall(r"#define (FF_MEDIA_(?:OK|ERR_\w+)) (\d+)u", header):
    name = "FF_MEDIA_OK" if code == "FF_MEDIA_OK" else code
    assert f"pub const {name}: u32 = {value};" in rust, (code, value)
assert len(re.findall(r"#define FF_MEDIA_ERR_\w+ \d+u", header)) == 6
for macro, rust_const in (
    ("FF_MEDIA_MAX_COMMAND_BYTES", "MAX_COMMAND_BYTES: usize = 1 << 20"),
    ("FF_MEDIA_MAX_ID_BYTES", "MAX_ID_BYTES: usize = 128"),
):
    assert f"#define {macro} " in header, macro
    assert rust_const in rust, (macro, rust_const)
# `ff_owned_bytes` is { data, len }: data first, then the length the ABI passes to
# ff_owned_bytes_free.
assert re.search(
    r"typedef struct ff_owned_bytes \{\s*uint8_t \*data;\s*size_t len;\s*\}", header
), "the C byte buffer must be { data, len }"
assert re.search(r"pub struct FfOwnedBytes \{.*?pub data: \*mut u8,.*?pub len: usize,", rust, re.S), (
    "the Rust byte buffer must mirror the C layout"
)
assert "pub type FfEventSink" in rust and "ff_event_sink_t" in header
rust_session = (ROOT / "native/media_core/crates/media-session/src/lib.rs").read_text()
header_states = dict(re.findall(r"FF_PLAYBACK_(\w+)\s*=\s*(\d+)", header))
rust_states = dict(
    (name.upper(), value)
    for name, value in re.findall(
        r"\b(Idle|Ready|Playing|Paused|Error)\s*=\s*(\d+)",
        rust_session,
    )
)
assert header_states == rust_states, (header_states, rust_states)
# Playback modes cross the wire as codes the schema names; the Rust session and
# the Dart wire enum must both agree with it, or a mode the UI offers would be
# rejected by the library that received it.
rust_plan = (ROOT / "native/media_core/crates/media-session/src/plan.rs").read_text()
rust_modes = re.findall(r'"(listLoop|repeatOne|shuffle|sequential)"', (ROOT / "native/media_core/crates/media-session/src/core.rs").read_text())
assert rust_modes, "the planner must name the playback modes"
assert set(rust_modes) == set(MEDIA["$defs"]["playbackMode"]["enum"]), rust_modes

# The session is the single writer of the record, so writing it, reading it back
# and the ABI that owns both must all name the same file: one place builds
# `playback-<account>.json` (docs/design/restore.md).
checkpoint_rust = (
    ROOT / "native/media_core/crates/media-session/src/checkpoint.rs"
).read_text()
assert "pub fn read(" in checkpoint_rust, "the session must read back what it wrote"
assert 'format!("playback-{}.json", safe_account(account))' in checkpoint_rust
assert "pub fn plan_restore(" in rust_plan
assert "pub fn restore_checkpoint(" in rust_session
assert "pub fn configure_checkpoint(" in rust_session

# Every declared entry point must exist in both files: the Phase 1 ABI is the
# byte transport Dart and the macOS host call, so a header-only symbol is a link
# error waiting for a user.
for symbol in (
    "ff_media_core_abi_version",
    "ff_media_core_capabilities_json",
    "ff_owned_bytes_free",
    "ff_player_new",
    "ff_player_free",
    "ff_player_set_event_sink",
    "ff_player_state",
    "ff_player_attach",
    "ff_player_detach",
    "ff_player_snapshot",
    "ff_player_diagnostics",
    "ff_player_execute",
    "ff_player_configure_checkpoint",
    "ff_player_restore_checkpoint",
    "ff_player_delete_checkpoint",
    "ff_player_flush_checkpoint",
):
    assert symbol in header and f"fn {symbol}" in rust, symbol

# The shipped artifact is libff_media_core.dylib: the linker argument, the file
# name embed.sh packages and the name the Dart host looks up must agree.
ffi_manifest = (ROOT / "native/media_core/crates/media-ffi/Cargo.toml").read_text()
ffi_build = (ROOT / "native/media_core/crates/media-ffi/build.rs").read_text()
assert 'name = "ff_media_core"' in ffi_manifest, "the cdylib name is the packaged file name"
assert 'LIB_NAME: &str = "libff_media_core.dylib"' in ffi_build
assert "-Wl,-install_name,@rpath/{LIB_NAME}" in ffi_build, (
    "the cdylib must carry an @rpath install name, not a build-tree path"
)

xcode = (ROOT / "apps/fideflow_flutter/macos/Runner.xcodeproj/project.pbxproj").read_text()
targets = re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([^;]+);", xcode)
assert targets and set(targets) == {"12.0"}, targets

for path in (ROOT / "apps/fideflow_flutter/lib/features").rglob("*.dart"):
    source = path.read_text()
    assert "fideflow_ncm_gateway" not in source, path
    assert "dart:convert" not in source and "jsonDecode" not in source, path
for path in (ROOT / "packages/application/lib").rglob("*.dart"):
    source = path.read_text()
    assert "fideflow_ncm_gateway" not in source and "dart:convert" not in source, path
for path in (ROOT / "packages/domain/lib").rglob("*.dart"):
    source = path.read_text()
    assert "package:" not in source, path

# The FFI host is an implementation of the SDK boundary, not a second way to
# reach playback: only the app's composition root may import it, and the stable
# SDK must not depend on the library that happens to be native (docs/design/boundaries.md).
for path in (ROOT / "apps/fideflow_flutter/lib/features").rglob("*.dart"):
    assert "fideflow_media_host" not in path.read_text(), path
media_host_pubspec = (ROOT / "packages/media_host/pubspec.yaml").read_text()
assert "ffi:" in media_host_pubspec, "the host is the only package that speaks dart:ffi"
assert "fideflow_media_sdk" in media_host_pubspec, media_host_pubspec
assert "fideflow_media_host" not in (ROOT / "packages/media_sdk/pubspec.yaml").read_text()
assert "fideflow_media_host" in (ROOT / "apps/fideflow_flutter/pubspec.yaml").read_text()

# Native dependency manifest, component allowlist and design cross-checks (docs/design/native-build.md).
NATIVE = json.loads((ROOT / "tooling/native/sources.manifest.json").read_text())
NATIVE_SECTIONS = {}
for line in (ROOT / "tooling/native/ffmpeg-components.txt").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    kind, names = line.split(":", 1)
    NATIVE_SECTIONS[kind.strip()] = names.split()
assert NATIVE["manifestVersion"] == 1
platform_contracts = runpy.run_path(str(ROOT / "tooling/native/manifest.py"))
assert not platform_contracts["platform_errors"](NATIVE), platform_contracts["platform_errors"](NATIVE)
windows_native = NATIVE["platforms"]["windows"]
for path, symbol, field in (
    ("library_locator.dart", "windowsMediaCoreLibraryName", "libraryName"),
):
    text = (ROOT / "packages/media_host/lib/src" / path).read_text()
    assert f"{symbol} = '{windows_native[field]}';" in text, field
assert NATIVE["platform"] == "macos"
assert NATIVE["deploymentTarget"] == "12.0", NATIVE["deploymentTarget"]
assert NATIVE["architectures"] == ["arm64", "x86_64"], NATIVE["architectures"]
assert NATIVE["sizeBudgetBytesPerArchitecture"] == 40 * 1024 * 1024
assert set(NATIVE_SECTIONS) == {
    "demuxer",
    "decoder",
    "parser",
    "protocol-base",
}, sorted(NATIVE_SECTIONS)
native_sources = NATIVE["sources"]
for name, version in (("ffmpeg", "7.1.5"), ("portaudio", "19.7.0"), ("libsoxr", "0.1.3")):
    assert native_sources[name]["version"] == version, (name, native_sources[name]["version"])
for name, entry in native_sources.items():
    if entry["archiveFormat"] == "files":
        pins = [item for item in entry["files"]]
        assert pins, name
    else:
        pins = [entry]
    for pin in pins:
        label = f"{name}/{pin.get('name', entry.get('downloadName'))}"
        assert re.fullmatch(r"[0-9a-f]{64}", pin["sha256"] or ""), f"unpinned native source {label}"
    assert entry["license"], name
assert NATIVE["defaultNetworkMode"] == "off"
assert set(NATIVE["networkModes"]) == {"off"}
assert NATIVE["platforms"]["windows"]["networkMode"] == "off"
assert set(NATIVE_SECTIONS["protocol-base"]) == {"file", "pipe"}
assert set(NATIVE["networkModes"]["off"]["protocols"]) == {"file", "pipe"}
assert NATIVE["networkModes"]["off"]["tlsBackend"] == "none"
assert not NATIVE["networkModes"]["off"]["requiredSources"]
windows_ffmpeg = (ROOT / "tooling/native/windows/ffmpeg.sh").read_text()
assert "--disable-network" in windows_ffmpeg
assert "--enable-network" not in windows_ffmpeg
assert "--enable-protocol=http" not in windows_ffmpeg
for flag in ("--enable-gpl", "--enable-nonfree", "--enable-version3"):
    assert flag in NATIVE["forbiddenConfigureFlags"], flag
# The repository keeps a single document. Pinned dependency versions stay in
# README.md; the network mode itself is checked against the manifest above.
README = ROOT / "README.md"
native_build_design = README.read_text()
for version in ("7.1.5", "19.7.0", "0.11.25", "0.1.3"):
    assert version in native_build_design, version
build_rs = (ROOT / "native/media_core/crates/media-output/build.rs").read_text()
assert f'PORTAUDIO_VERSION: &str = "{native_sources["portaudio"]["version"]}"' in build_rs
assert os.access(ROOT / "tooling/native/macos/build.sh", os.X_OK)
assert README.is_file(), "the README.md with the merged build guide is missing"
assert not (ROOT / "docs").exists(), "README.md is the only project document"

# Platform bootstraps must keep Flutter and Rust setup aligned. macOS also has
# to work when a GUI-launched terminal has not sourced ~/.cargo/env.
MACOS_BOOTSTRAP = ROOT / "tooling/bootstrap-macos.sh"
WINDOWS_BOOTSTRAP = ROOT / "tooling/bootstrap.ps1"
assert os.access(MACOS_BOOTSTRAP, os.X_OK), MACOS_BOOTSTRAP
macos_bootstrap = MACOS_BOOTSTRAP.read_text()
windows_bootstrap = WINDOWS_BOOTSTRAP.read_text()
for bootstrap in (macos_bootstrap, windows_bootstrap):
    assert "flutter pub get" in bootstrap
    assert "rustfmt clippy" in bootstrap
assert "aarch64-apple-darwin" in macos_bootstrap
assert "x86_64-apple-darwin" in macos_bootstrap
assert ".cargo" in macos_bootstrap and "CARGO_BIN_DIR" in macos_bootstrap
assert "xcode-select --install" in macos_bootstrap
assert "install --cask flutter" in macos_bootstrap
for formula in ("cmake", "nasm", "pkg-config"):
    assert formula in macos_bootstrap
assert "https://sh.rustup.rs" in macos_bootstrap
assert ".cargo/env" in macos_bootstrap
# The macOS script no longer writes shell init itself: it discovers rustup's
# standard install, exports it for its own build steps and tells the user how to
# load it in the parent shell, so the check follows what the script does.
assert 'PATH="$CARGO_BIN_DIR:$PATH"' in macos_bootstrap, (
    "bootstrap must put rustup's bin directory on PATH for its own build steps"
)
assert 'source "$HOME/.cargo/env"' in macos_bootstrap, (
    "bootstrap must say how the current shell gets Cargo"
)
assert "--no-modify-path" not in macos_bootstrap
assert ".cargo" in windows_bootstrap and "$cargoBin" in windows_bootstrap
assert "https://win.rustup.rs/x86_64" in windows_bootstrap
assert "Join-Path $installerDirectory 'rustup-init.exe'" in windows_bootstrap, (
    "rustup dispatches by filename: the downloaded installer must be rustup-init.exe"
)
assert "'fideflow-rustup-init.exe'" not in windows_bootstrap
assert "$env:CARGO_HOME" in windows_bootstrap
assert "function Test-RustDependencies" in windows_bootstrap
assert windows_bootstrap.count("Test-RustDependencies $cargoBin") == 2, (
    "check-only and setup must share Rust validation"
)
assert "--no-modify-path" not in windows_bootstrap

# App-bundle embedding of the native libraries (docs/design/native-build.md). The build phase, the
# Swift bootstrap, the entitlements and the CA bundle location have to stay in
# step with each other: dropping any one of them produces an app that builds and
# then cannot play or cannot verify HTTPS.
EMBED = ROOT / "tooling/native/macos/embed.sh"
assert os.access(EMBED, os.X_OK), EMBED
embed = EMBED.read_text()
assert "Contents/Frameworks" in embed and "@rpath/" in embed
assert 'ca_dest="$app/Contents/Resources/ssl/cert.pem"' in embed, (
    "the CA bundle must be a resource: codesign rejects non-code under Contents/Frameworks"
)
assert "*.dylib" in embed and "codesign --verify" in embed and "--force --sign" in embed
assert "app-bundle-report" in embed and "capcheck" in embed

# The Rust media host (docs/design/boundaries.md) is embedded with the same rules as the third-party
# set: rust.sh builds, flattens and signs it, embed.sh registers and verifies it,
# and the ABI probe loads it from the bundle through @rpath.
RUST_SH = ROOT / "tooling/native/macos/rust.sh"
ABI_PROBE = ROOT / "tooling/native/checks/abi_probe.c"
assert os.access(RUST_SH, os.X_OK), RUST_SH
assert ABI_PROBE.is_file(), ABI_PROBE
rust_sh = RUST_SH.read_text()
assert 'LIB_NAME="libff_media_core.dylib"' in rust_sh
assert "CARGO_BIN_DIR" in rust_sh, "Xcode builds must find a standard rustup install without shell init"
assert "install_name_tool -id" in rust_sh and "codesign --force --sign" in rust_sh
assert "mmacosx-version-min" in rust_sh, "the library must target the deployment minimum"
assert "rust.sh" in embed and "RUST_LIB_NAME=\"libff_media_core.dylib\"" in embed
assert "--allow-missing-rust" in embed and '"$RUST_SH" probe --bundle "$app"' in embed, (
    "embed.sh must probe the packaged media host through the C ABI"
)
assert "media_core.h" in ABI_PROBE.read_text(), "the probe compiles against the shipped header"
assert "libff_media_core.dylib" in ABI_PROBE.read_text()

build_phase_name = "Embed Native Libraries"
assert build_phase_name in xcode, build_phase_name
assert "tooling/native/macos/embed.sh" in xcode, "the build phase does not call embed.sh"
assert xcode.count("A17C0DE1A2B34C5D8E9F0013") == 2, "the embedding phase is not in the Runner target"
assert "NativeLibraries.swift in Sources" in xcode, "NativeLibraries.swift is not compiled"
assert (
    "$(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/Contents/Resources/native-libraries.json" in xcode
), "the embedding phase must declare its outputs, or Xcode may sign the bundle before it runs"
assert (
    "$(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/Contents/Frameworks/libff_media_core.dylib" in xcode
), "the embedded Rust library must be a declared phase output"
assert "--allow-missing-rust" in xcode, "a Debug build may run without a Rust toolchain"
assert "@executable_path/../Frameworks" in xcode, "Runner lost its Frameworks rpath"

bootstrap = (ROOT / "apps/fideflow_flutter/macos/Runner/NativeLibraries.swift").read_text()
assert "Contents/Resources/ssl/cert.pem" in bootstrap
assert 'setenv("SSL_CERT_FILE"' in bootstrap
assert "dlopen" in bootstrap
assert "NativeLibraries.prepare()" in (
    ROOT / "apps/fideflow_flutter/macos/Runner/AppDelegate.swift"
).read_text(), "the launch hook is gone"

for entitlements in ("DebugProfile", "Release"):
    text = (ROOT / f"apps/fideflow_flutter/macos/Runner/{entitlements}.entitlements").read_text()
    assert "com.apple.security.app-sandbox" in text, entitlements
    assert "com.apple.security.network.client" in text, (
        f"{entitlements}.entitlements: the sandbox blocks outbound HTTPS without network.client"
    )

# NCM HTTP gateways remain independent of native host implementation details.
assert "fideflow_media_host" not in (ROOT / "packages/ncm_gateway/pubspec.yaml").read_text()
for path in (ROOT / "packages/ncm_gateway/lib").rglob("*.dart"):
    assert "import 'dart:ffi'" not in path.read_text(), path
assert "--allow-missing-rust" in embed
assert "FF_PROVIDER_MODE" in README.read_text()

# Compressed-input ABI must ship as one contract across host and native code.
for symbol in ("ff_player_input_set_sink", "ff_player_input_register", "ff_player_input_revoke", "ff_player_input_acquire", "ff_input_commit", "ff_input_release"):
    assert symbol in header and f'fn {symbol}(' in rust and symbol in dart_ffi, symbol
assert "ff_input_buffer_t" in header and "pub struct FfInputBuffer" in rust
assert "ffinput://" in (ROOT / "schemas/media-control.v1.schema.json").read_text()

runpy.run_path(str(ROOT / "tooling/check_architecture.py"), run_name="__main__")

# NCM Host is additive to ABI 3. Both the transport and SDK route table are
# independent from the generic player/session protocol.
host_ffi = (ROOT / "native/media_core/crates/media-ffi/src/ncm_host.rs").read_text()
for symbol in ("ff_ncm_host_new", "ff_ncm_host_submit", "ff_ncm_host_cancel",
               "ff_ncm_host_set_event_sink", "ff_ncm_host_deliveries", "ff_ncm_host_free"):
    assert symbol in header and f"fn {symbol}(" in host_ffi and symbol in dart_ffi, symbol
host_schema = json.loads((ROOT / "schemas/ncm-host.v1.schema.json").read_text())
assert host_schema["$defs"]["request"]["properties"]["budgetMs"]["maximum"] == 15000
assert host_schema["$defs"]["request"]["properties"]["maxResponseBytes"]["maximum"] == 16 * 1024 * 1024
host_pin = json.loads((ROOT / "native/media_core/crates/ncm-api-compat/UPSTREAM.json").read_text())
assert json.loads((ROOT / "tooling/native/sources.manifest.json").read_text())["linkedSdks"]["ncmHost"]["upstreamSha256"] == host_pin["sha256"]
native_manifest = runpy.run_path(str(ROOT / "tooling/native/manifest.py"))
assert native_manifest["vendored_tree_sha256"](ROOT / host_pin["vendorPath"]) == host_pin["treeSha256"], "vendored SDK must match the recorded distribution tree"
print("NCM Host optional ABI and SDK pin OK")
