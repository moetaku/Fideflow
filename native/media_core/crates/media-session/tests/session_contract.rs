//! Control-plane contract tests: the Phase 0 acceptance rules, now against the
//! real planner.
//!
//! These run without audio hardware: every command either rejects before any
//! source is resolved or fails cleanly on a source that cannot be opened, so the
//! suite is deterministic in CI.

use std::sync::{Arc, Mutex};

use fideflow_media_session::{Phase, PlaybackSession, PlaybackState, epoch_ms};
use serde_json::Value;

/// Builds a `loadQueue` command envelope.
fn load_queue(session_id: &str, command_id: &str, sources: &[&str], autoplay: bool) -> String {
    let items: Vec<String> = sources
        .iter()
        .enumerate()
        .map(|(index, source)| {
            format!(
                "{{\"queueItemId\":\"item-{}\",\"trackId\":\"track-{}\",\"sourceUri\":\"{source}\"}}",
                index + 1,
                index + 1
            )
        })
        .collect();
    format!(
        "{{\"schemaVersion\":1,\"kind\":\"loadQueue\",\"clientId\":\"test\",\"commandId\":\"{command_id}\",\
         \"targetSessionId\":\"{session_id}\",\"expectedQueueRevision\":\"0\",\
         \"payload\":{{\"items\":[{}],\"startItemId\":\"item-1\",\"autoplay\":{autoplay}}}}}",
        items.join(",")
    )
}

/// Sends a simple command with the required routing fields.
fn simple(session_id: &str, command_id: &str, kind: &str) -> String {
    format!(
        "{{\"schemaVersion\":1,\"kind\":\"{kind}\",\"clientId\":\"test\",\"commandId\":\"{command_id}\",\
         \"targetSessionId\":\"{session_id}\",\"payload\":{{}}}}"
    )
}

fn send_command(session: &PlaybackSession, command: &str) -> Value {
    serde_json::from_str(&session.execute_json(command)).expect("a result message")
}

fn read_snapshot(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.snapshot_json()).expect("a snapshot message")
}

#[test]
fn a_fresh_session_is_idle_and_reports_schema_shaped_state() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let snapshot = read_snapshot(&session);
    assert_eq!(snapshot["schemaVersion"], 1);
    assert_eq!(snapshot["kind"], "snapshot");
    assert_eq!(snapshot["phase"], "idle");
    assert_eq!(snapshot["playWhenReady"], false);
    assert_eq!(snapshot["buffering"], false);
    assert_eq!(snapshot["isActuallyPlaying"], false);
    assert_eq!(snapshot["currentQueueItemId"], Value::Null);
    assert_eq!(snapshot["positionMs"], "0");
    assert_eq!(snapshot["durationMs"], Value::Null);
    assert_eq!(snapshot["suppressionReasons"], serde_json::json!([]));
    assert_eq!(session.state(), PlaybackState::Idle);
}

#[test]
fn play_without_a_queue_is_rejected_and_changes_nothing() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let reply = send_command(&session, &simple("session-test", "cmd-1", "play"));
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "emptyQueue");
    assert_eq!(read_snapshot(&session)["sessionRevision"], "0");
}

#[test]
fn commands_for_another_session_are_rejected() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let reply = send_command(&session, &simple("session-other", "cmd-1", "pause"));
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "sessionMismatch");
}

#[test]
fn unimplemented_kinds_and_schema_versions_are_rejected_by_code() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let reply = send_command(&session, &simple("session-test", "cmd-1", "setQuality"));
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "unsupportedCommand");

    let reply = send_command(
        &session,
        "{\"schemaVersion\":2,\"kind\":\"pause\",\"clientId\":\"test\",\"commandId\":\"cmd-2\",\
         \"targetSessionId\":\"session-test\",\"payload\":{}}",
    );
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "unsupportedSchemaVersion");

    let reply = send_command(&session, "{not json");
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "malformedCommand");
}

