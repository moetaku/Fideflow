//! Control-plane state: the authoritative queue, the play intent, and how a
//! command changes them.
//!
//! This module owns *decisions*; `worker` owns decoding and `lib` owns the
//! effects those decisions imply (starting output, spawning the worker, joining
//! threads). Keeping the split means the command planner can be tested without
//! audio hardware, which is what the deterministic Phase 0 contract tests did
//! with a fake and what the Phase 1 tests do against the real planner.

use std::collections::{HashMap, VecDeque};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

/// Bounded idempotency window: the architecture fixes 1024 finished records per
/// session, and `capabilities` publishes the same number.
pub const IDEMPOTENCY_WINDOW: usize = 1_024;

/// The gain a fresh session starts at: most of full scale, never silent.
pub const DEFAULT_VOLUME_PERMILLE: u32 = 800;

/// How many sources one queue item may be handed before the session stops asking.
///
/// Resolution is the host's job, so this is not a retry policy: it is the bound
/// that keeps a provider answering with a URL that cannot be started from turning
/// into an unbounded request loop (docs/design/provider.md). A fresh queue is a fresh budget,
/// because its items are new.
pub const MAX_SOURCE_ATTEMPTS: u32 = 3;

/// The margin before a source's expiry at which the session stops starting it.
///
/// Starting a source that lapses in the next few hundred milliseconds only
/// produces a failure a moment later. The margin is deliberately short: it is
/// about not making a doomed start, not about pre-empting the host's own (much
/// longer) cache margin.
pub const SOURCE_EXPIRY_SAFETY_MS: u64 = 5_000;

/// Wall-clock milliseconds since the Unix epoch.
///
/// Source expiry is the only thing in the session compared against wall-clock
/// time; every other counter is a monotonic frame or media position (docs/design/playback.md),
/// which is why this lives beside the expiry rule rather than in a clock the
/// rest of the planner would have to thread through.
#[must_use]
pub fn epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
        })
}

/// What the session is doing, as the schema's `phase` values.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Phase {
    /// No queue item is loaded.
    Idle,
    /// The item is selected and holds a position, but nothing has been
    /// prepared: the source is resolved when the user asks to play, which is
    /// what a restored queue is (docs/design/restore.md §7).
    Paused,
    /// The item was accepted and its source is being opened.
    Resolving,
    /// The source is open; audio is being buffered.
    Loading,
    /// PCM is available; whether it sounds depends on the play intent.
    Ready,
    /// The queue finished or is at its end.
    Ended,
    /// An error stopped the item; the queue and diagnostics are kept.
    Error,
}

impl Phase {
    /// The schema's `phase` string.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Paused => "paused",
            Self::Resolving => "resolving",
            Self::Loading => "loading",
            Self::Ready => "ready",
            Self::Ended => "ended",
            Self::Error => "error",
        }
    }
}

/// How the queue advances when an item ends.
///
/// The session owns this: the client sends `setMode` and renders the
/// `effectiveOrder` the snapshot reports, so two clients can never disagree about
/// what "next" means (docs/design/boundaries.md, architecture section 7).
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum PlayMode {
    /// Wrap around: past the last item the queue starts again.
    #[default]
    ListLoop,
    /// Forward without wrapping at either end.
    Sequential,
    /// Repeat the item that just ended. A manual next/previous still walks the
    /// queue, which is what the architecture asks for.
    RepeatOne,
    /// Walk a seeded permutation, keeping the current item in place when the mode
    /// is entered and remembering what was played for "previous".
    Shuffle,
}

impl PlayMode {
    /// The schema's `mode` string.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Sequential => "sequential",
            Self::ListLoop => "listLoop",
            Self::RepeatOne => "repeatOne",
            Self::Shuffle => "shuffle",
        }
    }

    /// Parses the schema's `mode` string.
    #[must_use]
    pub fn from_str_code(code: &str) -> Option<Self> {
        match code {
            "sequential" => Some(Self::Sequential),
            "listLoop" => Some(Self::ListLoop),
            "repeatOne" => Some(Self::RepeatOne),
            "shuffle" => Some(Self::Shuffle),
            _ => None,
        }
    }
}

/// Why the session moved to another item.
///
/// Manual and natural transitions share one entry point and differ only by this
/// reason, which is what keeps "single item repeat also applies to a manual skip"
/// from being re-decided in two places (architecture section 7).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransitionReason {
    /// The item drained and ended by itself.
    AutoAdvance,
    /// The user (or a system media button) asked for the next item.
    SkipNext,
    /// The user asked for the previous item.
    SkipPrevious,
}

