//! Queue edit contract: `playNext`, `append` and `remove` change the queue
//! without replacing it, address entries by identity, and keep the current item
//! (docs/design/playback.md).
//!
//! Like the other session tests these run without audio hardware: the sources
//! are `file:` URIs that cannot be opened, and every assertion is about the
//! control plane, which is decided before a decoder is involved.

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

/// An `editQueue` envelope carrying new entries for `playNext` or `append`.
fn insert(
    session_id: &str,
    command_id: &str,
    operation: &str,
    queue_revision: &str,
    items: &[(&str, &str)],
) -> String {
    let items: Vec<Value> = items
        .iter()
        .map(|(queue_item_id, track_id)| {
            json!({
                "queueItemId": queue_item_id,
                "trackId": track_id,
                "sourceUri": format!("file:///nonexistent/{queue_item_id}.mp3"),
            })
        })
        .collect();
    json!({
        "schemaVersion": 1,
        "kind": "editQueue",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": queue_revision,
        "payload": {"operation": operation, "items": items},
    })
    .to_string()
}

/// An `editQueue` envelope that drops one entry by identity.
fn remove(session_id: &str, command_id: &str, queue_revision: &str, item: &str) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "editQueue",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": queue_revision,
        "targetQueueItemId": item,
        "payload": {"operation": "remove"},
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
fn play_next_inserts_after_the_current_item() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 3, true));
    let reply = send(
        &session,
        &insert(
            "session-test",
            "cmd-2",
            "playNext",
            "1",
            &[("item-9", "track-9")],
        ),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");

    let snapshot = snapshot(&session);
    assert_eq!(
        order(&snapshot),
        ["item-1", "item-9", "item-2", "item-3"],
        "the new entry plays immediately after the current one"
    );
    assert_eq!(
        snapshot["currentQueueItemId"], "item-1",
        "an insert does not move the current item"
    );
    assert_eq!(snapshot["queueRevision"], "2");
}

#[test]
fn append_adds_at_the_end() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 2, true));
    let reply = send(
        &session,
        &insert(
            "session-test",
            "cmd-2",
            "append",
            "1",
            &[("item-8", "track-8"), ("item-9", "track-9")],
        ),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(order(&snapshot), ["item-1", "item-2", "item-8", "item-9"]);
    assert_eq!(snapshot["currentQueueItemId"], "item-1");
    assert_eq!(snapshot["queueRevision"], "2");
}

#[test]
fn removing_a_non_current_entry_keeps_the_current_item() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 3, true));
    let reply = send(&session, &remove("session-test", "cmd-2", "1", "item-2"));
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(order(&snapshot), ["item-1", "item-3"]);
    assert_eq!(snapshot["currentQueueItemId"], "item-1");
    assert_eq!(snapshot["queueRevision"], "2");
}

#[test]
fn removing_the_current_entry_advances_and_keeps_playing() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 3, true));
    let reply = send(&session, &remove("session-test", "cmd-2", "1", "item-1"));
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(order(&snapshot), ["item-2", "item-3"]);
    assert_eq!(
        snapshot["currentQueueItemId"], "item-2",
        "the successor becomes the current item"
    );
}

#[test]
fn remove_addresses_a_duplicated_track_by_identity() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    // Two entries for the same track, each with its own queue identity.
    let items = json!([
        {"queueItemId": "item-1", "trackId": "track-1", "sourceUri": "file:///a.mp3"},
        {"queueItemId": "item-2", "trackId": "track-1", "sourceUri": "file:///b.mp3"},
    ]);
    let load = json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": "cmd-1",
        "targetSessionId": "session-test",
        "expectedQueueRevision": "0",
        "payload": {"items": items, "startItemId": "item-1", "autoplay": false},
    })
    .to_string();
    send(&session, &load);

    let reply = send(&session, &remove("session-test", "cmd-2", "1", "item-1"));
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(
        order(&snapshot),
        ["item-2"],
        "the second entry of the duplicated track survives"
    );
    assert_eq!(snapshot["currentQueueItemId"], "item-2");
}

#[test]
fn removing_the_current_entry_under_repeat_one_advances() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 3, true));
    send(
        &session,
        &set_mode("session-test", "cmd-2", "repeatOne", "1"),
    );
    let reply = send(&session, &remove("session-test", "cmd-3", "2", "item-1"));
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(
        snapshot["currentQueueItemId"], "item-2",
        "repeatOne must not repeat the entry that was removed"
    );
}

#[test]
fn play_next_under_shuffle_places_the_new_entry_next() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 4, true));
    send(&session, &set_mode("session-test", "cmd-2", "shuffle", "1"));
    let before = snapshot(&session);
    assert_eq!(before["currentQueueItemId"], "item-1");

    let reply = send(
        &session,
        &insert(
            "session-test",
            "cmd-3",
            "playNext",
            "2",
            &[("item-9", "track-9")],
        ),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");
    let after = snapshot(&session);
    let shuffled = order(&after);
    assert_eq!(shuffled.len(), 5, "the order covers the whole queue");
    assert_eq!(shuffled[0], "item-1", "the current item stays in place");
    assert_eq!(
        shuffled[1], "item-9",
        "the new entry is next in the effective order, not merely next by index"
    );
    assert_eq!(after["currentQueueItemId"], "item-1");
    assert_eq!(after["queueRevision"], "3");
}

#[test]
fn editing_an_empty_queue_installs_and_starts_it() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let reply = send(
        &session,
        &insert(
            "session-test",
            "cmd-1",
            "playNext",
            "0",
            &[("item-1", "track-1"), ("item-2", "track-2")],
        ),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(order(&snapshot), ["item-1", "item-2"]);
    assert_eq!(snapshot["currentQueueItemId"], "item-1");
    assert_eq!(snapshot["queueRevision"], "1");
}

#[test]
fn removing_the_only_entry_stops_like_clear_queue() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 1, true));
    let reply = send(&session, &remove("session-test", "cmd-2", "1", "item-1"));
    assert_eq!(reply["status"], "accepted", "{reply}");
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["effectiveOrder"], Value::Null);
    assert_eq!(snapshot["currentQueueItemId"], Value::Null);
    assert_eq!(snapshot["phase"], "idle");
    assert_eq!(snapshot["playWhenReady"], false);
    assert_eq!(snapshot["queueRevision"], "2");
}

#[test]
fn an_edit_written_against_an_old_revision_is_refused() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 3, true));
    let reply = send(
        &session,
        &insert(
            "session-test",
            "cmd-2",
            "append",
            "0",
            &[("item-9", "track-9")],
        ),
    );
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "staleQueueRevision");
    assert_eq!(reply["currentQueueRevision"], "1");
    assert_eq!(order(&snapshot(&session)), ["item-1", "item-2", "item-3"]);
}

#[test]
fn an_edit_naming_an_unknown_entry_is_refused() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(&session, &load_queue("session-test", "cmd-1", 2, true));
    let reply = send(&session, &remove("session-test", "cmd-2", "1", "item-99"));
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "unknownQueueItem");
    assert_eq!(order(&snapshot(&session)), ["item-1", "item-2"]);
}