#[test]
fn load_queue_accepts_a_source_that_cannot_be_decoded_and_reports_the_failure() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let command = load_queue(
        "session-test",
        "cmd-1",
        &["file:///nonexistent/fideflow-missing.mp3"],
        true,
    );
    let reply = send_command(&session, &command);
    assert_eq!(reply["status"], "accepted");
    assert_eq!(reply["operationId"], "op-1");

    // The failure arrives asynchronously through the snapshot, not as a rejected
    // command: the control plane accepted a well-formed intent.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let snapshot = read_snapshot(&session);
        let phase = snapshot["phase"].as_str().unwrap_or_default();
        if phase == "error" {
            assert_eq!(snapshot["errorCode"], "sourceOpenFailed");
            assert_eq!(snapshot["playWhenReady"], false);
            break;
        }
        assert_ne!(phase, "ready", "a missing source must never report ready");
        assert!(
            std::time::Instant::now() < deadline,
            "the session never reported the decode failure"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(session.state(), PlaybackState::Error);
}

#[test]
fn a_repeated_command_id_returns_the_original_reply() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let command = load_queue(
        "session-test",
        "cmd-1",
        &["file:///nonexistent/a.mp3"],
        false,
    );
    let first = send_command(&session, &command);
    let revision_after_first = read_snapshot(&session)["queueRevision"]
        .as_str()
        .unwrap_or_default()
        .to_owned();

    // Same key, same payload: replayed, not re-executed. The queue revision is
    // the observable that answers this, because a second execution of `loadQueue`
    // would either advance it or be refused as stale. `sessionRevision` cannot be
    // used here: it also moves for the asynchronous failure of the missing source
    // (`load_queue_accepts_a_source_that_cannot_be_decoded_and_reports_the_failure`),
    // which is correct behaviour rather than evidence of a re-execution.
    let second = send_command(&session, &command);
    assert_eq!(first, second);
    let snapshot = read_snapshot(&session);
    assert_eq!(
        snapshot["queueRevision"], revision_after_first,
        "a replayed command must not reload the queue"
    );
    assert_eq!(snapshot["currentQueueItemId"], "item-1");

    // Same key, different payload: refused instead of applied.
    let different = load_queue(
        "session-test",
        "cmd-1",
        &["file:///nonexistent/b.mp3"],
        true,
    );
    let conflict = send_command(&session, &different);
    assert_eq!(conflict["status"], "rejected");
    assert_eq!(conflict["errorCode"], "idempotencyConflict");
}

#[test]
fn a_stale_queue_revision_is_rejected_with_the_current_one() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send_command(
        &session,
        &load_queue(
            "session-test",
            "cmd-1",
            &["file:///nonexistent/a.mp3"],
            false,
        ),
    );
    let skip =
        "{\"schemaVersion\":1,\"kind\":\"skipNext\",\"clientId\":\"test\",\"commandId\":\"cmd-2\",\
         \"targetSessionId\":\"session-test\",\"expectedQueueRevision\":\"0\",\
         \"targetQueueItemId\":\"item-1\",\"expectedGeneration\":\"1\",\"payload\":{}}"
            .to_string();
    let reply = send_command(&session, &skip);
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "staleQueueRevision");
    assert_eq!(reply["currentQueueRevision"], "1");
}

#[test]
fn seek_and_skip_require_the_current_item_and_generation() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send_command(
        &session,
        &load_queue(
            "session-test",
            "cmd-1",
            &["file:///nonexistent/a.mp3", "file:///nonexistent/b.mp3"],
            false,
        ),
    );
    // The right item but a stale generation: a delayed Seek must not reposition.
    let stale =
        "{\"schemaVersion\":1,\"kind\":\"seek\",\"clientId\":\"test\",\"commandId\":\"cmd-2\",\
         \"targetSessionId\":\"session-test\",\"targetQueueItemId\":\"item-1\",\
         \"expectedGeneration\":\"9\",\"payload\":{\"positionMs\":\"1000\"}}"
            .to_string();
    let reply = send_command(&session, &stale);
    assert_eq!(reply["errorCode"], "staleGeneration");

    // The right generation but the wrong item.
    let wrong_item =
        "{\"schemaVersion\":1,\"kind\":\"seek\",\"clientId\":\"test\",\"commandId\":\"cmd-3\",\
         \"targetSessionId\":\"session-test\",\"targetQueueItemId\":\"item-2\",\
         \"expectedGeneration\":\"1\",\"payload\":{\"positionMs\":\"1000\"}}"
            .to_string();
    let reply = send_command(&session, &wrong_item);
    assert_eq!(reply["errorCode"], "staleGeneration");
}

