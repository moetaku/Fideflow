//! Command parsing and planning.
//!
//! Planning is pure: it reads the queue and revisions, mutates them, and returns
//! the effects the engine must run. No thread is spawned and no device is touched
//! here, which is what makes the acceptance rules testable without audio
//! hardware, and what keeps "a command never blocks the executor" true by
//! construction (docs/design/playback.md).

use serde_json::{Map, Value, json};

use crate::checkpoint;
use crate::core::{
    Command, CommandReply, Core, Effect, Envelope, Interruption, Phase, Plan, PlayMode, QueueEdit,
    QueueItem, Rejection, Suppression, TransitionReason,
};

/// Schema version this build speaks (docs/design/boundaries.md).
pub const SCHEMA_VERSION: u64 = 1;

/// Full scale on the wire: the `volume` payload is a permille of it.
pub const MAX_VOLUME_PERMILLE: u32 = 1_000;

/// Parses a command envelope, returning the schema-shaped rejection otherwise.
///
/// # Errors
///
/// Returns the [`Rejection`] that describes the first schema violation.
pub fn parse_envelope(json_text: &str) -> Result<Envelope, Rejection> {
    let value: Value =
        serde_json::from_str(json_text).map_err(|error| Rejection::Malformed(error.to_string()))?;
    let object = value
        .as_object()
        .ok_or_else(|| Rejection::Malformed(String::from("the command must be a JSON object")))?;

    let schema_version = object
        .get("schemaVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| Rejection::Malformed(String::from("schemaVersion is missing")))?;
    if schema_version != SCHEMA_VERSION {
        return Err(Rejection::UnsupportedSchema(schema_version));
    }
    let kind = required_str(object, "kind")?;
    let client_id = required_str(object, "clientId")?;
    let command_id = required_str(object, "commandId")?;
    let target_session_id = required_str(object, "targetSessionId")?;
    let expected_queue_revision = optional_u64(object, "expectedQueueRevision")?;
    let target_queue_item_id = object
        .get("targetQueueItemId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let expected_generation = optional_u64(object, "expectedGeneration")?;
    let payload = object
        .get("payload")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let command = parse_command(
        &kind,
        &payload,
        target_queue_item_id.as_deref(),
        expected_generation,
    )?;

    Ok(Envelope {
        client_id,
        command_id,
        target_session_id,
        expected_queue_revision,
        target_queue_item_id,
        expected_generation,
        command,
    })
}

fn parse_command(
    kind: &str,
    payload: &Map<String, Value>,
    target_queue_item_id: Option<&str>,
    expected_generation: Option<u64>,
) -> Result<Command, Rejection> {
    Ok(match kind {
        "loadQueue" => {
            let items = parse_items(payload)?;
            let start_item_id = required_str(payload, "startItemId")?;
            let autoplay = payload
                .get("autoplay")
                .and_then(Value::as_bool)
                .ok_or_else(|| Rejection::Malformed(String::from("autoplay is missing")))?;
            Command::LoadQueue {
                items,
                start_item_id,
                autoplay,
                seed: optional_u64(payload, "seed")?,
            }
        }
        "sourceFailed" => Command::SourceFailed {
            target_queue_item_id: target_queue_item_id.map(str::to_owned).ok_or_else(|| {
                Rejection::Malformed(String::from("targetQueueItemId is missing"))
            })?,
            expected_generation: expected_generation.ok_or_else(|| {
                Rejection::Malformed(String::from("expectedGeneration is missing"))
            })?,
            error_code: required_str(payload, "errorCode")?,
        },
        "play" => Command::Play,
        "pause" => Command::Pause,
        "setTransientGain" => Command::SetTransientGain {
            permille: parse_volume(payload)?,
        },
        "setInterruption" => Command::SetInterruption {
            interruption_id: required_str(payload, "interruptionId")?,
            allow_resume: match payload.get("allowResume") {
                None => true,
                Some(Value::Bool(value)) => *value,
                _ => return Err(Rejection::Malformed("allowResume must be boolean".into())),
            },
            active: payload
                .get("active")
                .and_then(Value::as_bool)
                .ok_or_else(|| Rejection::Malformed("active is missing".into()))?,
        },
        "seek" => Command::Seek {
            position_ms: required_u64(payload, "positionMs")?,
            target_queue_item_id: target_queue_item_id.map(str::to_owned).ok_or_else(|| {
                Rejection::Malformed(String::from("targetQueueItemId is missing"))
            })?,
            expected_generation: expected_generation.ok_or_else(|| {
                Rejection::Malformed(String::from("expectedGeneration is missing"))
            })?,
        },
        "skipNext" => Command::SkipNext,
        "skipPrevious" => Command::SkipPrevious,
        "playItem" => Command::PlayItem,
        "editQueue" => {
            let edit = parse_queue_edit(payload, target_queue_item_id)?;
            if payload.get("exitIntelligence").and_then(Value::as_bool) == Some(true) {
                Command::ExternalEdit { edit }
            } else {
                Command::EditQueue { edit }
            }
        }
        "intelligence" => parse_intelligence(payload)?,
        "setMode"
        | "refreshOutputDevices"
        | "setOutputConfiguration"
        | "setPlaybackEffects"
        | "setVolume" => parse_settings_command(kind, payload)?,
        "stop" => {
            if payload
                .get("permissionExpired")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                Command::PermissionExpired
            } else if payload
                .get("offlineGap")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                Command::OfflineGap
            } else {
                Command::Stop
            }
        }
        "clearQueue" => Command::ClearQueue,
        // The expiry is optional and may be explicitly `null`: "no known expiry"
        // is a fact the caller may not have, unlike the counters it chose itself.
        "provideSource" => Command::ProvideSource {
            target_queue_item_id: target_queue_item_id.map(str::to_owned).ok_or_else(|| {
                Rejection::Malformed(String::from("targetQueueItemId is missing"))
            })?,
            source_uri: match payload.get("sourceUri") {
                Some(Value::Null) => None,
                _ => Some(required_str(payload, "sourceUri")?),
            },
            normalization: crate::effects::Normalization::from_json(payload),
            expires_at_ms: nullable_u64(payload, "expiresAtMs")?,
            expected_generation,
        },
        other => return Err(Rejection::UnsupportedCommand(other.to_owned())),
    })
}

fn parse_settings_command(kind: &str, payload: &Map<String, Value>) -> Result<Command, Rejection> {
    Ok(match kind {
        "setMode" => {
            let mode = PlayMode::from_str_code(&required_str(payload, "mode")?)
                .ok_or_else(|| Rejection::Malformed(String::from("mode is not a playback mode")))?;
            Command::SetMode {
                mode,
                seed: optional_u64(payload, "seed")?,
            }
        }
        "refreshOutputDevices" => Command::RefreshOutputDevices,
        "setOutputConfiguration" => {
            let device_uid = match payload.get("deviceUid") {
                None | Some(Value::Null) => None,
                Some(Value::String(uid))
                    if !uid.is_empty() && uid.len() <= 1023 && !uid.contains('\0') =>
                {
                    Some(uid.clone())
                }
                _ => return Err(Rejection::Malformed("invalid deviceUid".into())),
            };
            let exclusive = payload
                .get("exclusive")
                .and_then(Value::as_bool)
                .ok_or_else(|| Rejection::Malformed("exclusive is missing".into()))?;
            let resampling_enabled = match payload.get("resamplingEnabled") {
                None => false,
                Some(Value::Bool(enabled)) => *enabled,
                _ => return Err(Rejection::Malformed("invalid resamplingEnabled".into())),
            };
            let target_sample_rate = match payload.get("targetSampleRate") {
                None => 48_000,
                Some(value) => value
                    .as_u64()
                    .and_then(|rate| u32::try_from(rate).ok())
                    .filter(|rate| fideflow_media_output::RESAMPLING_SAMPLE_RATES.contains(rate))
                    .ok_or_else(|| Rejection::Malformed("invalid targetSampleRate".into()))?,
            };
            Command::SetOutputConfiguration {
                device_uid,
                exclusive,
                resampling_enabled,
                target_sample_rate,
            }
        }
        "setPlaybackEffects" => Command::SetPlaybackEffects {
            fade_enabled: payload
                .get("fadeEnabled")
                .and_then(Value::as_bool)
                .ok_or_else(|| Rejection::Malformed("fadeEnabled is missing".into()))?,
            volume_normalization_enabled: payload
                .get("volumeNormalizationEnabled")
                .and_then(Value::as_bool)
                .ok_or_else(|| {
                    Rejection::Malformed("volumeNormalizationEnabled is missing".into())
                })?,
        },
        "setVolume" => Command::SetVolume {
            volume: parse_volume(payload)?,
        },
        other => return Err(Rejection::UnsupportedCommand(other.to_owned())),
    })
}

fn parse_intelligence(payload: &Map<String, Value>) -> Result<Command, Rejection> {
    let operation = required_str(payload, "operation")?;
    if !matches!(operation.as_str(), "start" | "refill" | "exit") {
        return Err(Rejection::Malformed(String::from(
            "unknown intelligence operation",
        )));
    }
    Ok(Command::Intelligence {
        items: if operation == "exit" {
            vec![]
        } else {
            parse_items(payload)?
        },
        operation,
        session_id: required_str(payload, "sessionId")?,
        evict_count: usize::try_from(optional_u64(payload, "evictCount")?.unwrap_or(0))
            .map_err(|_| Rejection::Malformed(String::from("evictCount overflow")))?,
        advance: payload
            .get("advance")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        autoplay: payload
            .get("autoplay")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        expected_session_revision: optional_u64(payload, "expectedSessionRevision")?,
    })
}

/// Plans a command against the current state.
///
/// `frames_consumed` is the output's frame-clock reading; the planner needs it
/// only to resolve the restore position when a stopped or failed item restarts.
#[must_use]
pub fn plan(core: &mut Core, envelope: &Envelope, payload: &str, frames_consumed: u64) -> Plan {
    let result = plan_command(core, envelope, payload, frames_consumed);
    if result.reply.is_accepted()
        && matches!(
            envelope.command,
            Command::Play
                | Command::Pause
                | Command::Stop
                | Command::ClearQueue
                | Command::LoadQueue { .. }
                | Command::SkipNext
                | Command::SkipPrevious
                | Command::PlayItem
                | Command::Seek { .. }
                | Command::EditQueue { .. }
                | Command::ExternalEdit { .. }
                | Command::Intelligence { .. }
                | Command::PermissionExpired
                | Command::OfflineGap
                | Command::SourceFailed { .. }
        )
    {
        core.play_intent_version = core.play_intent_version.wrapping_add(1);
    }
    result
}

fn plan_command(core: &mut Core, envelope: &Envelope, payload: &str, frames_consumed: u64) -> Plan {
    if envelope.target_session_id != core.session_id {
        return reject(envelope, core, &Rejection::SessionMismatch, false);
    }
    match &envelope.command {
        Command::LoadQueue {
            items,
            start_item_id,
            autoplay,
            seed,
        } => plan_load_queue(core, envelope, items, start_item_id, *autoplay, *seed, None),
        Command::Intelligence {
            operation,
            session_id,
            items,
            evict_count,
            advance,
            autoplay,
            expected_session_revision,
        } => plan_intelligence(
            core,
            envelope,
            operation,
            session_id,
            items,
            *evict_count,
            *advance,
            *autoplay,
            *expected_session_revision,
        ),
        Command::ExternalEdit { edit } => plan_external_edit(core, envelope, edit),
        Command::SourceFailed {
            target_queue_item_id,
            expected_generation,
            error_code,
        } => plan_source_failed(
            core,
            envelope,
            target_queue_item_id,
            *expected_generation,
            error_code,
        ),
        Command::SetInterruption {
            interruption_id,
            active,
            allow_resume,
        } => plan_interruption(
            core,
            envelope,
            interruption_id,
            *active,
            *allow_resume,
            frames_consumed,
        ),
        Command::Play => plan_play(core, envelope, frames_consumed),
        Command::Pause => plan_pause(core, envelope),
        Command::Seek {
            position_ms,
            target_queue_item_id,
            expected_generation,
        } => plan_seek(
            core,
            envelope,
            *position_ms,
            target_queue_item_id,
            *expected_generation,
        ),
        Command::SkipNext => plan_skip(core, envelope, TransitionReason::SkipNext),
        Command::SkipPrevious => plan_skip(core, envelope, TransitionReason::SkipPrevious),
        Command::PlayItem => plan_play_item(core, envelope),
        Command::EditQueue { edit } => plan_edit_queue(core, envelope, edit, false),
        Command::SetMode { mode, seed } => plan_set_mode(core, envelope, *mode, *seed),
        Command::RefreshOutputDevices
        | Command::SetOutputConfiguration { .. }
        | Command::SetPlaybackEffects { .. }
        | Command::SetTransientGain { .. }
        | Command::SetVolume { .. } => plan_output_settings(core, envelope),
        Command::PermissionExpired | Command::OfflineGap => {
            plan_source_revocation(core, envelope, frames_consumed)
        }
        Command::Stop => plan_stop(core, envelope, false, frames_consumed),
        Command::ClearQueue => plan_stop(core, envelope, true, 0),
        Command::ProvideSource {
            target_queue_item_id,
            source_uri,
            normalization,
            expires_at_ms,
            expected_generation,
        } => plan_provide_source(
            core,
            envelope,
            target_queue_item_id,
            source_uri.as_deref(),
            *normalization,
            *expires_at_ms,
            *expected_generation,
        ),
    }
    .finish(core, envelope, payload)
}

