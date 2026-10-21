//! End-to-end playback against the real pipeline and the real `Core Audio` device.
//!
//! This test generates a WAV fixture, plays it through `FFmpeg` -> PCM ring ->
//! `PortAudio`, and asserts the docs/design/playback.md acceptance points that need actual output:
//! prime-then-play, position advancing from the frame clock, pause freezing it,
//! seek re-anchoring, the natural end of the item wrapping in the default mode
//! with no underrun, and the diagnostics metrics.
//!
//! It is `#[ignore]`d because it opens the default output device and makes sound.
//! Run it deliberately, on a machine with audio:
//!
//! ```text
//! cargo test -p fideflow-media-session --test session_playback -- --ignored --nocapture
//! ```

// The fixture is synthesized here and its WAV header is written by hand, so the
// small integer conversions below are exactly what the format asks for.
#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the synthesized fixture stays far inside every target type's range"
)]

use std::f64::consts::TAU;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use fideflow_media_session::PlaybackSession;
use serde_json::Value;

/// Fixture: 3 seconds of a quiet 440 Hz tone, 44.1 kHz stereo 16-bit.
///
/// 44.1 kHz exercises the application resampler when the shared system output
/// runs at another rate. Explicit conversion cases are also covered by decoder tests.
const FIXTURE_SECONDS: u32 = 3;
const FIXTURE_RATE: u32 = 44_100;
const FIXTURE_CHANNELS: u16 = 2;
const AMPLITUDE: f64 = 0.2;

fn shared_system_rate() -> u32 {
    let context = fideflow_media_output::OutputContext::new().unwrap();
    context
        .negotiate_rate(
            &fideflow_media_output::OutputConfiguration::default(),
            FIXTURE_RATE,
        )
        .unwrap()
}

fn write_fixture() -> PathBuf {
    static NEXT_FIXTURE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let serial = NEXT_FIXTURE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let directory =
        std::env::temp_dir().join(format!("ff-playback-{}-{serial}", std::process::id()));
    fs::create_dir_all(&directory).expect("a temp directory");
    let path = directory.join("ff-phase-one.wav");

    let frames = FIXTURE_RATE * FIXTURE_SECONDS;
    let mut samples: Vec<i16> = Vec::with_capacity((frames * u32::from(FIXTURE_CHANNELS)) as usize);
    for frame in 0..frames {
        let time = f64::from(frame) / f64::from(FIXTURE_RATE);
        let value = (AMPLITUDE * (TAU * 440.0 * time).sin() * f64::from(i16::MAX)) as i16;
        for _ in 0..FIXTURE_CHANNELS {
            samples.push(value);
        }
    }

    let data_bytes = (samples.len() * 2) as u32;
    let mut wav: Vec<u8> = Vec::with_capacity(44 + data_bytes as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&FIXTURE_CHANNELS.to_le_bytes());
    wav.extend_from_slice(&FIXTURE_RATE.to_le_bytes());
    let block_align = u32::from(FIXTURE_CHANNELS) * 2;
    wav.extend_from_slice(&(FIXTURE_RATE * block_align).to_le_bytes());
    wav.extend_from_slice(&(block_align as u16).to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    for sample in &samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    fs::write(&path, wav).expect("the fixture file");
    path
}

/// Percent-encodes a path into a `file://` URI.
///
/// Spaces have to be escaped because `FFmpeg` receives the URI verbatim; the
/// literals used here live under the system temp directory, which has none.
fn file_uri(path: &Path) -> String {
    format!("file://{}", path.to_string_lossy().replace(' ', "%20"))
}

fn snapshot(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.snapshot_json()).expect("a snapshot")
}

fn diagnostics(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.diagnostics_json()).expect("diagnostics")
}

fn send(session: &PlaybackSession, command: &str) -> Value {
    serde_json::from_str(&session.execute_json(command)).expect("a result")
}

fn field<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn number(value: &Value, key: &str) -> u64 {
    value
        .get(key)
        .and_then(|entry| entry.as_u64().or_else(|| entry.as_str()?.parse().ok()))
        .unwrap_or(0)
}