#[test]
fn skipping_at_a_queue_edge_wraps_in_the_default_mode() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send_command(
        &session,
        &load_queue(
            "session-test",
            "cmd-1",
            &["file:///nonexistent/a.mp3", "file:///nonexistent/b.mp3"],
            false,
        ),
    );
    // The default mode is `listLoop`, so the first item's "previous" is the last
    // item instead of a boundary the user has to understand.
    let previous = "{\"schemaVersion\":1,\"kind\":\"skipPrevious\",\"clientId\":\"test\",\"commandId\":\"cmd-2\",\
         \"targetSessionId\":\"session-test\",\"expectedQueueRevision\":\"1\",\
         \"targetQueueItemId\":\"item-1\",\"expectedGeneration\":\"1\",\"payload\":{}}".to_string();
    let reply = send_command(&session, &previous);
    assert_eq!(reply["status"], "accepted", "{reply}");
    assert_eq!(read_snapshot(&session)["currentQueueItemId"], "item-2");

    let next =
        "{\"schemaVersion\":1,\"kind\":\"skipNext\",\"clientId\":\"test\",\"commandId\":\"cmd-3\",\
         \"targetSessionId\":\"session-test\",\"expectedQueueRevision\":\"1\",\
         \"targetQueueItemId\":\"item-2\",\"expectedGeneration\":\"2\",\"payload\":{}}"
            .to_string();
    let reply = send_command(&session, &next);
    assert_eq!(reply["status"], "accepted");
    assert_eq!(reply["operationId"], "op-3");
    assert_eq!(read_snapshot(&session)["currentQueueItemId"], "item-1");
}

#[test]
fn attach_returns_a_baseline_and_detach_only_drops_the_subscriber() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let attachment: Value =
        serde_json::from_str(&session.attach("flutter-main")).expect("an attachment");
    assert_eq!(attachment["baseline"]["kind"], "snapshot");
    assert_eq!(attachment["baseline"]["sessionId"], "session-test");
    let connection_id = attachment["connectionId"]
        .as_str()
        .expect("a connection id")
        .to_owned();

    assert!(session.detach(&connection_id));
    assert!(!session.detach(&connection_id));
    assert_eq!(session.state(), PlaybackState::Idle);
}

#[test]
fn stop_keeps_the_queue_and_clears_the_play_intent() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send_command(
        &session,
        &load_queue(
            "session-test",
            "cmd-1",
            &["file:///nonexistent/a.mp3"],
            true,
        ),
    );
    let reply = send_command(&session, &simple("session-test", "cmd-2", "stop"));
    assert_eq!(reply["status"], "accepted");
    let snapshot = read_snapshot(&session);
    assert_eq!(snapshot["phase"], "idle");
    assert_eq!(snapshot["playWhenReady"], false);
    assert_eq!(snapshot["currentQueueItemId"], "item-1");
    assert_eq!(snapshot["queueRevision"], "1");

    let reply = send_command(&session, &simple("session-test", "cmd-3", "clearQueue"));
    assert_eq!(reply["status"], "accepted");
    let snapshot = read_snapshot(&session);
    assert_eq!(snapshot["queueRevision"], "2");
    assert_eq!(snapshot["currentQueueItemId"], Value::Null);
}

#[test]
fn attach_and_diagnostics_never_expose_the_source() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let secret = "file:///Users/example/Secret%20Album/private-track.mp3";
    let _ = session.attach("flutter-main");
    send_command(
        &session,
        &load_queue("session-test", "cmd-1", &[secret], false),
    );
    std::thread::sleep(std::time::Duration::from_millis(50));

    let mut seen = String::new();
    seen.push_str(&session.snapshot_json());
    seen.push_str(&session.diagnostics_json());
    seen.push_str(&session.attach("flutter-main"));
    seen.push_str(&PlaybackSession::capabilities_json());
    assert!(
        !seen.contains("Secret") && !seen.contains("private-track") && !seen.contains("file://"),
        "no session message may carry a source URI or a local path"
    );
    assert!(
        !seen.contains("/Users/"),
        "no message may leak a local path"
    );
}

