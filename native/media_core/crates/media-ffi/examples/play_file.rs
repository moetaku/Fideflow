//! Phase 1 acceptance probe: plays a real file through the shipped C ABI.
//!
//! Everything here goes through the same entry points a Dart host uses — the
//! `ff_*` C functions, not the Rust session API — so a passing run is evidence
//! that the packaged library, its JSON marshalling, its executor deadline and its
//! event sink work end to end. It opens the default output device and makes sound.
//!
//! ```text
//! cargo run -p fideflow-media-ffi --example play_file -- "<file>" [options]
//!   --seconds N        play at most N seconds (default 12; `--full` plays it all)
//!   --full             play to the end of the source and check the tail was
//!                      output before the default mode wrapped the queue
//!   --seek-ms N        seek target used by the checks (default 2000)
//!   --expect-underruns Allow underruns (for a machine under load)
//!   --quiet            Do not print the diagnostics document
//! ```
//!
//! One JSON line is printed and the exit code is non-zero when a Phase 1 rule is
//! violated, so the runbook can quote the result. Only the file *name* is
//! printed: docs/design/diagnostics.md forbids local paths in diagnostics and logs.

use std::env;
use std::ffi::c_void;
use std::fmt::Write as _;
use std::path::Path;
use std::process::ExitCode;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use ff_media_core::{
    FF_MEDIA_OK, FfOwnedBytes, FfPlayer, ff_media_core_abi_version,
    ff_media_core_capabilities_json, ff_owned_bytes_free, ff_player_diagnostics, ff_player_execute,
    ff_player_free, ff_player_new, ff_player_set_event_sink, ff_player_snapshot,
};

/// Snapshots the publisher pushed through the C event sink.
static PUSHED: AtomicUsize = AtomicUsize::new(0);
/// Last pushed message, so the probe can prove the sink carries real payloads.
static LAST_PUSHED: Mutex<Option<String>> = Mutex::new(None);

/// The event sink the ABI calls from its publisher thread.
///
/// # Safety
///
/// The ABI transfers ownership of the UTF-8 buffer to this sink.
unsafe extern "C" fn on_snapshot(json_bytes: *mut u8, len: usize, user: *mut c_void) {
    let _ = user;
    if json_bytes.is_null() || len == 0 {
        return;
    }
    // SAFETY: the registration transfers ownership of this buffer, and the
    // probe is its only owner: it copies what it needs and releases it once.
    let slice = unsafe { std::slice::from_raw_parts(json_bytes, len) };
    if let Ok(text) = std::str::from_utf8(slice) {
        PUSHED.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut last) = LAST_PUSHED.lock() {
            *last = Some(text.to_owned());
        }
    }
    // SAFETY: the ownership contract above; released exactly once.
    unsafe {
        ff_owned_bytes_free(FfOwnedBytes {
            data: json_bytes,
            len,
        });
    }
}

fn main() -> ExitCode {
    match Options::parse(env::args().skip(1)) {
        Ok(options) => probe(&options),
        Err(message) => {
            eprintln!("{message}");
            eprintln!(
                "usage: play_file <file> [--seconds N] [--full] [--seek-ms N] \
                 [--expect-underruns] [--quiet]"
            );
            ExitCode::from(2)
        }
    }
}

