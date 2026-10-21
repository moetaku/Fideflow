//! Compiles the `FFmpeg` shim and links the pinned macOS libraries (docs/design/native-build.md).
//!
//! `FFmpeg`'s structs stay inside `c/ff_ffmpeg_shim.c`, the same rule
//! `media-output` applies to `PortAudio`, so Rust only exchanges scalars, byte
//! buffers and opaque pointers. The libraries come from the prefix that
//! `tooling/native/macos/build.sh` built; without it the crate still compiles and
//! reports the pipeline as unavailable, which keeps `cargo test` working on a
//! fresh checkout.

#[path = "../../build-support/ffmpeg_prefix.rs"]
mod ffmpeg_prefix;

use ffmpeg_prefix::{AVAILABLE_CFG, DEPLOYMENT_TARGET, PREFIX_ENV, clang_arch, native_prefix};
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Component libraries, in dependency order. Pinned by the native manifest.
const FFMPEG_LIBRARIES: [&str; 4] = ["avformat", "avcodec", "avutil", "swresample"];
const PKG_CONFIG_MODULES: [&str; 4] = ["libavformat", "libavcodec", "libavutil", "libswresample"];

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=c/ff_ffmpeg_shim.c");
    println!("cargo:rerun-if-env-changed={PREFIX_ENV}");
    println!("cargo:rerun-if-env-changed=FF_ALLOW_MISSING_NATIVE");
    println!("cargo:rustc-check-cfg=cfg({AVAILABLE_CFG})");

    if matches!(
        env::var("CARGO_CFG_TARGET_OS").as_deref(),
        Ok("android" | "ios")
    ) {
        build_mobile();
        return;
    }
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        build_windows();
        return;
    }
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        build_linux();
        return;
    }
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        println!(
            "cargo:warning=fideflow-media-pipeline links the pinned macOS FFmpeg only; \
             the pipeline stays unavailable on this target"
        );
        return;
    }

    build_macos();
}

fn build_macos() {
    let Some(prefix) = native_prefix() else {
        println!(
            "cargo:warning=the pinned FFmpeg prefix is missing; run \
             `tooling/native/macos/build.sh build` or set {PREFIX_ENV}. \
             The pipeline stays unavailable."
        );
        return;
    };

    // pkg-config is only used to discover include and library locations inside
    // our own prefix: PKG_CONFIG_LIBDIR is pinned so a Homebrew FFmpeg can never
    // be picked up (docs/design/native-build.md).
    let library_dir = prefix.join("lib");
    let include_dir = prefix.join("include");
    let mut include_dirs = vec![include_dir.to_string_lossy().into_owned()];
    if let Some((cflags, libs)) = pkg_config_flags(&prefix) {
        include_dirs.extend(flag_values(&cflags, "-I"));
        for directory in flag_values(&libs, "-L") {
            println!("cargo:rustc-link-search=native={directory}");
        }
        for library in flag_values(&libs, "-l") {
            println!("cargo:rustc-link-lib=dylib={library}");
        }
    } else {
        println!(
            "cargo:warning=pkg-config could not resolve the FFmpeg prefix at {}; \
             falling back to its include and lib directories",
            prefix.display()
        );
        for library in FFMPEG_LIBRARIES {
            println!("cargo:rustc-link-lib=dylib={library}");
        }
    }
    println!("cargo:rustc-link-search=native={}", library_dir.display());

    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let arch = clang_arch(&target_arch).to_owned();
    let compiler = env::var("CC").unwrap_or_else(|_| String::from("clang"));
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    let object = out_dir.join("ff_ffmpeg_shim.o");

    let mut command = Command::new(&compiler);
    command.args([
        "-c",
        "c/ff_ffmpeg_shim.c",
        "-o",
        &object.to_string_lossy(),
        "-arch",
        &arch,
        &format!("-mmacosx-version-min={DEPLOYMENT_TARGET}"),
        "-O2",
        "-DNDEBUG",
        "-fPIC",
        "-Wall",
        "-Wextra",
    ]);
    for directory in &include_dirs {
        command.args(["-I", directory]);
    }
    let status = command
        .status()
        .unwrap_or_else(|error| panic!("failed to run {compiler}: {error}"));
    assert!(
        status.success(),
        "{compiler} failed to compile the FFmpeg shim"
    );

    // Archive the object so `rustc-link-lib=static` can consume it.
    let archive = out_dir.join("libff_ffmpeg_shim.a");
    let _ = std::fs::remove_file(&archive);
    let archiver = env::var("AR").unwrap_or_else(|_| String::from("ar"));
    let status = Command::new(&archiver)
        .args(["crs", &archive.to_string_lossy(), &object.to_string_lossy()])
        .status()
        .unwrap_or_else(|error| panic!("failed to run {archiver}: {error}"));
    assert!(
        status.success(),
        "{archiver} failed to create the FFmpeg shim archive"
    );

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=ff_ffmpeg_shim");

    // The host dylib resolves its FFmpeg dependencies through the app bundle,
    // where every library is a sibling; test and example binaries instead resolve
    // them from the build prefix. Neither target gets the other's rpath, so a
    // shipped library never carries a path into a developer's build tree.
    //
    // `rustc-link-arg` is the only key that reaches both a lib's unit-test harness
    // and its `tests/` and `examples/` binaries, and it applies to this crate's own
    // link steps only, so a dependent like `media-ffi` stays path-clean.
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", library_dir.display());
    println!("cargo:rustc-cfg={AVAILABLE_CFG}");
}