#[test]
fn capabilities_publish_the_frozen_phase_one_numbers() {
    let capabilities: Value =
        serde_json::from_str(&PlaybackSession::capabilities_json()).expect("capabilities JSON");
    assert_eq!(capabilities["schemaVersion"], 1);
    assert_eq!(capabilities["abiVersion"], 3);
    assert_eq!(capabilities["controlTransport"], "bytes+json");
    assert_eq!(capabilities["idempotencyWindow"], 1024);
    assert_eq!(capabilities["buffer"]["startWatermarkFrames"], 24_000);
    assert_eq!(capabilities["buffer"]["lowWatermarkFrames"], 12_000);
    assert_eq!(capabilities["buffer"]["highWatermarkFrames"], 72_000);
    assert_eq!(capabilities["buffer"]["ringCapacityFrames"], 84_000);
    assert_eq!(capabilities["buffer"]["pcmCapBytes"], 4_194_304);
    assert_eq!(capabilities["output"]["sampleRate"], 48_000);
    assert_eq!(capabilities["output"]["channels"], 2);
    assert_eq!(capabilities["decoder"]["resampler"], "soxr");
    assert_eq!(capabilities["sourceSchemes"][0], "file");
    // The modes this build can install, so a host offers exactly these.
    assert_eq!(
        capabilities["playbackModes"],
        serde_json::json!(["listLoop", "repeatOne", "shuffle", "sequential"])
    );
}

#[test]
fn the_publisher_emits_snapshots_to_the_registered_sink() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let count = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&count);
    session.set_event_sink(Some(Arc::new(move |_message: &str| {
        counter.fetch_add(1, Ordering::Relaxed);
    })));
    send_command(&session, &simple("session-test", "cmd-1", "stop"));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while count.load(Ordering::Relaxed) == 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(
        count.load(Ordering::Relaxed) > 0,
        "the publisher must emit a snapshot after a state change"
    );
    session.set_event_sink(None);
}

#[test]
fn a_rebuilt_session_starts_from_idle_with_a_fresh_identity() {
    let first = PlaybackSession::new();
    let second = PlaybackSession::new();
    assert_ne!(first.session_id(), second.session_id());
    assert_eq!(read_snapshot(&second)["phase"], "idle");
    assert_eq!(read_snapshot(&second)["sessionRevision"], "0");
    assert_eq!(second.state(), PlaybackState::Idle);
    // The Phase 1 phases map onto the coarse ABI enum without ambiguity.
    assert_eq!(Phase::Idle.as_str(), "idle");
    assert_eq!(Phase::Error.as_str(), "error");
}

/// Captures every event the session pushes, so a test can assert on the
/// `sourceRequest`s it produced.
fn capture_events(session: &PlaybackSession) -> Arc<Mutex<Vec<Value>>> {
    let events = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&events);
    session.set_event_sink(Some(Arc::new(move |doc: &str| {
        if let Ok(value) = serde_json::from_str::<Value>(doc) {
            captured.lock().unwrap().push(value);
        }
    })));
    events
}

/// The `sourceRequest`s captured so far for one queue item, in order.
fn source_requests(events: &Arc<Mutex<Vec<Value>>>, queue_item_id: &str) -> Vec<Value> {
    events
        .lock()
        .unwrap()
        .iter()
        .filter(|event| event["kind"] == "sourceRequest" && event["queueItemId"] == queue_item_id)
        .cloned()
        .collect()
}