/// Runs one probe and reports its verdict.
fn probe(options: &Options) -> ExitCode {
    let mut failures: Vec<String> = Vec::new();
    let abi_version = ff_media_core_abi_version();
    if abi_version != 3 {
        eprintln!("unexpected ABI version {abi_version}");
        return ExitCode::FAILURE;
    }

    // Capabilities must describe the library we actually linked, which is the
    // check that would catch a stale bundle.
    let Some(capabilities) = parse_owned(ff_media_core_capabilities_json()) else {
        println!(
            "{}",
            json!({"probe": "play", "failures": ["capabilitiesUnavailable"]})
        );
        return ExitCode::FAILURE;
    };
    if capabilities["decoder"]["available"] != Value::Bool(true) {
        println!(
            "{}",
            json!({"probe": "play", "failures": ["decoderUnavailable"],
                   "ffmpeg": capabilities["decoder"]["ffmpeg"]})
        );
        return ExitCode::FAILURE;
    }

    // SAFETY: every call below passes a live handle this scope owns; the sink
    // outlives the registration and the `user` context is unused.
    let player = ff_player_new();
    if player.is_null() {
        println!(
            "{}",
            json!({"probe": "play", "failures": ["playerUnavailable"]})
        );
        return ExitCode::FAILURE;
    }
    let outcome = unsafe {
        let sink_code = ff_player_set_event_sink(player, Some(on_snapshot), std::ptr::null_mut());
        if sink_code != FF_MEDIA_OK {
            failures.push(String::from("eventSinkRefused"));
        }
        run(player, options, &mut failures)
    };

    let report = match outcome {
        Ok(playback) => {
            // SAFETY: `player` is live and this is the only reader at this point.
            let diagnostics = unsafe { read_diagnostics(player) };
            finish(options, &capabilities, &playback, diagnostics, failures)
        }
        Err(error) => {
            failures.push(error);
            json!({
                "probe": "play",
                "file": options.file_name(),
                "abiVersion": abi_version,
                "failures": failures,
            })
        }
    };
    println!("{report}");

    // SAFETY: the handle is released exactly once, after the sink is cleared.
    unsafe {
        ff_player_set_event_sink(player, None, std::ptr::null_mut());
        ff_player_free(player);
    }

    if failures_empty(&report) {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// Playback facts the checks collect.
struct Playback {
    started_ms: u64,
    advanced_ms: u64,
    frozen_ms: u64,
    resumed_ms: u64,
    seek_ms: Option<u64>,
    final_phase: String,
    final_position_ms: u64,
    duration_ms: Option<u64>,
    /// Status of the skip at the queue edge, which wraps in the default mode.
    edge_skip: String,
    /// The mode the session reported after the probe changed it.
    mode: String,
    /// Queue entries the effective order covered after the probe changed it.
    order_items: usize,
    /// Highest position seen while draining, i.e. how close the item got to its
    /// own end before it wrapped.
    peak_ms: u64,
    play_seconds: f64,
}

#[allow(
    clippy::too_many_lines,
    reason = "the acceptance steps are a sequence; splitting them would hide the order"
)]
fn run(
    player: *mut FfPlayer,
    options: &Options,
    failures: &mut Vec<String>,
) -> Result<Playback, String> {
    // SAFETY: `player` is the live handle `main` owns.
    let baseline =
        unsafe { read_snapshot(player) }.map_err(|code| format!("snapshotFailed:{code}"))?;
    let session_id = baseline["sessionId"]
        .as_str()
        .ok_or("the baseline has no sessionId")?
        .to_owned();
    if baseline["phase"] != "idle" {
        failures.push(format!(
            "a fresh session reported phase {}",
            baseline["phase"]
        ));
    }

    let uri = file_uri(&options.file);
    let load = json!({
        "schemaVersion": 1,
        "kind": "loadQueue",
        "clientId": "play-file-probe",
        "commandId": "cmd-load",
        "targetSessionId": session_id,
        "expectedQueueRevision": "0",
        "payload": {
            "items": [{"queueItemId": "qi-1", "trackId": "probe-track", "sourceUri": uri}],
            "startItemId": "qi-1",
            "autoplay": true,
        },
    })
    .to_string();
    // SAFETY: `player` is live and the envelope is a live string.
    let reply =
        unsafe { execute(player, &load, 5_000) }.map_err(|code| format!("loadRefused:{code}"))?;
    if reply["status"] != "accepted" {
        return Err(format!("loadQueue was rejected: {reply}"));
    }

    // 1) Priming then real output: `isActuallyPlaying` is derived, never a
    //    claim the command made.
    let started = wait_for(
        player,
        "playback to start",
        Duration::from_secs(20),
        |state| state["isActuallyPlaying"] == Value::Bool(true),
    )?;
    if started["phase"] != "ready" {
        failures.push(format!("playing with phase {}", started["phase"]));
    }

    // 2) Position comes from the frame clock and advances while playing.
    std::thread::sleep(Duration::from_millis(700));
    let after_start = snapshot(player)?;
    let advanced = number(&after_start, "positionMs");
    let started_ms = number(&started, "positionMs");
    if advanced <= started_ms {
        failures.push(format!(
            "position did not advance ({started_ms} -> {advanced} ms)"
        ));
    }

    // 3) Pause freezes the clock instead of merely flagging the intent.
    let pause = command(&session_id, "cmd-pause", "pause", &json!({}));
    // SAFETY: `player` is live and the envelope is a live string.
    let reply =
        unsafe { execute(player, &pause, 5_000) }.map_err(|code| format!("pauseRefused:{code}"))?;
    if reply["status"] != "accepted" {
        failures.push(format!("pause was rejected: {reply}"));
    }
    std::thread::sleep(Duration::from_millis(300));
    let paused = snapshot(player)?;
    if paused["isActuallyPlaying"] != Value::Bool(false) {
        failures.push(String::from("a paused session still reported playback"));
    }
    let frozen_ms = number(&paused, "positionMs");
    std::thread::sleep(Duration::from_millis(400));
    let frozen_again = number(&snapshot(player)?, "positionMs");
    if frozen_again != frozen_ms {
        failures.push(format!(
            "a paused session advanced {frozen_ms} -> {frozen_again} ms"
        ));
    }

    // 4) Play resumes from the paused position rather than restarting the item.
    let play = command(&session_id, "cmd-play", "play", &json!({}));
    // SAFETY: `player` is live and the envelope is a live string.
    let reply =
        unsafe { execute(player, &play, 5_000) }.map_err(|code| format!("playRefused:{code}"))?;
    if reply["status"] != "accepted" {
        failures.push(format!("play was rejected: {reply}"));
    }
    let resumed = wait_for(
        player,
        "playback to resume",
        Duration::from_secs(10),
        |state| state["isActuallyPlaying"] == Value::Bool(true),
    )?;
    let resumed_ms = number(&resumed, "positionMs");
    if resumed_ms + 100 < frozen_ms {
        failures.push(format!(
            "resume restarted the item ({frozen_ms} -> {resumed_ms} ms)"
        ));
    }

    // 5) Seek re-anchors and keeps the play intent; the command carries the item
    //    and generation it addresses, as the schema requires.
    let current = snapshot(player)?;
    let generation = field(&current, "generation");
    let target_item = current["currentQueueItemId"]
        .as_str()
        .unwrap_or("qi-1")
        .to_owned();
    let seek = json!({
        "schemaVersion": 1,
        "kind": "seek",
        "clientId": "play-file-probe",
        "commandId": "cmd-seek",
        "targetSessionId": session_id,
        "targetQueueItemId": target_item,
        "expectedGeneration": generation,        "payload": {"positionMs": options.seek_ms.to_string()},
    })
    .to_string();
    // SAFETY: `player` is live and the envelope is a live string.
    let reply =
        unsafe { execute(player, &seek, 5_000) }.map_err(|code| format!("seekRefused:{code}"))?;
    if reply["status"] != "accepted" {
        failures.push(format!("seek was rejected: {reply}"));
    }
    let after_seek = wait_for(
        player,
        "the seek to settle",
        Duration::from_secs(10),
        |state| {
            state["isActuallyPlaying"] == Value::Bool(true)
                && number(state, "positionMs") >= options.seek_ms
        },
    )?;
    let seek_ms = Some(number(&after_seek, "positionMs"));
    if number(&after_seek, "positionMs") > options.seek_ms + 1_500 {
        failures.push(format!(
            "seek landed {} ms past the {} ms target",
            number(&after_seek, "positionMs"),
            options.seek_ms
        ));
    }

    // 6) The queue edge wraps in the default mode instead of refusing: a
    //    single-item queue restarts the item that is playing, which is what
    //    `listLoop` means.
    let skip = json!({
        "schemaVersion": 1,
        "kind": "skipNext",
        "clientId": "play-file-probe",
        "commandId": "cmd-skip",
        "targetSessionId": session_id,
        "expectedQueueRevision": field(&after_seek, "queueRevision"),
        // The schema requires the addressed item and generation for skips; the
        // session refuses a delayed skip that arrives after the track changed.
        "targetQueueItemId": field(&after_seek, "currentQueueItemId"),        "expectedGeneration": field(&after_seek, "generation"),
        "payload": {},
    })
    .to_string();
    // SAFETY: `player` is live and the envelope is a live string.
    let reply =
        unsafe { execute(player, &skip, 5_000) }.map_err(|code| format!("skipRefused:{code}"))?;
    let edge_skip = reply["status"].as_str().unwrap_or_default().to_owned();
    if edge_skip != "accepted" {
        failures.push(format!("the queue edge refused the skip: {reply}"));
    }
    let after_skip = wait_for(
        player,
        "the wrapped item to settle",
        Duration::from_secs(10),
        |state| state["phase"] == "ready" || state["phase"] == "resolving",
    )?;
    if after_skip["currentQueueItemId"] != after_seek["currentQueueItemId"] {
        failures.push(format!(
            "the queue edge moved to {} instead of restarting the single item",
            after_skip["currentQueueItemId"]
        ));
    }

    // 6b) Modes cross the wire as codes, and a mode change re-publishes the order
    //     the queue will play: the client renders it instead of computing it.
    let shuffle = json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "play-file-probe",
        "commandId": "cmd-mode",
        "targetSessionId": session_id,
        "expectedQueueRevision": field(&after_skip, "queueRevision"),
        "payload": {"mode": "shuffle", "seed": "7"},
    })
    .to_string();
    // SAFETY: `player` is live and the envelope is a live string.
    let reply = unsafe { execute(player, &shuffle, 5_000) }
        .map_err(|code| format!("setModeRefused:{code}"))?;
    if reply["status"] != "accepted" {
        failures.push(format!("setMode was rejected: {reply}"));
    }
    let shuffled = wait_for(
        player,
        "the shuffle order to be published",
        Duration::from_secs(10),
        |state| state["mode"] == "shuffle",
    )?;
    let mode = shuffled["mode"].as_str().unwrap_or_default().to_owned();
    let order_items = shuffled["effectiveOrder"].as_array().map_or(0, Vec::len);
    if order_items != 1 {
        failures.push(format!(
            "the shuffle order covered {order_items} of one queued item"
        ));
    }
    // The other direction: a mode this build does not implement is refused with a
    // stable code rather than silently accepted.
    let unknown = json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "play-file-probe",
        "commandId": "cmd-mode-unknown",
        "targetSessionId": session_id,
        "expectedQueueRevision": field(&shuffled, "queueRevision"),
        "payload": {"mode": "unsupportedProbeMode"},
    })
    .to_string();
    // SAFETY: `player` is live and the envelope is a live string.
    let reply = unsafe { execute(player, &unknown, 5_000) }
        .map_err(|code| format!("unknownModeRefused:{code}"))?;
    if reply["errorCode"] != "malformedCommand" {
        failures.push(format!(
            "an unknown playback mode reported {} instead of malformedCommand",
            reply["errorCode"]
        ));
    }
    let back_to_loop = json!({
        "schemaVersion": 1,
        "kind": "setMode",
        "clientId": "play-file-probe",
        "commandId": "cmd-mode-list-loop",
        "targetSessionId": session_id,
        "expectedQueueRevision": field(&shuffled, "queueRevision"),
        "payload": {"mode": "listLoop"},
    })
    .to_string();
    // SAFETY: `player` is live and the envelope is a live string.
    let reply = unsafe { execute(player, &back_to_loop, 5_000) }
        .map_err(|code| format!("setModeRefused:{code}"))?;
    if reply["status"] != "accepted" {
        failures.push(format!("returning to listLoop was rejected: {reply}"));
    }

    // 7) Bounded run or full playback. The default mode wraps at the end of the
    //    source, so the evidence that the tail was output is the position reaching
    //    the end of the item before it restarted, not an `ended` phase: with
    //    `listLoop`, `repeatOne` and `shuffle` there is no "play through and
    //    stop", and `ended` is only reachable with an empty queue.
    let watched_from = Instant::now();
    let default_seconds = if options.full { 900 } else { 12 };
    let deadline = Duration::from_secs(options.seconds.unwrap_or(default_seconds));
    let mut peak_ms = number(&after_skip, "positionMs");
    let final_state = if options.full {
        let duration = number(&snapshot(player)?, "durationMs");
        let until = Instant::now() + deadline;
        let mut state = snapshot(player)?;
        while Instant::now() < until {
            state = snapshot(player)?;
            peak_ms = peak_ms.max(number(&state, "positionMs"));
            // The wrap: the item restarted near zero after reaching its own end.
            if number(&state, "positionMs") < 1_000 && duration > 0 && peak_ms + 2_000 >= duration {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        state
    } else {
        std::thread::sleep(deadline);
        snapshot(player)?
    };
    if options.full {
        if final_state["playWhenReady"] != Value::Bool(true) {
            failures.push(String::from(
                "the default list loop cleared the play intent at the end of the queue",
            ));
        }
        if final_state["isActuallyPlaying"] != Value::Bool(true) {
            failures.push(String::from(
                "playback did not continue after the queue wrapped",
            ));
        }
        if final_state["currentQueueItemId"] != after_skip["currentQueueItemId"] {
            failures.push(format!(
                "the wrap landed on {} instead of the queue head",
                final_state["currentQueueItemId"]
            ));
        }
    } else {
        peak_ms = peak_ms.max(number(&final_state, "positionMs"));
        if final_state["isActuallyPlaying"] != Value::Bool(true) {
            failures.push(format!(
                "playback did not stay running for {} s (phase {})",
                deadline.as_secs(),
                final_state["phase"]
            ));
        }
    }

    let pushed = PUSHED.load(Ordering::Relaxed);
    if pushed == 0 {
        failures.push(String::from("the event sink never received a snapshot"));
    }

    Ok(Playback {
        started_ms,
        advanced_ms: advanced,
        frozen_ms,
        resumed_ms,
        seek_ms,
        final_phase: final_state["phase"].as_str().unwrap_or_default().to_owned(),
        final_position_ms: number(&final_state, "positionMs"),
        duration_ms: final_state["durationMs"]
            .as_u64()
            .or_else(|| field(&final_state, "durationMs").parse().ok()),
        edge_skip,
        mode,
        order_items,
        peak_ms,
        play_seconds: watched_from.elapsed().as_secs_f64(),
    })
}

/// Builds the report from the playback facts and the diagnostics document.
fn finish(
    options: &Options,
    capabilities: &Value,
    playback: &Playback,
    diagnostics: Value,
    mut failures: Vec<String>,
) -> Value {
    let underruns = diagnostics["counters"]["underruns"].as_u64().unwrap_or(0);
    let underrun_frames = diagnostics["counters"]["underrunFrames"]
        .as_u64()
        .unwrap_or(0);
    if underruns > 0 || underrun_frames > 0 {
        let message = format!("{underruns} underrun periods ({underrun_frames} frames of silence)");
        if options.expect_underruns {
            eprintln!("note: {message}");
        } else {
            failures.push(message);
        }
    }
    let callbacks = diagnostics["counters"]["callbackCalls"]
        .as_u64()
        .unwrap_or(0);
    if callbacks == 0 {
        failures.push(String::from("the audio callback never ran"));
    }
    if let Some(duration) = playback.duration_ms
        && options.full
    {
        // The tail is a device period of silence at most; give it some slack for
        // a device period and resampler delay. The run wraps instead of ending,
        // so the evidence is the highest position reached before the restart.
        if playback.peak_ms + 2_000 < duration {
            failures.push(format!(
                "the item wrapped at {} ms of a {duration} ms source",
                playback.peak_ms
            ));
        }
    }

    let mut report = json!({
        "probe": "play",
        "file": options.file_name(),
        "abiVersion": ff_media_core_abi_version(),
        "ffmpeg": capabilities["decoder"]["ffmpeg"],
        "resampler": diagnostics["source"]["resampler"],
        "codec": diagnostics["source"]["codec"],
        "sourceRate": diagnostics["source"]["sourceRate"],
        "outputRate": capabilities["output"]["sampleRate"],
        "durationMs": playback.duration_ms,
        "phase": playback.final_phase,
        "positionStartMs": playback.started_ms,
        "positionAfter700ms": playback.advanced_ms,
        "positionPausedMs": playback.frozen_ms,
        "positionResumedMs": playback.resumed_ms,
        "positionAfterSeekMs": playback.seek_ms,
        "positionEndMs": playback.final_position_ms,
        "positionPeakMs": playback.peak_ms,
        "playSeconds": playback.play_seconds,
        "edgeSkip": playback.edge_skip,
        "mode": playback.mode,
        "orderItems": playback.order_items,
        "firstFrameMillis": diagnostics["timing"]["firstFrameMillis"],
        "underruns": underruns,
        "callbackCalls": callbacks,
        "framesConsumed": diagnostics["counters"]["framesConsumed"],
        "tailSilenceFrames": diagnostics["counters"]["tailSilenceFrames"],
        "peakBufferFrames": diagnostics["buffer"]["peakFrames"],
        "bufferCapacityFrames": diagnostics["buffer"]["capacityFrames"],
        "device": diagnostics["output"]["deviceName"],
        "sinkMessages": PUSHED.load(Ordering::Relaxed),
        "failures": failures,
    });
    // The complete document is what a runbook quotes; `--quiet` keeps the line
    // small for a CI log that only needs the verdict.
    if !options.quiet {
        report["diagnostics"] = diagnostics;
    }
    report
}

/// Whether the report's `failures` array is empty.
fn failures_empty(report: &Value) -> bool {
    report["failures"].as_array().is_none_or(Vec::is_empty)
}

/// Sends one command and parses the `result` message.
///
/// # Safety
///
/// `player` must be a live handle created by this ABI.
unsafe fn execute(player: *mut FfPlayer, command: &str, timeout_ms: u32) -> Result<Value, u32> {
    let mut out = empty();
    // SAFETY: the caller upholds the handle contract and both buffers are live.
    let code = unsafe {
        ff_player_execute(
            player,
            command.as_ptr(),
            command.len(),
            timeout_ms,
            &raw mut out,
        )
    };
    if code != FF_MEDIA_OK {
        return Err(code);
    }
    parse_owned(out).ok_or(code)
}

/// Reads the current snapshot.
///
/// # Safety
///
/// `player` must be a live handle created by this ABI.
unsafe fn read_snapshot(player: *mut FfPlayer) -> Result<Value, u32> {
    let mut out = empty();
    // SAFETY: the caller upholds the handle contract and `out` is writable.
    let code = unsafe { ff_player_snapshot(player, &raw mut out) };
    if code != FF_MEDIA_OK {
        return Err(code);
    }
    parse_owned(out).ok_or(code)
}

/// Reads the diagnostics document.
///
/// # Safety
///
/// `player` must be a live handle created by this ABI.
unsafe fn read_diagnostics(player: *mut FfPlayer) -> Value {
    let mut out = empty();
    // SAFETY: the caller upholds the handle contract and `out` is writable.
    let code = unsafe { ff_player_diagnostics(player, &raw mut out) };
    if code != FF_MEDIA_OK {
        return Value::Null;
    }
    parse_owned(out).unwrap_or(Value::Null)
}

fn snapshot(player: *mut FfPlayer) -> Result<Value, String> {
    // SAFETY: `player` is live for the whole probe.
    unsafe { read_snapshot(player) }.map_err(|code| format!("snapshotFailed:{code}"))
}

/// Waits until `predicate` holds, or reports the deadline.
fn wait_for(
    player: *mut FfPlayer,
    what: &str,
    deadline: Duration,
    predicate: impl Fn(&Value) -> bool,
) -> Result<Value, String> {
    let until = Instant::now() + deadline;
    let mut last = snapshot(player)?;
    while Instant::now() < until {
        last = snapshot(player)?;
        if predicate(&last) {
            return Ok(last);
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Err(format!(
        "timed out waiting for {what}; last snapshot: {last}"
    ))
}

/// Copies and frees an owned buffer, parsing it as JSON.
fn parse_owned(bytes: FfOwnedBytes) -> Option<Value> {
    if bytes.data.is_null() {
        return None;
    }
    // SAFETY: the ABI produced this live buffer with this length.
    let slice = unsafe { std::slice::from_raw_parts(bytes.data, bytes.len) };
    let parsed = serde_json::from_slice(slice).ok();
    // SAFETY: the buffer is released exactly once, here.
    unsafe { ff_owned_bytes_free(bytes) };
    parsed
}

fn empty() -> FfOwnedBytes {
    FfOwnedBytes {
        data: std::ptr::null_mut(),
        len: 0,
    }
}

fn command(session_id: &str, command_id: &str, kind: &str, payload: &Value) -> String {
    json!({
        "schemaVersion": 1,
        "kind": kind,
        "clientId": "play-file-probe",
        "commandId": command_id,
        "targetSessionId": session_id,
        "payload": payload,
    })
    .to_string()
}

/// Reads a counter that the schema encodes as a decimal string.
fn field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Reads a millisecond counter that may be a string or a number.
fn number(value: &Value, key: &str) -> u64 {
    value
        .get(key)
        .and_then(Value::as_u64)
        .or_else(|| field(value, key).parse().ok())
        .unwrap_or(0)
}

/// Percent-encodes a path into a `file://` URI.
///
/// Spaces and non-ASCII bytes must be escaped: the probe is pointed at real music
/// files whose names contain both, and `FFmpeg` receives the URI verbatim.
fn file_uri(path: &Path) -> String {
    let text = path.to_string_lossy();
    let mut uri = String::with_capacity(text.len() + 8);
    uri.push_str("file://");
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' | b':' => {
                uri.push(char::from(byte));
            }
            other => {
                let _ = write!(uri, "%{other:02X}");
            }
        }
    }
    uri
}

