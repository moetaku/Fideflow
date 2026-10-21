//! Wire messages the session produces: snapshots, capabilities and diagnostics.
//!
//! Snapshots follow `schemas/media-control.v1.schema.json` exactly, including its
//! `additionalProperties: false` rule and its decimal-string 64-bit counters.
//! Diagnostics are deliberately a *different* message (docs/design/diagnostics.md): bounded metrics
//! and counters, no credentials, no media URLs, no local paths, no titles.

use std::sync::atomic::Ordering;

use serde_json::{Map, Value, json};

use crate::Realtime;
use crate::core::{Core, Phase, PlayMode};
use crate::plan::SCHEMA_VERSION;

/// The snapshot required by the schema's `snapshot` definition.
#[must_use]
pub fn snapshot_value(core: &Core, realtime: &Realtime) -> Value {
    let mut snapshot = Map::new();
    snapshot.insert(String::from("schemaVersion"), json!(SCHEMA_VERSION));
    snapshot.insert(String::from("kind"), json!("snapshot"));
    snapshot.insert(String::from("sessionId"), json!(core.session_id));
    snapshot.insert(
        String::from("sessionRevision"),
        json!(core.session_revision.to_string()),
    );
    snapshot.insert(
        String::from("queueRevision"),
        json!(core.queue_revision.to_string()),
    );
    snapshot.insert(
        String::from("generation"),
        json!(core.generation.to_string()),
    );
    snapshot.insert(String::from("phase"), json!(core.phase.as_str()));
    snapshot.insert(String::from("mode"), json!(core.mode.as_str()));
    snapshot.insert(
        String::from("intelligenceSessionId"),
        json!(core.intelligence_session_id),
    );
    snapshot.insert(String::from("playWhenReady"), json!(core.play_when_ready));
    snapshot.insert(String::from("buffering"), json!(core.buffering));
    snapshot.insert(String::from("isSeeking"), json!(core.is_seeking));
    let suppression: Vec<&str> = core
        .suppression
        .iter()
        .map(|reason| reason.as_str())
        .collect();
    snapshot.insert(String::from("suppressionReasons"), json!(suppression));
    snapshot.insert(
        String::from("isActuallyPlaying"),
        json!(is_actually_playing(core)),
    );
    snapshot.insert(
        String::from("currentQueueItemId"),
        json!(core.current_item().map(|item| &item.queue_item_id)),
    );
    // The order the queue will play, from the session's own mode rules. A client
    // renders the queue list from this instead of recomputing shuffle, which is
    // what keeps the session the single owner of the play order (docs/design/boundaries.md).
    snapshot.insert(
        String::from("effectiveOrder"),
        if core.queue.is_empty() {
            Value::Null
        } else {
            json!(core.effective_order())
        },
    );
    // The identity of every queued item, in the queue's own load order. A
    // client that did not load the queue - a session-side restore, or a
    // subscriber that attached later - has no other way to know which track an
    // id stands for, and the load order is what a seeded replay feeds back to the
    // session (docs/design/restore.md). A source is never published: it is short-lived and
    // belongs to the account that authorized it.
    snapshot.insert(
        String::from("queueItems"),
        if core.queue.is_empty() {
            Value::Null
        } else {
            json!(
                core.queue
                    .iter()
                    .map(|item| json!({
                        "queueItemId": item.queue_item_id,
                        "trackId": item.track_id,
                    }))
                    .collect::<Vec<Value>>()
            )
        },
    );
    snapshot.insert(
        String::from("positionMs"),
        json!(
            core.position_ms(realtime.frames_consumed.load(Ordering::Relaxed))
                .to_string()
        ),
    );
    snapshot.insert(
        String::from("volume"),
        json!(realtime.volume_permille.load(Ordering::Relaxed)),
    );
    // The seed of the order in effect, so a client can persist what it heard and
    // restore that exact order instead of rolling a new permutation. It is null
    // whenever the mode holds no seeded order: a non-shuffle mode, or a queue with
    // nothing left for a permutation to describe. That keeps the field honest
    // rather than reporting the last seed a shuffle happened to use after the
    // queue is cleared (docs/design/playback.md).
    snapshot.insert(
        String::from("shuffleSeed"),
        match core.mode {
            PlayMode::Shuffle if !core.queue.is_empty() => json!(core.shuffle_seed.to_string()),
            _ => Value::Null,
        },
    );
    snapshot.insert(
        String::from("durationMs"),
        match core.duration_ms {
            Some(duration) => json!(duration.to_string()),
            None => Value::Null,
        },
    );
    snapshot.insert(
        String::from("errorCode"),
        match &core.error_code {
            Some(error) => json!(error),
            None => Value::Null,
        },
    );
    snapshot.insert("failureKind".into(), json!(core.failure_kind.code()));
    insert_settings(&mut snapshot, core);
    Value::Object(snapshot)
}