/// Removing the pathname after opening proves that seeks do not reopen it.
/// Also exercise an EOF decoder, backward seeking and the zero-position flush.
#[test]
fn paused_seeks_reuse_an_open_decoder_even_after_eof() {
    // Priming uses negotiated output geometry, even when initially paused.
    if !fideflow_media_pipeline::is_available() || !fideflow_media_output::is_available() {
        return;
    }
    let fixture = write_fixture();
    let session = PlaybackSession::with_session_id(String::from("reuse-paused"));
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"reuse","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
        "trackId":"track-1","sourceUri":file_uri(&fixture)}],"startItemId":"item-1","autoplay":false}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    wait_for(&session, "initial prime", Duration::from_secs(5), |s| {
        s["phase"] == "ready"
    });
    #[cfg(not(windows))]
    fs::remove_file(&fixture).unwrap();
    #[cfg(windows)]
    {
        // Windows cannot unlink FFmpeg's open CRT file. The held sharing lock
        // plus decoder reuse counters prove the same lifetime contract.
        assert_eq!(
            fs::remove_file(&fixture).unwrap_err().raw_os_error(),
            Some(32)
        );
    }
    for (i, target) in [2500, 0, 1500, 100].into_iter().enumerate() {
        let before = snapshot(&session);
        let command = serde_json::json!({"schemaVersion":1,"kind":"seek","clientId":"reuse",
            "commandId":format!("seek-{i}"),"targetSessionId":session.session_id(),
            "targetQueueItemId":"item-1","expectedGeneration":before["generation"],
            "payload":{"positionMs":target.to_string()}});
        assert_eq!(send(&session, &command.to_string())["status"], "accepted");
        let ready = wait_for(&session, "reused prime", Duration::from_secs(5), |s| {
            s["phase"] == "ready" && number(s, "positionMs") == target
        });
        assert_eq!(ready["isSeeking"], false);
        assert_eq!(ready["playWhenReady"], false);
        assert_eq!(ready["isActuallyPlaying"], false);
        if target == 2500 {
            wait_for(&session, "decode EOF", Duration::from_secs(5), |_| {
                diagnostics(&session)["worker"]["state"] == "drained"
            });
        }
    }
    let timing = &diagnostics(&session)["timing"];
    assert_eq!(timing["seekDecoderReused"], 4);
    assert_eq!(timing["seekDecoderReopened"], 0);
    assert_eq!(timing["seekDecoderFallbacks"], 0);
    session.shutdown();
    #[cfg(windows)]
    fs::remove_file(&fixture).unwrap();
}

#[test]
fn direct_network_sources_are_rejected_without_connecting() {
    use std::net::TcpListener;
    if !fideflow_media_pipeline::is_available() {
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    for scheme in ["http", "https"] {
        let session = PlaybackSession::with_session_id(String::from("network-source-rejected"));
        let source = format!("{scheme}://{}/stream.wav", listener.local_addr().unwrap());
        let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
            "clientId":"network","commandId":"load","targetSessionId":session.session_id(),
            "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
            "trackId":"track-1","sourceUri":source}],"startItemId":"item-1","autoplay":false}});
        assert_eq!(send(&session, &load.to_string())["status"], "accepted");
        let failed = wait_for(
            &session,
            "network source rejection",
            Duration::from_secs(5),
            |s| s["phase"] == "error",
        );
        assert_eq!(failed["errorCode"], "sourceUnsupported");
        assert_eq!(
            number(&diagnostics(&session)["counters"], "framesWritten"),
            0
        );
        session.shutdown();
    }
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[test]
fn replacing_a_source_with_the_same_uri_invalidates_the_decoder() {
    // Priming uses negotiated output geometry, even when initially paused.
    if !fideflow_media_pipeline::is_available() || !fideflow_media_output::is_available() {
        return;
    }
    let fixture = write_fixture();
    let uri = file_uri(&fixture);
    let session = PlaybackSession::with_session_id(String::from("reuse-replacement"));
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"reuse","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
        "trackId":"track-1","sourceUri":uri}],"startItemId":"item-1","autoplay":false}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    wait_for(&session, "initial prime", Duration::from_secs(5), |s| {
        s["phase"] == "ready"
    });
    #[cfg(not(windows))]
    fs::remove_file(&fixture).unwrap();
    #[cfg(windows)]
    fs::write(&fixture, b"invalid replacement media").unwrap();
    let replace = serde_json::json!({"schemaVersion":1,"kind":"provideSource","clientId":"reuse",
        "commandId":"replace","targetSessionId":session.session_id(),
        "targetQueueItemId":"item-1","expectedGeneration":snapshot(&session)["generation"],
        "payload":{"sourceUri":uri}});
    assert_eq!(send(&session, &replace.to_string())["status"], "accepted");
    let seek = serde_json::json!({"schemaVersion":1,"kind":"seek","clientId":"reuse",
        "commandId":"seek","targetSessionId":session.session_id(),
        "targetQueueItemId":"item-1","expectedGeneration":snapshot(&session)["generation"],
        "payload":{"positionMs":"0"}});
    assert_eq!(send(&session, &seek.to_string())["status"], "accepted");
    let failed = wait_for(
        &session,
        "replacement reopened",
        Duration::from_secs(5),
        |s| s["phase"] == "error",
    );
    assert_eq!(failed["isSeeking"], false);
    let timing = diagnostics(&session)["timing"].clone();
    assert_eq!(timing["seekDecoderReused"], 0);
    assert_eq!(timing["seekDecoderReopened"], 1);
    session.shutdown();
    #[cfg(windows)]
    fs::remove_file(&fixture).unwrap();
}

