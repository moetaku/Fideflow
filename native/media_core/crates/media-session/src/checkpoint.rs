//! The session-side playback checkpoint (docs/design/restore.md).
//!
//! The session is the authoritative owner of the queue, the order it plays and
//! the position, so it is also the only writer of the restore record. This module
//! builds that record from the state the session already holds and writes it to
//! one file per account, atomically, so a crash mid-write cannot leave a half
//! record behind.
//!
//! The file is the same shape `packages/local_data` reads (`schemaVersion`,
//! `accountId`, `mode`, `shuffleSeed`, `currentIndex`, `positionMs`, `volume` and
//! the queue of stable track ids). The host re-resolves those ids on the next
//! launch; no URL, header or credential is ever written (architecture §7).

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::core::{Core, PlayMode};

/// The record schema version this build writes.
///
/// v2 records the *actual* play order and the identity of the current entry,
/// instead of a load order plus an effective-order slot. That makes a restore
/// reproduce a queue that was edited or entered into shuffle, and keeps a
/// duplicated track's two entries distinct. A v1 record is a version this build
/// deliberately does not migrate: it is treated as untrusted and restores nothing
/// (docs/design/restore.md).
pub const CHECKPOINT_SCHEMA_VERSION: u32 = 2;

/// The loudest the record may describe the gain, matching the schemas.
const MAX_VOLUME_PERMILLE: u32 = 1000;

/// How far the position must drift before a rewrite is worth the disk I/O.
///
/// Structural changes (queue, mode, seed, current item, volume) always write;
/// only the position is throttled, because it changes every tick.
const POSITION_STEP_MS: u64 = 3_000;

/// The account a record is filed under when a caller did not name one.
pub const GUEST_ACCOUNT: &str = "guest";

/// One entry of a restore record: a stable identity plus the track it plays.
///
/// The identity is what distinguishes two entries that carry the same track, so a
/// duplicated track comes back as two separate rows (docs/design/restore.md).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordItem {
    /// The session's own `queueItemId`.
    pub item_id: String,
    /// The stable track id the entry plays.
    pub track_id: String,
}

/// One restore record, before it is given an account and serialized.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Record {
    /// The queue's entries, in the order they actually play.
    pub items: Vec<RecordItem>,
    /// The identity of the entry that was playing.
    pub current_item_id: String,
    /// How far into the current item playback had reached.
    pub position_ms: u64,
    /// The mode in effect.
    pub mode: PlayMode,
    /// The seed a seeded load used, or `None` when the order is not reproducible
    /// from one. Informational in v2; the recorded order is what restores.
    pub shuffle_seed: Option<u64>,
    /// The gain in effect, as a permille of full scale.
    pub volume: u32,
}

/// Builds the record from the authoritative state, or `None` when the queue is
/// empty and there is nothing to describe.
///
/// The seed is claimed only when the shuffle order came from a *seeded load*: a
/// shuffle entered mid-playback pins the current item, and an edit reorders the
/// permutation, so neither can be rebuilt from the seed alone (docs/design/playback.md). The
/// queue is always the load order, because that is what a seeded replay feeds
/// back to the session.
#[must_use]
pub fn record(core: &Core, position_ms: u64) -> Option<Record> {
    if core.queue.is_empty() {
        return None;
    }
    // The effective order is what the user heard, so that is what is written:
    // feeding it back rebuilds the exact queue, including an edit's order and a
    // shuffle entered mid-playback (docs/design/restore.md).
    let items: Vec<RecordItem> = core
        .play_order()
        .iter()
        .filter_map(|index| core.queue.get(*index))
        .map(|item| RecordItem {
            item_id: item.queue_item_id.clone(),
            track_id: item.track_id.clone(),
        })
        .collect();
    if items.is_empty() {
        return None;
    }
    let current_item_id = core.current_item().map_or_else(
        || items[0].item_id.clone(),
        |item| item.queue_item_id.clone(),
    );
    let shuffle_seed = if core.mode == PlayMode::Shuffle && core.shuffle_seeded {
        Some(core.shuffle_seed)
    } else {
        None
    };
    Some(Record {
        items,
        current_item_id,
        position_ms,
        mode: core.mode,
        shuffle_seed,
        volume: core.volume_permille,
    })
}

/// The file that holds `account`'s record under `directory`.
///
/// One place builds the name, so the writer and the reader cannot disagree about
/// which file a record lives in.
fn record_path(directory: &Path, account: &str) -> PathBuf {
    let account = if account.is_empty() {
        GUEST_ACCOUNT
    } else {
        account
    };
    directory.join(format!("playback-{}.json", safe_account(account)))
}

