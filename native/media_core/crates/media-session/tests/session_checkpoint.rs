//! The session-side restore record (docs/design/restore.md): the session is the single writer of
//! the checkpoint file, so this drives the real session over the wire and reads
//! back what the publisher thread wrote.
//!
//! Like the other session tests these run without audio hardware: the sources are
//! `file:` URIs that cannot be opened, and every assertion is about the control
//! plane and the record it produces.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use fideflow_media_session::PlaybackSession;
use serde_json::{Value, json};

fn temp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ff-session-checkpoint-{label}-{}-{}",
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

fn set_volume(session_id: &str, command_id: &str, permille: u32) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "setVolume",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "payload": {"volume": permille},
    })
    .to_string()
}

fn clear_queue(session_id: &str, command_id: &str) -> String {
    json!({
        "schemaVersion": 1,
        "kind": "clearQueue",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "payload": {},
    })
    .to_string()
}

fn send(session: &PlaybackSession, command: &str) -> Value {
    serde_json::from_str(&session.execute_json(command)).expect("a result message")
}

/// The record file for one account in `directory`.
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

/// Waits until the record is gone, which is what a cleared queue produces.
fn wait_for_no_record(directory: &Path, account: &str) {
    let path = record_path(directory, account);
    let deadline = Instant::now() + Duration::from_secs(5);
    while path.exists() {
        assert!(
            Instant::now() < deadline,
            "the session left {} behind",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn a_loaded_queue_is_written_as_the_record_local_data_reads() {
    let directory = temp_dir("list-loop");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "guest");

    let reply = send(&session, &load_queue("session-test", "cmd-1", 3, None, "0"));
    assert_eq!(reply["status"], "accepted", "{reply}");

    let record = wait_for_record(&directory, "guest");
    assert_eq!(record["schemaVersion"], 2);
    assert_eq!(record["accountId"], "guest");
    assert_eq!(record["mode"], "listLoop");
    assert_eq!(record["shuffleSeed"], Value::Null);
    assert_eq!(record["currentItemId"], "item-1");
    assert!(record["currentItemId"].is_string());
    assert_eq!(record["positionMs"], "0");
    assert_eq!(record["volume"], 800);
    assert_eq!(
        record["items"]
            .as_array()
            .expect("items")
            .iter()
            .map(|item| item["trackId"].clone())
            .collect::<Vec<_>>(),
        vec![json!("track-1"), json!("track-2"), json!("track-3")]
    );

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_seeded_shuffle_is_written_with_its_seed_and_load_order() {
    let directory = temp_dir("seeded");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "ncm-user-1");

    assert_eq!(
        send(&session, &set_mode("session-test", "cmd-1", "shuffle", "0"))["status"],
        "accepted"
    );
    let reply = send(
        &session,
        &load_queue("session-test", "cmd-2", 4, Some(42), "1"),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");

    let record = wait_for_record(&directory, "ncm-user-1");
    assert_eq!(record["accountId"], "ncm-user-1");
    assert_eq!(record["mode"], "shuffle");
    assert_eq!(record["shuffleSeed"], "42");
    let mut tracks: Vec<Value> = record["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["trackId"].clone())
        .collect();
    tracks.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
    assert_eq!(
        tracks,
        vec![
            json!("track-1"),
            json!("track-2"),
            json!("track-3"),
            json!("track-4")
        ],
        "the record keeps the same tracks; v2 may permute them into play order"
    );

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_pinned_shuffle_does_not_claim_a_seed() {
    let directory = temp_dir("pinned");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "guest");

    // Load first, then enter shuffle: the mode change pins the current item, so
    // the seed alone cannot bring the order back.
    assert_eq!(
        send(&session, &load_queue("session-test", "cmd-1", 3, None, "0"))["status"],
        "accepted"
    );
    assert_eq!(
        send(&session, &set_mode("session-test", "cmd-2", "shuffle", "1"))["status"],
        "accepted"
    );

    // Give the publisher a moment to write the post-mode-change record.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let record = serde_json::from_str::<Value>(
            &fs::read_to_string(record_path(&directory, "guest")).unwrap_or_default(),
        )
        .unwrap_or(Value::Null);
        if record["mode"] == "shuffle" {
            assert_eq!(
                record["shuffleSeed"],
                Value::Null,
                "a pinned shuffle is not reproducible from a seed"
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the mode change was never written"
        );
        std::thread::sleep(Duration::from_millis(25));
    }

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn clearing_the_queue_removes_the_record() {
    let directory = temp_dir("clear");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "guest");

    send(&session, &load_queue("session-test", "cmd-1", 2, None, "0"));
    wait_for_record(&directory, "guest");

    assert_eq!(
        send(&session, &clear_queue("session-test", "cmd-2"))["status"],
        "accepted"
    );
    wait_for_no_record(&directory, "guest");

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn a_burst_of_rapid_writes_settles_on_the_newest_state() {
    let directory = temp_dir("burst");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "guest");

    send(&session, &load_queue("session-test", "cmd-1", 2, None, "0"));
    wait_for_record(&directory, "guest");

    // A tight burst of writes, far more than the persistence channel's capacity,
    // each replacing the last, and none of them flushed. Writes coalesce into one
    // slot instead of queueing, so the newest record must still reach disk — the
    // publisher never drops the latest state just because earlier ones are still
    // waiting (issue 5). The final volume is distinct from every earlier one, so
    // a record left over from an earlier write cannot pass.
    for index in 0..200u32 {
        let reply = send(
            &session,
            &set_volume("session-test", &format!("burst-{index}"), index % 900),
        );
        assert_eq!(reply["status"], "accepted", "{reply}");
    }
    assert_eq!(
        send(&session, &set_volume("session-test", "burst-last", 777))["status"],
        "accepted"
    );

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let record: Value = serde_json::from_str(
            &fs::read_to_string(record_path(&directory, "guest")).unwrap_or_default(),
        )
        .unwrap_or(Value::Null);
        if record["volume"] == 777 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the newest write never reached disk: {record}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }

    session.shutdown();
    let record: Value = serde_json::from_str(
        &fs::read_to_string(record_path(&directory, "guest")).expect("a record"),
    )
    .expect("a checkpoint document");
    assert_eq!(
        record["volume"], 777,
        "the last write is the one that survives"
    );

    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn shutting_down_flushes_the_last_position() {
    let directory = temp_dir("shutdown");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "guest");

    send(&session, &load_queue("session-test", "cmd-1", 2, None, "0"));
    // Shutdown writes the record itself, so this does not depend on the ticker.
    session.shutdown();

    let record: Value = serde_json::from_str(
        &fs::read_to_string(record_path(&directory, "guest")).expect("a flushed record"),
    )
    .expect("a checkpoint document");
    assert_eq!(
        record["items"]
            .as_array()
            .expect("items")
            .iter()
            .map(|item| item["trackId"].clone())
            .collect::<Vec<_>>(),
        vec![json!("track-1"), json!("track-2")]
    );
    assert_eq!(record["mode"], "listLoop");

    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn an_empty_directory_turns_the_writer_off() {
    let directory = temp_dir("off");
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    session.configure_checkpoint(&directory.to_string_lossy(), "guest");
    send(&session, &load_queue("session-test", "cmd-1", 2, None, "0"));
    wait_for_record(&directory, "guest");

    // Turning it off stops writing but keeps the record: an account switch uses
    // this to freeze the old account without deleting its queue (issue 8).
    session.configure_checkpoint("", "guest");
    assert!(
        record_path(&directory, "guest").exists(),
        "disabling the writer must not delete the record"
    );
    session.delete_checkpoint(&directory.to_string_lossy(), "guest");
    assert!(
        !record_path(&directory, "guest").exists(),
        "deleting removes the record explicitly"
    );

    session.shutdown();
    let _ = fs::remove_dir_all(&directory);
}