fn plan_output_settings(core: &mut Core, envelope: &Envelope) -> Plan {
    match &envelope.command {
        Command::RefreshOutputDevices => {
            accepted(envelope, core, None, vec![Effect::RefreshOutputDevices])
        }
        Command::SetOutputConfiguration {
            device_uid,
            exclusive,
            resampling_enabled,
            target_sample_rate,
        } => plan_output_configuration(
            core,
            envelope,
            device_uid.as_deref(),
            *exclusive,
            *resampling_enabled,
            *target_sample_rate,
        ),
        Command::SetPlaybackEffects {
            fade_enabled,
            volume_normalization_enabled,
        } => plan_playback_effects(core, envelope, *fade_enabled, *volume_normalization_enabled),
        Command::SetTransientGain { permille } => accepted(
            envelope,
            core,
            None,
            vec![Effect::SetTransientGain {
                permille: *permille,
            }],
        ),
        Command::SetVolume { volume } => plan_set_volume(core, envelope, *volume),
        _ => unreachable!("only output settings commands are dispatched here"),
    }
}

fn plan_playback_effects(
    core: &mut Core,
    envelope: &Envelope,
    fade_enabled: bool,
    volume_normalization_enabled: bool,
) -> Plan {
    core.fade_enabled = fade_enabled;
    core.volume_normalization_enabled = volume_normalization_enabled;
    core.bump();
    accepted(
        envelope,
        core,
        None,
        vec![Effect::ApplyPlaybackEffects, Effect::Publish],
    )
}

fn plan_external_edit(core: &mut Core, envelope: &Envelope, edit: &QueueEdit) -> Plan {
    let result = plan_edit_queue(core, envelope, edit, true);
    if result.reply.is_accepted() {
        core.intelligence_session_id = None;
    }
    result
}

impl Plan {
    /// Remembers the reply in the idempotency window when the plan asks for it.
    fn finish(self, core: &mut Core, envelope: &Envelope, payload: &str) -> Self {
        if self.remember {
            core.remember(idempotency_key(envelope), payload, &self.reply.to_json());
        }
        self
    }
}

/// The bounded-cache key for one client command.
#[must_use]
pub fn idempotency_key(envelope: &Envelope) -> String {
    format!("{}\u{1f}{}", envelope.client_id, envelope.command_id)
}

/// The first identity in `items` that repeats within the batch or already lives
/// in `existing`, if any.
///
/// Identity is what addresses an entry (docs/design/playback.md), so two entries under one id
/// make `currentQueueItemId` and a saved record ambiguous; a command that would
/// create one is refused instead of installed (issue 2).
fn duplicate_identity<'a>(items: &'a [QueueItem], existing: &[QueueItem]) -> Option<&'a str> {
    for (index, item) in items.iter().enumerate() {
        let in_batch = items[..index]
            .iter()
            .any(|other| other.queue_item_id == item.queue_item_id);
        let in_queue = existing
            .iter()
            .any(|other| other.queue_item_id == item.queue_item_id);
        if in_batch || in_queue {
            return Some(item.queue_item_id.as_str());
        }
    }
    None
}

fn plan_load_queue(
    core: &mut Core,
    envelope: &Envelope,
    items: &[QueueItem],
    start_item_id: &str,
    autoplay: bool,
    seed: Option<u64>,
    intelligence: Option<&str>,
) -> Plan {
    let Some(expected) = envelope.expected_queue_revision else {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("expectedQueueRevision is missing")),
            false,
        );
    };
    if expected != core.queue_revision {
        return reject(
            envelope,
            core,
            &Rejection::StaleQueueRevision {
                expected,
                actual: core.queue_revision,
            },
            false,
        );
    }
    if items.is_empty() {
        return reject(envelope, core, &Rejection::EmptyQueue, false);
    }
    // A load replaces the queue, so it is checked against itself alone.
    if let Some(duplicate) = duplicate_identity(items, &[]) {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(format!("queue item identity {duplicate} is not unique")),
            false,
        );
    }
    let Some(named) = items
        .iter()
        .position(|item| item.queue_item_id == start_item_id)
    else {
        // The schema requires the field to name one of `items`, seeded or not, so
        // a name that matches nothing stays a malformed command rather than a
        // silently ignored one.
        return reject(envelope, core, &Rejection::UnknownStartItem, true);
    };
    // A seeded shuffle load takes its head from the seed: the order belongs to
    // the session, and letting the caller name the first track as well would
    // make two owners of the same permutation (docs/design/playback.md). Any other load starts
    // on the item it named.
    if intelligence.is_some() && items.len() > 50 {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("heart window exceeds 50")),
            false,
        );
    }
    core.intelligence_session_id = intelligence.map(str::to_owned);
    if intelligence.is_some() {
        core.mode = PlayMode::Sequential;
        core.shuffle_order.clear();
        core.shuffle_seeded = false;
    }
    let seeded = seed.filter(|_| core.mode == PlayMode::Shuffle);
    core.queue = items.to_vec();
    core.queue_revision += 1;
    core.current = Some(named);
    core.play_when_ready = autoplay;
    core.generation += 1;
    core.is_seeking = false;
    core.phase = Phase::Resolving;
    core.buffering = false;
    core.item_finished = false;
    core.duration_ms = None;
    core.anchor_media_us = 0;
    core.anchor_frames = 0;
    core.clear_error();
    // A shuffle order that survived would be a permutation of a list that no
    // longer exists. The mode itself is the user's preference and stays.
    match seeded {
        Some(seed) => core.start_shuffle_from_seed(seed),
        None if core.mode == PlayMode::Shuffle => {
            let seed = core.next_shuffle_seed();
            core.rebuild_shuffle(seed);
        }
        None => {}
    }
    // A seeded load selected the head of its own permutation; every other path
    // is already on the name it was given.
    let index = core.current.unwrap_or(named);
    core.bump();
    accepted(
        envelope,
        core,
        Some(operation_id(core.generation)),
        vec![
            Effect::StartItem {
                index,
                position_ms: 0,
            },
            Effect::Publish,
        ],
    )
}

/// All validation precedes mutation; append and head eviction publish together.
#[allow(clippy::too_many_arguments)]
fn plan_intelligence(
    core: &mut Core,
    envelope: &Envelope,
    operation: &str,
    session_id: &str,
    items: &[QueueItem],
    evict_count: usize,
    advance: bool,
    autoplay: bool,
    expected_session_revision: Option<u64>,
) -> Plan {
    if operation == "start" {
        let Some(first) = items.first() else {
            return reject(envelope, core, &Rejection::EmptyQueue, false);
        };
        return plan_load_queue(
            core,
            envelope,
            items,
            &first.queue_item_id,
            autoplay,
            None,
            Some(session_id),
        );
    }
    if envelope.expected_queue_revision != Some(core.queue_revision) {
        return reject(
            envelope,
            core,
            &Rejection::StaleQueueRevision {
                expected: envelope.expected_queue_revision.unwrap_or(0),
                actual: core.queue_revision,
            },
            false,
        );
    }
    if core.intelligence_session_id.as_deref() != Some(session_id) {
        return reject(envelope, core, &Rejection::SessionMismatch, false);
    }
    if operation == "exit" {
        core.intelligence_session_id = None;
        core.queue_revision += 1;
        core.bump();
        return accepted(envelope, core, None, vec![Effect::Publish]);
    }
    if expected_session_revision.is_some_and(|revision| revision != core.session_revision) {
        return reject(envelope, core, &Rejection::StaleGeneration, false);
    }
    if items.is_empty()
        || evict_count > core.current.unwrap_or(0)
        || core.queue.len() - evict_count + items.len() > 50
        || duplicate_identity(items, &core.queue).is_some()
    {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("invalid intelligence window")),
            false,
        );
    }
    let old_len = core.queue.len();
    core.queue.drain(..evict_count);
    if let Some(current) = core.current {
        core.current = Some(current - evict_count);
    }
    let first_new = old_len - evict_count;
    core.queue.extend_from_slice(items);
    core.queue_revision += 1;
    if old_len == 0 || advance {
        core.play_when_ready = autoplay;
        let effect = transition_to(core, first_new);
        accepted(
            envelope,
            core,
            Some(operation_id(core.generation)),
            vec![effect, Effect::Publish],
        )
    } else {
        core.bump();
        accepted(envelope, core, None, vec![Effect::Publish])
    }
}

/// Rebuilds the session's queue from a stored record (docs/design/restore.md).
///
/// The record carries stable identities in the queue's own *load* order, which is
/// the one order a seeded replay can feed back to the session: the same seed over
/// the same load order is the same permutation, so a restored seed can open on the
/// slot the user was hearing rather than on the permutation's head. A shuffle the
/// record holds no seed for keeps its queue and draws a fresh order, landing on
/// its head, because promising the old order would be a lie (docs/design/playback.md).
///
/// The restored queue is *paused* and holds no sources, and nothing is prepared:
/// the saved position is held as the anchor so it is visible at once, and the
/// user's play intent is what makes the session ask the host to resolve a source
/// over the ordinary `sourceRequest` path (docs/design/provider.md, docs/design/restore.md §7). That is also why
/// the record never has to persist a URL.
///
/// The effects carry the gain as well as the start: `core` is the authority on
/// volume but the callback reads its own lock-free copy, which only
/// [`Effect::SetVolume`] syncs.
///
/// `None` when the session already holds a queue: a live session wins over a file.
#[must_use]
pub fn plan_restore(core: &mut Core, record: &checkpoint::Record) -> Option<Vec<Effect>> {
    if !core.queue.is_empty() || record.items.is_empty() {
        return None;
    }
    // v2 records the order the user heard and the identity of the entry that was
    // playing, so the queue is rebuilt exactly as it was — including an edited
    // order, a shuffle entered mid-playback, and a track that appears twice
    // (docs/design/restore.md).
    core.queue = record
        .items
        .iter()
        .map(|item| QueueItem::new(item.item_id.clone(), item.track_id.clone()))
        .collect();
    core.queue_revision += 1;
    core.mode = record.mode;
    core.volume_permille = record.volume;
    // Restoring is not a request to make noise *or* to resolve a source: the
    // queue comes back paused with its saved position, and the user pressing
    // play is what prepares it (architecture §8, docs/design/restore.md §7).
    core.play_when_ready = false;
    core.is_seeking = false;
    core.phase = Phase::Paused;
    core.buffering = false;
    core.item_finished = false;
    core.duration_ms = None;
    core.anchor_media_us = 0;
    core.anchor_frames = 0;
    core.clear_error();
    let index = core
        .queue
        .iter()
        .position(|item| item.queue_item_id == record.current_item_id)
        .unwrap_or(0);
    core.current = Some(index);
    if core.mode == PlayMode::Shuffle {
        // The recorded order *is* the shuffle order: an identity order over the
        // queue, with the cursor on the entry that was playing, so the published
        // list and adjacent navigation match what the user heard.
        core.shuffle_order = (0..core.queue.len()).collect();
        core.shuffle_cursor = index;
        core.shuffle_seed = record.shuffle_seed.unwrap_or(0);
        core.shuffle_seeded = false;
    } else {
        core.shuffle_order.clear();
        core.shuffle_cursor = 0;
    }
    core.generation += 1;
    core.bump();
    // The position belongs to the entry the record named: since the identity is
    // what selects the row, a record whose current entry is missing cannot apply
    // its progress to another track (issue 4).
    let position_ms = if core
        .queue
        .get(index)
        .is_some_and(|item| item.queue_item_id == record.current_item_id)
    {
        record.position_ms
    } else {
        0
    };
    // The anchor is the saved position, which is what makes it visible before
    // anything is prepared. No `StartItem` is emitted: it is what would ask the
    // host for a source, and a restore deliberately does not (docs/design/restore.md §7).
    core.anchor_media_us = position_ms.saturating_mul(1_000);
    Some(vec![
        Effect::SetVolume {
            volume: record.volume,
        },
        Effect::Publish,
    ])
}

