#![forbid(unsafe_code)]

//! Authoritative playback control plane for the `Fideflow` native host.
//!
//! Phase 1 turns the Phase 0 skeleton into a real session: it owns the queue, the
//! play intent, the generation that invalidates stale asynchronous work and the
//! position clock, and it drives the `media-pipeline` decode worker and the
//! `media-output` device on top of that.
//!
//! Threading model, fixed by docs/design/playback.md and restated here because every lock in this
//! crate depends on it:
//!
//! * **Executor** - whoever calls [`PlaybackSession::execute_json`]. Commands are
//!   serialized by one mutex, never wait for decoding, and return
//!   accepted/rejected.
//! * **Decode worker** - one thread per queue item, cancelled through a per-item
//!   atomic and joined when the item changes.
//! * **Publisher** - one ticker thread per session; it is the *only* thread that
//!   calls the event sink, and it also detects underruns, natural end and item
//!   transitions.
//! * **Audio callback** - owned by `Core Audio`. It touches the lock-free PCM ring
//!   and atomics only: no allocation, no locking, no I/O.
//!
//! Two rules keep those threads from blocking each other, and both are load
//! bearing:
//!
//! 1. A thread takes `device` before `core` and never the other way round.
//! 2. No thread calls the event sink while holding `core`.
//!
//! Commands are applied in two steps for the same reason: the planner mutates
//! state and returns the effects it implies, then those effects run with no core
//! lock held.

mod checkpoint;
mod core;
mod effects;
mod plan;
mod snapshot;
mod worker;

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, TryLockError, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use fideflow_media_output::{OutputConfiguration, OutputContext, OutputDevice};
use fideflow_media_pipeline::PcmRing;

pub use core::{
    Command, Core, Effect, Envelope, MAX_SOURCE_ATTEMPTS, OutputDiagnostics, Phase, Plan, PlayMode,
    QueueItem, Rejection, Suppression, TransitionReason, epoch_ms,
};
pub use plan::{SCHEMA_VERSION, parse_envelope};

/// ABI version of the C surface that exposes this session (docs/design/boundaries.md). `media-ffi`
/// re-exports this constant, so the header, the library and the docs cannot drift.
/// ABI 3 adds player-scoped compressed input and independently owned buffer leases.
pub const ABI_VERSION: u32 = 3;

/// Device period: 10 ms at 48 kHz. Small enough to stay responsive, large enough
/// that per-call overhead does not dominate the callback.
pub const OUTPUT_PERIOD_FRAMES: u32 = 480;

/// How often the publisher emits a progress snapshot while audio is moving.
const PUBLISH_INTERVAL_MS: u64 = 500;
/// Retry interval while waiting for the executor under a deadline.
const EXECUTOR_RETRY: Duration = Duration::from_micros(200);
/// How often the publisher looks for underruns, refills and natural end.
const TICK_INTERVAL: Duration = Duration::from_millis(250);

/// Worker state values, also read by the audio callback.
const WORKER_IDLE: u32 = 0;
const WORKER_WORKING: u32 = 1;
const WORKER_DRAINED: u32 = 2;
const WORKER_FAILED: u32 = 3;

pub use fideflow_media_pipeline::{
    HIGH_WATERMARK_FRAMES, LOW_WATERMARK_FRAMES, PCM_CHANNELS, PCM_SAMPLE_RATE,
    RING_CAPACITY_FRAMES, START_WATERMARK_FRAMES, ffmpeg_version,
    is_available as pipeline_available,
};

/// Returns `true` when the pinned `FFmpeg` pipeline is linked into this build.
#[must_use]
pub fn decode_available() -> bool {
    fideflow_media_pipeline::is_available()
}

/// Coarse state for hosts that only render a transport icon.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum PlaybackState {
    /// No item is loaded, or the queue ended.
    #[default]
    Idle = 0,
    /// An item is loaded and not sounding: preparing, buffering or suppressed.
    Ready = 1,
    /// Output is confirmed to be advancing.
    Playing = 2,
    /// The user paused; buffered audio and position are kept.
    Paused = 3,
    /// Playback stopped on an error the caller should surface.
    Error = 4,
}

/// A worker failure kept for diagnostics (docs/design/diagnostics.md: codes, never payloads).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkerError {
    /// Stable error code.
    pub code: String,
    /// Whether retrying the same source could succeed.
    pub retryable: bool,
}

/// State shared with the audio callback; every field is atomic or lock-free.
pub struct Realtime {
    /// Gates PCM consumption without stopping the device.
    pub pcm_enabled: AtomicBool,
    pub callback_active: AtomicBool,
    pub timing_origin: Instant,
    pub seek_started_us: AtomicU64,
    pub seek_generation: AtomicU64,
    /// Cumulative microseconds: gated, joined, opened, positioned, primed, audible.
    pub seek_stages: [AtomicU64; 6],
    /// Seek operations that decoded valid PCM using a retained decoder.
    pub seek_decoder_reused: AtomicU64,
    /// Fresh decoder opens attempted for seek operations.
    pub seek_decoder_reopened: AtomicU64,
    /// Retained decoders discarded after failed positioning or first read.
    pub seek_decoder_fallbacks: AtomicU64,
    /// Bounded PCM hand-off between the decode worker and the callback.
    pub ring: PcmRing,
    /// Valid frames the worker has written for the current item.
    pub frames_written: AtomicU64,
    /// Valid frames the output has consumed for the current item.
    pub frames_consumed: AtomicU64,
    /// Periods that could not be filled while audio was expected.
    pub underruns: AtomicU64,
    /// Frames of silence inserted because audio was expected but missing.
    pub underrun_frames: AtomicU64,
    /// Frames of silence after the source was fully drained (not an underrun).
    pub tail_silence_frames: AtomicU64,
    /// Audio callbacks served.
    pub callback_calls: AtomicU64,
    /// Highest buffer level observed, in frames.
    pub available_peak_frames: AtomicU64,
    /// Media time of the first frame written for the current item.
    pub base_media_us: AtomicU64,
    /// One of the `WORKER_*` constants.
    pub worker_state: AtomicU32,
    /// Last worker failure, when the state is `WORKER_FAILED`.
    pub worker_error: Mutex<Option<WorkerError>>,
    /// Set by the callback when it had to insert silence while audio was expected.
    pub underrun_flag: AtomicU32,
    /// The output gain, as a permille of full scale (0 = silent, 1000 = full).
    /// The audio callback reads this with no lock; `Effect::SetVolume` is the
    /// only writer, and it runs outside the core lock.
    pub volume_permille: AtomicU32,
    pub transient_gain_permille: AtomicU32,
    pub pcm_rate: AtomicU32,
    fade_enabled: AtomicBool,
    fade: effects::Ramp,
    song_gain: effects::Ramp,
    source_gain: AtomicU32,
}

impl Realtime {
    fn new() -> Self {
        Self {
            pcm_enabled: AtomicBool::new(false),
            callback_active: AtomicBool::new(false),
            timing_origin: Instant::now(),
            seek_started_us: AtomicU64::new(0),
            seek_generation: AtomicU64::new(0),
            seek_stages: std::array::from_fn(|_| AtomicU64::new(0)),
            seek_decoder_reused: AtomicU64::new(0),
            seek_decoder_reopened: AtomicU64::new(0),
            seek_decoder_fallbacks: AtomicU64::new(0),
            ring: PcmRing::new(384_000, PCM_CHANNELS),
            frames_written: AtomicU64::new(0),
            frames_consumed: AtomicU64::new(0),
            underruns: AtomicU64::new(0),
            underrun_frames: AtomicU64::new(0),
            tail_silence_frames: AtomicU64::new(0),
            callback_calls: AtomicU64::new(0),
            available_peak_frames: AtomicU64::new(0),
            base_media_us: AtomicU64::new(0),
            worker_state: AtomicU32::new(WORKER_IDLE),
            worker_error: Mutex::new(None),
            underrun_flag: AtomicU32::new(0),
            volume_permille: AtomicU32::new(core::DEFAULT_VOLUME_PERMILLE),
            transient_gain_permille: AtomicU32::new(1000),
            pcm_rate: AtomicU32::new(PCM_SAMPLE_RATE),
            fade_enabled: AtomicBool::new(false),
            fade: effects::Ramp::new(1.0),
            song_gain: effects::Ramp::new(1.0),
            source_gain: AtomicU32::new(1.0_f32.to_bits()),
        }
    }

    /// Diagnostic label for the worker state.
    #[must_use]
    pub fn worker_state_label(&self) -> &'static str {
        match self.worker_state.load(Ordering::Relaxed) {
            WORKER_WORKING => "working",
            WORKER_DRAINED => "drained",
            WORKER_FAILED => "failed",
            _ => "idle",
        }
    }
}

/// Destination for session events (snapshot messages).
pub type EventSink = Arc<dyn Fn(&str) + Send + Sync>;

/// Outcome of a session-side restore (docs/design/restore.md, issue 8).
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RestoreOutcome {
    /// A record was found and the queue was rebuilt.
    Restored = 0,
    /// There was no record for this account.
    NoCheckpoint = 1,
    /// A record existed but this build could not trust it (including a v1 file).
    InvalidCheckpoint = 2,
    /// The session already held a queue, so the record was not applied.
    LiveQueuePresent = 3,
}

/// One job for the checkpoint persistence thread.
enum Persist {
    /// Points the writer at a directory and account, taking `epoch`.
    Configure {
        directory: String,
        account: String,
        epoch: u64,
        ack: SyncSender<()>,
    },
    /// Stops writing without deleting the record.
    Disable { epoch: u64, ack: SyncSender<()> },
    /// Removes one account's record deliberately.
    Delete {
        directory: String,
        account: String,
        ack: SyncSender<()>,
    },
    /// Tells the persistence thread that the coalesced slot holds a newer record.
    ///
    /// The record itself lives in the slot, not the message, so a slow disk can
    /// make writes coalesce but can never drop the newest state (issue 5).
    Wake,
    /// Forces a write, bypassing the throttle, and reports whether it landed.
    Flush {
        epoch: u64,
        record: Option<checkpoint::Record>,
        ack: SyncSender<bool>,
    },
}

/// A record waiting to be persisted, with the account epoch it was built under.
///
/// Writes coalesce into one slot: a slow disk makes the slot hold the newest
/// state rather than a backlog of older ones, and the publisher never blocks on
/// a full channel (issue 5).
struct PendingRecord {
    epoch: u64,
    record: Option<checkpoint::Record>,
}

/// Owns the checkpoint writer and performs every disk operation, off the
/// publisher thread (issue 6).
fn persist_loop(
    rx: &Receiver<Persist>,
    active: &AtomicU64,
    diagnostics: &Mutex<Option<String>>,
    pending: &Mutex<Option<PendingRecord>>,
) {
    let mut writer: Option<checkpoint::CheckpointWriter> = None;
    let mut current: u64 = 0;
    let note = |code: Option<&str>| {
        if let Ok(mut slot) = diagnostics.lock() {
            *slot = code.map(str::to_owned);
        }
    };
    while let Ok(job) = rx.recv() {
        // Apply the coalesced write before the control message: it is the newest
        // state, and draining it first keeps a configure or a delete ordered after
        // the state it replaces, so an old write can never resurrect a cleared
        // queue (issue 5).
        let waiting = pending.lock().ok().and_then(|mut slot| slot.take());
        if let Some(PendingRecord { epoch, record }) = waiting
            && epoch == current
            && let Some(writer) = writer.as_mut()
        {
            let ok = writer.maybe_write(record);
            note(if ok {
                None
            } else {
                Some("checkpoint.writeFailed")
            });
        }
        match job {
            Persist::Configure {
                directory,
                account,
                epoch,
                ack,
            } => {
                writer = Some(checkpoint::CheckpointWriter::new(directory, &account));
                current = epoch;
                active.store(epoch, Ordering::SeqCst);
                note(None);
                let _ = ack.send(());
            }
            Persist::Disable { epoch, ack } => {
                // Stopping must not delete the record: an account switch keeps the
                // old account's file (issue 8).
                writer = None;
                current = epoch;
                active.store(epoch, Ordering::SeqCst);
                let _ = ack.send(());
            }
            Persist::Delete {
                directory,
                account,
                ack,
            } => {
                let mut writer = checkpoint::CheckpointWriter::new(directory, &account);
                note(if writer.clear() {
                    None
                } else {
                    Some("checkpoint.deleteFailed")
                });
                let _ = ack.send(());
            }
            // The record travels in the slot, which was drained above.
            Persist::Wake => {}
            Persist::Flush { epoch, record, ack } => {
                let ok = match writer.as_mut() {
                    Some(writer) if epoch == current => writer.write_now(record),
                    // Nothing is configured for this epoch: the flush is a no-op,
                    // not a failure.
                    _ => true,
                };
                note(if ok {
                    None
                } else {
                    Some("checkpoint.flushFailed")
                });
                let _ = ack.send(ok);
            }
        }
    }
}

/// A running decode worker.
struct WorkerHandle {
    /// Cooperative retirement does not invalidate `FFmpeg` I/O.
    retire: Arc<AtomicI32>,
    /// Per-item cancel flag; also read by `FFmpeg`'s interrupt callback.
    cancel: Arc<AtomicI32>,
    /// Thread that owns the worker, so a worker never joins itself.
    thread_id: thread::ThreadId,
    /// Join handle for the decode thread.
    join: JoinHandle<Option<fideflow_media_pipeline::Decoder>>,
    source_uri: String,
    queue_item_id: String,
    source_revision: u64,
}

struct RetiredDecoder {
    decoder: fideflow_media_pipeline::Decoder,
    source_uri: String,
    queue_item_id: String,
    source_revision: u64,
}

/// Everything a session's threads share.
///
/// The decode worker gets an `Arc<Inner>` so it can report back through the same
/// methods the executor and the publisher use; `self_ref` is how a method on
/// `Inner` reaches that `Arc` without threading it through every call.
#[derive(Debug)]
struct DeferredEffects {
    generation: u64,
    serial: u64,
    item_id: Option<String>,
    position_ms: Option<u64>,
    deadline: Instant,
    effects: Vec<Effect>,
}

#[derive(Default)]
struct PendingOutput {
    running: bool,
    request: Option<OutputRequest>,
}

enum OutputRequest {
    Refresh,
    Configure(OutputConfiguration, u64),
}

struct Inner {
    input: Arc<fideflow_media_pipeline::input::InputRegistry>,
    self_ref: OnceLock<Weak<Inner>>,
    core: Mutex<Core>,
    realtime: Arc<Realtime>,
    sink: Mutex<Option<EventSink>>,
    sample_rate_logs: Mutex<VecDeque<String>>,
    /// The checkpoint persistence channel (docs/design/restore.md).
    ///
    /// The publisher builds an immutable record and hands it to a dedicated
    /// thread, so disk work never runs on the publisher (issue 6). `None` once
    /// the session is released.
    checkpoint_tx: Mutex<Option<SyncSender<Persist>>>,
    /// The thread that owns the writer and performs every disk operation.
    checkpoint_worker: Mutex<Option<JoinHandle<()>>>,
    /// Whether a checkpoint destination is currently configured.
    checkpoint_enabled: AtomicBool,
    /// Monotonic source of account epochs; every configure takes the next one.
    checkpoint_next_epoch: AtomicU64,
    /// The epoch the persistence thread is currently serving. The publisher
    /// tags each job with it, so a job from a replaced account is dropped.
    checkpoint_active_epoch: Arc<AtomicU64>,
    /// The newest record waiting for the persistence thread; writes overwrite it
    /// rather than queueing, so the newest state is never dropped (issue 5).
    checkpoint_pending: Arc<Mutex<Option<PendingRecord>>>,
    /// The last persistence failure code, or `None` after a success (docs/design/diagnostics.md).
    checkpoint_diagnostics: Arc<Mutex<Option<String>>>,
    item_transition: Mutex<()>,
    worker: Mutex<Option<WorkerHandle>>,
    device: Mutex<Option<OutputDevice>>,
    output_context: Mutex<Option<OutputContext>>,
    output_control: Mutex<()>,
    output_pending: Mutex<PendingOutput>,
    output_worker: Mutex<Option<JoinHandle<()>>>,
    ticker: Mutex<Option<JoinHandle<()>>>,
    shutdown: AtomicBool,
    /// Publisher wake-up: set when a state change needs a snapshot promptly.
    dirty: Mutex<bool>,
    dirty_signal: Condvar,
    /// Monotonic origin for the session's own durations.
    started_at: Instant,
    /// Time of the last published snapshot, in milliseconds.
    last_publish_ms: AtomicU64,
}