/// System limits that keep playback silent without changing the user's intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Suppression {
    /// Another application took the audio focus.
    AudioFocus,
    /// The platform interrupted playback (call, Siri, route change).
    Interruption,
    /// No usable output device.
    DeviceUnavailable,
}

impl Suppression {
    /// The schema's `suppressionReasons` string.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AudioFocus => "audioFocus",
            Self::Interruption => "interruption",
            Self::DeviceUnavailable => "deviceUnavailable",
        }
    }
}

/// One queue entry. `queueItemId` is the identity, so the same track can appear
/// more than once (the architecture calls this out explicitly).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueueItem {
    /// Caller-supplied identity of this queue entry.
    pub queue_item_id: String,
    /// Track identity; opaque to the core.
    pub track_id: String,
    /// Generic source for this entry (Phase 1: a `file:` URI).
    pub source_uri: Option<String>,
    pub normalization: crate::effects::Normalization,
    /// Changes on every accepted source replacement, even if its URI is equal.
    pub source_revision: u64,
    /// When [`Self::source_uri`] stops being usable, as epoch milliseconds.
    ///
    /// `None` means the caller did not know: a `file:` source never expires, and
    /// a provider that said nothing is not guessed at (docs/design/provider.md).
    pub expires_at_ms: Option<u64>,
    /// How many unusable sources this item has held and given up on.
    ///
    /// Monotonic for the life of the queue item, and what bounds
    /// [`MAX_SOURCE_ATTEMPTS`]. A source that is revoked — expired before it could
    /// start, or tried and failed — counts once; a source that plays does not.
    pub source_attempts: u32,
}

impl QueueItem {
    /// A queue entry with no source yet, which is what a load without an upfront
    /// resolution produces.
    #[must_use]
    pub fn new(queue_item_id: String, track_id: String) -> Self {
        Self {
            queue_item_id,
            track_id,
            source_uri: None,
            normalization: crate::effects::Normalization::default(),
            source_revision: 0,
            expires_at_ms: None,
            source_attempts: 0,
        }
    }

    /// Whether the source this item holds is past the point of being startable.
    ///
    /// An item with no source, or one whose caller named no expiry, is not
    /// "expired": those are different answers, and the session asks for a source
    /// instead of revoking one.
    #[must_use]
    pub fn source_is_expired(&self, now_ms: u64) -> bool {
        self.source_uri.is_some()
            && self
                .expires_at_ms
                .is_some_and(|expiry| now_ms.saturating_add(SOURCE_EXPIRY_SAFETY_MS) >= expiry)
    }

    /// Revokes the source this item holds, so nothing can start it again.
    ///
    /// Callers count the attempt themselves: whether a revocation spends the
    /// item's budget depends on why it happened (docs/design/provider.md).
    pub fn revoke_source(&mut self) {
        self.source_revision += 1;
        self.source_uri = None;
        self.normalization = crate::effects::Normalization::default();
        self.expires_at_ms = None;
    }
}

/// A structural change the user made to the queue that keeps it playing.
///
/// The entry that is playing stays in place unless it is the one being removed,
/// which is why an edit carries no position: `remove` addresses identity and the
/// two inserts say where they go relative to the current item (docs/design/playback.md).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum QueueEdit {
    /// Insert these entries immediately after the current item, so they play next.
    PlayNext {
        /// New queue entries, in the order they should play.
        items: Vec<QueueItem>,
    },
    /// Add these entries at the end of the queue.
    Append {
        /// New queue entries, in the order they should play.
        items: Vec<QueueItem>,
    },
    /// Drop one entry, by identity, so a duplicated track is removed one at a time.
    Remove {
        /// `queueItemId` of the entry to drop.
        target_queue_item_id: String,
    },
}

