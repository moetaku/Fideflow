//! Session-side restore (docs/design/restore.md): the session reads its own record on launch and
//! rebuilds the queue, the order, the mode and the position without a client
//! replaying a single command.
//!
//! Like the other session tests these run without audio hardware. The sources are
//! `file:` URIs that cannot be opened, and every assertion is about the control
//! plane: what the session rebuilt, and what it published about it.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use fideflow_media_session::{PlaybackSession, RestoreOutcome};
use serde_json::{Value, json};

fn temp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ff-session-restore-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| duration.as_nanos())
    ));
    fs::create_dir_all(&dir).expect("a temporary directory");
    dir
}

fn load_queue(
    session_id: &str,
    command_id: &str,
    count: usize,
    seed: Option<u64>,
    revision: &str,
) -> String {
    let items: Vec<Value> = (1..=count)
        .map(|index| {
            json!({
                "queueItemId": format!("item-{index}"),
                "trackId": format!("track-{index}"),
                "sourceUri": format!("file:///nonexistent/{index}.mp3"),
            })
        })
        .collect();
    let mut payload = json!({
        "items": items,
        "startItemId": "item-1",
        "autoplay": false,
    });
    if let Some(seed) = seed {
        payload["seed"] = json!(seed.to_string());
    }
    json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": revision,
        "payload": payload,
    })
    .to_string()
}

fn set_mode(session_id: &str, command_id: &str, mode: &str, revision: &str) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": revision,
        "payload": {"mode": mode},
    })
    .to_string()
}

fn play_item(session_id: &str, command_id: &str, target: &str, revision: &str) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "playItem",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "targetQueueItemId": target,
        "expectedQueueRevision": revision,
        "payload": {},
    })
    .to_string()
}

fn send(session: &PlaybackSession, command: &str) -> Value {
    serde_json::from_str(&session.execute_json(command)).expect("a result message")
}

fn snapshot(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.snapshot_json()).expect("a snapshot document")
}

fn record_path(directory: &Path, account: &str) -> PathBuf {
    directory.join(format!("playback-{account}.json"))
}