/// The playback session: owns the queue and the threads that render it.
pub struct PlaybackSession {
    inner: Arc<Inner>,
}

impl Default for PlaybackSession {
    fn default() -> Self {
        Self::new()
    }
}

impl PlaybackSession {
    #[must_use]
    pub fn input_registry(&self) -> Arc<fideflow_media_pipeline::input::InputRegistry> {
        self.inner.input.clone()
    }
    /// Creates a session with a generated id.
    #[must_use]
    pub fn new() -> Self {
        Self::with_session_id(new_session_id())
    }

    /// Creates a session with an explicit id, used by tests and rebuilds.
    #[must_use]
    pub fn with_session_id(session_id: String) -> Self {
        let checkpoint_active_epoch = Arc::new(AtomicU64::new(0));
        let checkpoint_diagnostics = Arc::new(Mutex::new(None));
        let (checkpoint_tx, checkpoint_rx) = sync_channel::<Persist>(64);
        let checkpoint_pending: Arc<Mutex<Option<PendingRecord>>> = Arc::new(Mutex::new(None));
        let checkpoint_worker = thread::Builder::new()
            .name(String::from("ff-checkpoint"))
            .spawn({
                let active = Arc::clone(&checkpoint_active_epoch);
                let diagnostics = Arc::clone(&checkpoint_diagnostics);
                let pending = Arc::clone(&checkpoint_pending);
                move || persist_loop(&checkpoint_rx, &active, &diagnostics, &pending)
            })
            .ok();
        let inner = Arc::new(Inner {
            input: Arc::new(fideflow_media_pipeline::input::InputRegistry::default()),
            self_ref: OnceLock::new(),
            core: Mutex::new(Core::new(session_id)),
            realtime: Arc::new(Realtime::new()),
            sink: Mutex::new(None),
            sample_rate_logs: Mutex::new(VecDeque::new()),
            checkpoint_tx: Mutex::new(Some(checkpoint_tx)),
            checkpoint_worker: Mutex::new(checkpoint_worker),
            checkpoint_enabled: AtomicBool::new(false),
            checkpoint_next_epoch: AtomicU64::new(0),
            checkpoint_active_epoch,
            checkpoint_pending,
            checkpoint_diagnostics,
            item_transition: Mutex::new(()),
            worker: Mutex::new(None),
            device: Mutex::new(None),
            output_context: Mutex::new(None),
            output_control: Mutex::new(()),
            output_pending: Mutex::new(PendingOutput::default()),
            output_worker: Mutex::new(None),
            ticker: Mutex::new(None),
            shutdown: AtomicBool::new(false),
            dirty: Mutex::new(false),
            dirty_signal: Condvar::new(),
            started_at: Instant::now(),
            last_publish_ms: AtomicU64::new(0),
        });
        let _ = inner.self_ref.set(Arc::downgrade(&inner));
        let session = Self { inner };
        session.start_publisher();
        session
    }

    /// Session identity; changes when the session is rebuilt.
    #[must_use]
    pub fn session_id(&self) -> String {
        self.inner.core().session_id.clone()
    }

    /// Registers the event destination. Passing `None` clears it.
    pub fn set_event_sink(&self, sink: Option<EventSink>) {
        self.inner.set_sink(sink);
    }

    /// Configures the session-side restore record writer (docs/design/restore.md).
    ///
    /// The session owns the queue, the order it plays and the position, so it is
    /// also the single writer of the restore record: this points that writer at
    /// `directory` for `account`. An empty `directory` turns the writer off and
    /// removes the record; an empty `account` files under `guest`.
    pub fn configure_checkpoint(&self, directory: &str, account: &str) {
        let Some(tx) = self.inner.checkpoint_sender() else {
            return;
        };
        let epoch = self
            .inner
            .checkpoint_next_epoch
            .fetch_add(1, Ordering::SeqCst)
            + 1;
        if directory.trim().is_empty() {
            self.inner.checkpoint_enabled.store(false, Ordering::SeqCst);
            let (ack_tx, ack_rx) = sync_channel(1);
            if tx.send(Persist::Disable { epoch, ack: ack_tx }).is_ok() {
                let _ = ack_rx.recv_timeout(Duration::from_secs(5));
            }
            return;
        }
        self.inner.checkpoint_enabled.store(true, Ordering::SeqCst);
        let (ack_tx, ack_rx) = sync_channel(1);
        if tx
            .send(Persist::Configure {
                directory: directory.to_owned(),
                account: account.to_owned(),
                epoch,
                ack: ack_tx,
            })
            .is_ok()
        {
            let _ = ack_rx.recv_timeout(Duration::from_secs(5));
        }
    }

    /// Removes `directory`'s record for `account`, deliberately.
    ///
    /// Separate from [`PlaybackSession::configure_checkpoint`]: stopping the
    /// writer must not delete the record, because an account switch stops writing
    /// for the old account but keeps what it saved (issue 8).
    pub fn delete_checkpoint(&self, directory: &str, account: &str) {
        let Some(tx) = self.inner.checkpoint_sender() else {
            return;
        };
        let (ack_tx, ack_rx) = sync_channel(1);
        if tx
            .send(Persist::Delete {
                directory: directory.to_owned(),
                account: account.to_owned(),
                ack: ack_tx,
            })
            .is_ok()
        {
            let _ = ack_rx.recv_timeout(Duration::from_secs(5));
        }
    }

    /// Writes the current state now, bypassing the position throttle.
    ///
    /// Used before an account switch, and by [`PlaybackSession::shutdown`] so the
    /// last position of a session reaches disk even when it moved by less than the
    /// periodic step (issue 5).
    pub fn flush_checkpoint(&self) {
        self.inner.flush_checkpoint();
    }

    /// Rebuilds the queue from the record `directory` holds for `account`
    /// (docs/design/restore.md).
    ///
    /// The session owns the queue, the order it plays and the position, so it is
    /// also the one component that can put them back: this reads its own record
    /// and rebuilds them without a client replaying a single command. Returns
    /// whether a queue was restored; a record that is missing or cannot be trusted
    /// restores nothing, and a session that already holds a queue is left alone,
    /// because a live session wins over a file.
    ///
    /// The restored queue is paused and holds no sources, so the session asks the
    /// host to resolve the current item over the ordinary `sourceRequest` path,
    /// exactly as it would after a `loadQueue` (docs/design/provider.md).
    #[must_use]
    pub fn restore_checkpoint(&self, directory: &str, account: &str) -> RestoreOutcome {
        let record = match checkpoint::read(directory, account) {
            checkpoint::ReadOutcome::Missing => return RestoreOutcome::NoCheckpoint,
            checkpoint::ReadOutcome::Invalid => return RestoreOutcome::InvalidCheckpoint,
            checkpoint::ReadOutcome::Found(record) => *record,
        };
        let effects = {
            let mut core = self.inner.core();
            let Some(effects) = plan::plan_restore(&mut core, &record) else {
                return RestoreOutcome::LiveQueuePresent;
            };
            effects
        };
        self.inner.run_effects(effects);
        RestoreOutcome::Restored
    }

    /// Coarse state for hosts that only need a transport icon.
    #[must_use]
    pub fn state(&self) -> PlaybackState {
        self.inner.state()
    }

    /// Latest snapshot as schema JSON.
    #[must_use]
    pub fn snapshot_json(&self) -> String {
        let core = self.inner.core();
        snapshot::snapshot_value(&core, &self.inner.realtime).to_string()
    }

    /// Bounded diagnostics as JSON (docs/design/diagnostics.md).
    #[must_use]
    pub fn diagnostics_json(&self) -> String {
        let mut value = {
            let core = self.inner.core();
            snapshot::diagnostics_value(&core, &self.inner.realtime)
        };
        // Checkpoint failures are surfaced here rather than swallowed: a record
        // that could not be written is a fact a host should be able to see.
        if let Some(object) = value.as_object_mut() {
            let (allocated, readers, requests) = self.inner.input.metrics();
            object.insert("compressedInput".into(), serde_json::json!({"poolBytes":allocated,"activeReaders":readers,"requests":requests,"blockBytes":fideflow_media_pipeline::input::BLOCK_BYTES,"readerBlocks":fideflow_media_pipeline::input::READER_BLOCKS,"poolLimitBytes":fideflow_media_pipeline::input::MAX_INPUT_BYTES}));
            let last_error = self
                .inner
                .checkpoint_diagnostics
                .lock()
                .ok()
                .and_then(|slot| slot.clone());
            object.insert(
                String::from("checkpoint"),
                serde_json::json!({ "lastError": last_error }),
            );
        }
        value.to_string()
    }

    /// Capabilities of this build, for protocol negotiation.
    #[must_use]
    pub fn capabilities_json() -> String {
        snapshot::capabilities_value().to_string()
    }

    /// Registers a subscriber and returns `{connectionId, baseline}` as JSON.
    ///
    /// Registration and the baseline snapshot happen under one lock, so no event
    /// can slip between them (docs/design/boundaries.md).
    #[must_use]
    pub fn attach(&self, client_id: &str) -> String {
        let mut core = self.inner.core();
        let connection_id = core.register_connection(client_id);
        snapshot::attachment_value(&connection_id, &core, &self.inner.realtime).to_string()
    }

    /// Drops one subscriber. Playback is not affected.
    #[must_use]
    pub fn detach(&self, connection_id: &str) -> bool {
        self.inner.core().unregister_connection(connection_id)
    }

    /// Applies one command envelope and returns the `result` message as JSON.
    #[must_use]
    pub fn execute_json(&self, command_json: &str) -> String {
        let mut core = self.inner.core();
        let (reply, effects) = plan_locked(&self.inner, &mut core, command_json);
        drop(core);
        self.inner.run_effects(effects);
        reply
    }

    /// Applies one command envelope, waiting at most `timeout` for the executor.
    ///
    /// Returns `None` when the executor could not be acquired in time, which
    /// means the command was not submitted at all (docs/design/boundaries.md); the C ABI reports
    /// that as `FF_MEDIA_ERR_TIMEOUT` rather than as a rejection. The deadline
    /// bounds the executor lock only: planning never waits for the source, the
    /// decoder or the audio device, so it cannot turn into playback latency.
    #[must_use]
    pub fn execute_json_timeout(&self, command_json: &str, timeout: Duration) -> Option<String> {
        let deadline = Instant::now() + timeout;
        loop {
            let mut core = match self.inner.core.try_lock() {
                Ok(core) => core,
                // A poisoned executor still holds valid state; the panic that
                // poisoned it was contained by the C ABI, not by this crate.
                Err(TryLockError::Poisoned(error)) => error.into_inner(),
                Err(TryLockError::WouldBlock) => {
                    if Instant::now() >= deadline {
                        return None;
                    }
                    thread::sleep(EXECUTOR_RETRY);
                    continue;
                }
            };
            let (reply, effects) = plan_locked(&self.inner, &mut core, command_json);
            drop(core);
            self.inner.run_effects(effects);
            return Some(reply);
        }
    }

    /// Stops output, cancels work and joins the session's threads.
    pub fn shutdown(&self) {
        self.inner.shutdown();
    }

    fn start_publisher(&self) {
        let inner = Arc::clone(&self.inner);
        let spawned = thread::Builder::new()
            .name(String::from("ff-publisher"))
            .spawn(move || publisher_loop(&inner));
        if let Ok(handle) = spawned
            && let Ok(mut slot) = self.inner.ticker.lock()
        {
            *slot = Some(handle);
        }
    }
}

impl Drop for PlaybackSession {
    fn drop(&mut self) {
        self.inner.shutdown();
    }
}

/// What the session should do with the item `start_item` was pointed at.
///
/// The decision is made under the executor lock — where the queue, its expiries
/// and the item's attempt budget can be read and changed together — and acted on
/// after it, because starting a worker never happens while holding `core`.
struct PreparedItemStart {
    index: usize,
    generation: u64,
    queue_item_id: String,
    track_id: String,
    start: ItemStart,
    source_revision: u64,
}

enum ItemStart {
    /// Open this source.
    Source(String),
    /// No startable source: ask the host for one, for this reason.
    Request(&'static str),
    /// The item has been handed every source it is allowed; fail it instead of
    /// asking again.
    GiveUp,
}

impl Inner {
    fn core(&self) -> MutexGuard<'_, Core> {
        self.core
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The shared handle the decode worker is spawned with.
    fn shared(&self) -> Option<Arc<Inner>> {
        self.self_ref.get().and_then(Weak::upgrade)
    }

    /// Whether `generation` is still the session's current asynchronous work.
    pub(crate) fn is_current(&self, generation: u64) -> bool {
        self.core().generation == generation
    }

    fn device(&self) -> MutexGuard<'_, Option<OutputDevice>> {
        self.device
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn set_sink(&self, sink: Option<EventSink>) {
        if let Ok(mut slot) = self.sink.lock() {
            *slot = sink;
        }
    }

    fn state(&self) -> PlaybackState {
        let core = self.core();
        match core.phase {
            Phase::Idle | Phase::Ended => PlaybackState::Idle,
            Phase::Error => PlaybackState::Error,
            _ if snapshot::is_actually_playing(&core) => PlaybackState::Playing,
            _ if !core.play_when_ready => PlaybackState::Paused,
            _ => PlaybackState::Ready,
        }
    }

    /// Marks that a snapshot is due; the publisher thread emits it.
    fn mark_dirty(&self) {
        if let Ok(mut dirty) = self.dirty.lock() {
            *dirty = true;
        }
        self.dirty_signal.notify_all();
    }

    /// Runs a planned command's effects, never while holding `core`.
    fn run_effects(&self, effects: Vec<Effect>) {
        for effect in effects {
            self.run_effect(effect);
        }
    }

    fn run_effect(&self, effect: Effect) {
        match effect {
            Effect::StartItem { index, position_ms } => self.start_item(index, position_ms),
            Effect::SeekItem {
                index,
                position_ms,
                generation,
            } => {
                if self.is_current(generation) {
                    self.start_item_inner(index, position_ms, Some(generation));
                }
            }
            Effect::StopOutput => self.stop_output(true),
            Effect::ApplyPlaybackEffects => self.apply_playback_effects(),
            Effect::RevokeInput => {
                self.pause_output();
                self.stop_worker();
                self.stop_output(true);
                self.realtime
                    .worker_state
                    .store(WORKER_IDLE, Ordering::Relaxed);
            }
            Effect::PauseOutput => {
                self.pause_output();
                if self.core().output_devices_pending {
                    self.dispatch_output(None);
                }
            }
            Effect::ValidateRecoveryOutput => self.validate_recovery_output(),
            Effect::ResumeOutput => self.start_output(),
            Effect::RefreshOutputDevices => self.dispatch_output(None),
            Effect::ConfigureOutput {
                device_uid,
                exclusive,
                resampling_enabled,
                target_sample_rate,
                version,
            } => self.dispatch_output(Some((
                OutputConfiguration {
                    device_uid,
                    exclusive,
                    resampling_enabled,
                    target_sample_rate,
                },
                version,
            ))),
            Effect::SetTransientGain { permille } => self
                .realtime
                .transient_gain_permille
                .store(permille, Ordering::Relaxed),
            Effect::SetVolume { volume } => self
                .realtime
                .volume_permille
                .store(volume, Ordering::Relaxed),
            Effect::Publish => self.mark_dirty(),
        }
    }

    fn apply_playback_effects(&self) {
        let core = self.core();
        self.realtime
            .fade_enabled
            .store(core.fade_enabled, Ordering::Relaxed);
        let gain = if core.volume_normalization_enabled {
            f32::from_bits(self.realtime.source_gain.load(Ordering::Relaxed))
        } else {
            1.0
        };
        self.realtime.song_gain.request(gain);
        if !core.fade_enabled {
            self.realtime.fade.request(1.0);
        }
        drop(core);
        self.mark_dirty();
    }