/// The command kinds Phase 1 implements.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    /// Host-side JIT source failure for the current heart item.
    SourceFailed {
        target_queue_item_id: String,
        expected_generation: u64,
        error_code: String,
    },
    /// Atomic heart-stream queue operations.
    Intelligence {
        operation: String,
        session_id: String,
        items: Vec<QueueItem>,
        evict_count: usize,
        advance: bool,
        autoplay: bool,
        expected_session_revision: Option<u64>,
    },
    /// User-confirmed external insert that exits the stream atomically.
    ExternalEdit {
        edit: QueueEdit,
    },
    /// Replace the queue and select an item.
    LoadQueue {
        /// New queue contents.
        items: Vec<QueueItem>,
        /// `queueItemId` to start on.
        ///
        /// A seeded shuffle load does not start on a name: the seed decides both
        /// the order and its head. The field is still parsed, because the schema
        /// requires it to name one of `items`.
        start_item_id: String,
        /// Whether the intent is to start playing immediately.
        autoplay: bool,
        /// Shuffle seed for a load that wants the order to come from one.
        ///
        /// A caller that sends it gets the same permutation and the same first
        /// track back for the same seed, which is what makes a shuffle start
        /// reproducible instead of client-local (docs/design/playback.md).
        seed: Option<u64>,
    },
    /// Set the play intent and start or resume output.
    Play,
    /// Host lifecycle event; the token pairs one sleep/wake cycle.
    SetInterruption {
        interruption_id: String,
        active: bool,
        allow_resume: bool,
    },
    /// Clear the play intent; preparation may continue but must not sound.
    Pause,
    /// Reposition the current item.
    Seek {
        /// Target media position.
        position_ms: u64,
        /// Queue entry the command targets.
        target_queue_item_id: String,
        /// Generation the caller believed it was addressing.
        expected_generation: u64,
    },
    /// Move to the next queue entry, by the current mode's rules.
    SkipNext,
    /// Move to the previous queue entry, by the current mode's rules.
    SkipPrevious,
    /// Jump straight to one queue entry, without changing the queue itself.
    ///
    /// The target rides in the envelope's `targetQueueItemId`, the same field the
    /// current-item actions already use to reject a delayed command.
    PlayItem,
    /// Add, insert or remove queue entries without replacing the queue.
    EditQueue {
        /// The structural change to apply.
        edit: QueueEdit,
    },
    /// Change how the queue advances.
    SetMode {
        /// The mode to install.
        mode: PlayMode,
        /// Shuffle seed; the session derives one when the caller omits it.
        seed: Option<u64>,
    },
    SetPlaybackEffects {
        fade_enabled: bool,
        volume_normalization_enabled: bool,
    },
    RefreshOutputDevices,
    SetOutputConfiguration {
        device_uid: Option<String>,
        exclusive: bool,
        resampling_enabled: bool,
        target_sample_rate: u32,
    },
    /// Set the output gain, as a permille of full scale (0 = silent, 1000 = full).
    SetTransientGain {
        permille: u32,
    },
    SetVolume {
        /// The gain to install, already clamped to `0..=1000`.
        volume: u32,
    },
    /// Stop output, keep the queue, and reset the position.
    Stop,
    /// Revoke the input while preserving queue and progress.
    PermissionExpired,
    /// Pause at a missing offline range and require a new input.
    OfflineGap,
    /// Stop output and drop the queue.
    ClearQueue,
    /// Provide a resolved media source for a queue item.
    ProvideSource {
        /// Target queue item id.
        target_queue_item_id: String,
        /// URI to stream from.
        source_uri: Option<String>,
        normalization: crate::effects::Normalization,
        /// When that URI stops being usable, when the caller knew.
        expires_at_ms: Option<u64>,
        /// Generation when requested.
        expected_generation: Option<u64>,
    },
}

/// One platform interruption, bound to the intent version observed at entry.
#[derive(Clone, Debug)]
pub struct Interruption {
    pub id: String,
    pub intent_version: u64,
    pub resume: bool,
}

/// A parsed command envelope plus the fields shared by every kind.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Envelope {
    /// Stable idempotency key half, paired with the command id.
    pub client_id: String,
    /// Idempotency key half.
    pub command_id: String,
    /// Session the caller believes it is addressing.
    pub target_session_id: String,
    /// Queue revision the caller expected, when the kind requires it.
    pub expected_queue_revision: Option<u64>,
    /// Queue entry the caller believed it was addressing, when it sent one.
    ///
    /// The schema requires it for the current-item actions; the planner uses it
    /// to refuse a delayed command that would otherwise act on a new item.
    pub target_queue_item_id: Option<String>,
    /// Generation the caller believed it was addressing, when it sent one.
    pub expected_generation: Option<u64>,
    /// Parsed command kind and payload.
    pub command: Command,
}

/// Why a command was rejected. Codes are stable wire values (docs/design/boundaries.md).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Rejection {
    /// The envelope was not valid JSON or not schema-shaped.
    Malformed(String),
    /// The schema version is not the one this build speaks.
    UnsupportedSchema(u64),
    /// The command kind is not implemented in Phase 1.
    UnsupportedCommand(String),
    /// The command was addressed to a different session.
    SessionMismatch,
    /// The queue revision the caller expected is stale.
    StaleQueueRevision {
        /// Revision the caller sent.
        expected: u64,
        /// Revision the session holds.
        actual: u64,
    },
    /// The command named a different queue entry than the current one.
    StaleGeneration,
    /// The operation needs a loaded item and the queue has none.
    EmptyQueue,
    /// The item has no usable source.
    SourceUnsupported,
    /// The queue edge was reached.
    QueueBoundary,
    /// The same command id was seen with a different payload.
    IdempotencyConflict,
    /// The queue item is missing from the new queue when starting it.
    UnknownStartItem,
    /// A command named a queue entry this session does not hold.
    UnknownQueueItem,
}