/// Reads the record `directory` holds for `account`, or `None` when there is none
/// or it cannot be trusted.
///
/// Corruption is not an error: a launch that refuses to start over a bad record
/// is worse than one that starts with an empty queue, so anything this build
/// cannot read restores nothing at all - another version, a bad mode, or an index
/// past the end of the queue (docs/design/restore.md). The reader is deliberately as tolerant as
/// the Dart one, because either may be reading a file the other wrote.
/// The outcome of reading `account`'s record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReadOutcome {
    /// There is no record file.
    Missing,
    /// A file exists but this build cannot trust it: a version it does not know
    /// (including a v1 record it deliberately does not migrate), a corrupt field,
    /// or an identity that does not line up.
    Invalid,
    /// A record this build understands.
    Found(Box<Record>),
}

/// Reads the record `directory` holds for `account`.
///
/// Corruption is not an error: a launch that refuses to start over a bad record
/// is worse than one that starts with an empty queue, so a file this build cannot
/// read restores nothing at all (docs/design/restore.md). A v1 record is reported as
/// [`ReadOutcome::Invalid`]; v2 is the only shape this build restores.
#[must_use]
pub fn read(directory: &str, account: &str) -> ReadOutcome {
    let Ok(text) = fs::read_to_string(record_path(Path::new(directory), account)) else {
        return ReadOutcome::Missing;
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return ReadOutcome::Invalid;
    };
    match parse_record(&value) {
        Some(record) => ReadOutcome::Found(Box::new(record)),
        None => ReadOutcome::Invalid,
    }
}

/// Parses one stored object, or `None` when a field is missing or out of range.
fn parse_record(value: &Value) -> Option<Record> {
    let object = value.as_object()?;
    if object.get("schemaVersion").and_then(Value::as_u64)? != u64::from(CHECKPOINT_SCHEMA_VERSION)
    {
        return None;
    }
    let mut items = Vec::new();
    for entry in object.get("items")?.as_array()? {
        let item = entry.as_object()?;
        let item_id = item.get("itemId")?.as_str().filter(|id| !id.is_empty())?;
        let track_id = item.get("trackId")?.as_str().filter(|id| !id.is_empty())?;
        items.push(RecordItem {
            item_id: item_id.to_owned(),
            track_id: track_id.to_owned(),
        });
    }
    if items.is_empty() {
        return None;
    }
    // A duplicated identity would make the current entry ambiguous.
    for (index, item) in items.iter().enumerate() {
        if items[..index]
            .iter()
            .any(|other| other.item_id == item.item_id)
        {
            return None;
        }
    }
    let current_item_id = object.get("currentItemId")?.as_str()?;
    if !items.iter().any(|item| item.item_id == current_item_id) {
        return None;
    }
    let position_ms = object.get("positionMs")?.as_str()?.parse::<u64>().ok()?;
    let mode = PlayMode::from_str_code(object.get("mode")?.as_str()?)?;
    let shuffle_seed = match object.get("shuffleSeed") {
        None | Some(Value::Null) => None,
        Some(Value::String(seed)) => Some(seed.parse::<u64>().ok()?),
        Some(_) => return None,
    };
    let volume = u32::try_from(object.get("volume")?.as_u64()?).ok()?;
    if volume > MAX_VOLUME_PERMILLE {
        return None;
    }
    Some(Record {
        items,
        current_item_id: current_item_id.to_owned(),
        position_ms,
        mode,
        shuffle_seed,
        volume,
    })
}

/// Writes a record for one account, atomically, and throttles position-only
/// rewrites.
#[derive(Debug)]
pub struct CheckpointWriter {
    directory: PathBuf,
    account: String,
    last: Option<Record>,
}

impl CheckpointWriter {
    /// Creates a writer for `account` under `directory`.
    #[must_use]
    pub fn new(directory: impl Into<PathBuf>, account: &str) -> Self {
        let account = if account.is_empty() {
            String::from(GUEST_ACCOUNT)
        } else {
            account.to_owned()
        };
        Self {
            directory: directory.into(),
            account,
            last: None,
        }
    }

    /// The file this writer owns.
    #[must_use]
    pub fn path(&self) -> PathBuf {
        record_path(&self.directory, &self.account)
    }

    /// Writes when the record is worth a write, or clears the file when the queue
    /// is gone and something had been written before.
    ///
    /// Returns whether the store now reflects `record`, so a caller can record a
    /// failed write as a diagnostic instead of losing it silently.
    pub fn maybe_write(&mut self, record: Option<Record>) -> bool {
        match record {
            None => {
                if self.last.take().is_some() {
                    return fs::remove_file(self.path()).is_ok();
                }
                true
            }
            Some(record) => {
                if !self.changed(&record) {
                    return true;
                }
                if write_atomic(&self.path(), &self.json(&record)).is_ok() {
                    self.last = Some(record);
                    true
                } else {
                    false
                }
            }
        }
    }