/// The reason of the last request for one item, or an empty string.
fn last_reason(events: &Arc<Mutex<Vec<Value>>>, queue_item_id: &str) -> String {
    source_requests(events, queue_item_id)
        .last()
        .and_then(|event| event["reason"].as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// Builds a `provideSource` envelope. No `expectedGeneration` is sent: the field
/// is optional, and a test that installs a prefetch does not want the current-item
/// generation check to decide whether it lands.
fn provide_source(
    command_id: &str,
    queue_item_id: &str,
    source_uri: &str,
    expires_at_ms: Option<&Value>,
) -> String {
    let mut payload = serde_json::json!({ "sourceUri": source_uri });
    if let Some(expiry) = expires_at_ms {
        payload["expiresAtMs"] = expiry.clone();
    }
    serde_json::json!({
        "schemaVersion": 1,
        "kind": "provideSource",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": "session-test",
        "targetQueueItemId": queue_item_id,
        "payload": payload
    })
    .to_string()
}

/// Sends `playItem` for a row of the current queue, which is how a test reaches an
/// item the session has not played yet.
fn play_item(session: &PlaybackSession, command_id: &str, item_id: &str) -> Value {
    let command = serde_json::json!({
        "schemaVersion": 1,
        "kind": "playItem",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": "session-test",
        "expectedQueueRevision": "1",
        "targetQueueItemId": item_id,
        "payload": {}
    })
    .to_string();
    send_command(session, &command)
}

/// Waits until the session reports `phase`, or panics after a few seconds.
fn wait_for_phase(session: &PlaybackSession, phase: &str) -> Value {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let snapshot = read_snapshot(session);
        if snapshot["phase"] == phase {
            return snapshot;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the session never reached {phase}; last was {}",
            snapshot["phase"]
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

#[test]
fn an_expired_source_is_revoked_and_replaced_before_it_starts() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let events = capture_events(&session);

    let load = serde_json::json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": "cmd-1",
        "targetSessionId": "session-test",
        "expectedQueueRevision": "0",
        "payload": {
            "items": [
                { "queueItemId": "item-1", "trackId": "track-1" },
                { "queueItemId": "item-2", "trackId": "track-2" }
            ],
            "startItemId": "item-1",
            "autoplay": false
        }
    });
    assert_eq!(
        send_command(&session, &load.to_string())["status"],
        "accepted"
    );
    assert_eq!(
        last_reason(&events, "item-1"),
        "missing",
        "a queue item with no source at all says so"
    );

    // A prefetch whose lifetime runs out before the item is reached, inside the
    // safety margin: starting it would only fail a moment later.
    let expiry = Value::String((epoch_ms() + 1_000).to_string());
    let prefetch = provide_source(
        "cmd-2",
        "item-2",
        "file:///nonexistent/lapsed.mp3",
        Some(&expiry),
    );
    assert_eq!(send_command(&session, &prefetch)["status"], "accepted");

    // Reaching the item replaces the source instead of starting it.
    assert_eq!(play_item(&session, "cmd-3", "item-2")["status"], "accepted");
    let requests = source_requests(&events, "item-2");
    assert_eq!(
        requests.last().and_then(|event| event["reason"].as_str()),
        Some("expired"),
        "the lapsed source must be revoked and asked for again"
    );
    let snapshot = read_snapshot(&session);
    assert_eq!(snapshot["phase"], "resolving");
    assert_eq!(
        snapshot["errorCode"],
        Value::Null,
        "a lapsed source is replaced, not reported as a decode failure"
    );

    // A source the caller gave an expiry to, long in the future, is started as it
    // stands: no second request, and the failure (a missing file) is the file's.
    let future = Value::String((epoch_ms() + 3_600_000).to_string());
    let fresh = provide_source(
        "cmd-4",
        "item-2",
        "file:///nonexistent/fresh.mp3",
        Some(&future),
    );
    assert_eq!(send_command(&session, &fresh)["status"], "accepted");
    let snapshot = wait_for_phase(&session, "error");
    assert_eq!(snapshot["errorCode"], "sourceOpenFailed");
    assert_eq!(
        source_requests(&events, "item-2").len(),
        1,
        "a source with a known, future expiry must not be asked for again"
    );
}

#[test]
fn a_source_without_a_known_expiry_is_started_as_it_stands() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let events = capture_events(&session);

    let load = serde_json::json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": "cmd-1",
        "targetSessionId": "session-test",
        "expectedQueueRevision": "0",
        "payload": {
            "items": [
                { "queueItemId": "item-1", "trackId": "track-1" },
                { "queueItemId": "item-2", "trackId": "track-2" }
            ],
            "startItemId": "item-1",
            "autoplay": false
        }
    });
    assert_eq!(
        send_command(&session, &load.to_string())["status"],
        "accepted"
    );

    // An explicit `null` and an absent field both mean "no known expiry": a
    // `file:` source never lapses, and a provider that said nothing is not
    // guessed at (docs/design/provider.md).
    let explicit_null = provide_source(
        "cmd-2",
        "item-1",
        "file:///nonexistent/one.mp3",
        Some(&Value::Null),
    );
    assert_eq!(send_command(&session, &explicit_null)["status"], "accepted");
    let absent = provide_source("cmd-3", "item-2", "file:///nonexistent/two.mp3", None);
    assert_eq!(send_command(&session, &absent)["status"], "accepted");

    let snapshot = wait_for_phase(&session, "error");
    assert_eq!(
        snapshot["errorCode"], "sourceOpenFailed",
        "a source with no known expiry is opened as it stands"
    );
    assert_eq!(
        source_requests(&events, "item-1").len(),
        1,
        "the failure does not ask for a replacement on its own; a new play intent does"
    );
    assert_eq!(
        source_requests(&events, "item-2").len(),
        0,
        "an item the host already resolved is never asked for"
    );
}