/// Same file and targets in both states; run before/after engine changes.
#[test]
#[ignore = "opens the default output device and plays audio"]
fn seek_latency_benchmark() {
    let fixture = write_fixture();
    let session = PlaybackSession::with_session_id(String::from("seek-benchmark"));
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"bench","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
        "trackId":"track-1","sourceUri":file_uri(&fixture)}],"startItemId":"item-1","autoplay":true}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    wait_for(&session, "initial playback", Duration::from_secs(10), |s| {
        s["isActuallyPlaying"] == true
    });
    for paused in [false, true] {
        if paused {
            let command = serde_json::json!({"schemaVersion":1,"kind":"pause","clientId":"bench",
                "commandId":"pause","targetSessionId":session.session_id(),"payload":{}});
            assert_eq!(send(&session, &command.to_string())["status"], "accepted");
        }
        let mut samples = Vec::new();
        for i in 0..30 {
            let before = snapshot(&session);
            let target = if i % 2 == 0 { 500 } else { 1500 };
            let command = serde_json::json!({"schemaVersion":1,"kind":"seek","clientId":"bench",
                "commandId":format!("seek-{paused}-{i}"),"targetSessionId":session.session_id(),
                "targetQueueItemId":"item-1","expectedGeneration":before["generation"],
                "payload":{"positionMs":target.to_string()}});
            let started = Instant::now();
            assert_eq!(send(&session, &command.to_string())["status"], "accepted");
            loop {
                let s = snapshot(&session);
                let ready = s["phase"] == "ready" && number(&s, "positionMs") >= target;
                let consumed = number(&diagnostics(&session)["counters"], "framesConsumed") > 0;
                if ready && (paused || consumed) {
                    break;
                }
                assert!(
                    started.elapsed() < Duration::from_secs(5),
                    "seek failed: {s}"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
            samples.push(started.elapsed().as_micros());
        }
        samples.sort_unstable();
        println!(
            "seek paused={paused} n=30 P50={}us P95={}us",
            samples[14], samples[28]
        );
    }
    session.shutdown();
    let _ = fs::remove_file(fixture);
}

#[test]
#[ignore = "opens the default output device and plays audio"]
fn rapid_seeks_then_pause_keep_the_latest_target() {
    let fixture = write_fixture();
    let session = PlaybackSession::with_session_id(String::from("seek-races"));
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"race","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item",
        "trackId":"track","sourceUri":file_uri(&fixture)}],"startItemId":"item","autoplay":true}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    wait_for(&session, "initial playback", Duration::from_secs(10), |s| {
        s["isActuallyPlaying"] == true
    });
    for round in 0..10 {
        for target in [1200, 600] {
            let before = snapshot(&session);
            let seek = serde_json::json!({"schemaVersion":1,"kind":"seek","clientId":"race",
                "commandId":format!("seek-{round}-{target}"),"targetSessionId":session.session_id(),
                "targetQueueItemId":"item","expectedGeneration":before["generation"],
                "payload":{"positionMs":target.to_string()}});
            assert_eq!(send(&session, &seek.to_string())["status"], "accepted");
        }
        let pause = serde_json::json!({"schemaVersion":1,"kind":"pause","clientId":"race",
            "commandId":format!("pause-{round}"),"targetSessionId":session.session_id(),"payload":{}});
        assert_eq!(send(&session, &pause.to_string())["status"], "accepted");
        let state = wait_for(
            &session,
            "latest paused seek",
            Duration::from_secs(5),
            |s| s["phase"] == "ready",
        );
        assert_eq!(state["playWhenReady"], false);
        assert_eq!(state["isActuallyPlaying"], false);
        assert!(number(&state, "positionMs").abs_diff(600) <= 30);
        let position = number(&state, "positionMs");
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(number(&snapshot(&session), "positionMs"), position);
        let play = serde_json::json!({"schemaVersion":1,"kind":"play","clientId":"race",
            "commandId":format!("play-{round}"),"targetSessionId":session.session_id(),"payload":{}});
        assert_eq!(send(&session, &play.to_string())["status"], "accepted");
    }
    session.shutdown();
    let _ = fs::remove_file(fixture);
}