/// Rebuild buffered PCM before reopening a route with different geometry.
/// The existing output transaction preserves position and rechecks play intent.
pub(crate) fn plan_output_format(
    core: &mut Core,
    buffered: (u32, u32),
    negotiated: (u32, u32),
) -> Option<Effect> {
    if buffered == negotiated {
        return None;
    }
    Some(plan_output_rebuild(core))
}

/// A healthy shared stream follows hardware format notifications only while the
/// user has not selected a target PCM rate. Exclusive output remains source-led.
pub(crate) fn plan_system_sample_rate(core: &mut Core, rate: u32) -> Option<Effect> {
    if !core.output_running
        || core.output_busy
        || !core.play_when_ready
        || core.output_configuration.exclusive
        || core.output_configuration.resampling_enabled
        || core.pcm_rate == rate
        || !(8000..=384_000).contains(&rate)
    {
        return None;
    }
    Some(plan_output_rebuild(core))
}

fn plan_output_rebuild(core: &mut Core) -> Effect {
    core.output_version += 1;
    core.output_busy = true;
    core.bump();
    Effect::ConfigureOutput {
        device_uid: core.output_configuration.device_uid.clone(),
        exclusive: core.output_configuration.exclusive,
        resampling_enabled: core.output_configuration.resampling_enabled,
        target_sample_rate: core.output_configuration.target_sample_rate,
        version: core.output_version,
    }
}

fn plan_play(core: &mut Core, envelope: &Envelope, frames_consumed: u64) -> Plan {
    if core.current.is_none() && core.intelligence_session_id.is_some() {
        core.play_when_ready = true;
        core.bump();
        return accepted(envelope, core, None, vec![Effect::Publish]);
    }
    let Some(index) = core.current else {
        return reject(envelope, core, &Rejection::EmptyQueue, false);
    };
    core.play_when_ready = true;
    // A new play intent is also how a failed item is retried.
    core.clear_error();
    match core.phase {
        // Ready means PCM is already buffered: resume where the position stands.
        Phase::Ready => {
            core.bump();
            accepted(
                envelope,
                core,
                None,
                vec![Effect::ResumeOutput, Effect::Publish],
            )
        }
        // Accepted while preparing: record the intent, do not claim sound yet.
        Phase::Resolving | Phase::Loading => {
            core.bump();
            accepted(envelope, core, None, vec![Effect::Publish])
        }
        // `Paused` belongs here rather than with `Resolving`: a restored queue
        // holds a position but no source and no resolution in flight, so the
        // play intent is what prepares it — from its saved position, not from
        // the top (docs/design/restore.md §7).
        Phase::Idle | Phase::Paused | Phase::Ended | Phase::Error => {
            // Re-prepare from the current item: `ended` starts from the top, a
            // stopped, restored or failed item keeps its restore point
            // (docs/design/playback.md 6.2).
            let position_ms = match core.phase {
                Phase::Ended => 0,
                _ => core.position_ms(frames_consumed),
            };
            core.generation += 1;
            core.is_seeking = false;
            core.phase = Phase::Resolving;
            core.item_finished = false;
            core.duration_ms = None;
            core.bump();
            accepted(
                envelope,
                core,
                Some(operation_id(core.generation)),
                vec![Effect::StartItem { index, position_ms }, Effect::Publish],
            )
        }
    }
}

fn plan_pause(core: &mut Core, envelope: &Envelope) -> Plan {
    core.play_when_ready = false;
    core.bump();
    accepted(
        envelope,
        core,
        None,
        vec![Effect::PauseOutput, Effect::Publish],
    )
}

fn plan_seek(
    core: &mut Core,
    envelope: &Envelope,
    position_ms: u64,
    target_queue_item_id: &str,
    expected_generation: u64,
) -> Plan {
    let Some(index) = core.current else {
        return reject(envelope, core, &Rejection::EmptyQueue, false);
    };
    let matches_target = core
        .current_item()
        .is_some_and(|item| item.queue_item_id == target_queue_item_id);
    if !matches_target || expected_generation != core.generation {
        // A delayed Seek must never reposition a track the user moved on from.
        return reject(envelope, core, &Rejection::StaleGeneration, false);
    }
    core.generation += 1;
    core.is_seeking = true;
    core.phase = Phase::Resolving;
    core.buffering = false;
    core.item_finished = false;
    core.clear_error();
    core.bump();
    accepted(
        envelope,
        core,
        Some(operation_id(core.generation)),
        vec![
            Effect::SeekItem {
                index,
                position_ms,
                generation: core.generation,
            },
            Effect::Publish,
        ],
    )
}

fn plan_skip(core: &mut Core, envelope: &Envelope, reason: TransitionReason) -> Plan {
    let Some(expected) = envelope.expected_queue_revision else {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("expectedQueueRevision is missing")),
            false,
        );
    };
    if expected != core.queue_revision {
        return reject(
            envelope,
            core,
            &Rejection::StaleQueueRevision {
                expected,
                actual: core.queue_revision,
            },
            false,
        );
    }
    if core.current.is_none() {
        return reject(envelope, core, &Rejection::EmptyQueue, false);
    }
    // The schema makes a skip carry the item and generation it addresses, and a
    // delayed skip must not advance a track the user has already moved on from.
    // Both fields are optional here so an older or simpler caller still works.
    if let Some(target) = envelope.target_queue_item_id.as_deref()
        && core
            .current_item()
            .is_none_or(|item| item.queue_item_id != target)
    {
        return reject(envelope, core, &Rejection::StaleGeneration, false);
    }
    if let Some(expected) = envelope.expected_generation
        && expected != core.generation
    {
        return reject(envelope, core, &Rejection::StaleGeneration, false);
    }
    let Some(index) = core.next_item(reason) else {
        return reject(envelope, core, &Rejection::QueueBoundary, false);
    };
    let effect = transition_to(core, index);
    accepted(
        envelope,
        core,
        Some(operation_id(core.generation)),
        vec![effect, Effect::Publish],
    )
}

/// Jumps to one queue entry without touching the queue itself.
///
/// Unlike a load, the queue identity and its revision are untouched: this is a
/// current-item action, so it moves `generation` (any in-flight seek or read is
/// invalidated) and the session revision only.
fn plan_play_item(core: &mut Core, envelope: &Envelope) -> Plan {
    let Some(expected) = envelope.expected_queue_revision else {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("expectedQueueRevision is missing")),
            false,
        );
    };
    if expected != core.queue_revision {
        return reject(
            envelope,
            core,
            &Rejection::StaleQueueRevision {
                expected,
                actual: core.queue_revision,
            },
            false,
        );
    }
    let Some(target) = envelope.target_queue_item_id.as_deref() else {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("targetQueueItemId is missing")),
            false,
        );
    };
    let Some(index) = core
        .queue
        .iter()
        .position(|item| item.queue_item_id == target)
    else {
        return reject(envelope, core, &Rejection::UnknownQueueItem, true);
    };
    // Choosing a row is an explicit "play this", unlike a skip, which is
    // navigation and keeps whatever intent the session already had.
    let paused = !core.play_when_ready;
    core.play_when_ready = true;
    if core.current == Some(index) && !matches!(core.phase, Phase::Ended | Phase::Error) {
        // Choosing the row that is already playing must not restart it, but it
        // does mean the user wants to hear it.
        core.bump();
        let effects = if paused && core.phase == Phase::Ready {
            vec![Effect::ResumeOutput, Effect::Publish]
        } else {
            vec![Effect::Publish]
        };
        return accepted(envelope, core, None, effects);
    }
    if core.mode == PlayMode::Shuffle {
        core.set_shuffle_cursor(index);
    }
    let effect = transition_to(core, index);
    accepted(
        envelope,
        core,
        Some(operation_id(core.generation)),
        vec![effect, Effect::Publish],
    )
}

/// Applies a structural queue edit without replacing the queue.
///
/// Every accepted edit bumps `queueRevision`, because the queue that revision
/// describes changed; an edit that moves the current item also bumps
/// `generation`, because asynchronous work for the entry that is gone must be
/// invalidated. `playNext` and `append` leave the current item where it is
/// (docs/design/playback.md).
fn plan_edit_queue(core: &mut Core, envelope: &Envelope, edit: &QueueEdit, external: bool) -> Plan {
    if core.intelligence_session_id.is_some()
        && !external
        && !matches!(edit, QueueEdit::Remove { .. })
    {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("external insert requires exit")),
            false,
        );
    }
    let Some(expected) = envelope.expected_queue_revision else {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("expectedQueueRevision is missing")),
            false,
        );
    };
    if expected != core.queue_revision {
        return reject(
            envelope,
            core,
            &Rejection::StaleQueueRevision {
                expected,
                actual: core.queue_revision,
            },
            false,
        );
    }
    match edit {
        QueueEdit::PlayNext { items } => plan_queue_insert(core, envelope, items, true),
        QueueEdit::Append { items } => plan_queue_insert(core, envelope, items, false),
        QueueEdit::Remove {
            target_queue_item_id,
        } => plan_queue_remove(core, envelope, target_queue_item_id),
    }
}

/// Adds entries to the queue, immediately after the current item (`play_next`)
/// or at the end.
fn plan_queue_insert(
    core: &mut Core,
    envelope: &Envelope,
    items: &[QueueItem],
    play_next: bool,
) -> Plan {
    if items.is_empty() {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("items is empty")),
            false,
        );
    }
    // An insert lands on the queue that is already loaded, so an id it reuses —
    // from that queue or from within the batch — would make identity ambiguous
    // (issue 2).
    if let Some(duplicate) = duplicate_identity(items, &core.queue) {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(format!("queue item identity {duplicate} is already in use")),
            false,
        );
    }
    // An edit that lands on an empty queue is a content choice: the entries are
    // installed, the first is selected and playback starts, exactly as a
    // `loadQueue` with `autoplay: true` (docs/design/playback.md).
    if core.queue.is_empty() || core.current.is_none() {
        core.queue = items.to_vec();
        core.queue_revision += 1;
        core.current = Some(0);
        core.play_when_ready = true;
        core.generation += 1;
        core.is_seeking = false;
        core.phase = Phase::Resolving;
        core.buffering = false;
        core.item_finished = false;
        core.duration_ms = None;
        core.anchor_media_us = 0;
        core.anchor_frames = 0;
        core.clear_error();
        if core.mode == PlayMode::Shuffle {
            let seed = core.next_shuffle_seed();
            core.rebuild_shuffle(seed);
        }
        core.bump();
        return accepted(
            envelope,
            core,
            Some(operation_id(core.generation)),
            vec![
                Effect::StartItem {
                    index: 0,
                    position_ms: 0,
                },
                Effect::Publish,
            ],
        );
    }

    let current = core.current.unwrap_or(0);
    let count = items.len();
    if core.mode == PlayMode::Shuffle {
        // The session owns the effective order, so an insert places the new
        // entries where the order says they play, not where a natural index
        // would put them.
        if core.shuffle_order.len() != core.queue.len() {
            let seed = core.shuffle_seed;
            core.rebuild_shuffle(seed);
        }
        let insert_at = if play_next {
            core.shuffle_order
                .iter()
                .position(|item| *item == current)
                .map_or(0, |position| position + 1)
        } else {
            core.shuffle_order.len()
        };
        let position = core.queue.len();
        let new_indices: Vec<usize> = (position..position + count).collect();
        core.queue.extend_from_slice(items);
        core.shift_queue_indices(position, count);
        core.shuffle_order.splice(insert_at..insert_at, new_indices);
        core.set_shuffle_cursor(current);
    } else if play_next {
        let position = current + 1;
        for (offset, item) in items.iter().enumerate() {
            core.queue.insert(position + offset, item.clone());
        }
        core.shift_queue_indices(position, count);
    } else {
        let position = core.queue.len();
        core.queue.extend_from_slice(items);
        core.shift_queue_indices(position, count);
    }
    // An edit changes the permutation the seed describes, so the order is no
    // longer reproducible from it (docs/design/playback.md).
    core.shuffle_seeded = false;
    core.queue_revision += 1;
    core.bump();
    accepted(envelope, core, None, vec![Effect::Publish])
}