    /// Called only with PCM gated, before a new stream becomes audible.
    fn prepare_envelope(&self) {
        let core = self.core();
        self.realtime
            .fade
            .reset(if core.fade_enabled { 0.0 } else { 1.0 });
        if core.fade_enabled {
            self.realtime.fade.request(1.0);
        }
        let gain = if core.volume_normalization_enabled {
            f32::from_bits(self.realtime.source_gain.load(Ordering::Relaxed))
        } else {
            1.0
        };
        self.realtime.song_gain.reset(gain);
    }

    fn finish_deferred_effects(&self) {
        let deferred = {
            let mut core = self.core();
            let Some(pending) = core.deferred_effects.as_ref() else {
                return;
            };
            if pending.generation != core.generation {
                core.deferred_effects = None;
                return;
            }
            if core.fade_enabled
                && Instant::now() < pending.deadline
                && self.realtime.pcm_enabled.load(Ordering::SeqCst)
                && self.realtime.ring.available_frames() > 0
                && self.realtime.fade.value() > 0.0
            {
                return;
            }
            core.deferred_effects.take()
        };
        if let Some(pending) = deferred {
            for effect in pending.effects {
                match effect {
                    Effect::StartItem { index, position_ms } => self.start_item_transaction(
                        index,
                        position_ms,
                        Some(pending.generation),
                        None,
                        None,
                        pending.item_id.as_deref(),
                    ),
                    Effect::PauseOutput | Effect::StopOutput => self.complete_deferred_output(
                        matches!(effect, Effect::StopOutput),
                        pending.generation,
                        pending.serial,
                    ),
                    other => self.run_effect(other),
                }
            }
        }
    }

    fn complete_deferred_output(&self, clear: bool, generation: u64, serial: u64) {
        // Device-before-core order also serializes against a concurrent resume.
        let mut slot = self.device();
        let mut core = self.core();
        if core.generation != generation || core.transport_serial != serial || core.play_when_ready
        {
            return;
        }
        self.gate_pcm();
        core.output_running = false;
        core.exclusive_active = false;
        if let Some(device) = slot.as_mut() {
            device.pause();
        }
        slot.take();
        if clear {
            self.realtime.ring.clear();
        }
        core.bump();
        drop(core);
        drop(slot);
        self.mark_dirty();
    }

    /// Points the session at a queue item and starts buffering it.
    ///
    /// The source the item already holds is used only while it is still startable:
    /// one that has lapsed is revoked here and asked for again, because starting
    /// it would only produce a failure a moment later (docs/design/provider.md).
    fn start_item(&self, index: usize, position_ms: u64) {
        self.start_item_inner(index, position_ms, None);
    }

    fn start_item_inner(&self, index: usize, position_ms: u64, expected_generation: Option<u64>) {
        self.start_item_transaction(index, position_ms, expected_generation, None, None, None);
    }

    fn prepare_item_start(
        &self,
        index: usize,
        position_ms: u64,
        expected_generation: Option<u64>,
        output_version: Option<u64>,
        expected_item_id: Option<&str>,
    ) -> Option<PreparedItemStart> {
        let mut core = self.core();
        if expected_generation.is_some_and(|expected| core.generation != expected)
            || output_version.is_some_and(|version| core.output_version != version)
        {
            if output_version == Some(core.output_version) {
                core.output_busy = false;
                core.bump();
                drop(core);
                self.mark_dirty();
            }
            return None;
        }
        let index = if let Some(id) = expected_item_id {
            if core
                .current_item()
                .is_none_or(|item| item.queue_item_id != id)
            {
                return None;
            }
            core.current.unwrap_or(index)
        } else {
            index
        };
        let Some(item) = core.queue.get(index).cloned() else {
            if output_version == Some(core.output_version) {
                core.output_busy = false;
                core.bump();
                drop(core);
                self.mark_dirty();
            }
            return None;
        };
        core.current = Some(index);
        core.phase = Phase::Resolving;
        core.buffering = false;
        core.item_finished = false;
        core.duration_ms = None;
        core.anchor_media_us = position_ms.saturating_mul(1_000);
        core.anchor_frames = 0;
        core.intent_at = core.play_when_ready.then(Instant::now);
        let now = epoch_ms();
        let attempts = item.source_attempts;
        let start = match item.source_uri.as_deref() {
            // Nothing to start: ask for a source, unless this item has already
            // been handed as many as it is allowed (docs/design/provider.md).
            None if attempts >= MAX_SOURCE_ATTEMPTS => ItemStart::GiveUp,
            None if attempts == 0 => ItemStart::Request("missing"),
            None => ItemStart::Request("retry"),
            // A source whose lifetime has run out is not one to start. It
            // spends an attempt like a failure does, so a host that keeps
            // answering with a lapsed URL cannot loop.
            Some(_) if item.source_is_expired(now) => {
                if attempts >= MAX_SOURCE_ATTEMPTS {
                    ItemStart::GiveUp
                } else {
                    ItemStart::Request("expired")
                }
            }
            Some(uri) => ItemStart::Source(uri.to_owned()),
        };
        if !matches!(start, ItemStart::Source(_)) {
            // Whatever the answer was, the source this item held is not one
            // the session will start: drop it here so nothing can pick it up
            // again, and count what that cost the item's budget.
            if let Some(slot) = core.queue.get_mut(index) {
                slot.revoke_source();
                if item.source_uri.is_some() {
                    slot.source_attempts = attempts + 1;
                }
            }
        }
        Some(PreparedItemStart {
            index,
            generation: core.generation,
            queue_item_id: item.queue_item_id,
            track_id: item.track_id,
            start,
            source_revision: item.source_revision,
        })
    }

    fn start_item_transaction(
        &self,
        index: usize,
        position_ms: u64,
        expected_generation: Option<u64>,
        candidate: Option<OutputDevice>,
        output_version: Option<u64>,
        expected_item_id: Option<&str>,
    ) {
        let transition = self
            .item_transition
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let seeking =
            expected_generation.is_some() && output_version.is_none() && self.core().is_seeking;
        let Some(PreparedItemStart {
            index,
            generation,
            queue_item_id,
            track_id,
            start,
            source_revision,
        }) = self.prepare_item_start(
            index,
            position_ms,
            expected_generation,
            output_version,
            expected_item_id,
        )
        else {
            return;
        };
        // Drop the previous item's audio and reset its counters before the new
        // worker can write anything.
        if seeking {
            self.gate_pcm();
            self.realtime.seek_stage(generation, 0);
            self.core().output_running = false;
        } else if candidate.is_none() {
            self.stop_output(false);
        } else {
            self.gate_pcm();
        }
        // Both producer and consumer must be quiescent before resetting the ring.
        let reuse_source = match &start {
            ItemStart::Source(uri) if seeking => {
                Some((uri.as_str(), queue_item_id.as_str(), source_revision))
            }
            _ => None,
        };
        let retired = self.retire_worker(reuse_source);
        self.realtime.seek_stage(generation, 1);
        self.realtime.ring.clear();
        self.reset_item_counters();
        let source_gain = self
            .core()
            .queue
            .get(index)
            .and_then(|item| item.normalization.gain())
            .unwrap_or(1.0);
        self.realtime
            .source_gain
            .store(source_gain.to_bits(), Ordering::Relaxed);

        if let Some(device) = candidate {
            let info = diagnostics_from(device.info());
            let mut core = self.core();
            if core.play_when_ready
                && core.suppression.is_empty()
                && output_version.is_none_or(|version| version == core.output_version)
            {
                core.active_device_uid = Some(device.info().device_uid.clone());
                core.exclusive_active = device.exclusive_active();
                core.output = Some(info);
                drop(core);
                *self.device() = Some(device);
            }
        }
        {
            let mut core = self.core();
            if output_version == Some(core.output_version) {
                core.output_busy = false;
                core.bump();
            }
        }
        self.mark_dirty();

        match start {
            ItemStart::Source(source_uri) => {
                let decoder = retired
                    .filter(|old| {
                        seeking
                            && old.source_uri == source_uri
                            && old.queue_item_id == queue_item_id
                            && old.source_revision == source_revision
                    })
                    .map(|old| old.decoder);
                self.spawn_worker(
                    generation,
                    source_uri,
                    position_ms,
                    decoder,
                    queue_item_id,
                    source_revision,
                );
            }
            ItemStart::Request(reason) => {
                // A host sink may synchronously provide a source.
                drop(transition);
                self.emit_source_request(generation, &queue_item_id, &track_id, reason);
            }
            ItemStart::GiveUp => {
                // Every source this item could be handed has been tried: asking
                // again would only repeat a resolution that keeps failing.
                self.fail_item(generation, "sourceUnavailable", false);
            }
        }
    }

    /// Revokes the source of the current item after a failure.
    ///
    /// A URI that did not produce audio is not one to read again, so the next
    /// attempt resolves a fresh one; the attempt it spends is what bounds how
    /// often that can happen (docs/design/provider.md).
    fn revoke_failed_source(&self, generation: u64) {
        let mut core = self.core();
        if core.generation != generation {
            return;
        }
        let Some(index) = core.current else {
            return;
        };
        if let Some(item) = core.queue.get_mut(index)
            && item.source_uri.is_some()
        {
            item.revoke_source();
            item.source_attempts = item.source_attempts.saturating_add(1);
        }
    }

    fn emit_source_request(
        &self,
        generation: u64,
        queue_item_id: &str,
        track_id: &str,
        reason: &str,
    ) {
        let (session_id, session_revision) = {
            let core = self.core();
            (core.session_id.clone(), core.session_revision)
        };
        let doc = serde_json::json!({
            "schemaVersion": plan::SCHEMA_VERSION,
            "kind": "sourceRequest",
            "sessionId": session_id,
            "sessionRevision": session_revision.to_string(),
            "generation": generation.to_string(),
            "queueItemId": queue_item_id,
            "trackId": track_id,
            "requestId": format!("sr-{generation}-{queue_item_id}"),
            // Why this item needs a source. The host uses it to tell a first
            // resolution from a replacement, and only the latter has to bypass
            // its own cache (docs/design/provider.md).
            "reason": reason,
        });
        if let Ok(slot) = self.sink.lock()
            && let Some(sink) = &*slot
        {
            sink(&doc.to_string());
        }
    }

    /// Clears the per-item counters. The anchor is re-established at prime time.
    fn reset_item_counters(&self) {
        let realtime = &self.realtime;
        realtime.frames_written.store(0, Ordering::Relaxed);
        realtime.frames_consumed.store(0, Ordering::Relaxed);
        realtime.underruns.store(0, Ordering::Relaxed);
        realtime.underrun_frames.store(0, Ordering::Relaxed);
        realtime.tail_silence_frames.store(0, Ordering::Relaxed);
        realtime.callback_calls.store(0, Ordering::Relaxed);
        realtime.available_peak_frames.store(0, Ordering::Relaxed);
        realtime.base_media_us.store(0, Ordering::Relaxed);
        realtime.underrun_flag.store(0, Ordering::Relaxed);
        realtime.worker_state.store(WORKER_IDLE, Ordering::Relaxed);
        if let Ok(mut slot) = realtime.worker_error.lock() {
            *slot = None;
        }
    }

    fn spawn_worker(
        &self,
        generation: u64,
        source_uri: String,
        position_ms: u64,
        decoder: Option<fideflow_media_pipeline::Decoder>,
        queue_item_id: String,
        source_revision: u64,
    ) {
        let Some(shared) = self.shared() else {
            self.fail_item(generation, "workerUnavailable", true);
            return;
        };
        let cancel = Arc::new(AtomicI32::new(0));
        let worker_cancel = Arc::clone(&cancel);
        let retire = Arc::new(AtomicI32::new(0));
        let worker_retire = Arc::clone(&retire);
        let worker_source = source_uri.clone();
        let spawned = thread::Builder::new()
            .name(String::from("ff-decode"))
            .spawn(move || {
                worker::run(
                    shared,
                    generation,
                    worker_source,
                    position_ms,
                    worker_cancel,
                    worker_retire,
                    decoder,
                )
            });
        match spawned {
            Ok(join) => {
                let thread_id = join.thread().id();
                self.realtime
                    .worker_state
                    .store(WORKER_WORKING, Ordering::Relaxed);
                if let Ok(mut slot) = self.worker.lock() {
                    *slot = Some(WorkerHandle {
                        retire,
                        cancel,
                        thread_id,
                        join,
                        source_uri,
                        queue_item_id,
                        source_revision,
                    });
                }
            }
            Err(_) => self.fail_item(generation, "workerUnavailable", true),
        }
    }

    /// Cancels and joins the decode worker. Never joins the calling thread.
    fn stop_worker(&self) -> Option<RetiredDecoder> {
        self.retire_worker(None)
    }

    /// Give short in-flight reads at most 25 ms to return an usable decoder.
    /// Stop, switching sources and shutdown still interrupt immediately.
    fn retire_worker(&self, reuse_source: Option<(&str, &str, u64)>) -> Option<RetiredDecoder> {
        let handle = self.worker.lock().ok().and_then(|mut slot| slot.take());
        let handle = handle?;
        handle.retire.store(1, Ordering::SeqCst);
        if handle.thread_id == thread::current().id() {
            handle.cancel.store(1, Ordering::SeqCst);
            self.input.interrupt();
            // Called from the worker itself: the flag is set and dropping the
            // handle detaches the thread instead of deadlocking on the join.
            return None;
        }
        let compatible = reuse_source.is_some_and(|(uri, item, revision)| {
            handle.source_uri == uri
                && handle.queue_item_id == item
                && handle.source_revision == revision
        });
        if compatible && handle.source_uri.starts_with("ffinput://") {
            handle.cancel.store(1, Ordering::SeqCst);
            self.input.interrupt();
        } else if compatible {
            let deadline = Instant::now() + Duration::from_millis(25);
            while !handle.join.is_finished() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
        }
        if !handle.join.is_finished() {
            handle.cancel.store(1, Ordering::SeqCst);
            self.input.interrupt();
        }
        let decoder = handle.join.join().ok().flatten()?;
        if decoder.was_interrupted() && !decoder.is_host_input() {
            return None;
        }
        Some(RetiredDecoder {
            decoder,
            source_uri: handle.source_uri,
            queue_item_id: handle.queue_item_id,
            source_revision: handle.source_revision,
        })
    }

    /// Opens the output device if needed, then starts or resumes it.
    fn ensure_output_context(&self) -> Result<(), fideflow_media_output::OutputError> {
        let mut context = self
            .output_context
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if context.is_none() {
            *context = Some(OutputContext::new()?);
        }
        Ok(())
    }

    fn start_watermark(&self) -> usize {
        (self.realtime.pcm_rate.load(Ordering::Relaxed) as usize / 2)
            .min(self.realtime.ring.capacity_frames() / 2)
    }
    fn high_watermark(&self) -> usize {
        (self.realtime.pcm_rate.load(Ordering::Relaxed) as usize * 3 / 2)
            .min(self.realtime.ring.capacity_frames().saturating_sub(8192))
    }

    fn configure_decoder(
        &self,
        generation: u64,
        decoder: &mut fideflow_media_pipeline::Decoder,
    ) -> bool {
        if !self.is_current(generation) {
            return false;
        }
        let mut config = self.core().output_configuration.clone();
        // Hog mode can temporarily remove this device from the system default.
        // Rebuilding PCM must use the stream we already acquired, not resolve
        // the now unavailable default a second time.
        if config.device_uid.is_none() {
            config.device_uid = self.device().as_ref().map(|d| d.info().device_uid.clone());
        }
        let negotiated = self.ensure_output_context().and_then(|()| {
            let context = self
                .output_context
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let context = context.as_ref().unwrap();
            Ok((
                context.negotiate_rate(&config, decoder.info().sample_rate)?,
                context.negotiate_channels(&config, decoder.info().channels)?,
            ))
        });
        let (rate, channels) = match negotiated {
            Ok(format) => format,
            Err(error) => {
                self.output_failed(output_error_code(&error));
                return false;
            }
        };
        if (
            decoder.info().output_sample_rate,
            decoder.info().output_channels,
        ) != (rate, channels)
            && let Err(error) = decoder.configure_output(rate, channels)
        {
            self.on_failed(generation, error.code(), error.is_retryable());
            return false;
        }
        let mismatch = self
            .device()
            .as_ref()
            .is_some_and(|d| d.info().sample_rate != rate || d.info().channels != channels);
        if mismatch {
            self.pause_output();
        }
        let mut core = self.core();
        if core.generation != generation {
            return false;
        }
        self.realtime.ring.configure_channels(channels as usize);
        self.realtime.pcm_rate.store(rate, Ordering::Relaxed);
        core.pcm_rate = rate;
        drop(core);
        self.log_output_sample_rates("pcmConfigured", Some(decoder.info().sample_rate));
        true
    }