impl Rejection {
    /// The stable `errorCode` reported to the caller.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Malformed(_) => "malformedCommand",
            Self::UnsupportedSchema(_) => "unsupportedSchemaVersion",
            Self::UnsupportedCommand(_) => "unsupportedCommand",
            Self::SessionMismatch => "sessionMismatch",
            Self::StaleQueueRevision { .. } => "staleQueueRevision",
            Self::StaleGeneration => "staleGeneration",
            Self::EmptyQueue => "emptyQueue",
            Self::SourceUnsupported => "sourceUnsupported",
            Self::QueueBoundary => "queueBoundary",
            Self::IdempotencyConflict => "idempotencyConflict",
            Self::UnknownStartItem => "unknownStartItem",
            Self::UnknownQueueItem => "unknownQueueItem",
        }
    }
}

/// What the engine must do after the planner returned, in order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Effect {
    /// Load the queue item at this index and start buffering it.
    StartItem {
        /// Index into the queue.
        index: usize,
        /// Position to resume from.
        position_ms: u64,
    },
    /// Reposition the current item while retaining a running output device.
    SeekItem {
        index: usize,
        position_ms: u64,
        generation: u64,
    },
    /// Stop output and discard buffered PCM.
    StopOutput,
    /// Quiesce decoding and output before clearing all buffered audio.
    RevokeInput,
    ApplyPlaybackEffects,
    RefreshOutputDevices,
    ConfigureOutput {
        device_uid: Option<String>,
        exclusive: bool,
        resampling_enabled: bool,
        target_sample_rate: u32,
        version: u64,
    },
    /// Pause output but keep buffered PCM and the current position.
    PauseOutput,
    /// Refuse wake recovery if the previously active route disappeared.
    ValidateRecoveryOutput,
    /// Resume output on the current item.
    ResumeOutput,
    /// Copy the new gain into the callback's atomic. Volume must reach the
    /// audio thread lock-free, and this effect runs outside the core lock.
    SetTransientGain {
        permille: u32,
    },
    SetVolume {
        /// The gain, a permille of full scale.
        volume: u32,
    },
    /// Publish a snapshot to the event sink.
    Publish,
}