/// Drops one queue entry by identity.
///
/// Removing the entry that is playing selects its successor by the forward rule
/// and keeps the play intent, so an edit does not silently stop the music.
/// Removing the last entry is the `clearQueue` end state (docs/design/playback.md).
fn plan_queue_remove(core: &mut Core, envelope: &Envelope, target_queue_item_id: &str) -> Plan {
    let Some(index) = core
        .queue
        .iter()
        .position(|item| item.queue_item_id == target_queue_item_id)
    else {
        return reject(envelope, core, &Rejection::UnknownQueueItem, true);
    };
    if core.queue.len() == 1 {
        // Removing the only entry leaves the same state `clearQueue` produces.
        let context = core.intelligence_session_id.clone();
        let intent = core.play_when_ready;
        let result = plan_stop(core, envelope, true, 0);
        core.intelligence_session_id = context;
        if core.intelligence_session_id.is_some() {
            core.play_when_ready = intent;
        }
        return result;
    }
    let was_current = core.current == Some(index);
    // The successor is decided before the queue changes, by the same forward rule
    // a manual skip uses: `repeatOne` must not repeat the entry being removed.
    let successor = if was_current {
        core.next_item(TransitionReason::SkipNext)
    } else {
        None
    };
    core.queue.remove(index);
    core.forget_queue_index(index);
    core.shuffle_seeded = false;
    core.queue_revision += 1;

    let mut effects = Vec::new();
    if was_current {
        if successor.is_none() && core.intelligence_session_id.is_some() {
            core.current = if index > 0 { Some(index - 1) } else { None };
            core.generation += 1;
            core.phase = Phase::Ended;
            core.item_finished = true;
            core.bump();
            return accepted(
                envelope,
                core,
                None,
                vec![Effect::StopOutput, Effect::Publish],
            );
        }
        let successor = successor.unwrap_or(0);
        let next_index = if successor > index {
            successor - 1
        } else {
            successor
        };
        // `transition_to` sets the current item, moves the generation, clears the
        // error and returns the start effect, exactly as a skip does.
        effects.push(transition_to(core, next_index));
    } else {
        core.bump();
    }
    if core.mode == PlayMode::Shuffle
        && let Some(current) = core.current
    {
        core.set_shuffle_cursor(current);
    }
    effects.push(Effect::Publish);
    accepted(
        envelope,
        core,
        if was_current {
            Some(operation_id(core.generation))
        } else {
            None
        },
        effects,
    )
}

/// Installs a playback mode.
///
/// Entering shuffle keeps the item that is playing in place and clears the
/// history, because a new permutation defines a new walk through the queue.
/// Every accepted change bumps `queueRevision`, including one that installs the
/// mode that was already set: the order the revision describes may have changed,
/// and a client then needs exactly one rule for adopting it (architecture
/// section 7).
fn plan_set_mode(core: &mut Core, envelope: &Envelope, mode: PlayMode, seed: Option<u64>) -> Plan {
    let Some(expected) = envelope.expected_queue_revision else {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("expectedQueueRevision is missing")),
            false,
        );
    };
    if expected != core.queue_revision {
        return reject(
            envelope,
            core,
            &Rejection::StaleQueueRevision {
                expected,
                actual: core.queue_revision,
            },
            false,
        );
    }
    if core.intelligence_session_id.is_some()
        && !matches!(mode, PlayMode::Sequential | PlayMode::RepeatOne)
    {
        return reject(
            envelope,
            core,
            &Rejection::Malformed(String::from("mode unavailable in intelligence")),
            false,
        );
    }
    core.mode = mode;
    if mode == PlayMode::Shuffle {
        let seed = seed.unwrap_or_else(|| core.next_shuffle_seed());
        core.rebuild_shuffle(seed);
    } else {
        core.shuffle_order.clear();
        core.shuffle_cursor = 0;
        core.shuffle_seeded = false;
    }
    core.queue_revision += 1;
    core.bump();
    accepted(envelope, core, None, vec![Effect::Publish])
}

/// Installs the output gain.
///
/// Volume touches neither the queue nor the current item, so it bumps only the
/// session revision — no `queueRevision`, no operation — and carries one effect
/// that copies the new gain into the callback's atomic before publishing.
fn plan_set_volume(core: &mut Core, envelope: &Envelope, volume: u32) -> Plan {
    core.volume_permille = volume;
    core.bump();
    accepted(
        envelope,
        core,
        None,
        vec![Effect::SetVolume { volume }, Effect::Publish],
    )
}

/// Points the session at `index` and returns the effect that starts it.
///
/// Shared by every transition, manual or natural, so the state changes a switch
/// implies cannot drift between them (architecture section 7).
fn transition_to(core: &mut Core, index: usize) -> Effect {
    core.current = Some(index);
    core.generation += 1;
    core.is_seeking = false;
    core.phase = Phase::Resolving;
    core.buffering = false;
    core.item_finished = false;
    core.duration_ms = None;
    core.clear_error();
    core.bump();
    Effect::StartItem {
        index,
        position_ms: 0,
    }
}

/// The natural-end transition, for the publisher's tick.
///
/// `None` means the queue holds nothing else, which is the only way this session
/// reaches `ended` now that `listLoop` wraps.
#[must_use]
pub fn natural_end(core: &mut Core) -> Option<Effect> {
    let index = core.next_item(TransitionReason::AutoAdvance)?;
    Some(transition_to(core, index))
}

fn plan_stop(
    core: &mut Core,
    envelope: &Envelope,
    clear_queue: bool,
    frames_consumed: u64,
) -> Plan {
    let position = if clear_queue || core.current.is_none() {
        0
    } else {
        core.position_ms(frames_consumed)
    };
    core.generation += 1;
    core.is_seeking = false;
    core.phase = Phase::Idle;
    core.play_when_ready = false;
    core.buffering = false;
    core.item_finished = false;
    core.duration_ms = None;
    core.anchor_media_us = position.saturating_mul(1_000);
    core.anchor_frames = frames_consumed;
    if clear_queue {
        core.intelligence_session_id = None;
        core.queue.clear();
        core.current = None;
        core.queue_revision += 1;
        core.generation += 1;
    }
    core.clear_error();
    core.bump();
    accepted(
        envelope,
        core,
        None,
        vec![Effect::StopOutput, Effect::Publish],
    )
}

/// Installs a resolved source into one queue item.
///
/// The command is validated in full *before* the queue is touched, so a refused
/// `provideSource` leaves no trace (docs/design/boundaries.md): a delayed answer for the item that
/// is current right now must not overwrite that item's source on its way to being
/// rejected as stale.
///
/// `expected_generation` guards the *current* item only. An upcoming item is
/// prefetched ahead of playback, so the generation the host captured when it
/// asked is expected to have moved on by the time playback reaches the item; the
/// URI is stored so `start_item` finds it later without a second `sourceRequest`
/// (docs/design/provider.md). A queue that no longer holds the item is refused by identity, which
/// is what a prefetch left over from a replaced queue hits.
fn plan_provide_source(
    core: &mut Core,
    envelope: &Envelope,
    target_queue_item_id: &str,
    source_uri: Option<&str>,
    normalization: crate::effects::Normalization,
    expires_at_ms: Option<u64>,
    expected_generation: Option<u64>,
) -> Plan {
    let Some(index) = core
        .queue
        .iter()
        .position(|item| item.queue_item_id == target_queue_item_id)
    else {
        return reject(envelope, core, &Rejection::UnknownQueueItem, false);
    };

    let is_current = core.current == Some(index);
    if is_current
        && let Some(expected) = expected_generation
        && expected != core.generation
    {
        return reject(envelope, core, &Rejection::StaleGeneration, false);
    }

    // Committed only now: past this point the command is accepted, and every
    // state change happens exactly once.
    let item = &mut core.queue[index];
    item.source_revision += 1;
    item.source_uri = source_uri.map(str::to_owned);
    item.normalization = if source_uri.is_some() {
        normalization
    } else {
        crate::effects::Normalization::default()
    };
    // The caller named when this one lapses, if it knows; `null` and an absent
    // field both mean "no known expiry" (docs/design/provider.md).
    item.expires_at_ms = source_uri.and(expires_at_ms);
    // The item's attempt budget is deliberately *not* reset here: it counts how
    // many sources this entry has been handed and given up on, and a host that
    // keeps answering is exactly the loop it bounds (docs/design/provider.md). A reload builds
    // new queue items, which is where a fresh budget comes from.
    let mut effects = Vec::new();

    if source_uri.is_some() && is_current && core.phase == Phase::Resolving {
        core.phase = Phase::Loading;
        effects.push(Effect::StartItem {
            index,
            position_ms: core.anchor_media_us / 1_000,
        });
    }
    effects.push(Effect::Publish);
    accepted(envelope, core, None, effects)
}

/// The `result` message for a rejection, as JSON text.
#[must_use]
pub fn rejection_reply(envelope: &Envelope, rejection: &Rejection) -> String {
    let mut reply = Map::new();
    reply.insert(String::from("schemaVersion"), json!(SCHEMA_VERSION));
    reply.insert(String::from("kind"), json!("result"));
    reply.insert(String::from("commandId"), json!(envelope.command_id));
    reply.insert(String::from("status"), json!("rejected"));
    reply.insert(String::from("errorCode"), json!(rejection.code()));
    Value::Object(reply).to_string()
}

/// Builds an accepted reply.
fn accepted(
    envelope: &Envelope,
    core: &Core,
    operation_id: Option<String>,
    effects: Vec<Effect>,
) -> Plan {
    Plan {
        reply: CommandReply::Accepted {
            command_id: envelope.command_id.clone(),
            session_revision: core.session_revision,
            operation_id,
        },
        effects,
        remember: true,
    }
}

/// Builds a rejected reply carrying the current queue revision where relevant.
fn reject(envelope: &Envelope, core: &Core, rejection: &Rejection, remember: bool) -> Plan {
    Plan {
        reply: CommandReply::Rejected {
            command_id: envelope.command_id.clone(),
            rejection: rejection.clone(),
            queue_revision: core.queue_revision,
        },
        effects: Vec::new(),
        remember,
    }
}

/// A stable operation id for an accepted asynchronous command.
#[must_use]
pub fn operation_id(generation: u64) -> String {
    format!("op-{generation}")
}

fn required_str(object: &Map<String, Value>, field: &str) -> Result<String, Rejection> {
    object
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| Rejection::Malformed(format!("{field} is missing")))
}

/// Reads an optional 64-bit counter that the schema also allows to be `null`.
///
/// `null` and an absent field mean the same thing — the caller does not know —
/// which is what distinguishes an expiry (a fact the caller may not have) from
/// the counters it chose itself.
fn nullable_u64(object: &Map<String, Value>, field: &str) -> Result<Option<u64>, Rejection> {
    match object.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => text
            .parse::<u64>()
            .map(Some)
            .map_err(|_| Rejection::Malformed(format!("{field} is not a decimal string"))),
        Some(_) => Err(Rejection::Malformed(format!(
            "{field} must be a decimal string or null"
        ))),
    }
}

/// Reads a 64-bit counter, which the schema encodes as a decimal string.
fn optional_u64(object: &Map<String, Value>, field: &str) -> Result<Option<u64>, Rejection> {
    match object.get(field) {
        None => Ok(None),
        Some(Value::String(text)) => text
            .parse::<u64>()
            .map(Some)
            .map_err(|_| Rejection::Malformed(format!("{field} is not a decimal string"))),
        Some(_) => Err(Rejection::Malformed(format!(
            "{field} must be a decimal string"
        ))),
    }
}

fn required_u64(object: &Map<String, Value>, field: &str) -> Result<u64, Rejection> {
    optional_u64(object, field)?.ok_or_else(|| Rejection::Malformed(format!("{field} is missing")))
}

/// Parses a `setVolume` payload: the gain as a permille of full scale.
///
/// Unlike the 64-bit counters, the schema carries the volume as a plain JSON
/// integer, so a bare number is the well-formed shape. The schema bounds the
/// permille; an out-of-range value is a malformed payload, not something to
/// clamp silently.
fn parse_volume(payload: &Map<String, Value>) -> Result<u32, Rejection> {
    let volume = payload
        .get("volume")
        .and_then(Value::as_u64)
        .ok_or_else(|| Rejection::Malformed(String::from("volume must be an integer")))?;
    if volume > u64::from(MAX_VOLUME_PERMILLE) {
        return Err(Rejection::Malformed(String::from(
            "volume is above the permille range",
        )));
    }
    Ok(u32::try_from(volume).unwrap_or(MAX_VOLUME_PERMILLE))
}