    fn log_output_sample_rates(&self, event: &'static str, source_rate: Option<u32>) {
        let (config, active, source, pcm) = {
            let core = self.core();
            let prepared = core.current.is_some() && core.phase == Phase::Ready;
            (
                core.output_configuration.clone(),
                (core.output_running || core.exclusive_active)
                    .then(|| core.active_device_uid.clone())
                    .flatten(),
                source_rate
                    .or_else(|| (prepared && core.source_rate > 0).then_some(core.source_rate)),
                (source_rate.is_some() || prepared).then_some(core.pcm_rate),
            )
        };
        let system = {
            let context = self
                .output_context
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            context.as_ref().and_then(|context| {
                context
                    .system_sample_rate(active.as_deref().or(config.device_uid.as_deref()))
                    .ok()
            })
        };
        fideflow_media_output::log_sample_rates(event, system, source, pcm, &config);
        let message = serde_json::json!({
            "schemaVersion": 1, "kind": "outputSampleRates", "event": event,
            "systemRateHz": system, "sourceRateHz": source, "pcmRateHz": pcm,
            "targetRateHz": config.target_sample_rate,
            "resamplingEnabled": config.resampling_enabled, "exclusive": config.exclusive,
        })
        .to_string();
        {
            let mut logs = self
                .sample_rate_logs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if logs.len() == 32 {
                logs.pop_front();
            }
            logs.push_back(message);
        }
        self.mark_dirty();
    }

    fn dispatch_output(&self, configuration: Option<(OutputConfiguration, u64)>) {
        if self.shutdown.load(Ordering::SeqCst) {
            return;
        }
        let Some(inner) = self.shared() else {
            return;
        };
        let mut pending = self
            .output_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // One control worker and at most one pending request. A refresh must not
        // overwrite an already queued configuration change.
        if configuration.is_some() || pending.request.is_none() {
            pending.request = Some(match configuration {
                Some((configuration, version)) => OutputRequest::Configure(configuration, version),
                None => OutputRequest::Refresh,
            });
        }
        if pending.running {
            return;
        }
        pending.running = true;
        let handle = thread::Builder::new()
            .name("ff-output-control".into())
            .spawn(move || {
                loop {
                    let next = {
                        let mut pending = inner
                            .output_pending
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        if let Some(next) = pending.request.take() {
                            next
                        } else {
                            pending.running = false;
                            break;
                        }
                    };
                    match next {
                        OutputRequest::Refresh => inner.change_output(None),
                        OutputRequest::Configure(configuration, version) => {
                            inner.change_output(Some((configuration, version)));
                        }
                    }
                }
            });
        if let Ok(handle) = handle {
            *self
                .output_worker
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(handle);
        } else {
            pending.running = false;
            pending.request = None;
            drop(pending);
            self.output_failed("outputControlFailed");
        }
    }

    fn change_output(&self, configuration: Option<(OutputConfiguration, u64)>) {
        let _control = self
            .output_control
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self.shutdown.load(Ordering::SeqCst) {
            return;
        }
        if configuration
            .as_ref()
            .is_some_and(|(_, version)| self.core().output_version != *version)
        {
            return;
        }
        if configuration.is_none() {
            self.refresh_output_devices();
            return;
        }
        let (desired, transaction_version) = configuration.unwrap();
        let (was_playing, source_rate, source_channels) = {
            let mut core = self.core();
            core.output_busy = true;
            core.bump();
            (core.play_when_ready, core.source_rate, core.source_channels)
        };
        self.mark_dirty();
        self.pause_output();
        let result = self.prepare_output_configuration(&desired);
        let devices = match result {
            Ok(devices) => devices,
            Err(error) => {
                self.finish_output_failure(
                    output_error_code(&error),
                    was_playing,
                    transaction_version,
                );
                return;
            }
        };
        {
            let mut core = self.core();
            core.output_devices = devices;
            core.output_devices_pending = false;
            core.bump();
        }
        let mut candidate = None;
        // Open once while PCM is gated, then retain this stream through rebuild.
        // This prevents an exclusive owner from stealing the device between a probe and reopen.
        if was_playing && self.core().suppression.is_empty() {
            let opened = self.open_output_candidate(&desired, source_rate, source_channels);
            match opened {
                Ok(device) => candidate = Some(device),
                Err(error) => {
                    self.finish_output_failure(
                        output_error_code(&error),
                        was_playing,
                        transaction_version,
                    );
                    return;
                }
            }
        }
        let restart = {
            let mut core = self.core();
            if core.output_version != transaction_version {
                drop(core);
                drop(candidate.take());
                self.restore_session_preferences();
                return;
            }
            core.output_configuration = desired.clone();
            core.output_error = None;
            if core.current.is_none() {
                core.output_busy = false;
            }
            core.bump();
            core.current.map(|index| {
                let position =
                    core.position_ms(self.realtime.frames_consumed.load(Ordering::Relaxed));
                core.generation += 1;
                (index, position, core.generation)
            })
        };
        if let Some((index, position, generation)) = restart {
            self.start_item_transaction(
                index,
                position,
                Some(generation),
                candidate,
                Some(transaction_version),
                None,
            );
        } else {
            drop(candidate);
            self.start_output();
        }
        self.mark_dirty();
        self.log_output_sample_rates("configurationUpdated", None);
    }

    fn open_output_candidate(
        &self,
        configuration: &OutputConfiguration,
        source_rate: u32,
        source_channels: u32,
    ) -> Result<OutputDevice, fideflow_media_output::OutputError> {
        self.ensure_output_context().and_then(|()| {
            let (rate, channels) = {
                let context = self
                    .output_context
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let context = context.as_ref().unwrap();
                (
                    context.negotiate_rate(configuration, source_rate.max(8000))?,
                    context.negotiate_channels(configuration, source_channels)?,
                )
            };
            OutputDevice::start_configured(configuration, channels, rate, OUTPUT_PERIOD_FRAMES, {
                let realtime = Arc::clone(&self.realtime);
                move |out| render_pcm(&realtime, out)
            })
        })
    }

    // Metadata refresh must neither gate PCM nor close, reopen or renegotiate
    // transport. Enumeration errors are reported without stopping a healthy stream.
    fn refresh_output_devices(&self) {
        let result = self.ensure_output_context().and_then(|()| {
            let context = self
                .output_context
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            context.as_ref().unwrap().refresh()
        });
        let mut core = self.core();
        match result {
            Ok(mut devices) => {
                // HAL can hide the default while this process owns Hog Mode.
                // Keep the last known default name in the selector in that case.
                if core.exclusive_active && !devices.iter().any(|device| device.is_default) {
                    for device in &mut devices {
                        device.is_default = core
                            .output_devices
                            .iter()
                            .any(|previous| previous.uid == device.uid && previous.is_default);
                    }
                }
                core.output_devices = devices;
                core.output_devices_pending = false;
                if core.output_error.as_deref() == Some("outputEnumerationFailed") {
                    core.output_error = None;
                }
            }
            Err(_) => {
                // Preserve an existing playback fault and the stopped intent.
                if core.output_error.is_none() {
                    core.output_error = Some("outputEnumerationFailed".into());
                }
            }
        }
        core.bump();
        drop(core);
        self.mark_dirty();
        self.log_output_sample_rates("devicesRefreshed", None);
    }

    fn finish_output_failure(&self, code: &str, _resume: bool, version: u64) {
        if self.core().output_version != version {
            return;
        }
        self.restore_session_preferences();
        // A failed switch is a stop, including failure while following the
        // default. Do not resume the old exclusive stream and retrigger HAL
        // default notifications in a retry loop.
        self.output_failed(code);
    }

    fn prepare_output_configuration(
        &self,
        configuration: &OutputConfiguration,
    ) -> Result<Vec<fideflow_media_output::PlaybackDevice>, fideflow_media_output::OutputError>
    {
        self.ensure_output_context()?;
        let context = self
            .output_context
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let context = context.as_ref().unwrap();
        context.configure_session_preferences(configuration)?;
        context.refresh()
    }

    fn restore_session_preferences(&self) {
        let configuration = self.core().output_configuration.clone();
        let context = self
            .output_context
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(context) = context.as_ref() {
            let _ = context.configure_session_preferences(&configuration);
        }
    }

    fn output_failed(&self, error_code: &str) {
        self.pause_output();
        let mut core = self.core();
        core.deferred_effects = None;
        if matches!(core.phase, Phase::Resolving | Phase::Loading) {
            core.phase = Phase::Paused;
        }
        core.play_when_ready = false;
        core.buffering = false;
        core.output_error = Some(error_code.into());
        if matches!(
            error_code,
            "outputDeviceRemoved" | "outputDeviceUnavailable"
        ) {
            fallback_to_default(&mut core);
        }
        core.output_busy = false;
        core.bump();
        drop(core);
        self.mark_dirty();
    }

    fn check_output(&self) {
        let Ok(_control) = self.output_control.try_lock() else {
            return;
        };
        let (active, config, running, busy, failed) = {
            let core = self.core();
            (
                core.active_device_uid.clone(),
                core.output_configuration.clone(),
                core.output_running,
                core.output_busy,
                core.output_error.is_some() && !core.play_when_ready,
            )
        };
        if busy || !self.core().suppression.is_empty() {
            return;
        }
        let (changes, valid, selected_valid, default_uid, system_rate) = {
            let context = self
                .output_context
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(context) = context.as_ref() else {
                return;
            };
            let changes = context.changes();
            (
                changes,
                active
                    .as_deref()
                    .is_none_or(|uid| context.route_valid(Some(uid))),
                config
                    .device_uid
                    .as_deref()
                    .is_none_or(|uid| context.route_valid(Some(uid))),
                // Query only for a relevant notification, not every tick.
                if changes & 2 != 0 {
                    context.default_uid()
                } else {
                    None
                },
                // Probe only on a format notification, never on each tick.
                if changes & 4 != 0 && !config.exclusive && !config.resampling_enabled {
                    context.negotiate_rate(&config, 0).ok()
                } else {
                    None
                },
            )
        };
        self.observe_output_changes(changes, default_uid.as_deref());
        if changes & 4 != 0 {
            self.log_output_sample_rates("systemFormatChanged", None);
        }
        if !selected_valid {
            let core = self.core();
            let still_selected = !core.output_busy && core.output_configuration == config;
            drop(core);
            if still_selected {
                self.output_failed("outputDeviceUnavailable");
            }
            return;
        }
        if running && self.check_running_output(active.as_deref(), valid) {
            return;
        }
        if !failed && let Some(rate) = system_rate {
            let effect = plan::plan_system_sample_rate(&mut self.core(), rate);
            if let Some(effect) = effect {
                self.run_effect(effect);
                self.mark_dirty();
                return;
            }
        }
        if !failed
            && should_follow_default(
                &config,
                running,
                changes,
                active.as_deref(),
                default_uid.as_deref(),
            )
        {
            // A normal default-route change follows the system. Removal won above.
            let version = {
                let mut core = self.core();
                core.output_version += 1;
                core.output_busy = true;
                core.output_version
            };
            self.dispatch_output(Some((config, version)));
        } else if changes & 1 != 0 && !running && !failed {
            self.dispatch_output(None);
        }
    }

    fn observe_output_changes(&self, changes: u32, default_uid: Option<&str>) {
        let mut core = self.core();
        let mut metadata_updated = false;
        // Hog acquisition/release can emit default-output notifications without
        // changing the device list. Only list notifications require enumeration.
        if changes & 1 != 0 && !core.output_devices_pending {
            core.output_devices_pending = true;
            metadata_updated = true;
        }
        if changes & 2 != 0
            && let Some(uid) = default_uid
        {
            for device in &mut core.output_devices {
                let is_default = device.uid == uid;
                if device.is_default != is_default {
                    device.is_default = is_default;
                    metadata_updated = true;
                }
            }
        }
        if metadata_updated {
            core.bump();
            drop(core);
            self.mark_dirty();
        }
    }

    /// Validate against current intent while holding the device lock. A ticker
    /// snapshot can precede a pause; observing its now-closed stream is normal.
    /// Fault commitment and stream teardown share the same lock as play/pause.
    fn check_running_output(&self, observed_uid: Option<&str>, route_valid: bool) -> bool {
        let mut slot = self.device();
        let mut core = self.core();
        if !core.output_running
            || (!core.play_when_ready && core.deferred_effects.is_none())
            || core.output_busy
            || core.active_device_uid.as_deref() != observed_uid
        {
            return true;
        }
        let healthy = slot.as_ref().is_some_and(|device| {
            device.is_running()
                && (!core.output_configuration.exclusive || device.exclusive_active())
        });
        if route_valid && healthy {
            return false;
        }
        core.deferred_effects = None;
        core.output_running = false;
        core.exclusive_active = false;
        core.play_when_ready = false;
        core.buffering = false;
        core.output_error = Some(
            if route_valid {
                "outputStopped"
            } else {
                "outputDeviceRemoved"
            }
            .into(),
        );
        if !route_valid {
            fallback_to_default(&mut core);
        }
        core.bump();
        drop(core);
        self.gate_pcm();
        if let Some(device) = slot.as_mut() {
            device.pause();
        }
        slot.take();
        drop(slot);
        self.mark_dirty();
        true
    }

    fn validate_recovery_output(&self) {
        let active = self.core().active_device_uid.clone();
        let Some(uid) = active else {
            return;
        };
        let valid = self.ensure_output_context().map(|()| {
            let context = self
                .output_context
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            context
                .as_ref()
                .is_some_and(|context| context.route_valid(Some(&uid)))
        });
        match valid {
            Ok(true) => {}
            Ok(false) => self.output_failed("outputDeviceRemoved"),
            Err(error) => self.output_failed(output_error_code(&error)),
        }
    }

    fn start_output(&self) {
        let mut slot = self.device();
        {
            let core = self.core();
            if core.output_busy
                || !core.play_when_ready
                || core.phase != Phase::Ready
                || !core.suppression.is_empty()
            {
                return;
            }
        }
        if !self.realtime.pcm_enabled.load(Ordering::SeqCst) {
            self.prepare_envelope();
        }
        if let Some(existing) = slot.as_mut() {
            self.realtime.pcm_enabled.store(true, Ordering::SeqCst);
            if existing.is_running() {
                drop(slot);
                self.mark_ready();
                return;
            }
            if existing.resume().is_ok() {
                let info = diagnostics_from(existing.info());
                drop(slot);
                self.mark_ready_with(info);
                return;
            }
            // A device that refuses to restart is replaced below.
            slot.take();
        }
        // Pause closes transport but keeps buffered PCM. The default route may
        // have changed since that PCM was produced, even before HAL notifies us.
        let (configuration, generation, source_rate, source_channels) = {
            let core = self.core();
            (
                core.output_configuration.clone(),
                core.generation,
                core.source_rate,
                core.source_channels,
            )
        };
        let negotiated = self.ensure_output_context().and_then(|()| {
            let context = self
                .output_context
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let context = context.as_ref().unwrap();
            Ok((
                context.negotiate_rate(&configuration, source_rate)?,
                context.negotiate_channels(&configuration, source_channels)?,
            ))
        });
        let mut core = self.core();
        if core.generation != generation
            || core.output_configuration != configuration
            || core.output_busy
            || !core.play_when_ready
            || core.phase != Phase::Ready
            || !core.suppression.is_empty()
        {
            return;
        }
        let format = match negotiated {
            Ok(format) => format,
            Err(error) => {
                drop(core);
                drop(slot);
                self.output_failed(output_error_code(&error));
                return;
            }
        };
        let Ok(pcm_channels) = u32::try_from(self.realtime.ring.channels()) else {
            drop(core);
            drop(slot);
            self.output_failed("outputFormatUnsupported");
            return;
        };
        let rebuild = plan::plan_output_format(
            &mut core,
            (self.realtime.pcm_rate.load(Ordering::Relaxed), pcm_channels),
            format,
        );
        drop(core);
        if let Some(effect) = rebuild {
            drop(slot);
            self.gate_pcm();
            self.run_effect(effect);
            self.mark_dirty();
            return;
        }
        self.open_output_device(slot, &configuration, pcm_channels);
    }