/// Waits until `predicate` holds for the snapshot, or panics with the last state.
fn wait_for(
    session: &PlaybackSession,
    what: &str,
    deadline: Duration,
    predicate: impl Fn(&Value) -> bool,
) -> Value {
    let until = Instant::now() + deadline;
    let mut last = snapshot(session);
    while Instant::now() < until {
        last = snapshot(session);
        if predicate(&last) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for {what}; last snapshot: {last}");
}

#[test]
#[ignore = "opens the default output device and plays audio"]
#[allow(
    clippy::too_many_lines,
    reason = "the acceptance steps are one sequence; splitting them would hide the order"
)]
fn plays_pauses_seeks_and_wraps_a_real_file() {
    let fixture = write_fixture();
    let session = PlaybackSession::with_session_id(String::from("session-playback"));
    let session_id = session.session_id();
    let uri = file_uri(&fixture);

    let snapshots = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = std::sync::Arc::clone(&snapshots);
    session.set_event_sink(Some(std::sync::Arc::new(move |_message: &str| {
        counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    })));

    let load = format!(
        "{{\"schemaVersion\":1,\"kind\":\"loadQueue\",\"clientId\":\"e2e\",\"commandId\":\"cmd-1\",\
         \"targetSessionId\":\"{session_id}\",\"expectedQueueRevision\":\"0\",\
         \"payload\":{{\"items\":[{{\"queueItemId\":\"item-1\",\"trackId\":\"track-1\",\
         \"sourceUri\":\"{uri}\"}}],\"startItemId\":\"item-1\",\"autoplay\":true}}}}"
    );
    let reply = send(&session, &load);
    assert_eq!(
        reply["status"], "accepted",
        "loadQueue was rejected: {reply}"
    );

    // 1) The session primes before it sounds, then reports itself as playing.
    let playing = wait_for(
        &session,
        "playback to start",
        Duration::from_secs(10),
        |state| state["isActuallyPlaying"] == Value::Bool(true),
    );
    assert_eq!(playing["phase"], "ready");
    assert_eq!(playing["playWhenReady"], true);
    assert_eq!(playing["currentQueueItemId"], "item-1");
    assert_eq!(number(&playing, "durationMs"), 3_000);
    assert_eq!(diagnostics(&session)["output"]["running"], true);
    println!("primed and playing: {playing}");

    // 2) Position comes from the frame clock and keeps advancing.
    std::thread::sleep(Duration::from_millis(600));
    let advanced = snapshot(&session);
    let position = number(&advanced, "positionMs");
    assert!(
        position >= 400,
        "position should follow the frame clock, got {position} ms"
    );

    // 3) Seek re-anchors immediately and keeps playing.
    let seek = format!(
        "{{\"schemaVersion\":1,\"kind\":\"seek\",\"clientId\":\"e2e\",\"commandId\":\"cmd-2\",\
         \"targetSessionId\":\"{session_id}\",\"targetQueueItemId\":\"item-1\",\
         \"expectedGeneration\":\"{}\",\"payload\":{{\"positionMs\":\"2000\"}}}}",
        field(&advanced, "generation")
    );
    let reply = send(&session, &seek);
    assert_eq!(reply["status"], "accepted", "seek was rejected: {reply}");
    let after_seek = wait_for(
        &session,
        "the seek to settle",
        Duration::from_secs(5),
        |state| {
            state["isActuallyPlaying"] == Value::Bool(true)
                && field(state, "positionMs").parse::<u64>().unwrap_or(0) >= 2_000
        },
    );
    assert!(
        number(&after_seek, "positionMs") <= 2_600,
        "seek landed too far past the target: {after_seek}"
    );

    // 4) Pause freezes the position and clears the playing flag.
    let reply = send(
        &session,
        &format!(
            "{{\"schemaVersion\":1,\"kind\":\"pause\",\"clientId\":\"e2e\",\"commandId\":\"cmd-3\",\
             \"targetSessionId\":\"{session_id}\",\"payload\":{{}}}}"
        ),
    );
    assert_eq!(reply["status"], "accepted");
    std::thread::sleep(Duration::from_millis(300));
    let paused = snapshot(&session);
    assert_eq!(paused["isActuallyPlaying"], false);
    assert_eq!(paused["playWhenReady"], false);
    let frozen = number(&paused, "positionMs");
    std::thread::sleep(Duration::from_millis(400));
    assert_eq!(
        number(&snapshot(&session), "positionMs"),
        frozen,
        "a paused session must not advance the frame clock"
    );

    // 5) Play resumes from the paused position rather than restarting.
    let reply = send(
        &session,
        &format!(
            "{{\"schemaVersion\":1,\"kind\":\"play\",\"clientId\":\"e2e\",\"commandId\":\"cmd-4\",\
             \"targetSessionId\":\"{session_id}\",\"payload\":{{}}}}"
        ),
    );
    assert_eq!(reply["status"], "accepted");
    let resumed = wait_for(
        &session,
        "playback to resume",
        Duration::from_secs(5),
        |state| state["isActuallyPlaying"] == Value::Bool(true),
    );
    assert!(
        number(&resumed, "positionMs") >= frozen,
        "resume must not restart the item: {resumed}"
    );

    // 6) The natural end of the only item wraps, because `listLoop` is the mode a
    //    session starts in: the tail is output rather than truncated and the item
    //    restarts from the top with the intent intact. `ended` is no longer how a
    //    non-empty queue finishes, so the evidence for the tail is the position
    //    reaching the item's own length before the restart.
    //
    //    The counters are per item and are cleared when the next item starts, so
    //    they are sampled here, while the first run is still the current one.
    let duration_ms = number(&snapshot(&session), "durationMs");
    let until = Instant::now() + Duration::from_secs(15);
    let mut peak_ms = number(&snapshot(&session), "positionMs");
    let mut tail_silence = 0_u64;
    let mut underruns = 0_u64;
    loop {
        let state = snapshot(&session);
        peak_ms = peak_ms.max(number(&state, "positionMs"));
        let counters = diagnostics(&session)["counters"].clone();
        tail_silence = tail_silence.max(number(&counters, "tailSilenceFrames"));
        underruns = underruns.max(number(&counters, "underruns"));
        if duration_ms > 0 && number(&state, "positionMs") < 1_000 && peak_ms + 500 >= duration_ms {
            break;
        }
        assert!(
            Instant::now() < until,
            "the item never wrapped: it reached {peak_ms} ms of {duration_ms} ms"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    println!("wrapped after {peak_ms} ms of {duration_ms} ms");
    assert!(
        peak_ms + 500 >= duration_ms,
        "the item restarted at {peak_ms} ms, so its tail was truncated"
    );
    assert!(
        tail_silence > 0,
        "the end of the item is expected to have a short silent tail"
    );
    assert_eq!(
        underruns, 0,
        "a 3 second local file must play without underruns"
    );

    // 6b) The restarted item plays again: the wrap keeps the intent and the sound.
    let restarted = wait_for(
        &session,
        "the wrapped item to consume its first PCM",
        Duration::from_secs(10),
        |state| {
            state["isActuallyPlaying"] == Value::Bool(true)
                && number(&diagnostics(&session)["counters"], "framesConsumed") > 0
        },
    );
    assert_eq!(restarted["currentQueueItemId"], "item-1");
    assert_eq!(restarted["playWhenReady"], true);
    assert_eq!(restarted["mode"], "listLoop");
    assert!(
        snapshots.load(std::sync::atomic::Ordering::Relaxed) > 0,
        "the publisher never emitted a snapshot"
    );

    // 7) Diagnostics prove the real device and a clean run. The item is playing
    //    again after the wrap, so output is running; the per-item counters were
    //    sampled in step 6, before the restart cleared them.
    let diagnostics = diagnostics(&session);
    println!("diagnostics: {diagnostics}");
    assert_eq!(diagnostics["output"]["running"], true, "{diagnostics}");
    assert_eq!(diagnostics["output"]["internalRate"], shared_system_rate());
    assert_eq!(diagnostics["source"]["resampler"], "soxr");
    assert_eq!(diagnostics["source"]["codec"], "pcm_s16le");
    assert_eq!(diagnostics["source"]["sourceRate"], 44_100);
    assert!(number(&diagnostics["counters"], "framesConsumed") > 0);
    assert!(
        number(&diagnostics["counters"], "callbackCalls") > 0,
        "the audio callback never ran"
    );
    assert!(
        diagnostics["output"]["deviceName"]
            .as_str()
            .is_some_and(|name| !name.is_empty()),
        "the device name must be reported for docs/design/playback.md evidence"
    );
    assert!(
        diagnostics["timing"]["firstFrameMillis"].as_str().is_some(),
        "the time to the first frame must be measured"
    );

    let _ = fs::remove_file(&fixture);
    session.shutdown();
}

/// Exercise the actual HAL side effect: Hog Mode can hide the default UID.
/// Silent PCM avoids audible test output; run only on a machine with audio.
#[test]
#[ignore = "temporarily acquires exclusive access to the default output device"]
fn exclusive_default_and_explicit_routes_survive_live_decoder_rebuilds() {
    assert!(fideflow_media_pipeline::is_available());
    assert!(fideflow_media_output::is_available());
    let fixture = write_fixture();
    let mut bytes = fs::read(&fixture).unwrap();
    bytes[44..].fill(0);
    fs::write(&fixture, bytes).unwrap();
    let session = PlaybackSession::new();
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"exclusive","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
        "trackId":"track-1","sourceUri":file_uri(&fixture)}],"startItemId":"item-1","autoplay":true}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    let playing = wait_for(&session, "shared output", Duration::from_secs(5), |s| {
        s["isActuallyPlaying"] == true
    });
    let uid = playing["outputSettings"]["activeDeviceUid"].clone();
    assert!(uid.is_string());
    for (index, selected) in [Value::Null, uid, Value::Null].into_iter().enumerate() {
        let command = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration",
            "clientId":"exclusive","commandId":format!("switch-{index}"),
            "targetSessionId":session.session_id(),"payload":{"deviceUid":selected,"exclusive":true}});
        assert_eq!(send(&session, &command.to_string())["status"], "accepted");
        wait_for(&session, "exclusive switch", Duration::from_secs(5), |s| {
            s["outputSettings"]["busy"] == false
                && s["outputSettings"]["exclusiveActive"] == true
                && s["isActuallyPlaying"] == true
        });
        std::thread::sleep(Duration::from_millis(350));
        let current = snapshot(&session);
        assert_eq!(current["outputSettings"]["deviceUid"], selected);
        assert_eq!(current["outputSettings"]["errorCode"], Value::Null);
        assert_eq!(current["outputSettings"]["exclusiveActive"], true);
        assert_eq!(current["isActuallyPlaying"], true);
        assert_eq!(current["outputSettings"]["refreshPending"], false);
    }
    let before_failure = snapshot(&session);
    let invalid = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration",
        "clientId":"exclusive","commandId":"invalid-device","targetSessionId":session.session_id(),
        "payload":{"deviceUid":"ff-nonexistent-output-test","exclusive":true}});
    assert_eq!(send(&session, &invalid.to_string())["status"], "accepted");
    let failed = wait_for(
        &session,
        "failed switch stops playback",
        Duration::from_secs(5),
        |s| s["outputSettings"]["busy"] == false && s["outputSettings"]["errorCode"].is_string(),
    );
    assert_eq!(failed["playWhenReady"], false);
    assert_eq!(failed["isActuallyPlaying"], false);
    assert_eq!(failed["outputSettings"]["deviceUid"], Value::Null);
    assert_eq!(failed["outputSettings"]["exclusive"], false);
    assert_eq!(
        failed["outputSettings"]["deviceUid"],
        before_failure["outputSettings"]["deviceUid"]
    );
    assert_eq!(failed["generation"], before_failure["generation"]);
    let refresh = serde_json::json!({"schemaVersion":1,"kind":"refreshOutputDevices",
        "clientId":"exclusive","commandId":"refresh-after-failure","targetSessionId":session.session_id(),"payload":{}});
    assert_eq!(send(&session, &refresh.to_string())["status"], "accepted");
    std::thread::sleep(Duration::from_millis(600));
    let stopped = snapshot(&session);
    assert_eq!(stopped["playWhenReady"], false);
    assert_eq!(stopped["isActuallyPlaying"], false);
    assert_eq!(stopped["positionMs"], failed["positionMs"]);
    assert_eq!(
        stopped["outputSettings"]["errorCode"],
        failed["outputSettings"]["errorCode"]
    );
    let play = serde_json::json!({"schemaVersion":1,"kind":"play",
        "clientId":"exclusive","commandId":"manual-retry-default","targetSessionId":session.session_id(),"payload":{}});
    assert_eq!(send(&session, &play.to_string())["status"], "accepted");
    let resumed = wait_for(
        &session,
        "manual play uses default format",
        Duration::from_secs(5),
        |s| s["isActuallyPlaying"] == true,
    );
    assert_eq!(resumed["outputSettings"]["errorCode"], Value::Null);
    assert_eq!(resumed["outputSettings"]["deviceUid"], Value::Null);
    assert_eq!(resumed["outputSettings"]["exclusiveActive"], false);
    assert_eq!(
        diagnostics(&session)["output"]["internalRate"],
        shared_system_rate()
    );
    session.shutdown();
    let _ = fs::remove_file(&fixture);
}

