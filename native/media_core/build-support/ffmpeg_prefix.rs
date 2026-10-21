//! Shared build-script helper for crates that link pinned platform `FFmpeg`.
//!
//! `media-pipeline` compiles the C shim and links the libraries; `media-ffi`
//! links the result into the host dylib and needs the same prefix so its test and
//! example binaries can resolve `@rpath` at run time. One rule lives here so the
//! two build scripts cannot disagree about which prefix is current.
//!
//! Include it with:
//!
//! ```ignore
//! #[path = "../../build-support/ffmpeg_prefix.rs"]
//! mod ffmpeg_prefix;
//! ```

use std::env;
use std::path::PathBuf;

/// Explicit override, matching the variable `build.sh env` exports.
pub const PREFIX_ENV: &str = "FF_NATIVE_PREFIX";
/// Must match `tooling/native/sources.manifest.json`; checked by `manifest.py check`.
#[allow(dead_code, reason = "used by the build scripts that link FFmpeg")]
pub const DEPLOYMENT_TARGET: &str = "12.0";
/// cfg set when the pinned libraries are linked into this build.
#[allow(dead_code, reason = "used by the build scripts that link FFmpeg")]
pub const AVAILABLE_CFG: &str = "ff_ffmpeg_available";
/// Library that proves a prefix is the pinned `FFmpeg` build.
pub const REQUIRED_LIBRARY: &str = "lib/libavformat.dylib";

/// Maps a rustc target architecture to the `-arch` name clang expects.
#[must_use]
pub fn clang_arch(target_arch: &str) -> &str {
    match target_arch {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => other,
    }
}

/// Repository root, derived from the including crate (`native/media_core/crates/<crate>`).
fn repo_root() -> PathBuf {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR");
    let manifest_dir = PathBuf::from(manifest_dir);
    manifest_dir
        .join("../../..")
        .canonicalize()
        .unwrap_or(manifest_dir)
}

/// The install prefix built by `tooling/native/macos/build.sh` for this target.
#[must_use]
pub fn native_prefix() -> Option<PathBuf> {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let windows = target_os == "windows";
    let linux = target_os == "linux";
    let required = if windows {
        "lib/avformat.lib"
    } else if linux {
        "lib/libavformat.so"
    } else {
        REQUIRED_LIBRARY
    };
    if let Ok(explicit) = env::var(PREFIX_ENV) {
        let path = PathBuf::from(explicit);
        if path.join(required).is_file() {
            return Some(path);
        }
        println!("cargo:warning={PREFIX_ENV} does not contain {required}; ignoring it");
    }
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let directory_arch = if linux {
        target_arch.as_str()
    } else {
        clang_arch(&target_arch)
    };
    let candidate = repo_root()
        .join(if windows {
            "build/third_party/windows"
        } else if linux {
            "build/third_party/linux"
        } else {
            "build/third_party/macos"
        })
        .join(directory_arch);
    candidate.join(required).is_file().then_some(candidate)
}