    fn open_output_device(
        &self,
        mut slot: MutexGuard<'_, Option<OutputDevice>>,
        configuration: &OutputConfiguration,
        pcm_channels: u32,
    ) {
        self.realtime.pcm_enabled.store(true, Ordering::SeqCst);
        let realtime = Arc::clone(&self.realtime);
        let render = move |out: &mut [f32]| render_pcm(&realtime, out);
        let opened = OutputDevice::start_configured(
            configuration,
            pcm_channels,
            self.realtime.pcm_rate.load(Ordering::Relaxed),
            OUTPUT_PERIOD_FRAMES,
            render,
        );
        match opened {
            Ok(device) => {
                let info = diagnostics_from(device.info());
                let exclusive_active = device.exclusive_active();
                let active_uid = device.info().device_uid.clone();
                *slot = Some(device);
                {
                    let mut core = self.core();
                    core.exclusive_active = exclusive_active;
                    core.output_error = None;
                }
                drop(slot);
                self.core().active_device_uid = Some(active_uid);
                self.mark_ready_with(info);
            }
            Err(error) => {
                drop(slot);
                self.output_failed(output_error_code(&error));
            }
        }
    }

    /// Records that output is running and the current item is ready.
    fn mark_ready_with(&self, info: OutputDiagnostics) {
        {
            let slot = self.device();
            let mut core = self.core();
            core.output = Some(info);
            if core.output_busy
                || !core.play_when_ready
                || core.phase != Phase::Ready
                || !core.suppression.is_empty()
                || slot.as_ref().is_none_or(|device| !device.is_running())
            {
                drop(core);
                drop(slot);
                self.pause_output();
                return;
            }
            core.output_running = true;
            core.bump();
            if core.first_frame_millis.is_none()
                && let Some(intent_at) = core.intent_at
            {
                core.first_frame_millis = Some(intent_at.elapsed().as_millis());
                core.intent_at = None;
            }
        }
        self.mark_dirty();
        self.log_output_sample_rates("outputReady", None);
    }

    fn mark_ready(&self) {
        let info = self.core().output.clone().unwrap_or_default();
        self.mark_ready_with(info);
    }

    fn gate_pcm(&self) {
        self.realtime.pcm_enabled.store(false, Ordering::SeqCst);
        while self.realtime.callback_active.load(Ordering::SeqCst) {
            thread::yield_now();
        }
    }

    fn pause_output(&self) {
        self.gate_pcm();
        {
            let mut slot = self.device();
            {
                let mut core = self.core();
                core.output_running = false;
                core.exclusive_active = false;
            }
            if let Some(device) = slot.as_mut() {
                device.pause();
            }
            slot.take();
        }
        self.mark_dirty();
    }

    /// Pauses output and, when asked, drops buffered PCM.
    fn stop_output(&self, clear: bool) {
        self.gate_pcm();
        {
            let mut slot = self.device();
            {
                let mut core = self.core();
                core.output_running = false;
                core.exclusive_active = false;
            }
            slot.take();
            if clear {
                self.realtime.ring.clear();
            }
        }
        self.mark_dirty();
    }

    /// Moves the session into the error phase for the current generation.
    fn fail_item(&self, generation: u64, error_code: &str, retryable: bool) {
        self.revoke_failed_source(generation);
        {
            let mut core = self.core();
            if core.generation != generation {
                return;
            }
            core.deferred_effects = None;
            core.is_seeking = false;
            core.phase = Phase::Error;
            core.error_code = Some(error_code.to_owned());
            core.failure_kind = core::FailureKind::from_native_code(error_code);
            core.error_retryable = retryable;
            core.play_when_ready = core.intelligence_session_id.is_some() && core.play_when_ready;
            core.buffering = false;
            core.bump();
        }
        if let Ok(mut slot) = self.realtime.worker_error.lock() {
            *slot = Some(WorkerError {
                code: error_code.to_owned(),
                retryable,
            });
        }
        self.realtime
            .worker_state
            .store(WORKER_FAILED, Ordering::Relaxed);
        self.stop_output(true);
    }

    /// Worker-side: the source is open and PCM is flowing.
    fn on_primed(&self, generation: u64, base_media_us: u64, summary: &crate::SourceSummary) {
        let playing = {
            let mut core = self.core();
            if core.generation != generation {
                return;
            }
            core.duration_ms = summary.duration_ms;
            core.source_codec.clone_from(&summary.codec);
            core.source_rate = summary.source_rate;
            core.source_channels = summary.source_channels;
            core.resampler.clone_from(&summary.resampler);
            core.anchor_media_us = base_media_us;
            core.anchor_frames = self.realtime.frames_consumed.load(Ordering::Relaxed);
            core.is_seeking = false;
            core.phase = if !core.play_when_ready
                && matches!(
                    core.output_error.as_deref(),
                    Some("outputDeviceRemoved" | "outputDeviceUnavailable")
                ) {
                Phase::Paused
            } else {
                Phase::Ready
            };
            // Async readiness is a new snapshot: clients reject unchanged revisions.
            core.bump();
            self.realtime.seek_stage(generation, 4);
            core.play_when_ready
        };
        self.realtime
            .base_media_us
            .store(base_media_us, Ordering::Relaxed);
        if playing {
            self.start_output();
        } else {
            self.mark_dirty();
        }
    }

    /// Worker-side: the decoder and the resampler are both drained.
    fn on_drained(&self, generation: u64) {
        if self.core().generation != generation {
            return;
        }
        self.realtime
            .worker_state
            .store(WORKER_DRAINED, Ordering::Relaxed);
        self.mark_dirty();
    }

    /// Worker-side: the item failed. The code is stable and payload-free.
    fn on_failed(&self, generation: u64, code: &str, retryable: bool) {
        self.fail_item(generation, code, retryable);
    }

    fn shutdown(&self) {
        if self.shutdown.swap(true, Ordering::SeqCst) {
            return;
        }
        self.dirty_signal.notify_all();
        let ticker = self.ticker.lock().ok().and_then(|mut slot| slot.take());
        if let Some(ticker) = ticker {
            let _ = ticker.join();
        }
        if let Some(worker) = self
            .output_worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            let _ = worker.join();
        }
        // The publisher has stopped, so this is the last word on the record. The
        // forced flush bypasses the position throttle, and the persistence thread
        // is joined, so the final position is on disk before this returns (issue
        // 5, 6).
        self.flush_checkpoint();
        self.stop_checkpoint_worker();
        self.stop_worker();
        self.stop_output(true);
        self.output_context
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
    }

    /// One publisher pass: detect natural end, resolve buffering, publish.
    fn tick(&self) {
        self.check_output();
        self.finish_deferred_effects();
        let realtime = &self.realtime;
        let drained = realtime.worker_state.load(Ordering::Relaxed) == WORKER_DRAINED;
        let written = realtime.frames_written.load(Ordering::Relaxed);
        let consumed = realtime.frames_consumed.load(Ordering::Relaxed);
        let underrun = realtime.underrun_flag.swap(0, Ordering::Relaxed) == 1;
        let available = realtime.ring.available_frames();
        let mut effects: Vec<Effect> = Vec::new();

        {
            let mut core = self.core();
            // Buffering is entered when valid PCM could not sustain output and left
            // only once the start watermark is restored or the source is drained
            // (docs/design/playback.md), so the flag cannot flap.
            if !core.suppression.is_empty() {
                core.buffering = false;
            } else if core.buffering {
                if available >= self.start_watermark() || drained {
                    core.buffering = false;
                }
            } else if underrun {
                core.buffering = true;
            }
            // Natural end: the source is drained *and* the output consumed every
            // valid frame. Tail silence is not progress (docs/design/playback.md).
            let ended = drained
                && written > 0
                && consumed >= written
                && core.phase == Phase::Ready
                && core.output_running
                && core.suppression.is_empty()
                && !core.item_finished
                && core.deferred_effects.is_none();
            if ended {
                core.item_finished = true;
                core.buffering = false;
                // Natural end goes through the same transition the manual skips
                // use, so the mode's rules (repeat one, wrap around, shuffle) are
                // decided in exactly one place (architecture section 7). `None`
                // means nothing is left to play, which is the only way this
                // session reaches `ended` now that the default mode wraps.
                if let Some(effect) = plan::natural_end(&mut core) {
                    effects.push(effect);
                } else {
                    core.phase = Phase::Ended;
                    // A heart stream retains transport intent while it awaits supply.
                    core.play_when_ready = core.intelligence_session_id.is_some();
                    core.bump();
                    effects.push(Effect::StopOutput);
                }
            }
        }
        for effect in effects {
            self.run_effect(effect);
        }
        self.publish_if_due();
    }

    /// Emits a snapshot when a change is pending or the interval elapsed.
    fn publish_if_due(&self) {
        // Keep all FFI event delivery on the publisher. Rate logs are bounded
        // independently of snapshots and are never emitted by the render callback.
        let logs = {
            let mut logs = self
                .sample_rate_logs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            std::mem::take(&mut *logs)
        };
        for message in logs {
            self.emit(&message);
        }
        let pending = {
            let mut dirty = match self.dirty.lock() {
                Ok(dirty) => dirty,
                Err(error) => error.into_inner(),
            };
            let pending = *dirty;
            *dirty = false;
            pending
        };
        #[allow(
            clippy::cast_possible_truncation,
            reason = "a session uptime in milliseconds cannot reach 2^64"
        )]
        let now = self.started_at.elapsed().as_millis() as u64;
        let last = self.last_publish_ms.load(Ordering::Relaxed);
        let due = {
            let core = self.core();
            (core.output_running || core.buffering)
                && now.saturating_sub(last) >= PUBLISH_INTERVAL_MS
        };
        if !pending && !due {
            return;
        }
        self.last_publish_ms.store(now, Ordering::Relaxed);
        let message = {
            let mut core = self.core();
            // An interval snapshot reports playback progress, which changes no
            // plan: it still advances the revision, because clients discard a
            // revision that does not advance and would otherwise never see the
            // position move (docs/protocols/media-sdk.md). A `pending` publish
            // already carries the revision its plan bumped.
            if !pending {
                core.bump();
            }
            snapshot::snapshot_value(&core, &self.realtime).to_string()
        };
        self.emit(&message);
        self.write_checkpoint();
    }

    /// Builds the current record, or `None` when the queue is empty.
    fn build_record(&self) -> Option<checkpoint::Record> {
        let core = self.core();
        let position_ms = core.position_ms(self.realtime.frames_consumed.load(Ordering::Relaxed));
        checkpoint::record(&core, position_ms)
    }

    /// The persistence sender, cloned so a send never holds the lock.
    fn checkpoint_sender(&self) -> Option<SyncSender<Persist>> {
        self.checkpoint_tx.lock().ok().and_then(|slot| slot.clone())
    }

    /// Hands the current record to the persistence thread (docs/design/restore.md).
    ///
    /// The record is built under the `core` lock and then coalesced into a single
    /// slot, so the publisher never touches the disk and never blocks, and a slow
    /// disk can only make writes coalesce — the newest state is always the one
    /// the slot holds (issue 5). A dropped wake is harmless: the persistence loop
    /// drains the slot before every message it handles, and a wake only fails to
    /// send when such a message is already queued to do that draining.
    fn write_checkpoint(&self) {
        if !self.checkpoint_enabled.load(Ordering::SeqCst) {
            return;
        }
        let Some(tx) = self.checkpoint_sender() else {
            return;
        };
        let epoch = self.checkpoint_active_epoch.load(Ordering::SeqCst);
        let record = self.build_record();
        if let Ok(mut slot) = self.checkpoint_pending.lock() {
            *slot = Some(PendingRecord { epoch, record });
        }
        let _ = tx.try_send(Persist::Wake);
    }

    /// Forces the current record to disk and waits for the persistence thread.
    fn flush_checkpoint(&self) {
        if !self.checkpoint_enabled.load(Ordering::SeqCst) {
            return;
        }
        let Some(tx) = self.checkpoint_sender() else {
            return;
        };
        let epoch = self.checkpoint_active_epoch.load(Ordering::SeqCst);
        let record = self.build_record();
        let (ack_tx, ack_rx) = sync_channel(1);
        if tx
            .send(Persist::Flush {
                epoch,
                record,
                ack: ack_tx,
            })
            .is_ok()
        {
            // Bounded wait: a stuck disk must not hang shutdown forever.
            let _ = ack_rx.recv_timeout(Duration::from_secs(5));
        }
    }

    /// Stops the persistence thread after its queue has drained.
    fn stop_checkpoint_worker(&self) {
        let sender = self
            .checkpoint_tx
            .lock()
            .ok()
            .and_then(|mut slot| slot.take());
        drop(sender);
        let worker = self
            .checkpoint_worker
            .lock()
            .ok()
            .and_then(|mut slot| slot.take());
        if let Some(worker) = worker {
            let _ = worker.join();
        }
    }

    /// Calls the event sink. Never called while holding `core`.
    fn emit(&self, message: &str) {
        let sink = self
            .sink
            .lock()
            .ok()
            .and_then(|slot| slot.as_ref().map(Arc::clone));
        if let Some(sink) = sink {
            sink(message);
        }
    }

    /// Blocks until a snapshot is due or the tick interval elapses.
    ///
    /// The dirty flag is deliberately *not* cleared here: `publish_if_due` owns
    /// it, and clearing it on a timeout would drop the snapshot a command asked
    /// for while the publisher was already awake.
    fn wait_for_work(&self, interval: Duration) {
        match self.dirty.lock() {
            Ok(dirty) => {
                if *dirty {
                    return;
                }
                drop(self.dirty_signal.wait_timeout(dirty, interval));
            }
            Err(_) => thread::sleep(interval),
        }
    }
}

/// Fills one device period from the ring, counting what it had to substitute.
///
/// Runs on the audio thread: only the lock-free ring and atomics are touched.
struct CallbackGuard<'a>(&'a AtomicBool);
impl Drop for CallbackGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl Realtime {
    pub(crate) fn seek_stage(&self, generation: u64, stage: usize) {
        if generation == 0
            || self.seek_stages[stage].load(Ordering::Relaxed) != 0
            || self.seek_generation.load(Ordering::Relaxed) != generation
        {
            return;
        }
        let now = u64::try_from(self.timing_origin.elapsed().as_micros()).unwrap_or(u64::MAX);
        let elapsed = now
            .saturating_sub(self.seek_started_us.load(Ordering::Relaxed))
            .max(1);
        let _ = self.seek_stages[stage].compare_exchange(
            0,
            elapsed,
            Ordering::Relaxed,
            Ordering::Relaxed,
        );
    }
}

