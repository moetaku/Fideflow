//! Real-device validation uses silent PCM so running the test makes no sound.
use fideflow_media_session::PlaybackSession;
use serde_json::{Value, json};
use std::{
    fs, thread,
    time::{Duration, Instant},
};

fn snapshot(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.snapshot_json()).unwrap()
}
fn diagnostics(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.diagnostics_json()).unwrap()
}
fn command(session: &PlaybackSession, kind: &str, id: &str, payload: Value) {
    let before = snapshot(session);
    let mut value = json!({"schemaVersion":1,"kind":kind,"clientId":"effects-real",
        "commandId":id,"targetSessionId":session.session_id()});
    value["payload"] = payload;
    if matches!(kind, "loadQueue" | "skipNext") {
        value["expectedQueueRevision"] = before["queueRevision"].clone();
    }
    if matches!(kind, "seek" | "skipNext") {
        value["targetQueueItemId"] = before["currentQueueItemId"].clone();
        value["expectedGeneration"] = before["generation"].clone();
    }
    let reply: Value = serde_json::from_str(&session.execute_json(&value.to_string())).unwrap();
    assert_eq!(reply["status"], "accepted", "{reply}");
}
fn wait(session: &PlaybackSession, label: &str, predicate: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let value = snapshot(session);
        if predicate(&value) {
            return value;
        }
        assert!(
            Instant::now() < deadline,
            "{label}: {value}; {}",
            diagnostics(session)
        );
        thread::sleep(Duration::from_millis(10));
    }
}
fn silent_wav() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("ff-effects-silent-{}.wav", std::process::id()));
    let bytes: u32 = 44100 * 2 * 2 * 2;
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(bytes + 36).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&44100u32.to_le_bytes());
    wav.extend_from_slice(&176_400_u32.to_le_bytes());
    wav.extend_from_slice(&4u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&bytes.to_le_bytes());
    wav.resize(wav.len() + bytes as usize, 0);
    fs::write(&path, wav).unwrap();
    path
}

#[test]
#[ignore = "opens shared and exclusive real output devices with silent PCM"]
fn shared_and_exclusive_effects_survive_pause_cancel_skip_seek_and_stop() {
    assert!(fideflow_media_pipeline::is_available());
    let path = silent_wav();
    for exclusive in [false, true] {
        let session = PlaybackSession::new();
        command(
            &session,
            "setPlaybackEffects",
            "effects",
            json!({"fadeEnabled":true,"volumeNormalizationEnabled":true}),
        );
        command(
            &session,
            "setOutputConfiguration",
            "output",
            json!({"deviceUid":null,"exclusive":exclusive}),
        );
        wait(&session, "output configured", |s| {
            s["outputSettings"]["busy"] == false
        });
        command(
            &session,
            "loadQueue",
            "load",
            json!({"items":[
            {"queueItemId":"a","trackId":"a","sourceUri":format!("file://{}",path.display()),"normalizationGainDb":-10.7206,"normalizationPeak":1},
            {"queueItemId":"b","trackId":"b","sourceUri":format!("file://{}",path.display()),"normalizationGainDb":3.0815,"normalizationPeak":0.6215},
            {"queueItemId":"c","trackId":"c","sourceUri":format!("file://{}",path.display())}],
            "startItemId":"a","autoplay":true}),
        );
        let ready = wait(&session, "audible", |s| s["isActuallyPlaying"] == true);
        assert_eq!(ready["playbackEffects"]["normalizationActive"], true);
        assert_eq!(ready["volume"], 800);
        assert_eq!(ready["outputSettings"]["exclusiveActive"], exclusive);
        thread::sleep(Duration::from_millis(100));
        let received = Instant::now();
        command(&session, "pause", "pause", json!({}));
        assert!(
            received.elapsed() < Duration::from_millis(150),
            "pause waited for fade"
        );
        wait(&session, "fade then pause", |_| {
            diagnostics(&session)["output"]["running"] == false
        });
        assert_eq!(
            snapshot(&session)["outputSettings"]["exclusiveActive"],
            false
        );
        command(&session, "play", "resume", json!({}));
        wait(&session, "resume", |s| s["isActuallyPlaying"] == true);
        command(&session, "pause", "cancelled-pause", json!({}));
        command(&session, "play", "cancel-pause", json!({}));
        thread::sleep(Duration::from_millis(400));
        assert_eq!(snapshot(&session)["isActuallyPlaying"], true);
        command(&session, "skipNext", "skip", json!({}));
        let skipped = wait(&session, "skip", |s| {
            s["currentQueueItemId"] == "b" && s["isActuallyPlaying"] == true
        });
        assert_eq!(skipped["playbackEffects"]["normalizationActive"], true);
        command(&session, "seek", "tail", json!({"positionMs":"1700"}));
        let next = wait(&session, "natural tail", |s| {
            s["currentQueueItemId"] == "c" && s["isActuallyPlaying"] == true
        });
        assert_eq!(next["playbackEffects"]["normalizationActive"], false);
        assert_eq!(next["outputSettings"]["errorCode"], Value::Null);
        command(&session, "stop", "stop", json!({}));
        wait(&session, "fade then stop", |_| {
            diagnostics(&session)["output"]["running"] == false
        });
        session.shutdown();
    }
    fs::remove_file(path).unwrap();
}