/// Business results remain typed until the protocol boundary.
#[derive(Clone, Debug)]
pub enum CommandReply {
    Accepted {
        command_id: String,
        session_revision: u64,
        operation_id: Option<String>,
    },
    Rejected {
        command_id: String,
        rejection: Rejection,
        queue_revision: u64,
    },
}
impl CommandReply {
    pub fn is_accepted(&self) -> bool {
        matches!(self, Self::Accepted { .. })
    }
    pub fn to_json(&self) -> Value {
        match self {
            Self::Accepted {
                command_id,
                session_revision,
                operation_id,
            } => {
                let mut value = serde_json::json!({"schemaVersion": crate::plan::SCHEMA_VERSION, "kind": "result", "commandId": command_id, "status": "accepted", "sessionRevision": session_revision.to_string()});
                if let Some(id) = operation_id {
                    value["operationId"] = serde_json::json!(id);
                }
                value
            }
            Self::Rejected {
                command_id,
                rejection,
                queue_revision,
            } => {
                let mut value = serde_json::json!({"schemaVersion": crate::plan::SCHEMA_VERSION, "kind": "result", "commandId": command_id, "status": "rejected", "errorCode": rejection.code()});
                if matches!(rejection, Rejection::StaleQueueRevision { .. }) {
                    value["currentQueueRevision"] = serde_json::json!(queue_revision.to_string());
                }
                value
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum FailureKind {
    Source,
    Decode,
    Output,
    Other,
}
impl FailureKind {
    pub fn code(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Decode => "decode",
            Self::Output => "output",
            Self::Other => "other",
        }
    }
    pub fn from_native_code(code: &str) -> Self {
        match code {
            "sourceUnsupported" | "sourceOpenFailed" | "sourceHasNoAudio" | "sourceUnavailable" => {
                Self::Source
            }
            "decodeFailed" | "decodeUnavailable" | "seekFailed" => Self::Decode,
            "outputUnavailable" | "outputOpenFailed" => Self::Output,
            _ => Self::Other,
        }
    }
}

/// A planned command: the reply to send and the effects to run.
#[derive(Clone, Debug)]
pub struct Plan {
    /// The `result` message for the caller.
    pub reply: CommandReply,
    /// Effects to run after the plan, in order, with no core lock held.
    pub effects: Vec<Effect>,
    /// Whether to remember this command as finished (rejections are remembered
    /// too: a retry must not re-run a command that was already answered).
    pub remember: bool,
}

/// What the output device reported, for diagnostics (docs/design/diagnostics.md).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OutputDiagnostics {
    /// Device name the backend opened.
    pub device_name: String,
    /// Sample rate the backend opened.
    pub sample_rate: u32,
    /// Channels the backend opened.
    pub channels: u32,
    /// Backend sample format identifier.
    pub internal_format: u32,
    /// Frames per device period.
    pub period_frames: u32,
    /// Periods the backend allocated.
    pub periods: u32,
    /// Depth of one period in seconds.
    pub period_seconds: f64,
}

/// The authoritative control-plane state.
///
/// The boolean fields are *not* one state machine: `playWhenReady` is the user's
/// intent, `buffering` is a supply problem, `output_running` is a device fact and
/// `item_finished` is a drain fact. docs/design/playback.md requires them to be independent
/// (a system limit must not rewrite the intent), so they stay separate signals.
#[allow(
    clippy::struct_excessive_bools,
    reason = "intent, buffering, device state and drain state are independent by docs/design/playback.md"
)]
#[derive(Debug)]
pub struct Core {
    /// Identity of this session; changes when the session is rebuilt.
    pub session_id: String,
    /// Increases for every accepted state change.
    pub session_revision: u64,
    /// Increases when the queue or its order changes.
    pub queue_revision: u64,
    /// Increases whenever asynchronous work is invalidated.
    pub generation: u64,
    /// The authoritative queue.
    pub queue: Vec<QueueItem>,
    /// Index of the current item.
    pub current: Option<usize>,
    /// What the session is doing.
    pub phase: Phase,
    /// How the queue advances.
    pub mode: PlayMode,
    /// Runtime only: never persisted in a checkpoint.
    pub intelligence_session_id: Option<String>,
    /// Play order of `queue` indices while the mode is `Shuffle`; empty otherwise.
    pub shuffle_order: Vec<usize>,
    /// Position in [`Core::shuffle_order`] of the item that is playing.
    pub shuffle_cursor: usize,
    /// Seed of the current shuffle order; reproducible, and diagnostics-safe.
    pub shuffle_seed: u64,
    /// Whether the current shuffle order came from a seeded `loadQueue`.
    ///
    /// Only that order is reproducible from the seed over the load order: a
    /// shuffle entered mid-playback pins the current item, and an edit reorders
    /// the permutation, so neither can be rebuilt from the seed alone. The
    /// checkpoint writer consults this before claiming a seed (docs/design/playback.md).
    pub shuffle_seeded: bool,
    /// Seeds handed out so far by [`Core::next_shuffle_seed`].
    shuffle_seed_counter: u64,
    /// The output gain as a permille of full scale (0 = silent, 1000 = full).
    /// This is the authority; [`Realtime::volume_permille`] is the callback's
    /// lock-free copy of it, synced by [`Effect::SetVolume`].
    pub volume_permille: u32,
    pub fade_enabled: bool,
    pub volume_normalization_enabled: bool,
    pub(crate) transport_serial: u64,
    pub(crate) deferred_effects: Option<crate::DeferredEffects>,
    /// The user's play intent; system limits never rewrite it.
    pub play_when_ready: bool,
    /// Set while valid PCM cannot sustain output.
    pub buffering: bool,
    /// A same-item seek is preparing PCM for a new position.
    pub is_seeking: bool,
    /// Active system limits.
    pub suppression: Vec<Suppression>,
    pub interruption: Option<Interruption>,
    pub play_intent_version: u64,
    pub last_interruption_id: Option<String>,
    /// Stable code of the last error, when the phase is `Error`.
    pub error_code: Option<String>,
    pub failure_kind: FailureKind,
    /// Whether retrying the last failure could succeed.
    pub error_retryable: bool,
    /// Container duration of the current item, when the format reports one.
    pub duration_ms: Option<u64>,
    /// Media time the current item's first buffered frame corresponds to.
    pub anchor_media_us: u64,
    /// Consumed-frame counter value when the anchor was set.
    pub anchor_frames: u64,
    /// Whether the output device is pulling samples right now.
    pub output_running: bool,
    /// Codec short name of the current source, for diagnostics only.
    pub source_codec: String,
    /// Native sample rate of the current source, for diagnostics only.
    pub source_rate: u32,
    pub source_channels: u32,
    /// Resampler engine libswresample selected, for diagnostics only.
    pub resampler: String,
    /// Input EOF, decoder drain and tail output have all completed.
    pub item_finished: bool,
    /// When the current play intent started preparing an item; used to measure
    /// the time to the first frame (docs/design/diagnostics.md).
    pub intent_at: Option<Instant>,
    /// Time from intent to confirmed output for the last measured item.
    pub first_frame_millis: Option<u128>,
    /// Diagnostics of the device in use.
    pub output: Option<OutputDiagnostics>,
    pub output_configuration: fideflow_media_output::OutputConfiguration,
    pub output_devices: Vec<fideflow_media_output::PlaybackDevice>,
    pub output_error: Option<String>,
    pub output_busy: bool,
    pub output_version: u64,
    pub output_devices_pending: bool,
    pub active_device_uid: Option<String>,
    pub exclusive_active: bool,
    pub pcm_rate: u32,