/// Parses an `editQueue` payload into the structural change it describes.
fn parse_queue_edit(
    payload: &Map<String, Value>,
    target_queue_item_id: Option<&str>,
) -> Result<QueueEdit, Rejection> {
    match required_str(payload, "operation")?.as_str() {
        "playNext" => Ok(QueueEdit::PlayNext {
            items: parse_items(payload)?,
        }),
        "append" => Ok(QueueEdit::Append {
            items: parse_items(payload)?,
        }),
        // Identity, not position: the envelope names the entry, exactly as
        // `playItem` does, so a duplicated track is removable one at a time.
        "remove" => Ok(QueueEdit::Remove {
            target_queue_item_id: target_queue_item_id.map(str::to_owned).ok_or_else(|| {
                Rejection::Malformed(String::from("targetQueueItemId is missing"))
            })?,
        }),
        other => Err(Rejection::Malformed(format!(
            "unknown queue operation {other}"
        ))),
    }
}

fn parse_items(payload: &Map<String, Value>) -> Result<Vec<QueueItem>, Rejection> {
    let items = payload
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| Rejection::Malformed(String::from("items is missing")))?;
    items
        .iter()
        .map(|item| {
            let item = item
                .as_object()
                .ok_or_else(|| Rejection::Malformed(String::from("items must be objects")))?;
            let mut queue_item = QueueItem::new(
                required_str(item, "queueItemId")?,
                required_str(item, "trackId")?,
            );
            queue_item.source_uri = item
                .get("sourceUri")
                .and_then(Value::as_str)
                .map(str::to_owned);
            // A load may carry an expiry for the item it resolved upfront, the
            // same way `provideSource` does for a later one.
            queue_item.expires_at_ms = nullable_u64(item, "expiresAtMs")?;
            if queue_item.source_uri.is_some() {
                queue_item.normalization = crate::effects::Normalization::from_json(item);
            }
            Ok(queue_item)
        })
        .collect()
}

fn plan_source_failed(
    core: &mut Core,
    envelope: &Envelope,
    target_queue_item_id: &str,
    expected_generation: u64,
    error_code: &str,
) -> Plan {
    if core.intelligence_session_id.is_none()
        || core.generation != expected_generation
        || core
            .current_item()
            .is_none_or(|item| item.queue_item_id != target_queue_item_id)
    {
        reject(envelope, core, &Rejection::StaleGeneration, false)
    } else {
        core.is_seeking = false;
        core.phase = Phase::Error;
        core.error_code = Some(error_code.to_owned());
        core.failure_kind = crate::core::FailureKind::Source;
        core.buffering = false;
        core.bump();
        accepted(
            envelope,
            core,
            None,
            vec![Effect::StopOutput, Effect::Publish],
        )
    }
}

fn plan_interruption(
    core: &mut Core,
    envelope: &Envelope,
    interruption_id: &str,
    active: bool,
    allow_resume: bool,
    frames_consumed: u64,
) -> Plan {
    if active {
        if core.interruption.is_some()
            || core.last_interruption_id.as_deref() == Some(interruption_id)
        {
            return accepted(envelope, core, None, vec![]);
        }
        let resume = core.play_when_ready
            && core.current.is_some()
            && core.output_error.is_none()
            && core.error_code.is_none()
            && matches!(core.phase, Phase::Ready | Phase::Loading | Phase::Resolving);
        core.interruption = Some(Interruption {
            id: interruption_id.to_owned(),
            intent_version: core.play_intent_version,
            resume,
        });
        core.suppression.push(Suppression::Interruption);
        let pending = core.deferred_effects.take();
        core.buffering = false;
        core.bump();
        let mut effects = vec![Effect::PauseOutput];
        // Finish already accepted transitions while suppression keeps them silent.
        if let Some(pending) = pending {
            effects.extend(pending.effects);
        }
        effects.push(Effect::Publish);
        accepted(envelope, core, None, effects)
    } else {
        if core
            .interruption
            .as_ref()
            .is_none_or(|state| state.id != interruption_id)
        {
            return accepted(envelope, core, None, vec![]);
        }
        let state = core.interruption.take().unwrap();
        let resume =
            allow_resume && state.resume && state.intent_version == core.play_intent_version;
        core.last_interruption_id = Some(interruption_id.to_owned());
        core.suppression
            .retain(|reason| *reason != Suppression::Interruption);
        core.play_when_ready = resume
            && core.play_when_ready
            && core.output_error.is_none()
            && core.error_code.is_none();
        core.bump();
        if core.play_when_ready {
            let mut result = plan_play(core, envelope, frames_consumed);
            result.effects.insert(0, Effect::ValidateRecoveryOutput);
            result
        } else {
            accepted(
                envelope,
                core,
                None,
                vec![Effect::PauseOutput, Effect::Publish],
            )
        }
    }
}

fn plan_source_revocation(core: &mut Core, envelope: &Envelope, frames_consumed: u64) -> Plan {
    let position = core.position_ms(frames_consumed);
    for item in &mut core.queue {
        item.revoke_source();
    }
    core.generation += 1;
    core.is_seeking = false;
    core.phase = if matches!(envelope.command, Command::OfflineGap) {
        Phase::Paused
    } else {
        Phase::Error
    };
    core.play_when_ready = false;
    core.buffering = false;
    core.item_finished = false;
    core.anchor_media_us = position * 1000;
    core.anchor_frames = frames_consumed;
    core.error_code = Some(String::from(
        if matches!(envelope.command, Command::OfflineGap) {
            "playback.offlineGap"
        } else {
            "playback.vipExpired"
        },
    ));
    core.failure_kind = crate::core::FailureKind::Other;
    core.error_retryable = false;
    core.bump();
    accepted(
        envelope,
        core,
        None,
        vec![Effect::RevokeInput, Effect::Publish],
    )
}

fn plan_output_configuration(
    core: &mut Core,
    envelope: &Envelope,
    device_uid: Option<&str>,
    exclusive: bool,
    resampling_enabled: bool,
    target_sample_rate: u32,
) -> Plan {
    core.output_version += 1;
    core.output_busy = true;
    core.output_error = None;
    core.bump();
    accepted(
        envelope,
        core,
        None,
        vec![
            Effect::ConfigureOutput {
                device_uid: device_uid.map(str::to_owned),
                exclusive,
                resampling_enabled,
                target_sample_rate,
                version: core.output_version,
            },
            Effect::Publish,
        ],
    )
}