/// Whether media output is currently confirmed to be advancing.
#[must_use]
pub fn is_actually_playing(core: &Core) -> bool {
    core.phase == Phase::Ready
        && core.play_when_ready
        && core.suppression.is_empty()
        && !core.buffering
        && core.output_running
}

/// The `attach` response: a connection id plus the baseline snapshot.
#[must_use]
pub fn attachment_value(connection_id: &str, core: &Core, realtime: &Realtime) -> Value {
    json!({
        "connectionId": connection_id,
        "baseline": snapshot_value(core, realtime),
    })
}

/// Capabilities of this build, for protocol negotiation (docs/design/boundaries.md).
#[must_use]
pub fn capabilities_value() -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "abiVersion": crate::ABI_VERSION,
        "controlTransport": "bytes+json",
        "messageSchemaVersion": SCHEMA_VERSION,
        "idempotencyWindow": crate::core::IDEMPOTENCY_WINDOW,
        "playbackModes": ["listLoop", "repeatOne", "shuffle", "sequential"],
        "queueOperations": ["playNext", "append", "remove"],
        "volumeRange": {"min": 0, "max": 1000, "step": 1},
        "buffer": {
            "startWatermarkFrames": crate::START_WATERMARK_FRAMES,
            "lowWatermarkFrames": crate::LOW_WATERMARK_FRAMES,
            "highWatermarkFrames": crate::HIGH_WATERMARK_FRAMES,
            "ringCapacityFrames": crate::RING_CAPACITY_FRAMES,
            "pcmCapBytes": 4 * 1024 * 1024,
        },
        "output": {
            "backend": fideflow_media_output::backend(),
            "deviceSelection": fideflow_media_output::supports_device_selection(),
            "exclusive": fideflow_media_output::supports_exclusive_mode(),
            "sampleRate": crate::PCM_SAMPLE_RATE,
            "channels": crate::PCM_CHANNELS,
            "sampleFormat": "f32",
            "periodFrames": crate::OUTPUT_PERIOD_FRAMES,
        },
        "decoder": {
            "available": crate::pipeline_available(),
            "ffmpeg": crate::ffmpeg_version(),
            "resampler": "soxr",
        },
        "sourceSchemes": ["file", "ffinput"],
    })
}