fn render_pcm(realtime: &Realtime, out: &mut [f32]) {
    realtime.callback_active.store(true, Ordering::SeqCst);
    let _active = CallbackGuard(&realtime.callback_active);
    if !realtime.pcm_enabled.load(Ordering::SeqCst) {
        out.fill(0.0);
        return;
    }
    let frames = realtime.ring.read_frames(out);
    if frames > 0 && realtime.seek_stages[4].load(Ordering::Relaxed) != 0 {
        realtime.seek_stage(realtime.seek_generation.load(Ordering::Relaxed), 5);
    }
    realtime.callback_calls.fetch_add(1, Ordering::Relaxed);
    realtime
        .frames_consumed
        .fetch_add(frames as u64, Ordering::Relaxed);
    // The session's gain, applied per sample with a single lock-free read.
    // `frames` counts what the ring produced; silence stays silence, and the
    // gain never changes how much media time the callback consumed.
    let permille = realtime.volume_permille.load(Ordering::Relaxed);
    let platform_gain = f32::from(
        u16::try_from(realtime.transient_gain_permille.load(Ordering::Relaxed)).unwrap_or(1000),
    ) / 1000.0;
    let user_gain = f32::from(u16::try_from(permille).unwrap_or(u16::MAX)) / 1_000.0;
    let rate = realtime.pcm_rate.load(Ordering::Relaxed);
    let mut fade = realtime.fade.begin(rate);
    let mut song = realtime.song_gain.begin(rate);
    let enabled = realtime.fade_enabled.load(Ordering::Relaxed);
    let drained = realtime.worker_state.load(Ordering::Relaxed) == WORKER_DRAINED;
    let written = realtime.frames_written.load(Ordering::Relaxed);
    let consumed = realtime.frames_consumed.load(Ordering::Relaxed);
    let tail_window = written
        .min(u64::from(rate) * u64::from(effects::FADE_MS) / 1000)
        .max(1);
    let remaining = written
        .saturating_sub(consumed)
        .saturating_add(frames as u64);
    for (index, frame) in out[..frames * realtime.ring.channels()]
        .chunks_exact_mut(realtime.ring.channels())
        .enumerate()
    {
        let envelope = fade.next();
        #[allow(clippy::cast_precision_loss)]
        let tail = if enabled && drained {
            (remaining.saturating_sub(index as u64 + 1) as f32 / tail_window as f32).min(1.0)
        } else {
            1.0
        };
        let gain =
            platform_gain * user_gain * song.next() * if enabled { envelope * tail } else { 1.0 };
        // Exact unity is the intentional multiplication bypass.
        #[allow(clippy::float_cmp)]
        if gain != 1.0 {
            for sample in frame {
                *sample *= gain;
            }
        }
    }
    realtime.fade.finish(&fade);
    realtime.song_gain.finish(&song);
    realtime
        .available_peak_frames
        .fetch_max(realtime.ring.available_frames() as u64, Ordering::Relaxed);
    let wanted = out.len() / realtime.ring.channels();
    if frames >= wanted {
        return;
    }
    // Silence for the gap. It is not media progress, so it is never counted as
    // consumed frames (docs/design/playback.md). Whether it is an underrun or just the drained
    // tail is decided by the worker state.
    out[frames * realtime.ring.channels()..].fill(0.0);
    let missing = (wanted - frames) as u64;
    if realtime.worker_state.load(Ordering::Relaxed) == WORKER_DRAINED {
        realtime
            .tail_silence_frames
            .fetch_add(missing, Ordering::Relaxed);
    } else {
        realtime.underruns.fetch_add(1, Ordering::Relaxed);
        realtime
            .underrun_frames
            .fetch_add(missing, Ordering::Relaxed);
        realtime.underrun_flag.store(1, Ordering::Relaxed);
    }
}

/// The single publisher: natural end, underruns, refills and progress snapshots.
fn publisher_loop(inner: &Arc<Inner>) {
    loop {
        inner.wait_for_work(TICK_INTERVAL);
        if inner.shutdown.load(Ordering::SeqCst) {
            break;
        }
        inner.tick();
    }
}

/// Everything the worker reports back about a source.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct SourceSummary {
    /// Container duration, when the format reports one.
    pub duration_ms: Option<u64>,
    /// Codec short name.
    pub codec: String,
    /// Native sample rate before conversion.
    pub source_rate: u32,
    pub source_channels: u32,
    /// Resampler engine that was selected.
    pub resampler: String,
}

fn output_error_code(error: &fideflow_media_output::OutputError) -> &str {
    match error {
        fideflow_media_output::OutputError::Unavailable => "outputUnavailable",
        fideflow_media_output::OutputError::DeviceEnumeration => "outputEnumerationFailed",
        fideflow_media_output::OutputError::DeviceOpen(code) => code,
    }
}

/// Builds the diagnostics view of an opened device.
fn diagnostics_from(info: &fideflow_media_output::OutputInfo) -> OutputDiagnostics {
    OutputDiagnostics {
        device_name: info.device_name.clone(),
        sample_rate: info.sample_rate,
        channels: info.channels,
        internal_format: info.internal_format,
        period_frames: info.period_frames,
        periods: info.periods,
        period_seconds: info.period_seconds,
    }
}

/// A session id that is unique per process and creation.
fn new_session_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    format!("session-{nanos:x}")
}

/// Plans one command with the executor held and returns the serialized reply
/// plus the effects to run after the guard is dropped.
///
/// The signature is what keeps rule 2 of the threading contract true: the
/// caller drops the guard before `run_effects`, so no effect can call back into
/// `core` and deadlock against the non-reentrant mutex.
fn plan_locked(
    inner: &Inner,
    core: &mut MutexGuard<'_, Core>,
    command_json: &str,
) -> (String, Vec<Effect>) {
    let envelope = match plan::parse_envelope(command_json) {
        Ok(envelope) => envelope,
        Err(rejection) => return (unparseable_reply(&rejection), Vec::new()),
    };
    let key = plan::idempotency_key(&envelope);
    if let Some(cached) = core.replay(&key, command_json) {
        return (cached.to_string(), Vec::new());
    }
    if core.conflicts(&key, command_json) {
        return (
            plan::rejection_reply(&envelope, &Rejection::IdempotencyConflict),
            Vec::new(),
        );
    }
    let frames = inner.realtime.frames_consumed.load(Ordering::Relaxed);
    let received =
        u64::try_from(inner.realtime.timing_origin.elapsed().as_micros()).unwrap_or(u64::MAX);
    let mut plan = plan::plan(core, &envelope, command_json, frames);
    if plan
        .effects
        .iter()
        .any(|effect| matches!(effect, Effect::SeekItem { .. }))
    {
        inner.realtime.seek_generation.store(0, Ordering::Relaxed);
        for stage in &inner.realtime.seek_stages {
            stage.store(0, Ordering::Relaxed);
        }
        inner
            .realtime
            .seek_started_us
            .store(received, Ordering::Relaxed);
        inner
            .realtime
            .seek_generation
            .store(core.generation, Ordering::Relaxed);
    }
    schedule_transport_effects(inner, core, &envelope, &mut plan);
    (plan.reply.to_json().to_string(), plan.effects)
}

fn schedule_transport_effects(
    inner: &Inner,
    core: &mut Core,
    envelope: &Envelope,
    plan: &mut Plan,
) {
    if !plan.effects.is_empty() {
        if matches!(
            envelope.command,
            Command::Play
                | Command::Pause
                | Command::Stop
                | Command::ClearQueue
                | Command::PermissionExpired
                | Command::OfflineGap
                | Command::Seek { .. }
                | Command::SkipNext
                | Command::SkipPrevious
                | Command::PlayItem
                | Command::LoadQueue { .. }
        ) {
            core.transport_serial = core.transport_serial.wrapping_add(1);
        }
        let disruptive = plan.effects.iter().any(|effect| {
            matches!(
                effect,
                Effect::StartItem { .. } | Effect::PauseOutput | Effect::StopOutput
            )
        });
        let immediate = matches!(
            envelope.command,
            Command::PermissionExpired
                | Command::OfflineGap
                | Command::ClearQueue
                | Command::SetTransientGain { .. }
                | Command::SetInterruption { .. }
        );
        let seek = matches!(envelope.command, Command::Seek { .. });
        if immediate || seek || matches!(envelope.command, Command::SetOutputConfiguration { .. }) {
            core.deferred_effects = None;
        } else if matches!(envelope.command, Command::Play)
            && core.deferred_effects.as_ref().is_some_and(|pending| {
                pending
                    .effects
                    .iter()
                    .any(|effect| matches!(effect, Effect::PauseOutput))
            })
        {
            core.deferred_effects = None;
            inner.realtime.fade.request(1.0);
        }
        let pause_preparing = matches!(envelope.command, Command::Pause)
            && core.deferred_effects.as_ref().is_some_and(|pending| {
                pending
                    .effects
                    .iter()
                    .any(|effect| matches!(effect, Effect::StartItem { .. }))
            });
        let source_preparing = matches!(envelope.command, Command::ProvideSource { .. })
            && core.deferred_effects.as_ref().is_some_and(|pending| {
                pending.generation == core.generation
                    && pending.item_id.as_deref()
                        == core.current_item().map(|item| item.queue_item_id.as_str())
                    && pending
                        .effects
                        .iter()
                        .any(|effect| matches!(effect, Effect::StartItem { .. }))
            });
        if source_preparing {
            // The pending transition already owns the start position and fade
            // deadline. It will read the newly provided source when it runs.
            plan.effects
                .retain(|effect| !matches!(effect, Effect::StartItem { .. }));
        } else if pause_preparing {
            let serial = core.transport_serial;
            if let Some(pending) = core.deferred_effects.as_mut() {
                pending.serial = serial;
            }
            plan.effects
                .retain(|effect| !matches!(effect, Effect::PauseOutput));
        } else if disruptive && !immediate {
            core.deferred_effects = None;
            if core.fade_enabled
                && inner.realtime.pcm_enabled.load(Ordering::SeqCst)
                && inner.realtime.ring.available_frames() > 0
            {
                inner.realtime.fade.request(0.0);
                core.deferred_effects = Some(DeferredEffects {
                    generation: core.generation,
                    serial: core.transport_serial,
                    item_id: core.current_item().map(|item| item.queue_item_id.clone()),
                    position_ms: plan.effects.iter().find_map(|effect| match effect {
                        Effect::StartItem { position_ms, .. } => Some(*position_ms),
                        Effect::StopOutput => Some(core.anchor_media_us / 1_000),
                        _ => None,
                    }),
                    deadline: Instant::now() + Duration::from_millis(350),
                    effects: std::mem::take(&mut plan.effects),
                });
                plan.effects.push(Effect::Publish);
            }
        }
    }
}

/// Reply for a command that could not even be parsed.
fn unparseable_reply(rejection: &Rejection) -> String {
    serde_json::json!({
        "schemaVersion": SCHEMA_VERSION,
        "kind": "result",
        "commandId": "unknown",
        "status": "rejected",
        "errorCode": rejection.code(),
    })
    .to_string()
}

#[cfg(test)]
mod permission_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn asynchronous_readiness_advances_the_snapshot_revision_when_paused() {
        let session = PlaybackSession::new();
        session.inner.core().is_seeking = true;
        let before = session.inner.core().session_revision;
        let generation = session.inner.core().generation;
        session.inner.on_primed(
            generation,
            600_000,
            &SourceSummary {
                duration_ms: Some(3000),
                codec: String::from("wav"),
                source_rate: 44100,
                source_channels: 2,
                resampler: String::from("swr"),
            },
        );
        let core = session.inner.core();
        assert!(core.session_revision > before);
        assert_eq!(core.phase, Phase::Ready);
        assert!(!core.is_seeking);
        assert!(!core.play_when_ready);
        drop(core);
        session.shutdown();
    }

    #[test]
    fn stale_worker_notifications_do_not_clear_a_new_seek() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.generation = 2;
            core.phase = Phase::Resolving;
            core.is_seeking = true;
        }
        let before = session.inner.core().session_revision;
        session.inner.on_primed(
            1,
            0,
            &SourceSummary {
                duration_ms: Some(3000),
                codec: String::from("wav"),
                source_rate: 44100,
                source_channels: 2,
                resampler: String::from("soxr"),
            },
        );
        session.inner.on_failed(1, "decodeFailed", false);
        let core = session.inner.core();
        assert!(core.is_seeking);
        assert_eq!(core.phase, Phase::Resolving);
        assert_eq!(core.session_revision, before);
        assert!(core.error_code.is_none());
        assert!(!session.inner.realtime.pcm_enabled.load(Ordering::SeqCst));
        drop(core);
        session.shutdown();
    }

    #[test]
    fn gated_callback_neither_consumes_pcm_nor_counts_underruns() {
        let realtime = Realtime::new();
        assert_eq!(realtime.ring.write_frames(&[0.25; 128]), 64);
        let mut out = [1.0; 128];
        render_pcm(&realtime, &mut out);
        assert!(out.iter().all(|sample| *sample == 0.0));
        assert_eq!(realtime.ring.available_frames(), 64);
        assert_eq!(realtime.frames_consumed.load(Ordering::Relaxed), 0);
        assert_eq!(realtime.underruns.load(Ordering::Relaxed), 0);
        assert!(!realtime.callback_active.load(Ordering::SeqCst));
        realtime.pcm_enabled.store(true, Ordering::SeqCst);
        render_pcm(&realtime, &mut out);
        assert_eq!(realtime.frames_consumed.load(Ordering::Relaxed), 64);
        assert!(out.iter().all(|sample| *sample > 0.0));
        assert!(!realtime.callback_active.load(Ordering::SeqCst));
    }

    #[test]
    fn gate_waits_for_callback_before_clearing_pcm() {
        let session = PlaybackSession::new();
        let realtime = Arc::clone(&session.inner.realtime);
        realtime.pcm_enabled.store(true, Ordering::SeqCst);
        let done = Arc::new(AtomicBool::new(false));
        let finished = Arc::clone(&done);
        let callback = thread::spawn(move || {
            let mut out = [0.0; 256];
            while !finished.load(Ordering::SeqCst) {
                render_pcm(&realtime, &mut out);
            }
        });
        for _ in 0..100 {
            session.inner.gate_pcm();
            let consumed = session
                .inner
                .realtime
                .frames_consumed
                .load(Ordering::Relaxed);
            session.inner.realtime.ring.clear();
            assert_eq!(
                session
                    .inner
                    .realtime
                    .frames_consumed
                    .load(Ordering::Relaxed),
                consumed
            );
            session
                .inner
                .realtime
                .pcm_enabled
                .store(true, Ordering::SeqCst);
        }
        done.store(true, Ordering::SeqCst);
        callback.join().unwrap();
        session.shutdown();
    }

    #[test]
    fn expiry_clears_buffered_pcm_and_preserves_queue_and_progress() {
        let session = PlaybackSession::with_session_id(String::from("expiry-test"));
        let command = json!({"schemaVersion": 1, "kind": "loadQueue", "clientId": "test", "commandId": "load", "targetSessionId": "expiry-test", "expectedQueueRevision": "0", "payload": {"items": [{"queueItemId": "item", "trackId": "song"}], "startItemId": "item", "autoplay": false}});
        let _ = session.execute_json(&command.to_string());
        {
            let mut core = session.inner.core();
            core.anchor_media_us = 12_000_000;
            core.phase = Phase::Paused;
            core.queue[0].source_uri = Some(String::from("ffinput://1234"));
        }
        session.inner.realtime.ring.write_frames(&[0.5; 200]);
        assert!(session.inner.realtime.ring.available_frames() > 0);
        let revoke = json!({"schemaVersion": 1, "kind": "stop", "clientId": "test", "commandId": "expired", "targetSessionId": "expiry-test", "payload": {"permissionExpired": true}});
        let _ = session.execute_json(&revoke.to_string());
        assert_eq!(session.inner.realtime.ring.available_frames(), 0);
        let core = session.inner.core();
        assert_eq!(core.position_ms(0), 12_000);
        assert_eq!(core.queue.len(), 1);
        assert!(!core.play_when_ready);
        assert!(core.queue[0].source_uri.is_none());
        assert_eq!(core.error_code.as_deref(), Some("playback.vipExpired"));
    }
}

// The default menu entry is shared output. Re-prime on the next manual Play
// because the removed exclusive device may have used different PCM geometry.
fn fallback_to_default(core: &mut Core) {
    if core.output_configuration.device_uid.is_some() || core.output_configuration.exclusive {
        core.output_configuration.device_uid = None;
        core.output_configuration.exclusive = false;
        core.output_version += 1;
    }
    core.active_device_uid = None;
    core.exclusive_active = false;
    if core.current.is_some() {
        core.phase = Phase::Paused;
    }
}

