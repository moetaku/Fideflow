//! Builds pinned `PortAudio` with Core Audio, WASAPI or ALSA device policy.
use std::{env, path::PathBuf, process::Command};
const PORTAUDIO_VERSION: &str = "19.7.0";
fn run(command: &mut Command) {
    assert!(
        command.status().expect("native build tool").success(),
        "PortAudio build failed"
    );
}
fn main() {
    println!("cargo:rustc-check-cfg=cfg(ff_portaudio_available)");
    println!("cargo:rustc-check-cfg=cfg(ff_mobile_available)");
    println!("cargo:rerun-if-changed=c/ff_portaudio.c");
    println!("cargo:rerun-if-changed=c/device_id_extension.c");
    println!("cargo:rerun-if-env-changed=FF_PORTAUDIO_DIR");
    println!("cargo:rerun-if-env-changed=FF_NATIVE_PREFIX");
    println!("cargo:rerun-if-env-changed=FF_ALLOW_MISSING_NATIVE");
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
        return;
    }
    build_macos();
}

fn build_linux() {
    println!("cargo:rerun-if-changed=c/ff_portaudio_linux.c");
    let prefix = env::var_os("FF_NATIVE_PREFIX").map_or_else(
        || {
            PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
                .join("../../../build/third_party/linux")
                .join(
                    if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("aarch64") {
                        "aarch64"
                    } else {
                        "x86_64"
                    },
                )
        },
        PathBuf::from,
    );
    let library = prefix.join("lib/libportaudio.a");
    let alsa = Command::new("pkg-config")
        .args(["--atleast-version=1.2", "alsa"])
        .status();
    if !library.is_file() || !matches!(alsa, Ok(status) if status.success()) {
        if env::var("PROFILE").as_deref() == Ok("debug")
            && env::var("FF_ALLOW_MISSING_NATIVE").as_deref() == Ok("1")
        {
            println!("cargo:warning=Explicit debug build without Linux PortAudio/ALSA output");
            return;
        }
        panic!(
            "Linux output requires pinned PortAudio 19.7.0 and ALSA development files; run tooling/native/linux/build.sh portaudio"
        );
    }
    println!("cargo:rerun-if-changed={}", library.display());
    let flags = Command::new("pkg-config")
        .args(["--cflags", "alsa"])
        .output()
        .expect("pkg-config");
    assert!(flags.status.success(), "ALSA compiler flags unavailable");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let object = out.join("ff_portaudio_linux.o");
    run(Command::new(env::var("CC").unwrap_or_else(|_| "cc".into()))
        .args([
            "-c", "-O2", "-fPIC", "-std=c11", "-Wall", "-Wextra", "-Werror",
        ])
        .arg("-I")
        .arg(prefix.join("include"))
        .args(String::from_utf8_lossy(&flags.stdout).split_whitespace())
        .arg("c/ff_portaudio_linux.c")
        .arg("-o")
        .arg(&object));
    run(Command::new(env::var("AR").unwrap_or_else(|_| "ar".into()))
        .arg("crs")
        .arg(out.join("libff_portaudio_linux.a"))
        .arg(object));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    println!("cargo:rustc-link-lib=static=ff_portaudio_linux");
    println!("cargo:rustc-link-lib=static=portaudio");
    for lib in ["asound", "pthread", "m"] {
        println!("cargo:rustc-link-lib={lib}");
    }
    println!("cargo:rustc-cfg=ff_portaudio_available");
}