    /// Subscribers: `connectionId -> clientId`.
    pub connections: HashMap<String, String>,
    /// Next subscriber number.
    next_connection: u64,
    /// Bounded idempotency window: `(clientId, commandId) -> reply`.
    finished: HashMap<String, Value>,
    /// Insertion order for eviction.
    finished_order: VecDeque<String>,
}

impl Core {
    /// Creates a session with an empty queue.
    #[must_use]
    pub fn new(session_id: String) -> Self {
        Self {
            session_id,
            session_revision: 0,
            queue_revision: 0,
            generation: 0,
            queue: Vec::new(),
            current: None,
            phase: Phase::Idle,
            mode: PlayMode::default(),
            intelligence_session_id: None,
            shuffle_order: Vec::new(),
            shuffle_cursor: 0,
            shuffle_seed: 0,
            shuffle_seeded: false,
            shuffle_seed_counter: 0,
            volume_permille: DEFAULT_VOLUME_PERMILLE,
            fade_enabled: false,
            volume_normalization_enabled: false,
            deferred_effects: None,
            transport_serial: 0,
            play_when_ready: false,
            buffering: false,
            is_seeking: false,
            suppression: Vec::new(),
            interruption: None,
            play_intent_version: 0,
            last_interruption_id: None,
            error_code: None,
            failure_kind: FailureKind::Other,
            error_retryable: false,
            duration_ms: None,
            anchor_media_us: 0,
            anchor_frames: 0,
            output_running: false,
            source_codec: String::new(),
            source_rate: 0,
            source_channels: 2,
            resampler: String::new(),
            item_finished: false,
            intent_at: None,
            first_frame_millis: None,
            output: None,
            output_configuration: fideflow_media_output::OutputConfiguration::default(),
            output_devices: vec![],
            output_error: None,
            output_busy: false,
            output_version: 0,
            output_devices_pending: false,
            active_device_uid: None,
            exclusive_active: false,
            pcm_rate: crate::PCM_SAMPLE_RATE,

            connections: HashMap::new(),
            next_connection: 1,
            finished: HashMap::new(),
            finished_order: VecDeque::new(),
        }
    }

    /// Registers a subscriber and returns its connection id.
    pub fn register_connection(&mut self, client_id: &str) -> String {
        let connection_id = format!("conn-{}", self.next_connection);
        self.next_connection += 1;
        self.connections
            .insert(connection_id.clone(), client_id.to_owned());
        connection_id
    }

    /// Drops a subscriber; playback is not affected.
    pub fn unregister_connection(&mut self, connection_id: &str) -> bool {
        self.connections.remove(connection_id).is_some()
    }

    /// The current item, when one is selected.
    #[must_use]
    pub fn current_item(&self) -> Option<&QueueItem> {
        self.current.and_then(|index| self.queue.get(index))
    }

    /// Media position in milliseconds.
    ///
    /// docs/design/playback.md makes the frame clock authoritative: the position is the anchor
    /// media time plus the valid PCM frames the output has actually consumed
    /// since that anchor. Silence the callback synthesised never counts, so a
    /// buffering or paused session simply stops advancing.
    #[must_use]
    pub fn position_ms(&self, frames_consumed: u64) -> u64 {
        // The callback is still draining the retired item during a deferred
        // switch. Those frames must not become the new item's checkpoint.
        if let Some(position) = self
            .deferred_effects
            .as_ref()
            .and_then(|pending| pending.position_ms)
        {
            return position;
        }
        let consumed = frames_consumed.saturating_sub(self.anchor_frames);
        let position = self.anchor_media_us / 1_000 + consumed * 1_000 / u64::from(self.pcm_rate);
        match self.duration_ms {
            Some(duration) => position.min(duration),
            None => position,
        }
    }

    /// The order the queue will play, as indices into [`Core::queue`].
    ///
    /// In shuffle mode this is the session's own permutation; in every other mode
    /// it is the queue's own order. The snapshot publishes it as `effectiveOrder`
    /// so a client renders the queue instead of computing it.
    #[must_use]
    pub fn play_order(&self) -> Vec<usize> {
        if self.mode == PlayMode::Shuffle && self.shuffle_order.len() == self.queue.len() {
            self.shuffle_order.clone()
        } else {
            (0..self.queue.len()).collect()
        }
    }