#[test]
fn a_failed_source_is_revoked_and_its_replacement_budget_is_bounded() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let events = capture_events(&session);

    let load = serde_json::json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": "cmd-1",
        "targetSessionId": "session-test",
        "expectedQueueRevision": "0",
        "payload": {
            "items": [{ "queueItemId": "item-1", "trackId": "track-1" }],
            "startItemId": "item-1",
            "autoplay": false
        }
    });
    assert_eq!(
        send_command(&session, &load.to_string())["status"],
        "accepted"
    );

    // Three sources that cannot be opened. Each one is revoked when it fails, and
    // the retry that follows asks for a fresh one — which is the point: the session
    // must never read a URI it has already failed on.
    for attempt in 0..3 {
        let provide = provide_source(
            &format!("cmd-p{attempt}"),
            "item-1",
            &format!("file:///nonexistent/attempt-{attempt}.mp3"),
            None,
        );
        assert_eq!(
            send_command(&session, &provide)["status"],
            "accepted",
            "a replacement source is accepted"
        );
        assert_eq!(
            wait_for_phase(&session, "error")["errorCode"],
            "sourceOpenFailed"
        );
        // A new play intent retries the item through the host rather than the URL
        // that just failed.
        assert_eq!(
            send_command(
                &session,
                &simple("session-test", &format!("cmd-r{attempt}"), "play")
            )["status"],
            "accepted"
        );
    }

    let requests = source_requests(&events, "item-1");
    assert_eq!(
        requests
            .iter()
            .map(|event| event["reason"].as_str().unwrap_or_default())
            .collect::<Vec<_>>(),
        vec!["missing", "retry", "retry"],
        "each replacement after a failure says why it is needed"
    );
    // The budget is spent: the last play intent fails the item instead of asking a
    // host that has already answered three times.
    let snapshot = wait_for_phase(&session, "error");
    assert_eq!(snapshot["errorCode"], "sourceUnavailable");
    assert_eq!(source_requests(&events, "item-1").len(), 3);
}

#[test]
fn clear_queue_drops_the_queue_while_stop_keeps_it() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let load = load_queue(
        "session-test",
        "cmd-1",
        &["file:///nonexistent/a.mp3", "file:///nonexistent/b.mp3"],
        false,
    );
    assert_eq!(send_command(&session, &load)["status"], "accepted");
    let loaded_revision = read_snapshot(&session)["queueRevision"].clone();

    // Stopping keeps the queue: the items are still there to resume.
    assert_eq!(
        send_command(&session, &simple("session-test", "cmd-2", "stop"))["status"],
        "accepted"
    );
    let stopped = read_snapshot(&session);
    assert_eq!(stopped["phase"], "idle");
    assert_eq!(stopped["currentQueueItemId"], "item-1");
    assert_eq!(stopped["queueRevision"], loaded_revision);

    // Clearing drops it, and the revision that describes it moves: no item of the
    // old queue can be started again (docs/design/accounts.md).
    assert_eq!(
        send_command(&session, &simple("session-test", "cmd-3", "clearQueue"))["status"],
        "accepted"
    );
    let cleared = read_snapshot(&session);
    assert_eq!(cleared["phase"], "idle");
    assert_eq!(cleared["currentQueueItemId"], Value::Null);
    assert_eq!(cleared["effectiveOrder"], Value::Null);
    assert_ne!(cleared["queueRevision"], loaded_revision);
    assert_eq!(
        send_command(&session, &simple("session-test", "cmd-4", "play"))["errorCode"],
        "emptyQueue"
    );
}

