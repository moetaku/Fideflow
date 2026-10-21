#![cfg(target_os = "linux")]
use fideflow_media_output::{
    OutputConfiguration, OutputContext, OutputDevice, OutputError, backend,
    supports_exclusive_mode, version,
};
use std::{
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[test]
#[ignore = "requires isolated ALSA fixture; run tooling/native/linux/portaudio_smoke.sh"]
fn alsa_routes_callbacks_pause_and_configuration_recovery() {
    assert_eq!(std::env::var("FF_RUN_PORTAUDIO_SMOKE").as_deref(), Ok("1"));
    assert!(std::env::var_os("ALSA_CONFIG_PATH").is_some());
    assert_eq!(backend(), "portaudio");
    assert_eq!(version(), "19.7.0");
    assert!(supports_exclusive_mode());
    let context = OutputContext::new().unwrap();
    let devices = context.devices().unwrap();
    assert!(
        devices
            .iter()
            .all(|d| d.uid != "alsa:ff_shared" && d.uid != "alsa:lavrate" && d.uid != "alsa:upmix")
    );
    assert!(devices.iter().all(|d| d.uid == "alsa:default"
        || d.uid.starts_with("alsa:hw:")
        || d.uid.starts_with("alsa:dmix:")));
    assert!(
        devices
            .iter()
            .any(|d| d.uid == "alsa:default" && d.is_default)
    );
    assert_eq!(context.default_uid().as_deref(), Some("alsa:default"));
    for uid in [None, Some("alsa:ff_shared".into())] {
        let config = OutputConfiguration {
            exclusive: true,
            device_uid: uid,
            ..Default::default()
        };
        assert!(
            matches!(context.negotiate_channels(&config, 2), Err(OutputError::DeviceOpen(message)) if message == "outputExclusiveUnavailable")
        );
    }
    let absent = OutputConfiguration {
        exclusive: true,
        device_uid: Some("alsa:hw:CARD=FideflowMissingCard,DEV=0".into()),
        ..Default::default()
    };
    assert!(OutputDevice::start_configured(&absent, 2, 48000, 256, |_| {}).is_err());
    let calls = Arc::new(AtomicUsize::new(0));
    let capture = calls.clone();
    let config = OutputConfiguration {
        device_uid: Some("alsa:ff_capture".into()),
        ..Default::default()
    };
    let mut stream = OutputDevice::start_configured(&config, 2, 48000, 256, move |pcm| {
        pcm.fill(0.125);
        capture.fetch_add(1, Ordering::Relaxed);
    })
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while calls.load(Ordering::Relaxed) == 0 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(1));
    }
    assert!(
        calls.load(Ordering::Relaxed) > 0,
        "PortAudio must invoke the actual PCM callback"
    );
    assert!(!stream.exclusive_active());
    stream.pause();
    let paused = calls.load(Ordering::Relaxed);
    thread::sleep(Duration::from_millis(20));
    assert_eq!(
        calls.load(Ordering::Relaxed),
        paused,
        "pause must quiesce callbacks"
    );
    stream.resume().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while calls.load(Ordering::Relaxed) == paused && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(1));
    }
    assert!(calls.load(Ordering::Relaxed) > paused);
    drop(stream);
    let control = std::env::var("FF_PORTAUDIO_SMOKE_CONTROL").unwrap();
    assert!(
        Command::new(&control)
            .arg("remove")
            .status()
            .unwrap()
            .success()
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    while context.changes() & 1 == 0 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(50));
    }
    assert!(
        !context
            .devices()
            .unwrap()
            .iter()
            .any(|d| d.uid == "alsa:ff_shared")
    );
    assert!(!context.route_valid(Some("alsa:ff_shared")));
    assert!(
        Command::new(&control)
            .arg("restore")
            .status()
            .unwrap()
            .success()
    );
    assert!(context.route_valid(Some("alsa:ff_shared")));
    assert!(
        context
            .devices()
            .unwrap()
            .iter()
            .all(|d| d.uid != "alsa:ff_shared")
    );
    let restored = OutputConfiguration {
        device_uid: Some("alsa:ff_shared".into()),
        ..Default::default()
    };
    let stream =
        OutputDevice::start_configured(&restored, 2, 48000, 256, |pcm| pcm.fill(0.0)).unwrap();
    assert!(stream.is_running());
    drop(stream);
    assert!(
        Command::new(&control)
            .arg("fallback")
            .status()
            .unwrap()
            .success()
    );
    let devices = context.refresh().unwrap();
    assert!(
        devices
            .iter()
            .any(|d| d.uid == "alsa:default" && d.is_default)
    );
    assert_eq!(context.default_uid().as_deref(), Some("alsa:default"));
    let default_stream =
        OutputDevice::start_configured(&OutputConfiguration::default(), 2, 48000, 256, |pcm| {
            pcm.fill(0.0)
        })
        .unwrap();
    assert!(default_stream.is_running());
}