/// Bounded playback diagnostics (docs/design/diagnostics.md): counters, formats, no identity.
#[must_use]
pub fn diagnostics_value(core: &Core, realtime: &Realtime) -> Value {
    let output = core.output.clone().unwrap_or_default();
    let first_frame = core
        .first_frame_millis
        .map_or_else(|| Value::Null, |millis| json!(millis.to_string()));
    let worker_error = realtime
        .worker_error
        .lock()
        .ok()
        .and_then(|error| error.clone())
        .map_or_else(|| Value::Null, |error| json!(error.code));
    json!({
        "schemaVersion": 1,
        "kind": "diagnostics",
        "diagnosticsVersion": 1,
        "sessionId": core.session_id,
        "sessionRevision": core.session_revision.to_string(),
        "queueRevision": core.queue_revision.to_string(),
        "generation": core.generation.to_string(),
        "phase": core.phase.as_str(),
        "isActuallyPlaying": is_actually_playing(core),
        "timing": {
            "firstFrameMillis": first_frame,
            "seekDecoderReused": realtime.seek_decoder_reused.load(Ordering::Relaxed),
            "seekDecoderReopened": realtime.seek_decoder_reopened.load(Ordering::Relaxed),
            "seekDecoderFallbacks": realtime.seek_decoder_fallbacks.load(Ordering::Relaxed),
            "seekGeneration": realtime.seek_generation.load(Ordering::Relaxed).to_string(),
            "seekElapsedMicros": {
                "outputGated": realtime.seek_stages[0].load(Ordering::Relaxed),
                "workerJoined": realtime.seek_stages[1].load(Ordering::Relaxed),
                "sourceOpened": realtime.seek_stages[2].load(Ordering::Relaxed),
                "positioned": realtime.seek_stages[3].load(Ordering::Relaxed),
                "primed": realtime.seek_stages[4].load(Ordering::Relaxed),
                "firstFrame": realtime.seek_stages[5].load(Ordering::Relaxed),
            },
        },
        "output": {
            "running": core.output_running,
            "deviceName": output.device_name,
            "requestedRate": core.pcm_rate,
            "internalRate": output.sample_rate,
            "internalChannels": output.channels,
            "internalFormat": output.internal_format,
            "periodFrames": output.period_frames,
            "periods": output.periods,
            "periodSeconds": output.period_seconds,
        },
        "buffer": {
            "capacityFrames": realtime.ring.capacity_frames(),
            "availableFrames": realtime.ring.available_frames(),
            "peakFrames": realtime.available_peak_frames.load(Ordering::Relaxed),
            "silenceFrames": realtime.tail_silence_frames.load(Ordering::Relaxed)
                + realtime.underrun_frames.load(Ordering::Relaxed),
        },
        "counters": {
            "framesWritten": realtime.frames_written.load(Ordering::Relaxed),
            "framesConsumed": realtime.frames_consumed.load(Ordering::Relaxed),
            "underruns": realtime.underruns.load(Ordering::Relaxed),
            "underrunFrames": realtime.underrun_frames.load(Ordering::Relaxed),
            "tailSilenceFrames": realtime.tail_silence_frames.load(Ordering::Relaxed),
            "callbackCalls": realtime.callback_calls.load(Ordering::Relaxed),
        },
        "source": {
            "codec": core.source_codec,
            "sourceRate": core.source_rate,
            "resampler": core.resampler,
        },
        "worker": {
            "state": realtime.worker_state_label(),
            "errorCode": worker_error,
        },
    })
}

fn insert_settings(snapshot: &mut Map<String, Value>, core: &Core) {
    snapshot.insert("playbackEffects".into(), json!({
        "supported": true,
        "fadeEnabled": core.fade_enabled,
        "volumeNormalizationEnabled": core.volume_normalization_enabled,
        "normalizationActive": core.volume_normalization_enabled && core.current
            .and_then(|index| core.queue.get(index))
            .is_some_and(|item| item.source_uri.is_some() && item.normalization.gain().is_some()),
    }));
    snapshot.insert("outputSettings".into(), json!({
        "supported": fideflow_media_output::is_available(),
        "deviceUid": core.output_configuration.device_uid,
        "exclusive": core.output_configuration.exclusive,
        "resamplingEnabled": core.output_configuration.resampling_enabled,
        "targetSampleRate": core.output_configuration.target_sample_rate,
        "exclusiveActive": core.exclusive_active,
        "activeDeviceUid": core.active_device_uid,
        "busy": core.output_busy, "errorCode": core.output_error,
        "refreshPending": core.output_devices_pending,
        "devices": core.output_devices.iter().map(|d|json!({"uid":d.uid,"name":d.name,"isDefault":d.is_default,"exclusiveSupported":d.exclusive_supported,"sharedSupported":!(cfg!(target_os="linux") && d.exclusive_supported && d.uid.starts_with("alsa:hw:"))})).collect::<Vec<_>>()
    }));
}