/// Waits for the publisher to write the record, then returns it.
fn wait_for_record(directory: &Path, account: &str) -> Value {
    let path = record_path(directory, account);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Ok(text) = fs::read_to_string(&path) {
            return serde_json::from_str(&text).expect("a checkpoint document");
        }
        assert!(
            Instant::now() < deadline,
            "the session never wrote {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The track each queue item stands for, in the order the session will play them.
fn order_of_tracks(snapshot: &Value) -> Vec<String> {
    let identities: HashMap<&str, &str> = snapshot["queueItems"]
        .as_array()
        .expect("queueItems")
        .iter()
        .map(|item| {
            (
                item["queueItemId"].as_str().expect("a queueItemId"),
                item["trackId"].as_str().expect("a trackId"),
            )
        })
        .collect();
    snapshot["effectiveOrder"]
        .as_array()
        .expect("effectiveOrder")
        .iter()
        .map(|id| identities[id.as_str().expect("an id")].to_owned())
        .collect()
}

/// The track the session is on, or an empty string when it is on nothing.
fn current_track(snapshot: &Value) -> String {
    let current = snapshot["currentQueueItemId"].as_str().unwrap_or_default();
    snapshot["queueItems"]
        .as_array()
        .expect("queueItems")
        .iter()
        .find(|item| item["queueItemId"] == json!(current))
        .and_then(|item| item["trackId"].as_str())
        .unwrap_or_default()
        .to_owned()
}

fn write_record(directory: &Path, account: &str, record: &Value) {
    fs::write(record_path(directory, account), record.to_string()).expect("a written record");
}

#[test]
fn a_seeded_shuffle_restores_the_order_and_the_slot_it_was_hearing() {
    let directory = temp_dir("seeded");
    let path = directory.to_string_lossy().into_owned();

    // A first launch hears a seeded shuffle and moves to the third row.
    let first = PlaybackSession::with_session_id(String::from("session-first"));
    first.configure_checkpoint(&path, "guest");
    assert_eq!(
        send(&first, &set_mode("session-first", "cmd-1", "shuffle", "0"))["status"],
        "accepted"
    );
    assert_eq!(
        send(
            &first,
            &load_queue("session-first", "cmd-2", 5, Some(42), "1")
        )["status"],
        "accepted"
    );
    let heard = snapshot(&first);
    let third = heard["effectiveOrder"]
        .as_array()
        .expect("an order")
        .get(2)
        .expect("a third row")
        .as_str()
        .expect("an id")
        .to_owned();
    assert_eq!(
        send(&first, &play_item("session-first", "cmd-3", &third, "2"))["status"],
        "accepted"
    );
    let heard = snapshot(&first);
    let heard_order = order_of_tracks(&heard);
    let heard_track = current_track(&heard);
    assert!(!heard_track.is_empty(), "the first launch was on a track");
    first.shutdown();

    // The next launch restores itself: no command is replayed.
    let second = PlaybackSession::with_session_id(String::from("session-second"));
    second.configure_checkpoint(&path, "guest");
    assert_eq!(
        second.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored,
        "the record was restored"
    );
    let restored = snapshot(&second);
    assert_eq!(restored["mode"], "shuffle");
    assert_eq!(restored["shuffleSeed"], "42");
    assert_eq!(
        order_of_tracks(&restored),
        heard_order,
        "v2 keeps the order the user actually heard"
    );
    assert_eq!(
        current_track(&restored),
        heard_track,
        "the restore lands on the entry that was playing, not the permutation's head"
    );
    assert_eq!(
        restored["playWhenReady"], false,
        "a restore waits for the user, it does not make noise"
    );

    // Restoring twice is not a second queue: a live session wins over the file.
    assert_eq!(
        second.restore_checkpoint(&path, "guest"),
        RestoreOutcome::LiveQueuePresent,
        "a session that already holds a queue is left alone"
    );

    second.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_record_restores_duplicate_entries_and_an_edited_order() {
    let directory = temp_dir("dup");
    let path = directory.to_string_lossy().into_owned();
    // The order is deliberately not the load order, and track-b appears twice as
    // two distinct entries: the record must bring both back.
    write_record(
        &directory,
        "guest",
        &json!({
            "schemaVersion": 2,
            "accountId": "guest",
            "mode": "listLoop",
            "shuffleSeed": null,
            "currentItemId": "restored-2",
            "positionMs": "7000",
            "volume": 800,
            "items": [
                {"itemId": "restored-2", "trackId": "track-b"},
                {"itemId": "restored-0", "trackId": "track-a"},
                {"itemId": "restored-1", "trackId": "track-b"},
            ],
        }),
    );

    let session = PlaybackSession::with_session_id(String::from("session-dup"));
    assert_eq!(
        session.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored
    );
    let restored = snapshot(&session);
    assert_eq!(
        order_of_tracks(&restored),
        vec!["track-b", "track-a", "track-b"],
        "an edited order comes back exactly"
    );
    assert_eq!(
        restored["currentQueueItemId"], "restored-2",
        "the duplicated track is addressed by entry identity, not track id"
    );
    assert_eq!(
        restored["positionMs"], "7000",
        "the position follows the entry that was playing"
    );

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_no_seed_shuffle_keeps_the_playing_entry_and_its_progress() {
    let directory = temp_dir("noseed");
    let path = directory.to_string_lossy().into_owned();
    // A shuffle with no seed. v2 does not need one: the order is recorded, so the
    // playing entry and its position are preserved rather than mismatched (issue 4).
    write_record(
        &directory,
        "guest",
        &json!({
            "schemaVersion": 2,
            "accountId": "guest",
            "mode": "shuffle",
            "shuffleSeed": null,
            "currentItemId": "restored-1",
            "positionMs": "90000",
            "volume": 800,
            "items": [
                {"itemId": "restored-2", "trackId": "track-c"},
                {"itemId": "restored-1", "trackId": "track-b"},
                {"itemId": "restored-0", "trackId": "track-a"},
            ],
        }),
    );

    let session = PlaybackSession::with_session_id(String::from("session-noseed"));
    assert_eq!(
        session.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored
    );
    let restored = snapshot(&session);
    assert_eq!(restored["mode"], "shuffle");
    assert_eq!(
        current_track(&restored),
        "track-b",
        "the entry that was playing is the entry that comes back"
    );
    assert_eq!(restored["positionMs"], "90000");
    assert_eq!(
        order_of_tracks(&restored),
        vec!["track-c", "track-b", "track-a"]
    );

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_record_is_restored_as_a_paused_queue_with_its_row_position_and_volume() {
    let directory = temp_dir("row");
    let path = directory.to_string_lossy().into_owned();
    write_record(
        &directory,
        "guest",
        &json!({
            "schemaVersion": 2,
            "accountId": "guest",
            "mode": "repeatOne",
            "shuffleSeed": null,
            "currentItemId": "restored-2",
            "positionMs": "45000",
            "volume": 640,
            "items": [
                {"itemId": "restored-0", "trackId": "track-a"},
                {"itemId": "restored-1", "trackId": "track-b"},
                {"itemId": "restored-2", "trackId": "track-c"},
                {"itemId": "restored-3", "trackId": "track-d"},
            ],
        }),
    );

    let session = PlaybackSession::with_session_id(String::from("session-restore"));
    assert_eq!(
        session.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored
    );
    let restored = snapshot(&session);
    assert_eq!(restored["mode"], "repeatOne");
    assert_eq!(restored["queueRevision"], "1");
    assert_eq!(restored["playWhenReady"], false);
    assert_eq!(restored["volume"], 640);
    assert_eq!(restored["positionMs"], "45000");
    assert_eq!(
        order_of_tracks(&restored),
        vec!["track-a", "track-b", "track-c", "track-d"],
        "the queue comes back in its own order"
    );
    assert_eq!(
        current_track(&restored),
        "track-c",
        "the entry the user was on is the entry that comes back"
    );

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_missing_or_untrusted_record_restores_nothing() {
    let directory = temp_dir("corrupt");
    let path = directory.to_string_lossy().into_owned();

    // Absent.
    let session = PlaybackSession::with_session_id(String::from("session-nothing"));
    assert_eq!(
        session.restore_checkpoint(&path, "guest"),
        RestoreOutcome::NoCheckpoint
    );
    assert_eq!(snapshot(&session)["queueItems"], Value::Null);
    session.shutdown();

    // Unreadable: a v1 record, another version, an unknown mode, a bad identity
    // and a bad volume are all "no restorable record" rather than a launch that
    // refuses to start.
    for (label, record) in [
        (
            "v1",
            json!({"schemaVersion": 1, "accountId": "guest", "mode": "listLoop",
                   "shuffleSeed": null, "currentIndex": 0, "positionMs": "0",
                   "volume": 800, "queue": ["track-a"]}),
        ),
        (
            "version",
            json!({"schemaVersion": 99, "accountId": "guest", "mode": "listLoop",
                   "shuffleSeed": null, "currentItemId": "i", "positionMs": "0",
                   "volume": 800, "items": [{"itemId": "i", "trackId": "track-a"}]}),
        ),
        (
            "mode",
            json!({"schemaVersion": 2, "accountId": "guest", "mode": "shuffling",
                   "shuffleSeed": null, "currentItemId": "i", "positionMs": "0",
                   "volume": 800, "items": [{"itemId": "i", "trackId": "track-a"}]}),
        ),
        (
            "current identity",
            json!({"schemaVersion": 2, "accountId": "guest", "mode": "listLoop",
                   "shuffleSeed": null, "currentItemId": "gone", "positionMs": "0",
                   "volume": 800, "items": [{"itemId": "i", "trackId": "track-a"}]}),
        ),
        (
            "duplicate identity",
            json!({"schemaVersion": 2, "accountId": "guest", "mode": "listLoop",
                   "shuffleSeed": null, "currentItemId": "i", "positionMs": "0",
                   "volume": 800,
                   "items": [{"itemId": "i", "trackId": "track-a"},
                             {"itemId": "i", "trackId": "track-b"}]}),
        ),
        (
            "volume",
            json!({"schemaVersion": 2, "accountId": "guest", "mode": "listLoop",
                   "shuffleSeed": null, "currentItemId": "i", "positionMs": "0",
                   "volume": 5000, "items": [{"itemId": "i", "trackId": "track-a"}]}),
        ),
        (
            "empty queue",
            json!({"schemaVersion": 2, "accountId": "guest", "mode": "listLoop",
                   "shuffleSeed": null, "currentItemId": "", "positionMs": "0",
                   "volume": 800, "items": []}),
        ),
    ] {
        write_record(&directory, "guest", &record);
        let session = PlaybackSession::with_session_id(String::from("session-bad"));
        assert_eq!(
            session.restore_checkpoint(&path, "guest"),
            RestoreOutcome::InvalidCheckpoint,
            "{label} was restored"
        );
        assert_eq!(snapshot(&session)["queueItems"], Value::Null, "{label}");
        session.shutdown();
    }

    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_restore_keeps_being_written_so_another_launch_still_finds_it() {
    let directory = temp_dir("round-trip");
    let path = directory.to_string_lossy().into_owned();

    let first = PlaybackSession::with_session_id(String::from("session-one"));
    first.configure_checkpoint(&path, "guest");
    assert_eq!(
        send(&first, &set_mode("session-one", "cmd-1", "shuffle", "0"))["status"],
        "accepted"
    );
    assert_eq!(
        send(&first, &load_queue("session-one", "cmd-2", 4, Some(7), "1"))["status"],
        "accepted"
    );
    let heard = order_of_tracks(&snapshot(&first));
    first.shutdown();

    let second = PlaybackSession::with_session_id(String::from("session-two"));
    second.configure_checkpoint(&path, "guest");
    assert_eq!(
        second.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored
    );
    second.shutdown();

    // The restored session wrote a record of its own; a third launch replays it.
    let record = wait_for_record(&directory, "guest");
    assert_eq!(record["schemaVersion"], 2);
    let written: Vec<String> = record["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["trackId"].as_str().expect("a trackId").to_owned())
        .collect();
    assert_eq!(
        written, heard,
        "v2 writes the order that was heard, which the next launch replays"
    );

    let third = PlaybackSession::with_session_id(String::from("session-three"));
    third.configure_checkpoint(&path, "guest");
    assert_eq!(
        third.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored
    );
    assert_eq!(order_of_tracks(&snapshot(&third)), heard);
    third.shutdown();

    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_restored_queue_is_paused_and_plays_from_its_restore_point() {
    let directory = temp_dir("paused");
    let path = directory.to_string_lossy().into_owned();
    write_record(
        &directory,
        "guest",
        &json!({
            "schemaVersion": 2,
            "accountId": "guest",
            "mode": "listLoop",
            "shuffleSeed": null,
            "currentItemId": "restored-1",
            "positionMs": "45000",
            "volume": 1000,
            "items": [
                {"itemId": "restored-0", "trackId": "track-a"},
                {"itemId": "restored-1", "trackId": "track-b"},
            ],
        }),
    );

    let session = PlaybackSession::with_session_id(String::from("session-paused"));
    assert_eq!(
        session.restore_checkpoint(&path, "guest"),
        RestoreOutcome::Restored
    );

    // Nothing is prepared and nothing is asked for: the queue comes back paused,
    // on the entry it was on, holding the seconds it was at. A `resolving` phase
    // here would mean a source request had been sent, which a restore
    // deliberately does not do (docs/design/restore.md §7).
    let restored = snapshot(&session);
    assert_eq!(restored["phase"], "paused");
    assert_eq!(restored["playWhenReady"], false);
    assert_eq!(restored["positionMs"], "45000");
    assert_eq!(current_track(&restored), "track-b");

    // The user's play intent is what prepares it, from the restore point rather
    // than from the top of the track.
    let reply = send(
        &session,
        "{\"schemaVersion\":1,\"kind\":\"play\",\"clientId\":\"e2e\",\
          \"commandId\":\"cmd-play\",\"targetSessionId\":\"session-paused\",\
          \"payload\":{}}",
    );
    assert_eq!(reply["status"], "accepted");
    let playing = snapshot(&session);
    assert_eq!(playing["phase"], "resolving");
    assert_eq!(
        playing["positionMs"], "45000",
        "the restore point survives the delayed preparation"
    );
    assert_eq!(current_track(&playing), "track-b");

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}
