//! Seeded-shuffle end-to-end regression (docs/design/playback.md): a seed travels through the
//! wire in `loadQueue`, decides the session's permutation *and* its opening track,
//! comes back in the snapshot, and — fed back in — replays the exact order it
//! described. The suite walks that path across the three modes and on the
//! empty-queue boundary, which is the state a restored session starts from.
//!
//! Like the other session tests these run without audio hardware: the sources are
//! `file:` URIs that cannot be opened, and every assertion is about the control
//! plane, which is decided before a decoder is involved.

use fideflow_media_session::PlaybackSession;
use serde_json::{Value, json};

/// A `loadQueue` envelope for `count` items, named to start on `start` and
/// optionally carrying a shuffle `seed`, checked against `revision`.
fn load_queue(
    session_id: &str,
    command_id: &str,
    count: usize,
    start: &str,
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
        "startItemId": start,
        "autoplay": true,
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

/// A `loadQueue` envelope with no items at all, optionally seeded. The schema
/// still requires a well-formed `startItemId`, so the empty boundary is a queue
/// fact rather than a parsing one.
fn load_empty(session_id: &str, command_id: &str, seed: Option<u64>, revision: &str) -> String {
    let mut payload = json!({
        "items": [],
        "startItemId": "item-1",
        "autoplay": true,
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

/// A `setMode` envelope, optionally pinning the shuffle seed, against `revision`.
fn set_mode(
    session_id: &str,
    command_id: &str,
    mode: &str,
    seed: Option<u64>,
    revision: &str,
) -> String {
    let payload = match seed {
        Some(seed) => json!({"mode": mode, "seed": seed.to_string()}),
        None => json!({"mode": mode}),
    };
    json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "test",
        "commandId": command_id,
        "targetSessionId": session_id,
        "expectedQueueRevision": revision,
        "payload": payload,
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

fn snapshot(session: &PlaybackSession) -> Value {
    serde_json::from_str(&session.snapshot_json()).expect("a snapshot message")
}

/// The `effectiveOrder` array of queue ids, or an empty vector when there is none.
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

/// The seed the snapshot publishes as the order in effect, or `None` when the
/// mode holds no seeded order.
fn published_seed(snapshot: &Value) -> Option<String> {
    snapshot["shuffleSeed"].as_str().map(str::to_owned)
}

/// A session in `mode` with a `count`-item queue loaded by a seeded load, so the
/// seed owns both the permutation and the item that is playing.
fn seeded_session(mode: &str, count: usize, seed: u64) -> PlaybackSession {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let reply = send(
        &session,
        &set_mode("session-test", "cmd-1", mode, None, "0"),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");
    let reply = send(
        &session,
        &load_queue("session-test", "cmd-2", count, "item-1", Some(seed), "1"),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");
    session
}

#[test]
fn a_seeded_shuffle_load_publishes_the_seed_that_owns_the_order() {
    let session = seeded_session("shuffle", 6, 7);
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["mode"], "shuffle");
    assert_eq!(
        published_seed(&snapshot),
        Some(String::from("7")),
        "a client can only persist an order it was told the seed of"
    );

    let ordered = order(&snapshot);
    assert_eq!(ordered.len(), 6, "the permutation covers the whole queue");
    let mut unique = ordered.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), 6, "a permutation repeats nothing");
    assert_eq!(
        snapshot["currentQueueItemId"], ordered[0],
        "the seed names the opener, not the item the caller listed"
    );
    assert_ne!(
        snapshot["currentQueueItemId"], "item-1",
        "seed 7 opens elsewhere, so the test would notice an unseeded head"
    );
}

#[test]
fn the_published_seed_replays_the_same_order_and_opener() {
    // What a session heard: an order and the seed that describes it.
    let heard = snapshot(&seeded_session("shuffle", 6, 7));
    let seed = published_seed(&heard).expect("a seeded order publishes its seed");
    let heard_order = order(&heard);
    let heard_current = heard["currentQueueItemId"].clone();

    // What a restore does: start a fresh session, put it in shuffle, and hand it
    // back the seed that was persisted — not the one the original caller chose.
    let restored = PlaybackSession::with_session_id(String::from("session-restored"));
    let reply = send(
        &restored,
        &set_mode("session-restored", "restore-1", "shuffle", None, "0"),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");
    let seed_number: u64 = seed.parse().expect("the seed is a decimal integer");
    let reply = send(
        &restored,
        &load_queue(
            "session-restored",
            "restore-2",
            6,
            "item-1",
            Some(seed_number),
            "1",
        ),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");

    let replayed = snapshot(&restored);
    assert_eq!(
        published_seed(&replayed),
        Some(seed.clone()),
        "the seed round-trips through the wire unchanged"
    );
    assert_eq!(
        order(&replayed),
        heard_order,
        "the same seed replays the permutation it described"
    );
    assert_eq!(
        replayed["currentQueueItemId"], heard_current,
        "and the opener it derived, so a restore resumes where it left off"
    );
}

#[test]
fn only_shuffle_lets_a_seed_order_the_queue() {
    // The two non-shuffle modes have no order for a seed to describe: the queue
    // keeps its own order and the named item stays the opener.
    for mode in ["listLoop", "repeatOne"] {
        let session = seeded_session(mode, 4, 7);
        let snapshot = snapshot(&session);
        assert_eq!(snapshot["mode"], mode);
        assert_eq!(
            published_seed(&snapshot),
            None,
            "a seed outside shuffle is not an order anyone can replay ({mode})"
        );
        assert_eq!(
            order(&snapshot),
            ["item-1", "item-2", "item-3", "item-4"],
            "the queue plays in the order it was loaded ({mode})"
        );
        assert_eq!(
            snapshot["currentQueueItemId"], "item-1",
            "only shuffle derives its opener from the seed ({mode})"
        );
    }
}

#[test]
fn shuffle_without_a_seed_still_starts_on_the_named_item() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(
        &session,
        &set_mode("session-test", "cmd-1", "shuffle", None, "0"),
    );
    let reply = send(
        &session,
        &load_queue("session-test", "cmd-2", 4, "item-3", None, "1"),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");

    let snapshot = snapshot(&session);
    assert_eq!(
        snapshot["currentQueueItemId"], "item-3",
        "a caller that named a row keeps that row"
    );
    assert_eq!(order(&snapshot)[0], "item-3");
    assert!(
        published_seed(&snapshot).is_some(),
        "the session derives a seed even when the caller did not pin one"
    );
}

#[test]
fn a_mode_change_can_pin_the_seed_it_shuffles_to() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(
        &session,
        &load_queue("session-test", "cmd-1", 5, "item-1", None, "0"),
    );
    let reply = send(
        &session,
        &set_mode("session-test", "cmd-2", "shuffle", Some(2026), "1"),
    );
    assert_eq!(reply["status"], "accepted", "{reply}");

    let snapshot = snapshot(&session);
    assert_eq!(published_seed(&snapshot), Some(String::from("2026")));
    assert_eq!(
        snapshot["currentQueueItemId"], "item-1",
        "entering shuffle keeps the item that is playing in place"
    );
}

#[test]
fn an_empty_session_publishes_no_seed() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["effectiveOrder"], Value::Null);
    assert_eq!(published_seed(&snapshot), None);
}

#[test]
fn a_seeded_load_on_an_empty_queue_is_refused() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(
        &session,
        &set_mode("session-test", "cmd-1", "shuffle", None, "0"),
    );
    let reply = send(&session, &load_empty("session-test", "cmd-2", Some(7), "1"));
    assert_eq!(reply["status"], "rejected");
    assert_eq!(reply["errorCode"], "emptyQueue");

    // The refusal is a queue fact, not partial state: nothing was installed.
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["effectiveOrder"], Value::Null);
    assert_eq!(
        snapshot["queueRevision"], "1",
        "only the mode change moved it"
    );
}

#[test]
fn a_seeded_load_still_has_to_name_one_of_its_items() {
    let session = PlaybackSession::with_session_id(String::from("session-test"));
    send(
        &session,
        &set_mode("session-test", "cmd-1", "shuffle", None, "0"),
    );
    let reply = send(
        &session,
        &load_queue("session-test", "cmd-2", 3, "item-9", Some(7), "1"),
    );
    assert_eq!(reply["status"], "rejected");
    assert_eq!(
        reply["errorCode"], "unknownStartItem",
        "the field stays well-formed even when the seed decides the head"
    );
    assert_eq!(snapshot(&session)["effectiveOrder"], Value::Null);
}

#[test]
fn clearing_the_queue_drops_the_seed_with_it() {
    let session = seeded_session("shuffle", 4, 7);
    assert!(published_seed(&snapshot(&session)).is_some());

    send(&session, &clear_queue("session-test", "cmd-3"));
    let snapshot = snapshot(&session);
    assert_eq!(snapshot["effectiveOrder"], Value::Null);
    assert_eq!(
        published_seed(&snapshot),
        None,
        "no item is left for a permutation to describe"
    );
}