fn build_linux() {
    let Some(prefix) = native_prefix() else {
        missing_prefix("Linux");
        return;
    };
    for library in [
        "libavformat.so",
        "libavcodec.so",
        "libavutil.so",
        "libswresample.so",
        "libsoxr.so",
    ] {
        assert!(
            prefix.join("lib").join(library).exists(),
            "Linux native prefix is incomplete: missing {}",
            prefix.join("lib").join(library).display()
        );
    }
    let library_dir = prefix.join("lib");
    let include_dir = prefix.join("include");
    println!(
        "cargo:rerun-if-changed={}",
        include_dir.join("libavformat/avformat.h").display()
    );
    println!("cargo:rustc-link-search=native={}", library_dir.display());

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    let object = out_dir.join("ff_ffmpeg_shim.o");
    let compiler = env::var("CC").unwrap_or_else(|_| String::from("cc"));
    let status = Command::new(&compiler)
        .args(["-c", "c/ff_ffmpeg_shim.c", "-o"])
        .arg(&object)
        .args(["-O2", "-DNDEBUG", "-fPIC", "-Wall", "-Wextra", "-std=c11"])
        .arg("-I")
        .arg(&include_dir)
        .status()
        .unwrap_or_else(|error| panic!("failed to run {compiler}: {error}"));
    assert!(
        status.success(),
        "{compiler} failed to compile the FFmpeg shim"
    );
    let archive = out_dir.join("libff_ffmpeg_shim.a");
    let _ = std::fs::remove_file(&archive);
    let archiver = env::var("AR").unwrap_or_else(|_| String::from("ar"));
    let status = Command::new(&archiver)
        .args(["crs"])
        .arg(&archive)
        .arg(&object)
        .status()
        .unwrap_or_else(|error| panic!("failed to run {archiver}: {error}"));
    assert!(
        status.success(),
        "{archiver} failed to archive the FFmpeg shim"
    );
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    // GNU ld resolves archives left to right with --as-needed. Keep the shim
    // before its shared-library dependencies so their symbols remain linked.
    println!("cargo:rustc-link-lib=static=ff_ffmpeg_shim");
    for library in ["avformat", "avcodec", "swresample", "avutil", "soxr"] {
        println!("cargo:rustc-link-lib=dylib={library}");
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", library_dir.display());
    println!("cargo:rustc-cfg={AVAILABLE_CFG}");
}

fn missing_prefix(platform: &str) {
    let profile = env::var("PROFILE").unwrap_or_default();
    let development_skip =
        profile == "debug" && env::var("FF_ALLOW_MISSING_NATIVE").as_deref() == Ok("1");
    if development_skip {
        println!(
            "cargo:warning={platform} FFmpeg prefix missing; explicitly allowing a debug build without the native pipeline"
        );
    } else {
        panic!(
            "{platform} FFmpeg prefix is missing; run tooling/native/linux/build.sh all (debug-only UI builds may set FF_ALLOW_MISSING_NATIVE=1)"
        );
    }
}

fn build_windows() {
    let Some(prefix) = native_prefix() else {
        println!(
            "cargo:warning=Windows FFmpeg prefix missing; run tooling/native/windows/build.ps1"
        );
        return;
    };
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo OUT_DIR"));
    let object = out.join("ff_ffmpeg_shim.obj");
    let archive = out.join("ff_ffmpeg_shim.lib");
    let status = Command::new("cl")
        .args(["/nologo", "/c", "/O2", "/MD", "/std:c11", "/utf-8"])
        .arg(format!("/I{}", prefix.join("include").display()))
        .arg(format!("/Fo{}", object.display()))
        .arg("c/ff_ffmpeg_shim.c")
        .status()
        .expect("MSVC cl; initialize VsDevCmd first");
    assert!(status.success(), "FFmpeg shim compilation failed");
    assert!(
        Command::new("lib")
            .arg("/nologo")
            .arg(format!("/OUT:{}", archive.display()))
            .arg(object)
            .status()
            .expect("MSVC librarian")
            .success()
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    println!("cargo:rustc-link-lib=static=ff_ffmpeg_shim");
    for library in FFMPEG_LIBRARIES {
        println!("cargo:rustc-link-lib=dylib={library}");
    }
    println!("cargo:rustc-cfg={AVAILABLE_CFG}");
}

/// Runs pkg-config inside the pinned prefix and returns its cflags and libs.
fn pkg_config_flags(prefix: &Path) -> Option<(String, String)> {
    let pkgconfig_dir = prefix.join("lib/pkgconfig");
    let query = |flag: &str| -> Option<String> {
        let output = Command::new("pkg-config")
            .arg(flag)
            .args(PKG_CONFIG_MODULES)
            .env("PKG_CONFIG_LIBDIR", &pkgconfig_dir)
            .env("PKG_CONFIG_PATH", "")
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    };
    Some((query("--cflags")?, query("--libs")?))
}

/// Extracts the values of one flag prefix (`-I`, `-L`, `-l`) from a flag string.
fn flag_values(flags: &str, prefix: &str) -> Vec<String> {
    flags
        .split_whitespace()
        .filter_map(|flag| flag.strip_prefix(prefix))
        .map(str::to_owned)
        .collect()
}

fn build_mobile() {
    let prefix = PathBuf::from(env::var("FF_NATIVE_PREFIX").expect("mobile FFmpeg prefix"));
    assert!(
        prefix.join("include/libavformat/avformat.h").is_file(),
        "missing mobile FFmpeg"
    );
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let mut cc = Command::new(env::var("CC").expect("mobile CC"));
    cc.args(env::var("FF_CFLAGS").unwrap_or_default().split_whitespace());
    let status = cc
        .args(["-c", "-O2", "-fPIC", "-std=c11"])
        .arg(format!("-I{}", prefix.join("include").display()))
        .arg("c/ff_ffmpeg_shim.c")
        .arg("-o")
        .arg(out.join("shim.o"))
        .status()
        .expect("mobile compiler");
    assert!(status.success(), "mobile FFmpeg shim compilation failed");
    assert!(
        Command::new(env::var("AR").expect("mobile AR"))
            .arg("crs")
            .arg(out.join("libff_ffmpeg_shim.a"))
            .arg(out.join("shim.o"))
            .status()
            .unwrap()
            .success()
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=ff_ffmpeg_shim");
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    for lib in FFMPEG_LIBRARIES {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }
    println!("cargo:rustc-cfg={AVAILABLE_CFG}");
}