#[test]
#[ignore = "repeatedly opens and releases exclusive access to the default output"]
fn rapid_exclusive_play_pause_does_not_report_output_failure() {
    let fixture = write_fixture();
    let mut bytes = fs::read(&fixture).unwrap();
    bytes[44..].fill(0);
    fs::write(&fixture, bytes).unwrap();
    let session = PlaybackSession::new();
    let configure = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration",
        "clientId":"pause-loop","commandId":"exclusive","targetSessionId":session.session_id(),
        "payload":{"deviceUid":null,"exclusive":true}});
    assert_eq!(send(&session, &configure.to_string())["status"], "accepted");
    wait_for(&session, "configuration", Duration::from_secs(5), |s| {
        s["outputSettings"]["exclusive"] == true && s["outputSettings"]["busy"] == false
    });
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"pause-loop","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
        "trackId":"track-1","sourceUri":file_uri(&fixture)}],"startItemId":"item-1","autoplay":false}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    wait_for(&session, "prime", Duration::from_secs(5), |s| {
        s["phase"] == "ready"
    });
    for cycle in 0..60 {
        for kind in ["play", "pause"] {
            let command = serde_json::json!({"schemaVersion":1,"kind":kind,
                "clientId":"pause-loop","commandId":format!("{kind}-{cycle}"),
                "targetSessionId":session.session_id(),"payload":{}});
            assert_eq!(send(&session, &command.to_string())["status"], "accepted");
            if kind == "play" {
                wait_for(&session, "resumed", Duration::from_secs(5), |s| {
                    s["isActuallyPlaying"] == true
                });
            } else {
                let paused = snapshot(&session);
                assert_eq!(paused["playWhenReady"], false, "cycle {cycle}");
                assert_eq!(paused["isActuallyPlaying"], false, "cycle {cycle}");
                assert_eq!(
                    paused["outputSettings"]["exclusiveActive"], false,
                    "cycle {cycle}"
                );
            }
            std::thread::sleep(Duration::from_millis(5 + cycle % 11));
            assert_eq!(
                snapshot(&session)["outputSettings"]["errorCode"],
                Value::Null,
                "{kind} cycle {cycle}"
            );
        }
    }
    session.shutdown();
    let _ = fs::remove_file(&fixture);
}