    /// Writes `record` now, bypassing the position throttle.
    ///
    /// Used on shutdown, where the last position must reach disk even when it
    /// moved by less than [`POSITION_STEP_MS`] since the preceding write. Returns
    /// whether the write succeeded, so a caller can observe a failed flush.
    pub fn write_now(&mut self, record: Option<Record>) -> bool {
        match record {
            None => {
                if self.last.take().is_some() {
                    return self.clear();
                }
                true
            }
            Some(record) => {
                if write_atomic(&self.path(), &self.json(&record)).is_ok() {
                    self.last = Some(record);
                    true
                } else {
                    false
                }
            }
        }
    }

    /// Removes the file and forgets the last write.
    ///
    /// Returns whether the file is gone, treating "already absent" as success.
    pub fn clear(&mut self) -> bool {
        self.last = None;
        match fs::remove_file(self.path()) {
            Ok(()) => true,
            Err(error) => error.kind() == std::io::ErrorKind::NotFound,
        }
    }

    fn changed(&self, record: &Record) -> bool {
        match &self.last {
            None => true,
            Some(last) => {
                last.items != record.items
                    || last.current_item_id != record.current_item_id
                    || last.mode != record.mode
                    || last.shuffle_seed != record.shuffle_seed
                    || last.volume != record.volume
                    || record.position_ms.abs_diff(last.position_ms) >= POSITION_STEP_MS
            }
        }
    }

    fn json(&self, record: &Record) -> Value {
        let items: Vec<Value> = record
            .items
            .iter()
            .map(|item| json!({"itemId": item.item_id, "trackId": item.track_id}))
            .collect();
        json!({
            "schemaVersion": CHECKPOINT_SCHEMA_VERSION,
            "accountId": self.account,
            "mode": record.mode.as_str(),
            "shuffleSeed": record.shuffle_seed.map(|seed| seed.to_string()),
            "currentItemId": record.current_item_id,
            "positionMs": record.position_ms.to_string(),
            "volume": record.volume,
            "items": items,
        })
    }
}