// An absent default while hog mode is active is not a new output route.
fn should_follow_default(
    config: &OutputConfiguration,
    running: bool,
    changes: u32,
    active: Option<&str>,
    default: Option<&str>,
) -> bool {
    changes & 2 != 0
        && config.device_uid.is_none()
        && running
        && default.is_some()
        && active != default
}

#[cfg(test)]
mod output_tests {
    use super::*;
    #[test]
    fn wake_with_a_removed_previous_route_cannot_autoplay_the_default_speaker() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.queue = vec![QueueItem::new("item".into(), "track".into())];
            core.current = Some(0);
            core.phase = Phase::Ready;
            core.play_when_ready = true;
            core.anchor_media_us = 12_000_000;
            core.active_device_uid = Some("fideflow-test-removed-route-4b48a3".into());
            // Follow-default preference must not override the disconnect safety rule.
            assert!(core.output_configuration.device_uid.is_none());
        }
        session.inner.validate_recovery_output();
        let core = session.inner.core();
        assert!(!core.play_when_ready);
        assert!(!core.output_running);
        assert!(core.output_error.is_some());
        assert_eq!(core.position_ms(0), 12_000);
        assert_eq!(core.queue.len(), 1);
        drop(core);
        session.shutdown();
    }

    #[test]
    fn unavailable_selection_also_falls_back_while_already_paused() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.output_configuration = OutputConfiguration {
                device_uid: Some("removed".into()),
                exclusive: true,
                ..OutputConfiguration::default()
            };
            core.active_device_uid = Some("removed".into());
            core.play_when_ready = false;
        }
        session.inner.output_failed("outputDeviceUnavailable");
        let core = session.inner.core();
        assert_eq!(core.output_configuration, OutputConfiguration::default());
        assert_eq!(core.active_device_uid, None);
        assert!(!core.play_when_ready);
        assert!(!core.output_running);
        assert!(!core.exclusive_active);
        drop(core);
        session.shutdown();
    }
    #[test]
    fn metadata_refresh_does_not_gate_pcm_or_change_playback_intent() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.phase = Phase::Ready;
            core.play_when_ready = true;
            core.output_running = true;
            // A pending configuration also must not be cleared by metadata.
            core.output_busy = true;
            core.generation = 17;
        }
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        session.inner.change_output(None);
        let core = session.inner.core();
        assert!(core.play_when_ready);
        assert!(core.output_running);
        assert!(core.output_busy);
        assert_eq!(core.generation, 17);
        assert!(session.inner.realtime.pcm_enabled.load(Ordering::SeqCst));
        drop(core);
        session.shutdown();
    }
    #[test]
    fn default_output_notifications_do_not_mark_the_device_list_dirty() {
        let session = PlaybackSession::new();
        session.inner.core().output_devices = vec![
            fideflow_media_output::PlaybackDevice {
                uid: "speaker".into(),
                is_default: true,
                ..Default::default()
            },
            fideflow_media_output::PlaybackDevice {
                uid: "usb".into(),
                ..Default::default()
            },
        ];
        // Acquisition can temporarily hide the default; release restores it.
        for default in [None, Some("speaker"), Some("usb")] {
            session.inner.observe_output_changes(2, default);
            assert!(!session.inner.core().output_devices_pending);
        }
        assert!(!session.inner.core().output_devices[0].is_default);
        assert!(session.inner.core().output_devices[1].is_default);
        // A real list change must still be deferred until pause/selector refresh.
        session.inner.observe_output_changes(1, None);
        assert!(session.inner.core().output_devices_pending);
        session.shutdown();
    }
    #[test]
    fn a_health_check_from_before_pause_does_not_report_a_closed_stream() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.active_device_uid = Some("speaker".into());
            core.output_running = true;
            // The pause planner clears intent before its close effect runs.
            core.play_when_ready = false;
        }
        assert!(session.inner.check_running_output(Some("speaker"), true));
        assert_eq!(session.inner.core().output_error, None);
        session.inner.pause_output();
        assert!(session.inner.check_running_output(Some("speaker"), true));
        assert_eq!(session.inner.core().output_error, None);
        session.shutdown();
    }
    #[test]
    fn an_unexpected_closed_stream_while_playing_is_still_a_fault() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.active_device_uid = Some("speaker".into());
            core.output_running = true;
            core.play_when_ready = true;
        }
        assert!(session.inner.check_running_output(Some("speaker"), true));
        assert_eq!(
            session.inner.core().output_error.as_deref(),
            Some("outputStopped")
        );
        assert!(!session.inner.core().play_when_ready);
        session.shutdown();
    }
    #[test]
    fn missing_default_during_exclusive_playback_does_not_switch() {
        let follow = OutputConfiguration {
            device_uid: None,
            exclusive: true,
            ..OutputConfiguration::default()
        };
        assert!(!should_follow_default(
            &follow,
            true,
            2,
            Some("speaker"),
            None
        ));
        assert!(!should_follow_default(
            &follow,
            true,
            2,
            Some("speaker"),
            Some("speaker")
        ));
        assert!(should_follow_default(
            &follow,
            true,
            2,
            Some("speaker"),
            Some("usb")
        ));
        assert!(!should_follow_default(
            &follow,
            false,
            2,
            Some("speaker"),
            Some("usb")
        ));
        let explicit = OutputConfiguration {
            device_uid: Some("speaker".into()),
            exclusive: true,
            ..OutputConfiguration::default()
        };
        assert!(!should_follow_default(
            &explicit,
            true,
            2,
            Some("speaker"),
            Some("usb")
        ));
    }
    #[test]
    fn failed_live_switch_stops_and_cannot_reopen_without_play_intent() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.phase = Phase::Ready;
            core.play_when_ready = true;
            core.output_busy = true;
            core.output_version = 1;
            core.output_configuration.exclusive = true;
        }
        session
            .inner
            .finish_output_failure("outputExclusiveUnavailable", true, 1);
        // Subsequent worker/publisher attempts cannot reopen the device.
        for _ in 0..3 {
            session.inner.start_output();
        }
        let core = session.inner.core();
        assert!(!core.play_when_ready);
        assert!(!core.output_running);
        assert!(!core.output_busy);
        assert_eq!(
            core.output_error.as_deref(),
            Some("outputExclusiveUnavailable")
        );
        assert!(session.inner.output_context.lock().unwrap().is_none());
        drop(core);
        session.shutdown();
    }
    #[test]
    fn device_failure_preserves_source_pcm_generation_and_position() {
        let session = PlaybackSession::new();
        let inner = &session.inner;
        let command = serde_json::json!({"schemaVersion":1,"kind":"loadQueue","clientId":"test","commandId":"load","targetSessionId":session.session_id(),"expectedQueueRevision":"0","payload":{"items":[{"queueItemId":"a","trackId":"t"}],"startItemId":"a","autoplay":false}});
        let _ = session.execute_json(&command.to_string());
        {
            let mut core = inner.core();
            core.phase = Phase::Ready;
            core.play_when_ready = true;
            core.output_running = true;
            core.queue[0].source_uri = Some("file:///retained.wav".into());
            core.pcm_rate = 44100;
            core.anchor_media_us = 500_000;
            core.anchor_frames = 0;
            core.exclusive_active = true;
            core.output_configuration = OutputConfiguration {
                device_uid: Some("removed".into()),
                exclusive: true,
                ..OutputConfiguration::default()
            };
        }
        inner
            .realtime
            .frames_consumed
            .store(44100, Ordering::Relaxed);
        inner.realtime.ring.write_frames(&[0.25; 32]);
        let before = inner.core().generation;
        inner.output_failed("outputDeviceRemoved");
        let core = inner.core();
        assert_eq!(core.generation, before);
        assert_eq!(core.phase, Phase::Paused);
        assert_eq!(core.output_configuration, OutputConfiguration::default());
        assert_eq!(core.active_device_uid, None);
        assert_eq!(core.position_ms(44100), 1500);
        assert_eq!(
            core.queue[0].source_uri.as_deref(),
            Some("file:///retained.wav")
        );
        assert!(!core.play_when_ready);
        assert!(!core.output_running);
        assert!(!core.exclusive_active);
        assert_eq!(core.error_code, None);
        assert_eq!(core.output_error.as_deref(), Some("outputDeviceRemoved"));
        assert_eq!(inner.realtime.ring.available_frames(), 16);
        drop(core);
        session.shutdown();
    }
    #[test]
    fn output_failure_during_preparation_can_be_retried() {
        let session = PlaybackSession::new();
        session.inner.core().phase = Phase::Loading;
        session.inner.output_failed("outputDeviceUnavailable");
        assert_eq!(session.inner.core().phase, Phase::Paused);
        session.shutdown();
    }
    #[test]
    fn a_stale_output_rebuild_does_not_restore_a_skipped_track_or_leave_busy() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.generation = 2;
            core.output_version = 1;
            core.output_busy = true;
        }
        session
            .inner
            .start_item_transaction(0, 1000, Some(1), None, Some(1), None);
        let core = session.inner.core();
        assert_eq!(core.generation, 2);
        assert_eq!(core.current, None);
        assert!(!core.output_busy);
        drop(core);
        session.shutdown();
    }
    #[test]
    fn an_old_switch_failure_does_not_overwrite_a_new_request() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.output_version = 2;
            core.output_busy = true;
        }
        session
            .inner
            .finish_output_failure("outputExclusiveUnavailable", false, 1);
        let core = session.inner.core();
        assert!(core.output_busy);
        assert_eq!(core.output_error, None);
        drop(core);
        session.shutdown();
    }
    #[test]
    fn stale_configuration_never_opens_a_device() {
        let session = PlaybackSession::new();
        session.inner.core().output_version = 2;
        session.inner.change_output(Some((
            OutputConfiguration {
                device_uid: Some("old".into()),
                exclusive: true,
                ..OutputConfiguration::default()
            },
            1,
        )));
        assert_eq!(
            session.inner.core().output_configuration,
            OutputConfiguration::default()
        );
        assert!(session.inner.output_context.lock().unwrap().is_none());
        session.shutdown();
    }
    #[test]
    fn software_gain_uses_dynamic_geometry_and_bypasses_unity() {
        let realtime = Realtime::new();
        realtime.ring.configure_channels(1);
        realtime.volume_permille.store(1000, Ordering::Relaxed);
        realtime.pcm_enabled.store(true, Ordering::SeqCst);
        let input = [-1.0, 0.999_999_9, 0.25, 0.0];
        realtime.ring.write_frames(&input);
        let mut out = [0.0; 4];
        render_pcm(&realtime, &mut out);
        assert_eq!(input.map(f32::to_bits), out.map(f32::to_bits));
        realtime.volume_permille.store(500, Ordering::Relaxed);
        realtime.ring.write_frames(&input);
        render_pcm(&realtime, &mut out);
        assert_eq!(out.map(f32::to_bits), input.map(|v| (v * 0.5).to_bits()));
    }
    #[test]
    fn platform_gain_multiplies_user_volume_without_changing_it() {
        let realtime = Realtime::new();
        realtime.ring.configure_channels(1);
        realtime.volume_permille.store(500, Ordering::Relaxed);
        realtime
            .transient_gain_permille
            .store(200, Ordering::Relaxed);
        realtime.pcm_enabled.store(true, Ordering::SeqCst);
        realtime.ring.write_frames(&[1.0, -1.0]);
        let mut out = [0.0; 2];
        render_pcm(&realtime, &mut out);
        assert!((out[0] - 0.1).abs() < f32::EPSILON);
        assert!((out[1] + 0.1).abs() < f32::EPSILON);
        assert_eq!(realtime.volume_permille.load(Ordering::Relaxed), 500);
        realtime
            .transient_gain_permille
            .store(1000, Ordering::Relaxed);
        realtime.ring.write_frames(&[1.0, -1.0]);
        render_pcm(&realtime, &mut out);
        assert_eq!(out.map(f32::to_bits), [0.5_f32, -0.5].map(f32::to_bits));
    }

    #[test]
    fn watermarks_follow_rate_and_fit_the_ring() {
        let session = PlaybackSession::new();
        session
            .inner
            .realtime
            .pcm_rate
            .store(44100, Ordering::Relaxed);
        assert_eq!(session.inner.start_watermark(), 22050);
        assert_eq!(session.inner.high_watermark(), 66150);
        session.inner.realtime.ring.configure_channels(8);
        session
            .inner
            .realtime
            .pcm_rate
            .store(384_000, Ordering::Relaxed);
        assert!(session.inner.high_watermark() < session.inner.realtime.ring.capacity_frames());
        assert!(session.inner.start_watermark() < session.inner.high_watermark());
        session.shutdown();
    }
    #[test]
    fn sample_rate_logs_reach_the_event_sink_without_a_ui_attachment() {
        let session = PlaybackSession::new();
        let (sender, receiver) = std::sync::mpsc::channel();
        session.set_event_sink(Some(Arc::new(move |message| {
            let document: serde_json::Value = serde_json::from_str(message).unwrap();
            if document["kind"] == "outputSampleRates" {
                let _ = sender.send(document);
            }
        })));
        {
            let mut core = session.inner.core();
            core.output_configuration.device_uid = Some("secret-url-and-path".into());
            core.output_configuration.resampling_enabled = true;
            core.output_configuration.target_sample_rate = 96_000;
            core.pcm_rate = 96_000;
        }
        for _ in 0..2 {
            session
                .inner
                .log_output_sample_rates("devicesRefreshed", Some(44_100));
            let document = receiver.recv_timeout(Duration::from_secs(3)).unwrap();
            assert_eq!(document["schemaVersion"], 1);
            assert_eq!(document["event"], "devicesRefreshed");
            assert_eq!(document["sourceRateHz"], 44_100);
            assert_eq!(document["pcmRateHz"], 96_000);
            assert_eq!(document["targetRateHz"], 96_000);
            assert_eq!(document["systemRateHz"], serde_json::Value::Null);
            assert!(!document.to_string().contains("secret-url-and-path"));
        }
        session.shutdown();
    }

    #[test]
    fn resampling_settings_survive_route_fallback_and_reach_snapshots() {
        let session = PlaybackSession::new();
        {
            let mut core = session.inner.core();
            core.output_configuration = OutputConfiguration {
                device_uid: Some("removed".into()),
                exclusive: true,
                resampling_enabled: true,
                target_sample_rate: 96_000,
            };
            core.pcm_rate = 96_000;
            fallback_to_default(&mut core);
            assert!(core.output_configuration.resampling_enabled);
            assert_eq!(core.output_configuration.target_sample_rate, 96_000);
            assert!(!core.output_configuration.exclusive);
            assert!(core.output_configuration.device_uid.is_none());
        }
        let snapshot: serde_json::Value = serde_json::from_str(&session.snapshot_json()).unwrap();
        assert_eq!(snapshot["outputSettings"]["resamplingEnabled"], true);
        assert_eq!(snapshot["outputSettings"]["targetSampleRate"], 96_000);
        let diagnostics: serde_json::Value =
            serde_json::from_str(&session.diagnostics_json()).unwrap();
        assert_eq!(diagnostics["output"]["requestedRate"], 96_000);
        session.shutdown();
    }

    #[test]
    fn resampling_commands_default_off_and_preserve_each_selected_rate() {
        for exclusive in [false, true] {
            for enabled in [false, true] {
                for rate in fideflow_media_output::RESAMPLING_SAMPLE_RATES {
                    let text = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration",
                        "clientId":"test","commandId":"configure","targetSessionId":"s",
                        "payload":{"exclusive":exclusive,"resamplingEnabled":enabled,"targetSampleRate":rate}}).to_string();
                    let envelope = plan::parse_envelope(&text).unwrap();
                    let mut core = Core::new("s".into());
                    let result = plan::plan(&mut core, &envelope, &text, 0);
                    assert!(result.effects.iter().any(|effect| matches!(effect,
                        Effect::ConfigureOutput { exclusive: value, resampling_enabled,
                            target_sample_rate, .. }
                            if *value == exclusive && *resampling_enabled == enabled && *target_sample_rate == rate)));
                }
            }
        }
        let text = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration",
            "clientId":"test","commandId":"legacy","targetSessionId":"s",
            "payload":{"exclusive":true}})
        .to_string();
        assert!(matches!(
            plan::parse_envelope(&text).unwrap().command,
            Command::SetOutputConfiguration {
                exclusive: true,
                resampling_enabled: false,
                target_sample_rate: 48_000,
                ..
            }
        ));
    }

    #[test]
    fn configuration_parser_validates_uid_and_exclusive() {
        for payload in [
            serde_json::json!({"deviceUid":"","exclusive":true}),
            serde_json::json!({"deviceUid":"abc"}),
            serde_json::json!({"exclusive":true,"resamplingEnabled":1}),
            serde_json::json!({"exclusive":true,"resamplingEnabled":null}),
            serde_json::json!({"exclusive":true,"targetSampleRate":12345}),
            serde_json::json!({"exclusive":true,"targetSampleRate":48000.5}),
            serde_json::json!({"exclusive":true,"targetSampleRate":null}),
            serde_json::json!({"deviceUid":"a\u{0}b","exclusive":false}),
        ] {
            let envelope = serde_json::json!({"schemaVersion":1,"kind":"setOutputConfiguration","clientId":"a","commandId":"b","targetSessionId":"c","payload":payload});
            assert!(plan::parse_envelope(&envelope.to_string()).is_err());
        }
    }
}