#[test]
#[ignore = "plays silent PCM and refreshes real output devices in shared and exclusive modes"]
fn refreshing_devices_preserves_continuous_shared_and_exclusive_playback() {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    let fixture = write_fixture();
    let mut bytes = fs::read(&fixture).unwrap();
    let data_size = FIXTURE_RATE * u32::from(FIXTURE_CHANNELS) * 2 * 12;
    bytes.resize(44 + data_size as usize, 0);
    bytes[44..].fill(0);
    bytes[4..8].copy_from_slice(&(36 + data_size).to_le_bytes());
    bytes[40..44].copy_from_slice(&data_size.to_le_bytes());
    fs::write(&fixture, bytes).unwrap();
    let session = PlaybackSession::new();
    let watching = Arc::new(AtomicBool::new(false));
    let interrupted = Arc::new(AtomicBool::new(false));
    session.set_event_sink(Some(Arc::new({
        let watching = Arc::clone(&watching);
        let interrupted = Arc::clone(&interrupted);
        move |message| {
            if watching.load(Ordering::SeqCst) {
                let event: Value = serde_json::from_str(message).unwrap();
                if event["isActuallyPlaying"] == false || event["outputSettings"]["busy"] == true {
                    interrupted.store(true, Ordering::SeqCst);
                }
            }
        }
    })));
    let load = serde_json::json!({"schemaVersion":1,"kind":"loadQueue",
        "clientId":"refresh-continuity","commandId":"load","targetSessionId":session.session_id(),
        "expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"item-1",
        "trackId":"track-1","sourceUri":file_uri(&fixture)}],"startItemId":"item-1","autoplay":true}});
    assert_eq!(send(&session, &load.to_string())["status"], "accepted");
    wait_for(&session, "initial playback", Duration::from_secs(5), |s| {
        s["isActuallyPlaying"] == true
    });
    for exclusive in [false, true] {
        let configure = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration",
            "clientId":"refresh-continuity","commandId":format!("configure-{exclusive}"),
            "targetSessionId":session.session_id(),"payload":{"deviceUid":null,"exclusive":exclusive}});
        assert_eq!(send(&session, &configure.to_string())["status"], "accepted");
        let baseline = wait_for(&session, "mode ready", Duration::from_secs(5), |s| {
            s["isActuallyPlaying"] == true
                && s["outputSettings"]["busy"] == false
                && s["outputSettings"]["exclusiveActive"] == exclusive
        });
        let started = Instant::now();
        watching.store(true, Ordering::SeqCst);
        for index in 0..30 {
            let refresh = serde_json::json!({"schemaVersion":1,"kind":"refreshOutputDevices",
                "clientId":"refresh-continuity","commandId":format!("refresh-{exclusive}-{index}"),
                "targetSessionId":session.session_id(),"payload":{}});
            assert_eq!(send(&session, &refresh.to_string())["status"], "accepted");
            std::thread::sleep(Duration::from_millis(25));
            let current = snapshot(&session);
            assert_eq!(current["isActuallyPlaying"], true);
            assert_eq!(current["outputSettings"]["busy"], false);
            assert_eq!(current["outputSettings"]["errorCode"], Value::Null);
            assert_eq!(current["outputSettings"]["exclusiveActive"], exclusive);
            assert_eq!(current["generation"], baseline["generation"]);
            assert_eq!(
                current["outputSettings"]["activeDeviceUid"],
                baseline["outputSettings"]["activeDeviceUid"]
            );
        }
        watching.store(false, Ordering::SeqCst);
        assert!(!interrupted.load(Ordering::SeqCst));
        let progress = number(&snapshot(&session), "positionMs") - number(&baseline, "positionMs");
        assert!(
            u128::from(progress) + 150 >= started.elapsed().as_millis(),
            "refresh must not stall the PCM clock"
        );
    }
    session.shutdown();
    let _ = fs::remove_file(&fixture);
}