    /// The `queueItemId`s of [`Core::play_order`], for the snapshot.
    #[must_use]
    pub fn effective_order(&self) -> Vec<String> {
        self.play_order()
            .iter()
            .filter_map(|index| self.queue.get(*index))
            .map(|item| item.queue_item_id.clone())
            .collect()
    }

    /// A fresh, reproducible seed for the next shuffle order.
    pub fn next_shuffle_seed(&mut self) -> u64 {
        self.shuffle_seed_counter = self.shuffle_seed_counter.wrapping_add(1);
        let mut state = self.shuffle_seed_counter;
        splitmix64(&mut state)
    }

    /// Builds the shuffle order for `seed`: the current item stays first, and the
    /// rest is permuted. Also the reset point for shuffle history.
    pub fn rebuild_shuffle(&mut self, seed: u64) {
        self.shuffle_seed = seed;
        // A re-roll pins whatever item is current, which a seed over the load
        // order cannot reproduce; only a seeded load sets this back to true.
        self.shuffle_seeded = false;
        let mut state = seed;
        let mut rest: Vec<usize> = (0..self.queue.len())
            .filter(|index| Some(*index) != self.current)
            .collect();
        shuffle_in_place(&mut rest, &mut state);
        let mut order = Vec::with_capacity(self.queue.len());
        if let Some(current) = self.current {
            order.push(current);
        }
        order.extend(rest);
        self.shuffle_order = order;
        self.shuffle_cursor = 0;
    }

    /// Builds the shuffle order for `seed` over the *whole* queue and starts on
    /// its head, so the seed alone decides both the permutation and the track a
    /// playlist opens with.
    ///
    /// [`Core::rebuild_shuffle`] pins whatever item is current, which is right
    /// for a mid-playback re-roll but wrong for a fresh load: a client that had
    /// to name the head itself would be the second owner of the shuffle, and two
    /// clients could disagree. Here nothing is pinned, which is what makes the
    /// same seed replay the same playlist (docs/design/playback.md).
    pub fn start_shuffle_from_seed(&mut self, seed: u64) {
        self.current = None;
        self.rebuild_shuffle(seed);
        self.current = self.shuffle_order.first().copied();
        // This is the one shuffle order a seed can replay: nothing was pinned.
        self.shuffle_seeded = true;
    }

    /// Points the shuffle cursor at `index`, when it is part of the order.
    pub fn set_shuffle_cursor(&mut self, index: usize) {
        if let Some(position) = self.shuffle_order.iter().position(|item| *item == index) {
            self.shuffle_cursor = position;
        }
    }

    /// Keeps the stored orders valid after `index` leaves [`Core::queue`].
    ///
    /// The shuffle order is an index list, so an entry that is removed has to
    /// disappear from it and every index after it has to move down. The current
    /// item is adjusted too: an edit that removes an entry before it must not
    /// leave it pointing at its neighbour.
    pub fn forget_queue_index(&mut self, index: usize) {
        self.shuffle_order.retain(|item| *item != index);
        for item in &mut self.shuffle_order {
            if *item > index {
                *item -= 1;
            }
        }
        if let Some(current) = &mut self.current
            && *current > index
        {
            *current -= 1;
        }
    }

    /// Keeps the stored orders valid after `count` entries are inserted into
    /// [`Core::queue`] at `position`.
    ///
    /// The mirror of [`Core::forget_queue_index`]: every index at or after the
    /// insertion point moves up, so the shuffle order keeps naming the same
    /// entries it did before the edit.
    pub fn shift_queue_indices(&mut self, position: usize, count: usize) {
        for item in &mut self.shuffle_order {
            if *item >= position {
                *item += count;
            }
        }
        if let Some(current) = &mut self.current
            && *current >= position
        {
            *current += count;
        }
    }

    /// Records an accepted state change.
    ///
    /// `bump` deliberately does *not* touch the error fields: the failure path
    /// has to be able to set them and increase the revision in one step.
    pub fn bump(&mut self) {
        self.session_revision += 1;
    }

    /// Clears the previous failure after a command that leaves the error state.
    pub fn clear_error(&mut self) {
        self.error_code = None;
        self.failure_kind = FailureKind::Other;
        self.error_retryable = false;
    }

    /// Answers a repeated command id, or returns `None` for a fresh one.
    #[must_use]
    pub fn replay(&self, key: &str, payload: &str) -> Option<Value> {
        self.finished
            .get(key)
            .filter(|entry| entry.get("payload").and_then(Value::as_str) == Some(payload))
            .map(|entry| {
                entry
                    .get("reply")
                    .cloned()
                    .unwrap_or(Value::Object(Map::new()))
            })
    }

