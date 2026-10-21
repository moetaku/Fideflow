//! Gives the session's test binaries the same `FFmpeg` search path the pipeline uses.
//!
//! The session links `FFmpeg` only transitively, through `media-pipeline`, but its
//! integration tests load `libavformat.dylib` at run time exactly like the host
//! does. A test binary is a separate link step, so it needs the prefix on its own
//! rpath; the shipped host dylib gets `@loader_path` from `media-ffi` instead and
//! never carries a path into a developer's build tree.
//!
//! `rustc-link-arg` is the only key that reaches both the lib's own unit-test
//! harness and the `tests/` binaries; `rustc-link-arg-tests` alone leaves the
//! unit-test link step without the prefix.

#[path = "../../build-support/ffmpeg_prefix.rs"]
mod ffmpeg_prefix;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed={}", ffmpeg_prefix::PREFIX_ENV);
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let Some(prefix) = ffmpeg_prefix::native_prefix() else {
        return;
    };
    let library_dir = prefix.join("lib");
    if !library_dir.is_dir() {
        return;
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", library_dir.display());
}