/// Planner tests: the mode rules and the queue actions, with no audio hardware
/// and no source that has to decode. They drive the same [`plan`] entry point the
/// executor does, so a rule cannot pass here and fail in the session.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{PlayMode, TransitionReason};

    /// A session whose queue holds `count` items, at the revision a load produces.
    fn core_with(count: usize) -> Core {
        let mut core = Core::new(String::from("session-test"));
        core.queue = (1..=count)
            .map(|index| {
                let mut item = QueueItem::new(format!("item-{index}"), format!("track-{index}"));
                item.source_uri = Some(format!("file:///nonexistent/{index}.mp3"));
                item
            })
            .collect();
        core.current = Some(0);
        core.queue_revision = 1;
        core.bump();
        core
    }

    #[test]
    fn source_failure_origin_is_independent_of_error_code_spelling() {
        let mut core = core_with(1);
        core.intelligence_session_id = Some("heart-test".into());
        let text = command(
            "sourceFailed",
            "source-failure",
            &json!({"targetQueueItemId": "item-1", "expectedGeneration": core.generation.to_string()}),
            &json!({"errorCode": "new-provider.network-failure"}),
        );
        let envelope = parse_envelope(&text).unwrap();
        let result = plan(&mut core, &envelope, &text, 0);
        assert!(matches!(result.reply, CommandReply::Accepted { .. }));
        assert!(matches!(
            core.failure_kind,
            crate::core::FailureKind::Source
        ));
        assert_eq!(
            core.error_code.as_deref(),
            Some("new-provider.network-failure")
        );
    }

    fn interruption(core: &mut Core, id: &str, active: bool) -> Plan {
        let text = command(
            "setInterruption",
            if active { "begin" } else { "end" },
            &json!({}),
            &json!({"interruptionId": id, "active": active}),
        );
        let envelope = parse_envelope(&text).unwrap();
        plan(core, &envelope, &text, 0)
    }

    #[test]
    fn platform_can_end_an_interruption_without_resuming() {
        let mut core = core_with(1);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        interruption(&mut core, "call", true);
        let text = command(
            "setInterruption",
            "end-no-resume",
            &json!({}),
            &json!({"interruptionId":"call", "active":false, "allowResume":false}),
        );
        let envelope = parse_envelope(&text).unwrap();
        let result = plan(&mut core, &envelope, &text, 0);
        assert!(!core.play_when_ready);
        assert!(core.suppression.is_empty());
        assert!(
            !result
                .effects
                .iter()
                .any(|e| matches!(e, Effect::ResumeOutput))
        );
    }

    #[test]
    fn transient_gain_never_changes_saved_user_volume() {
        let mut core = core_with(1);
        let original = core.volume_permille;
        let text = command(
            "setTransientGain",
            "duck",
            &json!({}),
            &json!({"volume":200}),
        );
        let envelope = parse_envelope(&text).unwrap();
        let result = plan(&mut core, &envelope, &text, 0);
        assert_eq!(core.volume_permille, original);
        assert!(
            result
                .effects
                .iter()
                .any(|e| matches!(e, Effect::SetTransientGain { permille: 200 }))
        );
        let invalid = command(
            "setTransientGain",
            "bad-duck",
            &json!({}),
            &json!({"volume":1001}),
        );
        assert!(parse_envelope(&invalid).is_err());
    }

    #[test]
    fn interruption_preserves_queue_position_and_resumes_only_its_matching_cycle() {
        let mut core = core_with(2);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        core.anchor_media_us = 12_000_000;
        let generation = core.generation;
        let begin = interruption(&mut core, "sleep-1", true);
        assert!(
            begin
                .effects
                .iter()
                .any(|e| matches!(e, Effect::PauseOutput))
        );
        assert_eq!(core.suppression, vec![Suppression::Interruption]);
        assert!(interruption(&mut core, "sleep-1", true).effects.is_empty());
        assert!(interruption(&mut core, "old", false).effects.is_empty());
        assert!(!core.suppression.is_empty());
        let end = interruption(&mut core, "sleep-1", false);
        assert!(
            end.effects
                .iter()
                .any(|e| matches!(e, Effect::ResumeOutput))
        );
        assert!(core.suppression.is_empty());
        assert_eq!(core.position_ms(0), 12_000);
        assert_eq!(core.generation, generation);
        assert_eq!(core.queue.len(), 2);
        assert!(interruption(&mut core, "sleep-1", false).effects.is_empty());
        assert!(interruption(&mut core, "sleep-1", true).effects.is_empty());
        interruption(&mut core, "sleep-2", true);
        assert!(interruption(&mut core, "sleep-1", false).effects.is_empty());
        assert!(core.interruption.is_some());
    }

    #[test]
    fn interruption_never_autoplays_paused_stopped_or_failed_output() {
        for phase in [Phase::Ready, Phase::Idle, Phase::Paused] {
            let mut core = core_with(1);
            core.phase = phase;
            core.play_when_ready = false;
            interruption(&mut core, "sleep", true);
            let end = interruption(&mut core, "sleep", false);
            assert!(!core.play_when_ready);
            assert!(
                !end.effects
                    .iter()
                    .any(|e| matches!(e, Effect::ResumeOutput | Effect::StartItem { .. }))
            );
        }
        let mut core = core_with(1);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        core.output_error = Some("outputDeviceRemoved".into());
        interruption(&mut core, "sleep", true);
        interruption(&mut core, "sleep", false);
        assert!(!core.play_when_ready);
    }

    #[test]
    fn accepted_transport_and_account_clear_cancel_interruption_recovery() {
        for kind in [
            "play",
            "pause",
            "stop",
            "clearQueue",
            "skipNext",
            "skipPrevious",
            "loadQueue",
        ] {
            let mut core = core_with(2);
            core.phase = Phase::Ready;
            core.play_when_ready = true;
            interruption(&mut core, "sleep", true);
            let payload = if kind == "loadQueue" {
                json!({"items":[{"queueItemId":"new","trackId":"new"}],"startItemId":"new","autoplay":true})
            } else {
                json!({})
            };
            let text = command(
                kind,
                "user",
                &json!({"expectedQueueRevision":"1"}),
                &payload,
            );
            assert_eq!(send(&mut core, &text)["status"], "accepted", "{kind}");
            interruption(&mut core, "sleep", false);
            assert!(!core.play_when_ready, "{kind}");
        }
    }

    #[test]
    fn non_transport_changes_and_rejected_commands_preserve_recovery() {
        let mut core = core_with(1);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        interruption(&mut core, "sleep", true);
        let volume = command("setVolume", "volume", &json!({}), &json!({"volume":500}));
        assert_eq!(send(&mut core, &volume)["status"], "accepted");
        let stale = command(
            "skipNext",
            "stale",
            &json!({"expectedQueueRevision":"0"}),
            &json!({}),
        );
        assert_eq!(send(&mut core, &stale)["status"], "rejected");
        interruption(&mut core, "sleep", false);
        assert!(core.play_when_ready);
    }

    #[test]
    fn stop_retains_the_frame_clock_position_and_clear_resets_it() {
        let mut core = core_with(2);
        core.pcm_rate = 48_000;
        core.anchor_media_us = 12_000_000;
        core.anchor_frames = 48_000;
        let stop = command("stop", "stop", &json!({}), &json!({}));
        let envelope = parse_envelope(&stop).unwrap();
        assert_eq!(
            plan(&mut core, &envelope, &stop, 96_000).reply.to_json()["status"],
            "accepted"
        );
        assert_eq!(core.position_ms(96_000), 13_000);
        assert_eq!(core.phase, Phase::Idle);
        assert_eq!(core.queue.len(), 2);
        assert!(!core.play_when_ready);
        let again = command("stop", "again", &json!({}), &json!({}));
        let envelope = parse_envelope(&again).unwrap();
        let _ = plan(&mut core, &envelope, &again, 96_000);
        assert_eq!(core.position_ms(96_000), 13_000);
        let clear = command("clearQueue", "clear", &json!({}), &json!({}));
        assert_eq!(send(&mut core, &clear)["status"], "accepted");
        assert!(core.queue.is_empty());
        assert_eq!(core.anchor_media_us, 0);
        let empty_stop = command("stop", "empty-stop", &json!({}), &json!({}));
        let envelope = parse_envelope(&empty_stop).unwrap();
        let _ = plan(&mut core, &envelope, &empty_stop, 96_000);
        assert_eq!(core.position_ms(96_000), 0);
    }

    #[test]
    fn system_rate_changes_rebuild_only_automatic_shared_output() {
        let mut core = core_with(1);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        core.output_running = true;
        core.anchor_media_us = 12_000_000;
        core.pcm_rate = 48_000;
        core.output_configuration.target_sample_rate = 192_000;
        let generation = core.generation;
        assert_eq!(plan_system_sample_rate(&mut core, 48_000), None);
        assert_eq!(plan_system_sample_rate(&mut core, 0), None);
        core.output_configuration.exclusive = true;
        assert_eq!(plan_system_sample_rate(&mut core, 44_100), None);
        core.output_configuration.exclusive = false;
        core.output_configuration.resampling_enabled = true;
        assert_eq!(plan_system_sample_rate(&mut core, 44_100), None);
        core.output_configuration.resampling_enabled = false;
        core.play_when_ready = false;
        assert_eq!(plan_system_sample_rate(&mut core, 44_100), None);
        core.play_when_ready = true;
        core.output_running = false;
        assert_eq!(plan_system_sample_rate(&mut core, 44_100), None);
        core.output_running = true;
        assert_eq!(
            plan_system_sample_rate(&mut core, 44_100),
            Some(Effect::ConfigureOutput {
                device_uid: None,
                exclusive: false,
                resampling_enabled: false,
                target_sample_rate: 192_000,
                version: 1,
            })
        );
        assert!(core.output_busy);
        assert_eq!(core.position_ms(0), 12_000);
        assert_eq!(core.generation, generation);
        assert!(core.play_when_ready);
        // Duplicate notifications cannot supersede the queued transaction.
        assert_eq!(plan_system_sample_rate(&mut core, 96_000), None);
    }

    #[test]
    fn resume_rebuilds_changed_output_geometry_without_losing_position_or_intent() {
        for format in [(48000, 1), (44100, 2)] {
            let mut core = core_with(1);
            core.output_configuration.resampling_enabled = true;
            core.output_configuration.target_sample_rate = 96_000;
            core.phase = Phase::Ready;
            core.anchor_media_us = 12_000_000;
            core.play_when_ready = false;
            let play = command("play", "resume", &json!({}), &json!({}));
            assert_eq!(send(&mut core, &play)["status"], "accepted");
            let position = core.position_ms(0);
            let revision = core.session_revision;
            let effect = plan_output_format(&mut core, (48000, 2), format);
            assert_eq!(
                effect,
                Some(Effect::ConfigureOutput {
                    device_uid: None,
                    exclusive: false,
                    resampling_enabled: true,
                    target_sample_rate: 96_000,
                    version: 1,
                })
            );
            assert!(core.output_busy);
            assert!(core.play_when_ready);
            assert!(!core.output_running);
            assert_eq!(core.position_ms(0), position);
            assert_eq!(core.current, Some(0));
            assert!(core.queue[0].source_uri.is_some());
            assert!(core.session_revision > revision);
            // A pause while the asynchronous rebuild is queued must still win.
            let pause = command("pause", "pause-again", &json!({}), &json!({}));
            assert_eq!(send(&mut core, &pause)["status"], "accepted");
            assert!(!core.play_when_ready);
        }
    }

    #[test]
    fn resume_keeps_pcm_when_the_new_route_accepts_the_buffered_format() {
        let mut core = core_with(1);
        core.phase = Phase::Ready;
        core.play_when_ready = true;
        let revision = core.session_revision;
        assert_eq!(plan_output_format(&mut core, (48000, 2), (48000, 2)), None);
        assert!(!core.output_busy);
        assert_eq!(core.output_version, 0);
        assert_eq!(core.session_revision, revision);
    }

    /// Runs one envelope the way the executor does and returns the reply.
    fn send(core: &mut Core, command: &str) -> Value {
        let envelope = parse_envelope(command).expect("a well-formed envelope");
        plan(core, &envelope, command, 0).reply.to_json()
    }

    fn command(kind: &str, command_id: &str, extra: &Value, payload: &Value) -> String {
        let mut value = json!({
            "schemaVersion": SCHEMA_VERSION,
            "kind": kind,
            "clientId": "test",
            "commandId": command_id,
            "targetSessionId": "session-test",
            "payload": payload,
        });
        let object = value.as_object_mut().expect("an object");
        for (key, item) in extra.as_object().expect("an object") {
            object.insert(key.clone(), item.clone());
        }
        value.to_string()
    }

    /// A skip addressing the item and generation that are current right now.
    fn skip(kind: &str, command_id: &str, core: &Core) -> String {
        command(
            kind,
            command_id,
            &json!({
                "expectedQueueRevision": core.queue_revision.to_string(),
                "targetQueueItemId": core.current_item().map(|item| item.queue_item_id.clone()),
                "expectedGeneration": core.generation.to_string(),
            }),
            &json!({}),
        )
    }

    /// A load of `count` fresh items that starts on `start`, optionally seeded.
    fn load(count: usize, start: &str, seed: Option<u64>, command_id: &str, core: &Core) -> String {
        let items: Vec<Value> = (1..=count)
            .map(|index| {
                json!({
                    "queueItemId": format!("item-{index}"),
                    "trackId": format!("track-{index}"),
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
        command(
            "loadQueue",
            command_id,
            &json!({"expectedQueueRevision": core.queue_revision.to_string()}),
            &payload,
        )
    }

    /// A jump to one queue entry, as the queue panel sends it.
    fn jump(queue_item_id: &str, command_id: &str, core: &Core) -> String {
        command(
            "playItem",
            command_id,
            &json!({
                "expectedQueueRevision": core.queue_revision.to_string(),
                "targetQueueItemId": queue_item_id,
            }),
            &json!({}),
        )
    }

    /// A mode change against the revision the session holds right now.
    fn mode(mode: &str, seed: Option<u64>, command_id: &str, core: &Core) -> String {
        let payload = match seed {
            Some(seed) => json!({"mode": mode, "seed": seed.to_string()}),
            None => json!({"mode": mode}),
        };
        command(
            "setMode",
            command_id,
            &json!({"expectedQueueRevision": core.queue_revision.to_string()}),
            &payload,
        )
    }

    /// The `queueItemId` the session is on.
    fn current(core: &Core) -> String {
        core.current_item()
            .map(|item| item.queue_item_id.clone())
            .unwrap_or_default()
    }

    #[test]
    fn list_loop_wraps_in_both_directions() {
        let mut core = core_with(3);
        for (index, expected) in [(1, "item-2"), (2, "item-3"), (3, "item-1")] {
            let text = skip("skipNext", &format!("next-{index}"), &core);
            let reply = send(&mut core, &text);
            assert_eq!(reply["status"], "accepted", "{reply}");
            assert_eq!(current(&core), expected);
        }
        let text = skip("skipPrevious", "prev-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(
            current(&core),
            "item-3",
            "the first item's previous is the last one"
        );
        assert_eq!(core.queue_revision, 1, "a skip is a current-item action");
    }

    #[test]
    fn repeat_one_repeats_a_natural_end_but_advances_on_a_manual_skip() {
        let mut core = core_with(3);
        let text = mode("repeatOne", None, "mode-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        let generation = core.generation;

        // The end of an item repeats it; the item is not left at all.
        assert_eq!(core.next_item(TransitionReason::AutoAdvance), Some(0));
        let effect = natural_end(&mut core).expect("the item repeats");
        match effect {
            Effect::StartItem { index, position_ms } => {
                assert_eq!(index, 0);
                assert_eq!(position_ms, 0);
            }
            other => panic!("unexpected effect {other:?}"),
        }
        assert_eq!(current(&core), "item-1");
        assert_eq!(core.generation, generation + 1);

        // A manual next still walks the queue, which is what the architecture
        // asks for: repeating is about how an item ends, not about the user.
        let text = skip("skipNext", "next-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(current(&core), "item-2");
    }

    #[test]
    fn a_natural_end_only_has_nowhere_to_go_when_the_queue_is_empty() {
        let mut empty = Core::new(String::from("session-test"));
        assert!(natural_end(&mut empty).is_none());

        let mut single = core_with(1);
        let effect = natural_end(&mut single).expect("a one-item queue repeats itself");
        assert!(matches!(effect, Effect::StartItem { index: 0, .. }));
    }

    #[test]
    fn shuffle_plays_every_item_once_before_it_repeats_any() {
        let mut core = core_with(5);
        let text = mode("shuffle", Some(42), "mode-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        let mut played = vec![current(&core)];
        for index in 0..4 {
            let text = skip("skipNext", &format!("next-{index}"), &core);
            assert_eq!(send(&mut core, &text)["status"], "accepted");
            played.push(current(&core));
        }
        assert_eq!(
            played[0], "item-1",
            "entering shuffle keeps the current item"
        );
        let unique: std::collections::HashSet<&String> = played.iter().collect();
        assert_eq!(
            unique.len(),
            played.len(),
            "a permutation must not repeat an item: {played:?}"
        );
    }

    #[test]
    fn shuffle_navigation_walks_the_adjacent_list_and_wraps() {
        let mut core = core_with(4);
        let text = mode("shuffle", Some(7), "mode-1", &core);
        send(&mut core, &text);
        let order = core.effective_order();
        assert_eq!(order.len(), 4);

        // A jump into the middle of the list does not change how the neighbours
        // are defined: they are the entries around it in the published list.
        let middle = order[2].clone();
        let text = jump(&middle, "jump-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(current(&core), middle);

        let text = skip("skipNext", "next-1", &core);
        send(&mut core, &text);
        assert_eq!(current(&core), order[3]);
        let text = skip("skipPrevious", "prev-1", &core);
        send(&mut core, &text);
        assert_eq!(current(&core), middle);
        let text = skip("skipPrevious", "prev-2", &core);
        send(&mut core, &text);
        assert_eq!(current(&core), order[1]);

        // Both ends wrap. A back-step from the head lands on the last entry, and
        // the permutation itself is kept as it was.
        let text = jump(&order[3].clone(), "jump-2", &core);
        send(&mut core, &text);
        let text = skip("skipNext", "next-2", &core);
        send(&mut core, &text);
        assert_eq!(
            current(&core),
            order[0],
            "next from the tail wraps to the head"
        );
        let text = skip("skipPrevious", "prev-3", &core);
        send(&mut core, &text);
        assert_eq!(
            current(&core),
            order[3],
            "previous from the head wraps to the tail"
        );
        assert_eq!(
            core.effective_order(),
            order,
            "an adjacent walk never re-rolls the list"
        );
    }

    #[test]
    fn shuffle_orders_are_reproducible_for_a_seed() {
        let mut first = core_with(6);
        let mut second = core_with(6);
        let text = mode("shuffle", Some(2026), "mode-1", &first);
        send(&mut first, &text);
        let text = mode("shuffle", Some(2026), "mode-1", &second);
        send(&mut second, &text);
        assert_eq!(first.effective_order(), second.effective_order());
        assert_eq!(first.shuffle_seed, 2026);
        assert_eq!(
            first.play_order().len(),
            first.queue.len(),
            "the permutation covers the whole queue"
        );
    }

    #[test]
    fn a_seeded_load_derives_its_first_track_from_the_seed() {
        let mut core = core_with(6);
        let text = mode("shuffle", Some(2026), "mode-1", &core);
        send(&mut core, &text);

        let text = load(6, "item-1", Some(7), "load-1", &core);
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "accepted", "{reply}");
        assert_eq!(
            core.shuffle_seed, 7,
            "the seed the load pinned is in effect"
        );
        let order = core.effective_order();
        assert_eq!(order.len(), 6, "the permutation covers the whole queue");
        assert_eq!(
            current(&core),
            order[0],
            "the seed names the first track, not the caller's start item"
        );
        assert_ne!(
            current(&core),
            "item-1",
            "seed 7 opens on another row, so the test would notice an unseeded head"
        );

        // The same seed replays the same playlist, first track included, which is
        // what a restore needs to reproduce the order it heard.
        let mut restored = core_with(6);
        let text = mode("shuffle", Some(2026), "mode-1", &restored);
        send(&mut restored, &text);
        let text = load(6, "item-1", Some(7), "load-1", &restored);
        send(&mut restored, &text);
        assert_eq!(restored.effective_order(), order);
        assert_eq!(current(&restored), order[0]);
    }

    #[test]
    fn an_unseeded_load_still_starts_on_the_item_it_named() {
        let mut core = core_with(6);
        let text = mode("shuffle", Some(2026), "mode-1", &core);
        send(&mut core, &text);

        let text = load(6, "item-4", None, "load-1", &core);
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "accepted", "{reply}");
        assert_eq!(
            current(&core),
            "item-4",
            "a caller that picked a row keeps that row"
        );
        assert_eq!(core.effective_order()[0], "item-4");
    }

    #[test]
    fn a_seed_is_ignored_outside_shuffle() {
        let mut core = core_with(3);
        let text = load(3, "item-2", Some(7), "load-1", &core);
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "accepted", "{reply}");
        assert_eq!(
            current(&core),
            "item-2",
            "only shuffle has an order to seed"
        );
        assert_eq!(core.effective_order(), vec!["item-1", "item-2", "item-3"]);
        assert_eq!(core.queue_revision, 2);
    }

    #[test]
    fn a_seeded_load_still_has_to_name_one_of_its_items() {
        let mut core = core_with(3);
        let text = mode("shuffle", Some(2026), "mode-1", &core);
        send(&mut core, &text);

        // The field is required to be well-formed even when the seed decides the
        // head, so a garbage name is a malformed command rather than a silent one.
        let text = load(3, "item-9", Some(7), "load-1", &core);
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "rejected");
        assert_eq!(reply["errorCode"], "unknownStartItem");
        assert_eq!(
            core.queue.len(),
            3,
            "the queue the session held is untouched"
        );
    }

    #[test]
    fn installing_a_mode_bumps_the_queue_revision_and_keeps_the_current_item() {
        let mut core = core_with(3);
        let revision = core.queue_revision;
        let text = mode("shuffle", Some(1), "mode-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(core.mode, PlayMode::Shuffle);
        assert_eq!(core.current, Some(0));
        assert_eq!(
            core.queue_revision,
            revision + 1,
            "the order a client renders changed, so the revision describes it"
        );
        assert_eq!(core.effective_order()[0], "item-1");

        // Leaving shuffle puts the queue's own order back and bumps again.
        let text = mode("listLoop", None, "mode-2", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(
            core.effective_order(),
            vec!["item-1", "item-2", "item-3"],
            "the effective order in every other mode is the queue's own"
        );
        assert_eq!(core.queue_revision, revision + 2);
    }

    #[test]
    fn set_mode_refuses_an_unknown_mode_and_a_stale_revision() {
        let mut core = core_with(2);
        let text = command(
            "setMode",
            "mode-1",
            &json!({"expectedQueueRevision": core.queue_revision.to_string()}),
            &json!({"mode": "oneShot"}),
        );
        let rejection = parse_envelope(&text).expect_err("an unknown mode is malformed");
        assert_eq!(rejection.code(), "malformedCommand");
        assert_eq!(core.mode, PlayMode::ListLoop);

        let text = json!({
            "schemaVersion": SCHEMA_VERSION,
            "kind": "setMode",
            "clientId": "test",
            "commandId": "mode-2",
            "targetSessionId": "session-test",
            "expectedQueueRevision": "99",
            "payload": {"mode": "shuffle"},
        })
        .to_string();
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "rejected");
        assert_eq!(reply["errorCode"], "staleQueueRevision");
        assert_eq!(reply["currentQueueRevision"], "1");
        // The mode the session holds is untouched by the refusal.
        assert_eq!(core.mode, PlayMode::ListLoop);
        assert!(core.shuffle_order.is_empty());

        // A mode command without the CAS field it needs is malformed, not applied.
        let text = json!({
            "schemaVersion": SCHEMA_VERSION,
            "kind": "setMode",
            "clientId": "test",
            "commandId": "mode-3",
            "targetSessionId": "session-test",
            "payload": {"mode": "shuffle"},
        })
        .to_string();
        assert_eq!(send(&mut core, &text)["errorCode"], "malformedCommand");
    }

    /// A volume change against the session that is live right now.
    fn volume(value: u64, command_id: &str) -> String {
        command(
            "setVolume",
            command_id,
            &json!({}),
            &json!({"volume": value}),
        )
    }

    #[test]
    fn set_volume_installs_the_gain_without_touching_the_queue() {
        let mut core = core_with(2);
        let revision = core.queue_revision;
        let session_revision = core.session_revision;
        let reply = send(&mut core, &volume(350, "vol-1"));
        assert_eq!(reply["status"], "accepted", "{reply}");
        assert_eq!(core.volume_permille, 350);
        assert_eq!(
            core.queue_revision, revision,
            "the gain is not a queue fact, so the revision that describes the queue stays"
        );
        assert_eq!(
            core.session_revision,
            session_revision + 1,
            "a snapshot consumer still has to see the change"
        );

        // Every point of the range is legal, including silence and full scale.
        assert_eq!(send(&mut core, &volume(0, "vol-2"))["status"], "accepted");
        assert_eq!(core.volume_permille, 0);
        assert_eq!(
            send(&mut core, &volume(1_000, "vol-3"))["status"],
            "accepted"
        );
        assert_eq!(core.volume_permille, 1_000);

        // Re-installing the value that is already set still publishes: the reply
        // is what the caller waits for, and a snapshot consumer needs no special
        // rule to learn the gain the session holds.
        assert_eq!(
            send(&mut core, &volume(1_000, "vol-4"))["status"],
            "accepted"
        );
        assert_eq!(core.volume_permille, 1_000);
    }

    #[test]
    fn set_volume_refuses_an_out_of_range_and_a_missing_value() {
        let core = core_with(1);
        // Out of range is a malformed payload, refused while parsing, before
        // any plan could run.
        let error = parse_envelope(&volume(1_001, "vol-1")).expect_err("above the range");
        assert_eq!(error.code(), "malformedCommand");
        assert_eq!(
            core.volume_permille,
            crate::core::DEFAULT_VOLUME_PERMILLE,
            "a refused gain must not half-apply"
        );

        let error = parse_envelope(&command("setVolume", "vol-2", &json!({}), &json!({})))
            .expect_err("the volume is missing");
        assert_eq!(error.code(), "malformedCommand");

        // The schema carries the volume as a JSON integer; anything else is not
        // a gain this session can install.
        let error = parse_envelope(&command(
            "setVolume",
            "vol-3",
            &json!({}),
            &json!({"volume": "800"}),
        ))
        .expect_err("a decimal string is not an integer");
        assert_eq!(error.code(), "malformedCommand");
    }

    #[test]
    fn play_item_moves_the_current_item_without_touching_the_queue() {
        let mut core = core_with(3);
        let revision = core.queue_revision;
        let generation = core.generation;
        let text = jump("item-3", "jump-1", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(current(&core), "item-3");
        assert_eq!(
            core.queue_revision, revision,
            "a jump is a current-item action"
        );
        assert_eq!(core.generation, generation + 1);
        assert!(
            core.play_when_ready,
            "choosing a row is an explicit request to hear it"
        );

        // Choosing the row that is already playing must not restart it.
        let text = jump("item-3", "jump-2", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(core.generation, generation + 1);
        assert_eq!(current(&core), "item-3");
    }

    #[test]
    fn play_item_refuses_an_unknown_item_and_an_old_revision() {
        let mut core = core_with(2);
        let text = jump("item-9", "jump-1", &core);
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "rejected");
        assert_eq!(reply["errorCode"], "unknownQueueItem");
        assert_eq!(current(&core), "item-1");

        let text = json!({
            "schemaVersion": SCHEMA_VERSION,
            "kind": "playItem",
            "clientId": "test",
            "commandId": "jump-2",
            "targetSessionId": "session-test",
            "expectedQueueRevision": "3",
            "targetQueueItemId": "item-2",
            "payload": {},
        })
        .to_string();
        assert_eq!(send(&mut core, &text)["errorCode"], "staleQueueRevision");
        assert_eq!(current(&core), "item-1");

        // The item the schema requires for a jump is not optional.
        let text = json!({
            "schemaVersion": SCHEMA_VERSION,
            "kind": "playItem",
            "clientId": "test",
            "commandId": "jump-3",
            "targetSessionId": "session-test",
            "expectedQueueRevision": "1",
            "payload": {},
        })
        .to_string();
        assert_eq!(send(&mut core, &text)["errorCode"], "malformedCommand");
    }

    /// A resolved source for one queue item, as the host's broker sends it.
    fn provide(
        queue_item_id: &str,
        uri: &str,
        generation: Option<u64>,
        command_id: &str,
    ) -> String {
        let extra = match generation {
            Some(generation) => json!({
                "targetQueueItemId": queue_item_id,
                "expectedGeneration": generation.to_string(),
            }),
            None => json!({"targetQueueItemId": queue_item_id}),
        };
        command(
            "provideSource",
            command_id,
            &extra,
            &json!({"sourceUri": uri}),
        )
    }

    #[test]
    fn a_stale_provide_source_is_rejected_without_touching_the_queue() {
        let mut core = core_with(2);
        // The generation a host would have captured before a skip or a seek.
        core.generation = 5;
        core.phase = Phase::Resolving;
        let source_before = core.queue[0].source_uri.clone();
        let session_revision = core.session_revision;

        let text = provide("item-1", "file:///nonexistent/stale.mp3", Some(4), "ps-1");
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "rejected", "{reply}");
        assert_eq!(reply["errorCode"], "staleGeneration");
        assert_eq!(
            core.queue[0].source_uri, source_before,
            "a refused command must not overwrite the item's source on its way out"
        );
        assert_eq!(
            core.phase,
            Phase::Resolving,
            "and it must not start the item"
        );
        assert_eq!(
            core.session_revision, session_revision,
            "a refusal publishes nothing at all"
        );

        // The same answer for the generation the session holds is accepted, and
        // installs exactly that source.
        let text = provide("item-1", "file:///nonexistent/fresh.mp3", Some(5), "ps-2");
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "accepted", "{reply}");
        assert_eq!(
            core.queue[0].source_uri.as_deref(),
            Some("file:///nonexistent/fresh.mp3")
        );
        assert_eq!(core.phase, Phase::Loading);
    }

    #[test]
    fn revoking_a_queued_source_does_not_change_transport_or_spend_attempts() {
        let mut core = core_with(2);
        core.phase = Phase::Ready;
        core.play_when_ready = false;
        core.queue[1].expires_at_ms = Some(999_999_999);
        let text = command(
            "provideSource",
            "revoke",
            &json!({"targetQueueItemId": "item-2"}),
            &json!({"sourceUri": null}),
        );
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "accepted");
        assert_eq!(core.queue[1].source_uri, None);
        assert_eq!(core.queue[1].expires_at_ms, None);
        assert_eq!(core.queue[1].source_attempts, 0);
        assert_eq!(core.current, Some(0));
        assert_eq!(core.phase, Phase::Ready);
        assert!(!core.play_when_ready);
        assert!(core.queue[0].source_uri.is_some());
    }

    #[test]
    fn an_upcoming_item_accepts_a_prefetch_whose_generation_has_moved_on() {
        let mut core = core_with(2);
        core.generation = 5;

        // The broker prefetched item-2 while the session was on an earlier
        // generation. The item is not playing yet, so a generation that has since
        // moved on is expected and the URI is still the right one to store: this is
        // what makes the later transition need no second sourceRequest (docs/design/provider.md).
        let text = provide(
            "item-2",
            "file:///nonexistent/prefetch.mp3",
            Some(3),
            "pf-1",
        );
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "accepted", "{reply}");
        assert_eq!(
            core.queue[1].source_uri.as_deref(),
            Some("file:///nonexistent/prefetch.mp3")
        );
        assert_eq!(core.current, Some(0), "the prefetch does not move the item");
        assert_eq!(
            core.phase,
            Phase::Idle,
            "a queued source is not a transport change"
        );
    }

    #[test]
    fn a_provide_source_for_an_unknown_item_is_refused() {
        let mut core = core_with(2);
        let text = provide("item-9", "file:///nonexistent/x.mp3", Some(0), "ps-1");
        let reply = send(&mut core, &text);
        assert_eq!(reply["status"], "rejected");
        assert_eq!(reply["errorCode"], "unknownQueueItem");
    }

    /// A queue edit, as the queue panel sends it, against the current revision.
    fn edit(operation: &str, command_id: &str, core: &Core, extra: &Value) -> String {
        let mut envelope = json!({
            "expectedQueueRevision": core.queue_revision.to_string(),
        });
        let object = envelope.as_object_mut().expect("an object");
        for (key, item) in extra.as_object().expect("an object") {
            object.insert(key.clone(), item.clone());
        }
        command(
            "editQueue",
            command_id,
            &envelope,
            &json!({"operation": operation}),
        )
    }

    #[test]
    fn removing_the_current_item_keeps_the_play_intent() {
        let mut core = core_with(3);
        core.play_when_ready = true;
        let text = edit(
            "remove",
            "remove-1",
            &core,
            &json!({"targetQueueItemId": "item-1"}),
        );
        let envelope = parse_envelope(&text).expect("a well-formed envelope");
        let plan = plan(&mut core, &envelope, &text, 0);
        assert_eq!(
            plan.reply.to_json()["status"],
            "accepted",
            "{}",
            plan.reply.to_json()
        );
        assert_eq!(current(&core), "item-2");
        assert!(
            core.play_when_ready,
            "removing the item that is playing keeps the intent to play"
        );
        assert!(matches!(
            plan.effects[0],
            Effect::StartItem { index: 0, .. }
        ));
    }

    #[test]
    fn an_edit_on_an_empty_queue_installs_and_starts_it() {
        let mut core = Core::new(String::from("session-test"));
        let text = command(
            "editQueue",
            "add-1",
            &json!({"expectedQueueRevision": "0"}),
            &json!({
                "operation": "playNext",
                "items": [
                    {"queueItemId": "item-1", "trackId": "track-1"},
                    {"queueItemId": "item-2", "trackId": "track-2"},
                ],
            }),
        );
        let envelope = parse_envelope(&text).expect("a well-formed envelope");
        let plan = plan(&mut core, &envelope, &text, 0);
        assert_eq!(
            plan.reply.to_json()["status"],
            "accepted",
            "{}",
            plan.reply.to_json()
        );
        assert_eq!(current(&core), "item-1");
        assert!(
            core.play_when_ready,
            "adding a song to an empty player starts it"
        );
        assert!(matches!(
            plan.effects[0],
            Effect::StartItem { index: 0, .. }
        ));
    }

    #[test]
    fn an_insert_that_reuses_an_identity_is_refused() {
        let mut core = core_with(2);
        // `item-1` is already the queue's own; installing it twice would make
        // `currentQueueItemId` ambiguous and a saved record invalid (issue 2).
        let text = command(
            "editQueue",
            "add-dup",
            &json!({"expectedQueueRevision": "1"}),
            &json!({
                "operation": "playNext",
                "items": [{"queueItemId": "item-1", "trackId": "track-x"}],
            }),
        );
        let envelope = parse_envelope(&text).expect("a well-formed envelope");
        let plan = plan(&mut core, &envelope, &text, 0);
        assert_eq!(
            plan.reply.to_json()["status"],
            "rejected",
            "{}",
            plan.reply.to_json()
        );
        assert_eq!(plan.reply.to_json()["errorCode"], "malformedCommand");
        assert_eq!(core.queue.len(), 2, "a refused insert installs nothing");
    }

    #[test]
    fn a_load_with_a_repeated_identity_is_refused() {
        let mut core = Core::new(String::from("session-test"));
        let text = command(
            "loadQueue",
            "load-dup",
            &json!({"expectedQueueRevision": "0"}),
            &json!({
                "items": [
                    {"queueItemId": "item-1", "trackId": "track-1"},
                    {"queueItemId": "item-1", "trackId": "track-2"},
                ],
                "startItemId": "item-1",
                "autoplay": true,
            }),
        );
        let envelope = parse_envelope(&text).expect("a well-formed envelope");
        let plan = plan(&mut core, &envelope, &text, 0);
        assert_eq!(
            plan.reply.to_json()["status"],
            "rejected",
            "{}",
            plan.reply.to_json()
        );
        assert_eq!(plan.reply.to_json()["errorCode"], "malformedCommand");
        assert!(core.queue.is_empty(), "a refused load installs nothing");
    }
    fn heart(core: &Core, operation: &str, items: Value, extra: Value) -> String {
        let mut payload =
            json!({"operation": operation, "sessionId": "heart-test", "autoplay": true});
        payload["items"] = items;
        let Value::Object(extra) = extra else {
            panic!("object")
        };
        for (key, value) in extra {
            payload[key] = value;
        }
        command(
            "intelligence",
            &format!("heart-{}-{}", operation, core.session_revision),
            &json!({"expectedQueueRevision": core.queue_revision.to_string()}),
            &payload,
        )
    }

    #[test]
    fn heart_start_is_atomic_and_disallows_shuffle_or_list_loop() {
        let mut core = core_with(2);
        core.mode = PlayMode::Shuffle;
        let text = heart(
            &core,
            "start",
            json!([{ "queueItemId": "new-1", "trackId": "ncm-1" }]),
            json!({}),
        );
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(core.mode, PlayMode::Sequential);
        assert_eq!(core.intelligence_session_id.as_deref(), Some("heart-test"));
        assert_eq!(current(&core), "new-1");
        for value in ["shuffle", "listLoop"] {
            let text = mode(value, None, value, &core);
            let revision = core.queue_revision;
            assert_eq!(send(&mut core, &text)["status"], "rejected");
            assert_eq!(core.queue_revision, revision);
        }
        let text = mode("repeatOne", None, "repeat", &core);
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(core.next_item(TransitionReason::AutoAdvance), Some(0));
        assert_eq!(core.next_item(TransitionReason::SkipNext), None);
        assert_eq!(core.next_item(TransitionReason::SkipPrevious), None);
    }

    #[test]
    fn heart_window_keeps_current_identity_and_rejects_unsafe_eviction() {
        let mut core = core_with(50);
        core.intelligence_session_id = Some(String::from("heart-test"));
        core.mode = PlayMode::Sequential;
        core.current = Some(47);
        let items: Value = json!(
            (51..=70)
                .map(
                    |i| json!({"queueItemId": format!("item-{i}"), "trackId": format!("track-{i}")})
                )
                .collect::<Vec<_>>()
        );
        let text = heart(&core, "refill", items.clone(), json!({"evictCount": "20"}));
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert_eq!(core.queue.len(), 50);
        assert_eq!(current(&core), "item-48");
        assert_eq!(core.current, Some(27));
        let before = core.queue.clone();
        let text = heart(
            &core,
            "refill",
            json!([{ "queueItemId": "item-71", "trackId": "track-71" }]),
            json!({"evictCount": "28"}),
        );
        assert_eq!(send(&mut core, &text)["status"], "rejected");
        assert_eq!(core.queue, before);
    }

    #[test]
    fn heart_remove_last_retains_context_but_clear_exits() {
        let mut core = core_with(1);
        core.intelligence_session_id = Some(String::from("heart-test"));
        core.mode = PlayMode::Sequential;
        core.play_when_ready = false;
        let text = edit(
            "remove",
            "remove-last",
            &core,
            &json!({"targetQueueItemId": "item-1"}),
        );
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert!(core.queue.is_empty());
        assert_eq!(core.intelligence_session_id.as_deref(), Some("heart-test"));
        let text = heart(
            &core,
            "refill",
            json!([{ "queueItemId": "item-2", "trackId": "track-2" }]),
            json!({"autoplay": false}),
        );
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert!(!core.play_when_ready);
        let text = command("clearQueue", "clear-heart", &json!({}), &json!({}));
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert!(core.intelligence_session_id.is_none());
    }

    #[test]
    fn heart_stale_intent_does_not_resume_after_pause() {
        let mut core = core_with(1);
        core.intelligence_session_id = Some(String::from("heart-test"));
        core.mode = PlayMode::Sequential;
        let revision = core.session_revision;
        let pause = command("pause", "pause-heart", &json!({}), &json!({}));
        send(&mut core, &pause);
        let text = heart(
            &core,
            "refill",
            json!([{ "queueItemId": "item-2", "trackId": "track-2" }]),
            json!({"advance": true, "expectedSessionRevision": revision.to_string()}),
        );
        assert_eq!(send(&mut core, &text)["status"], "rejected");
        assert!(!core.play_when_ready);
        assert_eq!(core.queue.len(), 1);
    }

    #[test]
    fn heart_external_insert_requires_explicit_atomic_exit() {
        let mut core = core_with(1);
        core.intelligence_session_id = Some(String::from("heart-test"));
        let items = json!([{ "queueItemId": "item-2", "trackId": "track-2" }]);
        let text = command(
            "editQueue",
            "insert-refused",
            &json!({"expectedQueueRevision": "1"}),
            &json!({"operation": "append", "items": items}),
        );
        assert_eq!(send(&mut core, &text)["status"], "rejected");
        assert!(core.intelligence_session_id.is_some());
        let text = command(
            "editQueue",
            "insert-confirmed",
            &json!({"expectedQueueRevision": "1"}),
            &json!({"operation": "append", "items": items, "exitIntelligence": true}),
        );
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert!(core.intelligence_session_id.is_none());
        assert_eq!(core.queue.len(), 2);
    }
    #[test]
    fn heart_source_failure_preserves_intent_and_rejects_stale_generation() {
        let mut core = core_with(1);
        core.intelligence_session_id = Some(String::from("heart-test"));
        core.play_when_ready = true;
        let failure = command(
            "sourceFailed",
            "failure-1",
            &json!({"targetQueueItemId": "item-1", "expectedGeneration": "0"}),
            &json!({"errorCode": "sourceOpenFailed"}),
        );
        assert_eq!(send(&mut core, &failure)["status"], "accepted");
        assert_eq!(core.phase, Phase::Error);
        assert!(core.play_when_ready);
        core.generation += 1;
        let failure = command(
            "sourceFailed",
            "failure-2",
            &json!({"targetQueueItemId": "item-1", "expectedGeneration": "0"}),
            &json!({"errorCode": "sourceOpenFailed"}),
        );
        assert_eq!(send(&mut core, &failure)["errorCode"], "staleGeneration");
    }

    #[test]
    fn heart_empty_queue_accepts_pause_and_resume_intent() {
        let mut core = Core::new(String::from("session-test"));
        core.intelligence_session_id = Some(String::from("heart-test"));
        let text = command("play", "resume-empty", &json!({}), &json!({}));
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert!(core.play_when_ready);
        let text = command("pause", "pause-empty", &json!({}), &json!({}));
        assert_eq!(send(&mut core, &text)["status"], "accepted");
        assert!(!core.play_when_ready);
        assert!(core.queue.is_empty());
    }
}