/// Replaces anything outside `[A-Za-z0-9._-]`, so a provider id can never steer
/// the path a record is written to.
fn safe_account(account: &str) -> String {
    account
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

/// Writes `value` to `path` through a temporary file and a rename, so a reader
/// sees either the previous record or the new one, never a partial write.
fn write_atomic(path: &Path, value: &Value) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    let temp = parent.join(format!(".playback.{}.{}.tmp", std::process::id(), stamp));
    let mut file = fs::File::create(&temp)?;
    file.write_all(value.to_string().as_bytes())?;
    file.flush()?;
    drop(file);
    fs::rename(&temp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{CheckpointWriter, record, safe_account};
    use crate::core::{Core, PlayMode, QueueItem};
    use serde_json::{Value, json};
    use std::fs;
    use std::path::PathBuf;

    fn core_with(count: usize) -> Core {
        let mut core = Core::new(String::from("session-test"));
        core.queue = (1..=count)
            .map(|index| QueueItem::new(format!("item-{index}"), format!("track-{index}")))
            .collect();
        core.current = Some(0);
        core.queue_revision = 1;
        core
    }

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ff-checkpoint-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |duration| duration.as_nanos())
        ));
        fs::create_dir_all(&dir).expect("a temporary directory");
        dir
    }

    #[test]
    fn an_empty_queue_has_no_record() {
        let core = Core::new(String::from("session-test"));
        assert!(record(&core, 0).is_none());
    }

    #[test]
    fn a_list_loop_record_carries_the_play_order_and_no_seed() {
        let core = core_with(3);
        let built = record(&core, 1500).expect("a record");
        assert_eq!(
            built
                .items
                .iter()
                .map(|item| item.track_id.as_str())
                .collect::<Vec<_>>(),
            vec!["track-1", "track-2", "track-3"]
        );
        assert_eq!(built.current_item_id, "item-1");
        assert_eq!(built.position_ms, 1500);
        assert_eq!(built.mode, PlayMode::ListLoop);
        assert_eq!(built.shuffle_seed, None);
        assert_eq!(built.volume, core.volume_permille);
    }

    #[test]
    fn a_seeded_load_claims_its_seed_and_the_current_entry_identity() {
        let mut core = core_with(4);
        core.mode = PlayMode::Shuffle;
        core.start_shuffle_from_seed(42);
        core.current = Some(2);
        core.shuffle_order = vec![1, 2, 0, 3];
        let built = record(&core, 0).expect("a record");
        assert_eq!(
            built.shuffle_seed,
            Some(42),
            "a seeded load is reproducible from its seed"
        );
        assert_eq!(
            built
                .items
                .iter()
                .map(|item| item.track_id.as_str())
                .collect::<Vec<_>>(),
            vec!["track-2", "track-3", "track-1", "track-4"],
            "the record keeps the order the user actually heard"
        );
        assert_eq!(
            built.current_item_id, "item-3",
            "the current entry is addressed by identity, not a slot"
        );
    }

    #[test]
    fn a_pinned_shuffle_does_not_claim_a_seed() {
        let mut core = core_with(3);
        core.mode = PlayMode::Shuffle;
        // `rebuild_shuffle` is what a mid-playback mode change uses: it pins the
        // current item, which a seed over the load order cannot reproduce.
        core.rebuild_shuffle(7);
        assert!(!core.shuffle_seeded);
        assert_eq!(record(&core, 0).expect("a record").shuffle_seed, None);
    }

    #[test]
    fn the_json_matches_the_record_shape_local_data_reads() {
        let mut core = core_with(2);
        core.mode = PlayMode::Shuffle;
        core.start_shuffle_from_seed(99);
        let built = record(&core, 42).expect("a record");
        let writer = CheckpointWriter::new("/tmp", "ncm-user-1");
        let json = writer.json(&built);
        assert_eq!(json["schemaVersion"], 2);
        assert_eq!(json["accountId"], "ncm-user-1");
        assert_eq!(json["mode"], "shuffle");
        assert_eq!(json["shuffleSeed"], "99");
        assert_eq!(json["positionMs"], "42");
        assert_eq!(json["volume"], 800);
        assert!(json["currentItemId"].is_string());
        let items = json["items"].as_array().expect("items");
        assert_eq!(items.len(), 2);
        assert!(items[0]["itemId"].is_string());
        assert!(items[0]["trackId"].is_string());
    }

    #[test]
    fn a_null_seed_is_json_null_not_the_string_null() {
        let core = core_with(1);
        let writer = CheckpointWriter::new("/tmp", "guest");
        let json = writer.json(&record(&core, 0).expect("a record"));
        assert_eq!(json["shuffleSeed"], Value::Null);
    }

    #[test]
    fn writes_atomically_and_clears_when_the_queue_is_gone() {
        let dir = temp_dir("write");
        let mut writer = CheckpointWriter::new(&dir, "guest");
        writer.maybe_write(record(&core_with(2), 0));
        let text = fs::read_to_string(writer.path()).expect("the record was written");
        let json: Value = serde_json::from_str(&text).expect("valid JSON");
        assert_eq!(
            Value::Array(
                json["items"]
                    .as_array()
                    .expect("items")
                    .iter()
                    .map(|item| item["trackId"].clone())
                    .collect::<Vec<_>>()
            ),
            json!(["track-1", "track-2"])
        );

        writer.maybe_write(None);
        assert!(
            !writer.path().exists(),
            "a cleared queue removes the record"
        );

        // No queued write leaves no stray temporary file behind.
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .expect("the directory")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| {
                std::path::Path::new(name)
                    .extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("tmp"))
            })
            .collect();
        assert!(
            leftovers.is_empty(),
            "temporary files were left: {leftovers:?}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_position_only_drift_is_throttled_until_it_is_worth_it() {
        let dir = temp_dir("throttle");
        let mut writer = CheckpointWriter::new(&dir, "guest");
        let core = core_with(1);
        writer.maybe_write(record(&core, 0));
        let first = fs::read_to_string(writer.path()).expect("the first write");

        writer.maybe_write(record(&core, 1_000));
        assert_eq!(
            fs::read_to_string(writer.path()).expect("unchanged"),
            first,
            "a small drift does not rewrite"
        );

        writer.maybe_write(record(&core, 3_000));
        let rewritten = fs::read_to_string(writer.path()).expect("rewritten");
        assert_ne!(rewritten, first, "a three-second drift is worth a write");
        assert!(rewritten.contains("\"positionMs\":\"3000\""));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_now_bypasses_the_position_throttle() {
        let dir = temp_dir("flush");
        let mut writer = CheckpointWriter::new(&dir, "guest");
        let core = core_with(1);
        writer.maybe_write(record(&core, 0));
        // A drift below the throttle would normally be skipped; shutdown forces it.
        assert!(writer.write_now(record(&core, 1_500)));
        let text = fs::read_to_string(writer.path()).expect("flushed");
        assert!(text.contains("\"positionMs\":\"1500\""));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_account_with_path_characters_cannot_escape_the_directory() {
        assert_eq!(safe_account("../../etc/passwd"), ".._.._etc_passwd");
        assert_eq!(safe_account("ncm-user-1"), "ncm-user-1");
    }

    #[test]
    fn the_writer_uses_one_file_per_account() {
        let dir = temp_dir("accounts");
        let writer = CheckpointWriter::new(&dir, "ncm-user-1");
        assert_eq!(writer.path(), dir.join("playback-ncm-user-1.json"));
        let guest = CheckpointWriter::new(&dir, "");
        assert_eq!(guest.path(), dir.join("playback-guest.json"));
        let _ = fs::remove_dir_all(&dir);
    }
}
