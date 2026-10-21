//! Link-time rpaths for the C ABI crate.
//!
//! `media-ffi` is the one crate whose *shipped* artifact is linked, so its rpath
//! placement is the only one that must describe the app bundle rather than a
//! developer's build tree:
//!
//! * the `cdylib` resolves the `FFmpeg` and `PortAudio` libraries that sit next to
//!   it in `Contents/Frameworks`, so it gets `@loader_path`;
//! * the unit-test and example binaries run from `target/`, where the pinned
//!   prefix's libraries are the only ones dyld can find, so they get that prefix.
//!
//! The prefix rpath has to use `cargo:rustc-link-arg` because that is the only key
//! that reaches the lib's own unit-test harness. That key also applies to the
//! `cdylib`, so the shipped library would carry a `/Users/...` rpath. Two things
//! keep that out of a signed bundle:
//!
//! * `tooling/native/macos/rust.sh` deletes any non-relocatable rpath while it
//!   flattens the library, warns, and re-signs afterwards;
//! * `embed.sh` verifies the staged file, so a leaked path fails the build rather
//!   than shipping.

#[path = "../../build-support/ffmpeg_prefix.rs"]
mod ffmpeg_prefix;

/// File name of the shipped dynamic library. Keep it in step with the crate's
/// `[lib] name`; `embed.sh` and the Dart host look the library up by this name.
const LIB_NAME: &str = "libff_media_core.dylib";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed={}", ffmpeg_prefix::PREFIX_ENV);
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        // The Flutter bundle places this cdylib and its FFmpeg siblings in one
        // directory. Tests/examples run from target/, so keep their build-prefix
        // lookup separate from the relocatable artifact's $ORIGIN lookup.
        println!("cargo:rustc-link-arg-cdylib=-Wl,-rpath,$ORIGIN");
        if let Some(prefix) = ffmpeg_prefix::native_prefix() {
            println!(
                "cargo:rustc-link-arg=-Wl,-rpath,{}",
                prefix.join("lib").display()
            );
        }
        return;
    }
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    println!("cargo:rustc-link-arg-cdylib=-Wl,-rpath,@loader_path");
    // Pin the install name instead of letting the linker default to the build
    // output path: the library is loaded from Contents/Frameworks by a host that
    // resolves `@rpath`, and tooling/native/macos/embed.sh verifies this string.
    println!("cargo:rustc-link-arg-cdylib=-Wl,-install_name,@rpath/{LIB_NAME}");

    let Some(prefix) = ffmpeg_prefix::native_prefix() else {
        return;
    };
    let library_dir = prefix.join("lib");
    if !library_dir.is_dir() {
        return;
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", library_dir.display());
}