#[test]
fn provide_source_fulfills_source_request_and_updates_queue_item() {
    use std::sync::{Arc, Mutex};
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let events = Arc::new(Mutex::new(Vec::new()));
    let events_captured = Arc::clone(&events);
    session.set_event_sink(Some(Arc::new(move |doc: &str| {
        events_captured.lock().unwrap().push(doc.to_string());
    })));

    let queue_payload = serde_json::json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": "cmd-1",
        "targetSessionId": "session-test",
        "expectedQueueRevision": "0",
        "payload": {
            "items": [
                { "queueItemId": "item-1", "trackId": "track-1" },
                { "queueItemId": "item-2", "trackId": "track-2" }
            ],
            "startItemId": "item-1",
            "autoplay": true
        }
    });
    let reply = send_command(&session, &queue_payload.to_string());
    assert_eq!(reply["status"], "accepted");

    let snap = read_snapshot(&session);
    assert_eq!(snap["phase"], "resolving");

    let captured = events.lock().unwrap();
    let source_req = captured.iter().find(|e| e.contains("sourceRequest"));
    assert!(source_req.is_some(), "Expected a sourceRequest event");

    let provide = serde_json::json!({
        "schemaVersion": 1,
        "kind": "provideSource",
        "clientId": "test",
        "commandId": "cmd-2",
        "targetSessionId": "session-test",
        "targetQueueItemId": "item-1",
        "expectedGeneration": "1",
        "payload": {
            "sourceUri": "file:///nonexistent/resolved.mp3"
        }
    });
    let reply = send_command(&session, &provide.to_string());
    assert_eq!(reply["status"], "accepted");
}

#[test]
fn a_revoked_prefetch_requests_a_new_source_when_skipped_to() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let events = capture_events(&session);
    let load = serde_json::json!({
        "schemaVersion": 1, "kind": "loadQueue", "clientId": "test",
        "commandId": "load", "targetSessionId": "session-test",
        "expectedQueueRevision": "0",
        "payload": {"items": [
            {"queueItemId": "item-1", "trackId": "track-1"},
            {"queueItemId": "item-2", "trackId": "track-2", "sourceUri": "https://cdn.test/standard.mp3"}
        ], "startItemId": "item-1", "autoplay": false}
    });
    assert_eq!(
        send_command(&session, &load.to_string())["status"],
        "accepted"
    );
    let revoke = serde_json::json!({
        "schemaVersion": 1, "kind": "provideSource", "clientId": "test",
        "commandId": "revoke", "targetSessionId": "session-test",
        "targetQueueItemId": "item-2", "payload": {"sourceUri": null}
    });
    assert_eq!(
        send_command(&session, &revoke.to_string())["status"],
        "accepted"
    );
    assert_eq!(read_snapshot(&session)["currentQueueItemId"], "item-1");
    let revision = read_snapshot(&session)["queueRevision"].clone();
    let skip = serde_json::json!({
        "schemaVersion": 1, "kind": "skipNext", "clientId": "test",
        "commandId": "next", "targetSessionId": "session-test",
        "expectedQueueRevision": revision, "payload": {}
    });
    assert_eq!(
        send_command(&session, &skip.to_string())["status"],
        "accepted"
    );
    assert_eq!(read_snapshot(&session)["currentQueueItemId"], "item-2");
    let requests = source_requests(&events, "item-2");
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["reason"], "missing");
}