#[cfg(test)]
#[allow(
    clippy::float_cmp,
    clippy::needless_pass_by_value,
    clippy::manual_assert,
    clippy::manual_is_variant_and
)]
mod playback_effect_tests {
    use super::*;
    use serde_json::{Value, json};

    fn pcm(frames: usize, channels: usize) -> Realtime {
        let realtime = Realtime::new();
        realtime.ring.configure_channels(channels);
        realtime.volume_permille.store(1000, Ordering::Relaxed);
        realtime.pcm_enabled.store(true, Ordering::SeqCst);
        realtime
            .worker_state
            .store(WORKER_WORKING, Ordering::Relaxed);
        let samples = vec![0.25; frames * channels];
        let cancel = AtomicI32::new(0);
        realtime.ring.write_all(&samples, &cancel, None);
        realtime
            .frames_written
            .store(frames as u64, Ordering::Relaxed);
        realtime
    }

    #[test]
    fn callback_combines_gain_and_fade_without_changing_user_volume() {
        let realtime = pcm(14400, 6);
        realtime.fade_enabled.store(true, Ordering::Relaxed);
        realtime.fade.reset(0.0);
        realtime.fade.request(1.0);
        realtime.song_gain.reset(2.0);
        let mut out = vec![0.0; 14400 * 6];
        render_pcm(&realtime, &mut out);
        assert!(out[0] > 0.0 && out[0] < 0.0001);
        assert_eq!(*out.last().unwrap(), 0.5);
        for frame in out.as_chunks::<6>().0 {
            assert!(frame.iter().all(|v| *v == frame[0]));
        }
        assert_eq!(realtime.volume_permille.load(Ordering::Relaxed), 1000);
        assert_eq!(realtime.frames_consumed.load(Ordering::Relaxed), 14400);
    }

    #[test]
    fn short_drained_tail_ends_at_zero_and_underrun_does_not_advance_ramps() {
        let realtime = pcm(100, 2);
        realtime.fade_enabled.store(true, Ordering::Relaxed);
        realtime
            .worker_state
            .store(WORKER_DRAINED, Ordering::Relaxed);
        let mut out = vec![1.0; 240];
        render_pcm(&realtime, &mut out);
        assert!(
            out[..200]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|f| f[0])
                .is_sorted_by(|a, b| a >= b)
        );
        assert_eq!(out[198], 0.0);
        assert!(out[200..].iter().all(|v| *v == 0.0));
        realtime.song_gain.request(2.0);
        render_pcm(&realtime, &mut out);
        assert_eq!(realtime.song_gain.value(), 1.0);
        assert_eq!(realtime.frames_consumed.load(Ordering::Relaxed), 100);
    }

    fn envelope(kind: &str, id: &str, payload: Value) -> String {
        json!({"schemaVersion":1,"kind":kind,"clientId":"effects",
            "commandId":id,"targetSessionId":"effects-test","payload":payload})
        .to_string()
    }

    #[test]
    fn interruption_gates_pcm_immediately_and_preserves_the_frame_clock() {
        let session = PlaybackSession::with_session_id("effects-test".into());
        {
            let mut core = session.inner.core();
            core.queue = vec![QueueItem::new("item".into(), "track".into())];
            core.current = Some(0);
            core.phase = Phase::Ready;
            core.play_when_ready = true;
            core.fade_enabled = true;
            core.anchor_media_us = 12_000_000;
        }
        session.inner.realtime.ring.write_frames(&[0.25; 200]);
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        let begin = envelope(
            "setInterruption",
            "sleep",
            json!({"interruptionId":"cycle","active":true}),
        );
        let reply: Value = serde_json::from_str(&session.execute_json(&begin)).unwrap();
        assert_eq!(reply["status"], "accepted");
        let before = session
            .inner
            .realtime
            .frames_consumed
            .load(Ordering::Relaxed);
        let available = session.inner.realtime.ring.available_frames();
        let mut output = [1.0; 64];
        render_pcm(&session.inner.realtime, &mut output);
        assert_eq!(output, [0.0; 64]);
        assert_eq!(
            session
                .inner
                .realtime
                .frames_consumed
                .load(Ordering::Relaxed),
            before
        );
        assert_eq!(session.inner.realtime.ring.available_frames(), available);
        assert_eq!(session.inner.core().position_ms(before), 12_000);
        assert!(!session.inner.core().output_running);
        assert!(session.inner.device().is_none());
        // Simulate a failed reopen: it must not be retried by a later wake event.
        session.inner.output_failed("outputStopped");
        let end = envelope(
            "setInterruption",
            "wake",
            json!({"interruptionId":"cycle","active":false}),
        );
        let reply: serde_json::Value = serde_json::from_str(&session.execute_json(&end)).unwrap();
        assert_eq!(reply["status"], "accepted");
        assert!(!session.inner.core().play_when_ready);
        assert_eq!(
            session.inner.core().output_error.as_deref(),
            Some("outputStopped")
        );
        session.shutdown();
    }

    #[test]
    fn interruption_finishes_pending_skip_preparation_without_a_fade_delay() {
        let session = PlaybackSession::with_session_id("effects-test".into());
        let mut core = session.inner.core();
        core.queue = vec![QueueItem::new("item".into(), "track".into())];
        core.current = Some(0);
        core.phase = Phase::Resolving;
        core.play_when_ready = true;
        core.fade_enabled = true;
        core.deferred_effects = Some(DeferredEffects {
            generation: core.generation,
            serial: core.transport_serial,
            item_id: Some("item".into()),
            position_ms: Some(0),
            deadline: Instant::now() + Duration::from_millis(350),
            effects: vec![
                Effect::StartItem {
                    index: 0,
                    position_ms: 0,
                },
                Effect::Publish,
            ],
        });
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        session.inner.realtime.ring.write_frames(&[0.25; 200]);
        let (_, effects) = plan_locked(
            &session.inner,
            &mut core,
            &envelope(
                "setInterruption",
                "sleep",
                json!({"interruptionId":"cycle","active":true}),
            ),
        );
        assert!(core.deferred_effects.is_none());
        assert_eq!(effects.first(), Some(&Effect::PauseOutput));
        assert!(effects.contains(&Effect::StartItem {
            index: 0,
            position_ms: 0
        }));
        assert_eq!(core.suppression, vec![core::Suppression::Interruption]);
    }

    #[test]
    fn pause_is_deferred_and_new_play_cancels_its_completion() {
        let session = PlaybackSession::with_session_id("effects-test".into());
        let mut core = session.inner.core();
        core.queue = vec![QueueItem::new("item".into(), "track".into())];
        core.current = Some(0);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        core.fade_enabled = true;
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        session
            .inner
            .realtime
            .ring
            .write_all(&vec![0.1; 2000], &AtomicI32::new(0), None);
        let (reply, effects) = plan_locked(
            &session.inner,
            &mut core,
            &envelope("pause", "pause", json!({})),
        );
        assert_eq!(
            serde_json::from_str::<Value>(&reply).unwrap()["status"],
            "accepted"
        );
        assert_eq!(effects, vec![Effect::Publish]);
        let pending = core.deferred_effects.take().unwrap();
        core.deferred_effects = Some(pending);
        let (_, effects) = plan_locked(
            &session.inner,
            &mut core,
            &envelope("play", "play", json!({})),
        );
        assert!(core.deferred_effects.is_none());
        assert!(effects.contains(&Effect::ResumeOutput));
        assert!(core.play_when_ready);
    }

    #[test]
    fn consecutive_skips_replace_the_pending_item_and_do_not_inherit_old_position() {
        let session = PlaybackSession::with_session_id("effects-test".into());
        let mut core = session.inner.core();
        core.queue = ["a", "b", "c"]
            .into_iter()
            .map(|id| QueueItem::new(id.into(), id.into()))
            .collect();
        core.current = Some(0);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        core.fade_enabled = true;
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        session
            .inner
            .realtime
            .frames_consumed
            .store(480_000, Ordering::Relaxed);
        session
            .inner
            .realtime
            .ring
            .write_all(&vec![0.1; 2000], &AtomicI32::new(0), None);
        for id in ["skip-1", "skip-2"] {
            let mut command: Value =
                serde_json::from_str(&envelope("skipNext", id, json!({}))).unwrap();
            command["expectedQueueRevision"] = json!("0");
            let (reply, _) = plan_locked(&session.inner, &mut core, &command.to_string());
            assert_eq!(
                serde_json::from_str::<Value>(&reply).unwrap()["status"],
                "accepted"
            );
            assert_eq!(core.position_ms(481_000), 0);
        }
        assert_eq!(core.current_item().unwrap().queue_item_id, "c");
        assert_eq!(
            core.deferred_effects.as_ref().unwrap().item_id.as_deref(),
            Some("c")
        );
        let generation = core.generation;
        drop(core);
        session
            .inner
            .start_item_transaction(1, 0, Some(generation - 1), None, None, Some("b"));
        assert_eq!(
            session.inner.core().current_item().unwrap().queue_item_id,
            "c"
        );
        assert!(session.inner.realtime.pcm_enabled.load(Ordering::SeqCst));
    }

    #[test]
    fn prefetch_during_deferred_skip_preserves_start_position_and_deadline() {
        let session = PlaybackSession::with_session_id("effects-test".into());
        let mut core = session.inner.core();
        core.queue = ["a", "b"]
            .into_iter()
            .map(|id| QueueItem::new(id.into(), id.into()))
            .collect();
        core.current = Some(0);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        core.fade_enabled = true;
        core.anchor_media_us = 120_000_000;
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        session
            .inner
            .realtime
            .ring
            .write_all(&vec![0.1; 2000], &AtomicI32::new(0), None);
        let mut skip: Value =
            serde_json::from_str(&envelope("skipNext", "skip", json!({}))).unwrap();
        skip["expectedQueueRevision"] = json!("0");
        let (reply, _) = plan_locked(&session.inner, &mut core, &skip.to_string());
        assert_eq!(
            serde_json::from_str::<Value>(&reply).unwrap()["status"],
            "accepted"
        );
        let deadline = core.deferred_effects.as_ref().unwrap().deadline;
        let mut source: Value = serde_json::from_str(&envelope(
            "provideSource",
            "prefetch",
            json!({"sourceUri":"https://cdn.test/b"}),
        ))
        .unwrap();
        source["targetQueueItemId"] = json!("b");
        source["expectedGeneration"] = json!(core.generation.to_string());
        let (reply, effects) = plan_locked(&session.inner, &mut core, &source.to_string());
        assert_eq!(
            serde_json::from_str::<Value>(&reply).unwrap()["status"],
            "accepted"
        );
        assert_eq!(effects, vec![Effect::Publish]);
        let pending = core.deferred_effects.as_ref().unwrap();
        assert_eq!(pending.deadline, deadline);
        assert_eq!(pending.position_ms, Some(0));
        assert!(pending.effects.contains(&Effect::StartItem {
            index: 1,
            position_ms: 0
        }));
        assert_eq!(core.position_ms(480_000), 0);
        assert_eq!(
            core.queue[1].source_uri.as_deref(),
            Some("https://cdn.test/b")
        );
    }

    #[test]
    fn deferred_pause_and_stop_publish_completion_with_a_new_revision() {
        for clear in [false, true] {
            let session = PlaybackSession::with_session_id("effects-test".into());
            {
                let mut core = session.inner.core();
                core.output_running = true;
                core.exclusive_active = true;
                core.deferred_effects = Some(DeferredEffects {
                    generation: core.generation,
                    serial: core.transport_serial,
                    item_id: None,
                    position_ms: None,
                    deadline: Instant::now(),
                    effects: vec![
                        if clear {
                            Effect::StopOutput
                        } else {
                            Effect::PauseOutput
                        },
                        Effect::Publish,
                    ],
                });
            }
            let before: Value = serde_json::from_str(&session.snapshot_json()).unwrap();
            session.inner.finish_deferred_effects();
            let after: Value = serde_json::from_str(&session.snapshot_json()).unwrap();
            let revision = |snapshot: &Value| {
                snapshot["sessionRevision"]
                    .as_str()
                    .unwrap()
                    .parse::<u64>()
                    .unwrap()
            };
            assert!(revision(&after) > revision(&before));
            assert_eq!(before["outputSettings"]["exclusiveActive"], true);
            assert_eq!(after["outputSettings"]["exclusiveActive"], false);
            assert!(!session.inner.core().output_running);
        }
    }

    #[test]
    fn no_callback_timeout_and_disabling_fade_finish_pending_pause() {
        for disable in [false, true] {
            let session = PlaybackSession::with_session_id("effects-test".into());
            {
                let mut core = session.inner.core();
                core.fade_enabled = !disable;
                core.output_running = true;
                core.deferred_effects = Some(DeferredEffects {
                    generation: 0,
                    serial: 0,
                    item_id: None,
                    position_ms: None,
                    deadline: Instant::now()
                        .checked_sub(Duration::from_millis(1))
                        .unwrap(),
                    effects: vec![Effect::PauseOutput],
                });
            }
            session
                .inner
                .realtime
                .pcm_enabled
                .store(true, Ordering::SeqCst);
            session.inner.finish_deferred_effects();
            assert!(session.inner.core().deferred_effects.is_none());
            assert!(!session.inner.realtime.pcm_enabled.load(Ordering::SeqCst));
        }
    }

    #[test]
    fn stale_pause_completion_does_not_gate_new_play() {
        let session = PlaybackSession::with_session_id("effects-test".into());
        session.inner.core().play_when_ready = true;
        session
            .inner
            .realtime
            .pcm_enabled
            .store(true, Ordering::SeqCst);
        session.inner.complete_deferred_output(false, 0, 0);
        assert!(session.inner.realtime.pcm_enabled.load(Ordering::SeqCst));
        session.inner.core().play_when_ready = false;
        session.inner.core().transport_serial = 2;
        session.inner.complete_deferred_output(false, 0, 1);
        assert!(session.inner.realtime.pcm_enabled.load(Ordering::SeqCst));
    }

    #[test]
    fn source_replacement_and_revocation_clear_old_song_gain() {
        let mut core = Core::new("effects-test".into());
        core.queue = vec![QueueItem::new("item".into(), "track".into())];
        for (i, payload) in [
            json!({"sourceUri":"https://cdn.test/a", "normalizationGainDb":3.0815}),
            json!({"sourceUri":"https://cdn.test/b"}),
            json!({"sourceUri":null,"normalizationGainDb":5}),
        ]
        .into_iter()
        .enumerate()
        {
            let text = envelope("provideSource", &format!("source-{i}"), payload);
            let mut value: Value = serde_json::from_str(&text).unwrap();
            value["targetQueueItemId"] = json!("item");
            let text = value.to_string();
            let envelope = parse_envelope(&text).unwrap();
            assert_eq!(
                plan::plan(&mut core, &envelope, &text, 0).reply.to_json()["status"],
                "accepted"
            );
            assert_eq!(core.queue[0].normalization.gain().is_some(), i == 0);
        }
    }
}
