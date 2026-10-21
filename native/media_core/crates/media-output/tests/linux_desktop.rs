#![cfg(target_os = "linux")]
use fideflow_media_output::{OutputConfiguration, OutputContext, OutputDevice, PlaybackDevice};
use std::{
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

fn sinks(pid: u32) -> String {
    let out = Command::new("pactl")
        .env("LC_ALL", "C.UTF-8")
        .args(["list", "short", "sinks"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let mut states = String::from_utf8(out.stdout.clone())
        .unwrap()
        .lines()
        .map(|line| {
            let fields: Vec<_> = line.split('\t').collect();
            fields[1].to_string()
        })
        .collect::<Vec<_>>();
    states.sort();
    let inputs = Command::new("pactl")
        .env("LC_ALL", "C.UTF-8")
        .args(["list", "sink-inputs"])
        .output()
        .unwrap();
    let listing = String::from_utf8(out.stdout.clone()).unwrap();
    let mapping = listing
        .lines()
        .map(|l| {
            let f: Vec<_> = l.split('\t').collect();
            (f[0], f[1])
        })
        .collect::<std::collections::HashMap<_, _>>();
    for block in String::from_utf8(inputs.stdout)
        .unwrap()
        .split("Sink Input #")
    {
        if !block.contains(&format!("application.process.id = \"{pid}\"")) {
            continue;
        }
        let sink = block
            .lines()
            .find_map(|line| line.trim().strip_prefix("Sink: "))
            .unwrap();
        states.push(format!("test stream => {}", mapping.get(sink).unwrap()));
    }
    let default = Command::new("pactl")
        .args(["get-default-sink"])
        .output()
        .unwrap();
    states.push(format!(
        "default {}",
        String::from_utf8(default.stdout).unwrap().trim()
    ));
    states.sort();
    states.join("\n")
}

struct Playing(std::process::Child);
impl Drop for Playing {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn sink_name(uid: &str, name: &str) -> String {
    if uid.starts_with("alsa:pulse:DEVICE=") {
        uid.trim_start_matches("alsa:pulse:DEVICE=").to_string()
    } else {
        let listing = Command::new("pactl")
            .env("LC_ALL", "C.UTF-8")
            .args(["list", "sinks"])
            .output()
            .unwrap();
        let listing = String::from_utf8(listing.stdout).unwrap();
        let card_name = name.split(" / ").next().unwrap();
        listing
            .split("Sink #")
            .find_map(|block| {
                if !block
                    .lines()
                    .any(|line| line.trim() == format!("Description: {name}"))
                    && !block.contains(&format!("alsa.card_name = \"{card_name}\""))
                {
                    return None;
                }
                block
                    .lines()
                    .find_map(|line| line.trim().strip_prefix("Name: ").map(str::to_owned))
            })
            .unwrap()
    }
}

fn assert_shared_label(context: &OutputContext, device: &PlaybackDevice, sink_name: &str) {
    if device.exclusive_supported {
        let shared_uid = format!("alsa:pulse:DEVICE={sink_name}");
        let shared = context
            .devices()
            .unwrap()
            .into_iter()
            .find(|d| d.uid == shared_uid)
            .unwrap();
        assert_eq!(
            device.name, shared.name,
            "shared and exclusive labels must match"
        );
        assert!(!device.name.contains("[ALSA hw]"));
    }
}

fn assert_stream_label(context: &OutputContext, device: &PlaybackDevice, output: &OutputDevice) {
    assert_eq!(output.info().device_name, device.name);
    let _ = context.changes();
    assert_eq!(
        context
            .devices()
            .unwrap()
            .into_iter()
            .find(|d| d.uid == device.uid)
            .unwrap()
            .name,
        device.name
    );
}

fn assert_legacy_shared_route(device: &PlaybackDevice) {
    let legacy = OutputConfiguration {
        device_uid: Some(
            device
                .uid
                .replacen("alsa:hw:", "alsa:dmix:", 1)
                .replace(",SUBDEV=0", ""),
        ),
        ..Default::default()
    };
    let output =
        OutputDevice::start_configured(&legacy, 2, 48_000, 512, |pcm| pcm.fill(0.0)).unwrap();
    assert!(output.info().device_uid.starts_with("alsa:pulse:DEVICE="));
    drop(output);
}

#[test]
#[ignore = "requires a live PulseAudio/PipeWire desktop; temporarily disables each target card profile"]
fn desktop_shared_and_exclusive_routes_restore_sinks() {
    assert_eq!(std::env::var("FF_RUN_DESKTOP_SMOKE").as_deref(), Ok("1"));

    let context = OutputContext::new().unwrap();
    let devices = context.devices().unwrap();
    assert!(
        devices
            .iter()
            .any(|d| d.uid.starts_with("alsa:pulse:DEVICE="))
    );
    assert!(
        devices
            .iter()
            .filter(|d| d.uid.starts_with("alsa:pulse:DEVICE="))
            .all(|d| !d.name.starts_with("alsa_output."))
    );
    for device in devices {
        let sink_name = sink_name(&device.uid, &device.name);
        assert_shared_label(&context, &device, &sink_name);
        let desktop_playback = Playing(
            Command::new("pacat")
                .args([
                    "--playback",
                    "--raw",
                    "--rate=48000",
                    "--channels=2",
                    "--device",
                    &sink_name,
                ])
                .stdin(std::fs::File::open("/dev/zero").unwrap())
                .spawn()
                .unwrap(),
        );
        std::thread::sleep(Duration::from_millis(500));
        let before = sinks(desktop_playback.0.id());
        let config = OutputConfiguration {
            device_uid: Some(device.uid.clone()),
            exclusive: device.exclusive_supported,
            ..Default::default()
        };
        let rate = context.negotiate_rate(&config, 48000).expect(&device.uid);
        let channels = context.negotiate_channels(&config, 2).expect(&device.uid);
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(
            sinks(desktop_playback.0.id()),
            before,
            "negotiation must restore desktop state"
        );
        let calls = Arc::new(AtomicUsize::new(0));
        let capture = calls.clone();
        let output = OutputDevice::start_configured(&config, channels, rate, 512, move |pcm| {
            pcm.fill(0.0);
            capture.fetch_add(1, Ordering::Relaxed);
        })
        .expect(&device.uid);
        std::thread::sleep(Duration::from_millis(500));
        assert!(output.is_running(), "{}", device.uid);
        assert_stream_label(&context, &device, &output);
        assert!(calls.load(Ordering::Relaxed) > 0, "{} callback", device.uid);
        assert_eq!(output.exclusive_active(), device.exclusive_supported);
        println!(
            "PASS {} => {} ({}Hz, {}ch)",
            device.uid,
            output.info().device_name,
            rate,
            channels
        );
        if config.exclusive {
            assert!(
                !sinks(desktop_playback.0.id())
                    .lines()
                    .any(|line| line == sink_name),
                "exclusive open must release target desktop profile"
            );
            let _ = context.changes();
            assert_eq!(context.negotiate_channels(&config, 2).unwrap(), channels);
        }
        drop(output);
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(
            sinks(desktop_playback.0.id()),
            before,
            "close must restore desktop state"
        );
        if config.exclusive {
            // Reaching the PortAudio format/open failure path must also restore.
            let bad =
                OutputDevice::start_configured(&config, 32, 384_000, 512, |pcm| pcm.fill(0.0));
            assert!(bad.is_err());
            std::thread::sleep(Duration::from_millis(100));
            assert_eq!(
                sinks(desktop_playback.0.id()),
                before,
                "failed open must restore desktop state"
            );
            assert_legacy_shared_route(&device);
        }
    }
}
