//! Playback-mode contract: the wire says which mode is installed and which order
//! the queue will play, so a client renders the queue instead of computing it.
//!
//! Like `session_contract`, these run without audio hardware: the sources are
//! `file:` URIs that cannot be opened, and every assertion is about the control
//! plane, which is decided before any decoder is involved.

use fideflow_media_session::PlaybackSession;
use serde_json::{Value, json};

/// A `loadQueue` envelope for `count` items, starting on the first.
fn load_queue(session_id: &str, command_id: &str, count: usize, autoplay: bool) -> String {
    let items: Vec<Value> = (1..=count)
        .map(|index| {
            json!({
                "queueItemId": format!("item-{index}"),
                "trackId": format!("track-{index}"),
                "sourceUri": format!("file:///nonexistent/{index}.mp3"),
            })
        })
        .collect();
    json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": "0",
        "payload": {
            "items": items,
            "startItemId": "item-1",
            "autoplay": autoplay,
        },
    })
    .to_string()
}

/// A `setMode` envelope against the revision the caller believes is current.
fn set_mode(session_id: &str, command_id: &str, mode: &str, queue_revision: &str) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": queue_revision,
        "payload": {"mode": mode, "seed": "99"},
    })
    .to_string()
}

/// A `playItem` envelope for one queue entry.
fn play_item(session_id: &str, command_id: &str, item: &str, queue_revision: &str) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "playItem",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": queue_revision,
        "targetQueueItemId": item,
        "payload": {},
    })
    .to_string()
}

fn send(session: &PlaybackSession, command: &str) -> Value {
    serde_json::from_str(&session.execute_json(command)).expect("a result message")
}

fn snapshot(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.snapshot_json()).expect("a snapshot message")
}

/// The `effectiveOrder` array, or an empty vector when the queue is empty.
fn order(snapshot: &Value) -> Vec<String> {
    snapshot["effectiveOrder"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn a_session_without_a_queue_reports_the_default_mode() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["mode"], "listLoop");
    assert_eq!(snapshot["effectiveOrder"], Value::Null);
}

#[test]
fn a_loaded_queue_reports_its_own_order() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let reply = send(&session, &load_queue("session-test", "cmd-1", 3, false));
    assert_eq!(reply["status"], "accepted");
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["mode"], "listLoop");
    assert_eq!(order(&snapshot), ["item-1", "item-2", "item-3"]);
    assert_eq!(snapshot["currentQueueItemId"], "item-1");
}

#[test]
fn shuffle_publishes_a_permutation_and_bumps_the_queue_revision() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 4, false));
    let before = snapshot(&session);
    assert_eq!(before["queueRevision"], "1");

    let reply = send(&session, &set_mode("session-test", "cmd-2", "shuffle", "1"));
    assert_eq!(reply["status"], "accepted", "{reply}");

    let after = snapshot(&session);
    assert_eq!(after["mode"], "shuffle");
    assert_eq!(after["queueRevision"], "2");
    // The item that was playing stays the item that is playing.
    assert_eq!(after["currentQueueItemId"], "item-1");
    let mut shuffled = order(&after);
    assert_eq!(shuffled.len(), 4, "the order covers the whole queue");
    assert_eq!(shuffled[0], "item-1");
    shuffled.sort();
    assert_eq!(shuffled, ["item-1", "item-2", "item-3", "item-4"]);

    // Leaving shuffle restores the queue's own order.
    let reply = send(
        &session,
        &set_mode("session-test", "cmd-3", "listLoop", "2"),
    );
    assert_eq!(reply["status"], "accepted");
    let restored = snapshot(&session);
    assert_eq!(order(&restored), ["item-1", "item-2", "item-3", "item-4"]);
    assert_eq!(restored["queueRevision"], "3");
}

#[test]
fn a_mode_command_written_against_an_old_revision_is_refused() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 3, false));
    send(&session, &set_mode("session-test", "cmd-2", "shuffle", "1"));

    let reply = send(
        &session,
        &set_mode("session-test", "cmd-3", "repeatOne", "1"),
    );
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "staleQueueRevision");
    assert_eq!(reply["currentQueueRevision"], "2");
    assert_eq!(snapshot(&session)["mode"], "shuffle");
}

#[test]
fn a_mode_name_this_build_does_not_know_is_refused() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 2, false));
    let command = json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "test",
        "commandId": "cmd-2",
        "targetSessionId": "session-test",
        "expectedQueueRevision": "1",
        "payload": {"mode": "unknown-mode"},
    })
    .to_string();
    let reply = send(&session, &command);
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "malformedCommand");
    assert_eq!(snapshot(&session)["mode"], "listLoop");
}

#[test]
fn jumping_to_a_queue_entry_moves_the_current_item_and_keeps_the_order() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    // Leave source resolution pending: an invalid file can fail on the decode
    // worker before the snapshot, clearing play intent for an unrelated reason.
    let mut load: Value =
        serde_json::from_str(&load_queue("session-test", "cmd-1", 4, false)).unwrap();
    for item in load["payload"]["items"].as_array_mut().unwrap() {
        item.as_object_mut().unwrap().remove("sourceUri");
    }
    send(&session, &load.to_string());
    send(&session, &set_mode("session-test", "cmd-2", "shuffle", "1"));
    let shuffled = snapshot(&session);
    let ordered = order(&shuffled);
    let target = ordered.last().expect("four items").clone();

    let reply = send(&session, &play_item("session-test", "cmd-3", &target, "2"));
    assert_eq!(reply["status"], "accepted", "{reply}");
    let after = snapshot(&session);
    assert_eq!(after["currentQueueItemId"], target.clone());
    assert_eq!(
        after["playWhenReady"], true,
        "choosing a row is an explicit request to hear it"
    );
    assert_eq!(
        order(&after),
        ordered,
        "a jump is a current-item action: the order is untouched"
    );
    assert_eq!(
        after["queueRevision"], "2",
        "and so is the revision that describes the queue"
    );

    let reply = send(
        &session,
        &play_item("session-test", "cmd-4", "item-99", "2"),
    );
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "unknownQueueItem");
    assert_eq!(snapshot(&session)["currentQueueItemId"], target);
}