fn build_macos() {
    let source = env::var_os("FF_PORTAUDIO_DIR").map_or_else(
        || {
            PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
                .join("../../../build/third_party/portaudio/19.7.0")
        },
        PathBuf::from,
    );
    if !source.join("include/portaudio.h").exists() {
        println!(
            "cargo:warning=PortAudio {PORTAUDIO_VERSION} is not staged; run tooling/native/macos/build.sh fetch"
        );
        return;
    }
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let arch = if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    // Copy only the backend being extended, leaving the pinned upstream source intact.
    let backend = out.join("pa_mac_core_extended.c");
    let mut text =
        std::fs::read_to_string(source.join("src/hostapi/coreaudio/pa_mac_core.c")).unwrap();
    text.push_str(&std::fs::read_to_string("c/device_id_extension.c").unwrap());
    std::fs::write(&backend, text).unwrap();
    let sources = [
        "src/common/pa_allocation.c",
        "src/common/pa_converters.c",
        "src/common/pa_cpuload.c",
        "src/common/pa_debugprint.c",
        "src/common/pa_dither.c",
        "src/common/pa_front.c",
        "src/common/pa_process.c",
        "src/common/pa_ringbuffer.c",
        "src/common/pa_stream.c",
        "src/common/pa_trace.c",
        "src/os/unix/pa_unix_hostapis.c",
        "src/os/unix/pa_unix_util.c",
        "src/hostapi/coreaudio/pa_mac_core_utilities.c",
        "src/hostapi/coreaudio/pa_mac_core_blocking.c",
    ];
    let mut inputs: Vec<PathBuf> = sources.iter().map(|s| source.join(s)).collect();
    inputs.push(backend);
    inputs.push(PathBuf::from("c/ff_portaudio.c"));
    let mut objects = Vec::new();
    for (index, input) in inputs.iter().enumerate() {
        let object = out.join(format!("pa_{index}.o"));
        let mut cc = Command::new("clang");
        cc.args([
            "-c",
            "-O2",
            "-fPIC",
            "-std=c11",
            "-DPA_USE_COREAUDIO=1",
            "-DHAVE_NANOSLEEP=1",
            "-mmacosx-version-min=12.0",
            "-arch",
            arch,
        ]);
        for dir in [
            "include",
            "src/common",
            "src/os/unix",
            "src/hostapi/coreaudio",
        ] {
            cc.arg("-I").arg(source.join(dir));
        }
        cc.arg(input).arg("-o").arg(&object);
        run(&mut cc);
        objects.push(object);
    }
    let mut ar = Command::new("ar");
    ar.arg("crs")
        .arg(out.join("libfideflow_portaudio.a"))
        .args(objects);
    run(&mut ar);
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=fideflow_portaudio");
    for framework in [
        "CoreAudio",
        "AudioToolbox",
        "AudioUnit",
        "CoreFoundation",
        "Carbon",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rustc-cfg=ff_portaudio_available");
}

fn build_windows() {
    println!("cargo:rerun-if-changed=c/ff_wasapi.cpp");
    let prefix = env::var_os("FF_NATIVE_PREFIX").map_or_else(
        || {
            PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
                .join("../../../build/third_party/windows/x86_64")
        },
        PathBuf::from,
    );
    if !prefix.join("lib/portaudio_static_x64.lib").is_file() {
        println!("cargo:warning=Windows PortAudio missing; run tooling/native/windows/build.ps1");
        return;
    }
    println!(
        "cargo:rerun-if-changed={}",
        prefix.join("lib/portaudio_static_x64.lib").display()
    );
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let object = out.join("ff_wasapi.obj");
    run(Command::new("cl")
        .args([
            "/nologo",
            "/c",
            "/O2",
            "/MD",
            "/std:c++17",
            "/EHsc",
            "/utf-8",
        ])
        .arg(format!("/I{}", prefix.join("include").display()))
        .arg(format!("/Fo{}", object.display()))
        .arg("c/ff_wasapi.cpp"));
    run(Command::new("lib")
        .arg("/nologo")
        .arg(format!("/OUT:{}", out.join("ff_wasapi.lib").display()))
        .arg(object));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    for library in ["ff_wasapi", "portaudio_static_x64"] {
        println!("cargo:rustc-link-lib=static={library}");
    }
    for library in ["ole32", "uuid", "winmm", "avrt", "ksuser"] {
        println!("cargo:rustc-link-lib={library}");
    }
    println!("cargo:rustc-cfg=ff_portaudio_available");
}

fn build_mobile() {
    println!("cargo:rustc-check-cfg=cfg(ff_mobile_available)");
    println!("cargo:rerun-if-changed=c/ff_mobile.c");
    println!("cargo:rerun-if-env-changed=FF_MINIAUDIO_DIR");
    let source =
        env::var("FF_MINIAUDIO_DIR").expect("mobile build requires pinned FF_MINIAUDIO_DIR");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let ios = env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios");
    let mut cc = Command::new(env::var("CC").expect("mobile CC"));
    cc.args(env::var("FF_CFLAGS").unwrap_or_default().split_whitespace());
    cc.args(["-c", "-O2", "-fPIC", "-std=c11", "-I", &source]);
    if ios {
        cc.args(["-x", "objective-c"]);
    }
    run(cc.arg("c/ff_mobile.c").arg("-o").arg(out.join("mobile.o")));
    run(Command::new(env::var("AR").expect("mobile AR"))
        .arg("crs")
        .arg(out.join("libff_mobile.a"))
        .arg(out.join("mobile.o")));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=ff_mobile");
    if ios {
        for framework in ["AudioToolbox", "CoreAudio", "AVFoundation", "Foundation"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rustc-link-lib=objc");
    } else {
        for lib in ["log", "android", "OpenSLES", "dl"] {
            println!("cargo:rustc-link-lib={lib}");
        }
    }
    println!("cargo:rustc-cfg=ff_mobile_available");
}