    /// Returns `true` when the key was used with a different payload.
    #[must_use]
    pub fn conflicts(&self, key: &str, payload: &str) -> bool {
        self.finished
            .get(key)
            .is_some_and(|entry| entry.get("payload").and_then(Value::as_str) != Some(payload))
    }

    /// The item that follows the current one on a natural end or a manual skip.
    ///
    /// Pure mode rules; applying the transition to the session state is the
    /// caller's job. Returns `None` only when the queue holds nothing.
    #[must_use]
    pub fn next_item(&mut self, reason: TransitionReason) -> Option<usize> {
        let current = self.current?;
        if self.queue.is_empty() {
            return None;
        }
        if reason == TransitionReason::AutoAdvance && self.mode == PlayMode::RepeatOne {
            // The one place a manual skip deliberately differs from the end of an
            // item: repeating is about how an item ends, not about the user.
            return Some(current);
        }
        if self.mode == PlayMode::Sequential || self.intelligence_session_id.is_some() {
            return if reason == TransitionReason::SkipPrevious {
                current.checked_sub(1)
            } else {
                (current + 1 < self.queue.len()).then_some(current + 1)
            };
        }
        match self.mode {
            PlayMode::Sequential => None,
            PlayMode::Shuffle => self.next_in_shuffle(reason),
            PlayMode::RepeatOne | PlayMode::ListLoop => {
                let last = self.queue.len() - 1;
                Some(if reason == TransitionReason::SkipPrevious {
                    if current == 0 { last } else { current - 1 }
                } else if current >= last {
                    0
                } else {
                    current + 1
                })
            }
        }
    }

    /// Walks the effective shuffle list by neighbouring entry (docs/design/boundaries.md).
    ///
    /// "previous" is the entry before the current one *in the published list*,
    /// not the last item visited: a jump into the middle of the list, or a
    /// restore that lands on a slot, must be reversible. The list wraps at both
    /// ends and the permutation is kept as it is, so the walk is exactly the
    /// order the snapshot publishes (issue 12).
    fn next_in_shuffle(&mut self, reason: TransitionReason) -> Option<usize> {
        let current = self.current?;
        if self.shuffle_order.len() != self.queue.len() {
            // A queue that changed under the mode (a load) rebuilds lazily, so the
            // order can never point at an item that is gone.
            let seed = self.shuffle_seed;
            self.rebuild_shuffle(seed);
        }
        if self.shuffle_order.len() <= 1 {
            // A one-item queue has nowhere else to go; an empty one is handled by
            // the caller before reaching here.
            return Some(current);
        }
        // Keep the cursor pointed at the item that is playing, so a jump or an
        // edit can never desync the two.
        self.set_shuffle_cursor(current);
        let len = self.shuffle_order.len();
        let cursor = if reason == TransitionReason::SkipPrevious {
            if self.shuffle_cursor == 0 {
                len - 1
            } else {
                self.shuffle_cursor - 1
            }
        } else {
            (self.shuffle_cursor + 1) % len
        };
        self.shuffle_cursor = cursor;
        self.shuffle_order.get(cursor).copied()
    }

    /// Remembers a finished command inside the bounded window.
    pub fn remember(&mut self, key: String, payload: &str, reply: &Value) {
        if self.finished.contains_key(&key) {
            return;
        }
        self.finished
            .insert(key.clone(), json!({ "payload": payload, "reply": reply }));
        self.finished_order.push_back(key);
        while self.finished_order.len() > IDEMPOTENCY_WINDOW {
            if let Some(evicted) = self.finished_order.pop_front() {
                self.finished.remove(&evicted);
            }
        }
    }
}

/// `SplitMix64`: a tiny, dependency-free generator, so a seeded order is identical
/// on every platform and a mode test can assert an exact sequence.
fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut value = *state;
    value = (value ^ (value >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

/// A uniform index in `0..bound` by rejection sampling, which avoids the modulo
/// bias a plain `%` would put on the first few items of a queue.
fn bounded(state: &mut u64, bound: usize) -> usize {
    let bound = u64::try_from(bound).unwrap_or(u64::MAX).max(1);
    let limit = u64::MAX - (u64::MAX % bound);
    loop {
        let value = splitmix64(state);
        if value < limit {
            return usize::try_from(value % bound).unwrap_or(0);
        }
    }
}

/// Fisher-Yates over the given items, drawing from `state`.
pub fn shuffle_in_place(items: &mut [usize], state: &mut u64) {
    for index in (1..items.len()).rev() {
        let swap = bounded(state, index + 1);
        items.swap(index, swap);
    }
}