/// Probe arguments.
struct Options {
    file: std::path::PathBuf,
    seconds: Option<u64>,
    full: bool,
    seek_ms: u64,
    expect_underruns: bool,
    quiet: bool,
}

impl Options {
    fn parse(arguments: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut file = None;
        let mut seconds = None;
        let mut full = false;
        let mut seek_ms = 2_000;
        let mut expect_underruns = false;
        let mut quiet = false;
        let mut arguments = arguments.peekable();

        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--seconds" => {
                    let value = arguments.next().ok_or("--seconds needs a value")?;
                    seconds = Some(value.parse().map_err(|_| "--seconds needs a number")?);
                }
                "--full" => full = true,
                "--seek-ms" => {
                    let value = arguments.next().ok_or("--seek-ms needs a value")?;
                    seek_ms = value.parse().map_err(|_| "--seek-ms needs a number")?;
                }
                "--expect-underruns" => expect_underruns = true,
                "--quiet" => quiet = true,
                other if other.starts_with("--") => {
                    return Err(format!("unknown option '{other}'"));
                }
                other => {
                    if file.is_some() {
                        return Err(String::from("only one file may be played"));
                    }
                    file = Some(std::path::PathBuf::from(other));
                }
            }
        }
        Ok(Self {
            file: file.ok_or("a file to play is required")?,
            seconds,
            full,
            seek_ms,
            expect_underruns,
            quiet,
        })
    }

    /// File name only; docs/design/diagnostics.md keeps local paths out of tool output.
    fn file_name(&self) -> String {
        self.file
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().into_owned())
    }
}
