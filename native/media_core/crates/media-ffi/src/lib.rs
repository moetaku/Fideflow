//! Stable C ABI for platform hosts. Dart never owns this pointer on mobile.
//!
//! This is the byte transport docs/design/boundaries.md requires: control messages cross the
//! boundary as UTF-8 JSON in `FfOwnedBytes`, and snapshots come back the same
//! way, while audio frames never do. `schemas/media_core.h` is the normative
//! header and `tooling/check_contracts.py` fails the build if the two drift.
//!
//! Rules this file enforces, because a host cannot be expected to know them:
//!
//! * Handles are **not** bound to a thread. The session serialises commands
//!   internally, so any thread may call any function.
//! * No Rust panic crosses the boundary. Every entry point catches one and
//!   returns [`FF_MEDIA_ERR_INTERNAL`]; the caller must not read a result buffer
//!   after a failure.
//! * Byte buffers have exactly one owner. `data`/`len` from this ABI are
//!   released once with [`ff_owned_bytes_free`].
//! * [`ff_player_free`] clears the event sink, stops output and joins the
//!   session's threads before freeing, so no callback can run afterwards.
//! * A call tells "the command was rejected" apart from "the transport failed":
//!   the former is a `result` message with `status: rejected`, the latter is a
//!   result code other than [`FF_MEDIA_OK`].

mod ncm_host;

use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::time::Duration;

use fideflow_media_session::{PlaybackSession, PlaybackState};

/// ABI version exposed to hosts (docs/design/boundaries.md). The header pins the same value.
/// ABI 3 adds player-scoped compressed input and independently owned buffer leases.
pub const ABI_VERSION: u32 = 3;

/// Result codes, mirrored one-for-one by the header's `FF_MEDIA_*` macros.
pub const FF_MEDIA_OK: u32 = 0;
/// A null handle or null out-parameter.
pub const FF_MEDIA_ERR_NULL_HANDLE: u32 = 1;
/// An argument that is null, empty, not UTF-8, or longer than its limit.
pub const FF_MEDIA_ERR_INVALID_ARGUMENT: u32 = 2;
/// Valid UTF-8 that is not a JSON object; it was never submitted.
pub const FF_MEDIA_ERR_MALFORMED_MESSAGE: u32 = 3;
/// A message this build's ABI refuses to carry (over the size limit).
pub const FF_MEDIA_ERR_UNSUPPORTED: u32 = 4;
/// The executor was busy for the whole deadline; nothing was submitted.
pub const FF_MEDIA_ERR_TIMEOUT: u32 = 5;
/// A contained internal failure; the caller must treat the call as failed.
pub const FF_MEDIA_ERR_INTERNAL: u32 = 6;

/// Largest command envelope this ABI carries. The schema's own limits are far
/// smaller; this only stops a host from handing over something absurd.
const MAX_COMMAND_BYTES: usize = 1 << 20;
/// Limit for `clientId` and `connectionId`, matching the schema's id length.
const MAX_ID_BYTES: usize = 128;
/// Limit for the checkpoint directory this ABI carries.
const MAX_PATH_BYTES: usize = 4096;

/// The C event sink: it takes ownership of `json` and releases it with
/// [`ff_owned_bytes_free`]. `Option` makes the null pointer a valid "clear it"
/// value.
pub type FfEventSink = Option<unsafe extern "C" fn(json: *mut u8, len: usize, user: *mut c_void)>;

/// Owned UTF-8 bytes. Release exactly once with [`ff_owned_bytes_free`].
#[repr(C)]
pub struct FfOwnedBytes {
    /// Buffer base, or null when empty.
    pub data: *mut u8,
    /// Buffer length in bytes.
    pub len: usize,
}

/// A session handle plus everything the ABI needs to keep alive for it.
pub struct FfPlayer {
    session: PlaybackSession,
}

/// Registration passed to the session's publisher. See [`ff_player_set_event_sink`].
struct CSink {
    sink: unsafe extern "C" fn(json: *mut u8, len: usize, user: *mut c_void),
    user: *mut c_void,
}

// SAFETY: the caller guarantees, as the header documents, that the sink and its
// context stay valid until the sink is cleared or the player is freed, and that
// the sink may be called from the session's publisher thread. This type only
// forwards bytes to them; it never dereferences `user`.
unsafe impl Send for CSink {}
unsafe impl Sync for CSink {}

/// An empty owned buffer, used whenever a call produced nothing.
fn empty_bytes() -> FfOwnedBytes {
    FfOwnedBytes {
        data: std::ptr::null_mut(),
        len: 0,
    }
}

/// Moves a string into an owned buffer.
fn owned_bytes(text: String) -> FfOwnedBytes {
    let bytes = text.into_bytes().into_boxed_slice();
    let len = bytes.len();
    FfOwnedBytes {
        data: Box::into_raw(bytes).cast::<u8>(),
        len,
    }
}

/// Runs an ABI body, turning a Rust panic into a stable result code.
fn guard(body: impl FnOnce() -> u32) -> u32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(FF_MEDIA_ERR_INTERNAL)
}

/// Borrows a UTF-8 argument that may legitimately be empty (an empty directory
/// turns the checkpoint writer off).
///
/// # Safety
///
/// `pointer` must be null or point to `len` readable bytes.
unsafe fn borrow_str_allow_empty<'a>(
    pointer: *const u8,
    len: usize,
    max: usize,
) -> Result<&'a str, u32> {
    if len == 0 {
        return Ok("");
    }
    if pointer.is_null() {
        return Err(FF_MEDIA_ERR_INVALID_ARGUMENT);
    }
    if len > max {
        return Err(FF_MEDIA_ERR_UNSUPPORTED);
    }
    // SAFETY: the caller guarantees `len` readable bytes at `pointer`.
    let slice = unsafe { std::slice::from_raw_parts(pointer, len) };
    std::str::from_utf8(slice).map_err(|_| FF_MEDIA_ERR_INVALID_ARGUMENT)
}

/// Borrows a UTF-8 argument of a bounded length.
///
/// # Safety
///
/// `pointer` must be null or point to `len` readable bytes.
unsafe fn borrow_str<'a>(pointer: *const u8, len: usize, max: usize) -> Result<&'a str, u32> {
    if pointer.is_null() || len == 0 {
        return Err(FF_MEDIA_ERR_INVALID_ARGUMENT);
    }
    if len > max {
        return Err(FF_MEDIA_ERR_UNSUPPORTED);
    }
    // SAFETY: the caller guarantees `len` readable bytes at `pointer`.
    let slice = unsafe { std::slice::from_raw_parts(pointer, len) };
    std::str::from_utf8(slice).map_err(|_| FF_MEDIA_ERR_INVALID_ARGUMENT)
}

#[unsafe(no_mangle)]
pub extern "C" fn ff_media_core_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn ff_media_core_capabilities_json() -> FfOwnedBytes {
    // The session owns the capability document, so the ABI cannot describe a
    // build differently from the library it exposes.
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(serde_json::Value::Object(mut value)) =
            serde_json::from_str(&PlaybackSession::capabilities_json())
        else {
            return String::new();
        };
        value.insert("ncmHost".into(), serde_json::json!({"schemaVersion": 1}));
        serde_json::Value::Object(value).to_string()
    }))
    .map_or_else(|_| empty_bytes(), owned_bytes)
}

/// Releases a byte buffer returned by this ABI.
///
/// # Safety
///
/// `bytes` must be null/empty or a live buffer returned by this ABI and must
/// not have been freed already.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_owned_bytes_free(bytes: FfOwnedBytes) {
    if bytes.data.is_null() {
        return;
    }
    let slice = std::ptr::slice_from_raw_parts_mut(bytes.data, bytes.len);
    // SAFETY: The caller transfers the unique buffer and its original length.
    unsafe { drop(Box::from_raw(slice)) }
}

#[unsafe(no_mangle)]
pub extern "C" fn ff_player_new() -> *mut FfPlayer {
    let player = catch_unwind(AssertUnwindSafe(|| FfPlayer {
        session: PlaybackSession::new(),
    }));
    match player {
        Ok(player) => Box::into_raw(Box::new(player)),
        // A host that gets null here reports an unavailable player and never
        // calls into the ABI again.
        Err(_) => std::ptr::null_mut(),
    }
}

/// Releases a handle returned by [`ff_player_new`].
///
/// # Safety
///
/// `player` must be null or a live pointer returned by [`ff_player_new`] that
/// has not previously been released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_free(player: *mut FfPlayer) {
    if player.is_null() {
        return;
    }
    // SAFETY: The caller upholds the ownership contract documented above.
    let player = unsafe { Box::from_raw(player) };
    player.session.input_registry().shutdown();
    player.session.set_event_sink(None);
    // Joins the publisher and the decode worker and stops output, so nothing can
    // call `FfPlayer` (or the host's sink) after this returns.
    player.session.shutdown();
    drop(player);
}

/// Registers (`Some`) or clears (`None`) the event destination.
///
/// # Safety
///
/// `player` must be null or a live handle; `sink`, when non-null, must be a
/// function that stays callable and whose `user` context stays valid until the
/// sink is cleared or the player is freed. The sink runs on the session's
/// publisher thread, takes ownership of the buffer it receives (and must release
/// it with [`ff_owned_bytes_free`]), and must not call back into this ABI: it may
/// hand the pointer to another thread or a deferred dispatch instead.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_set_event_sink(
    player: *mut FfPlayer,
    sink: FfEventSink,
    user: *mut c_void,
) -> u32 {
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let Some(sink) = sink else {
        player.session.set_event_sink(None);
        return FF_MEDIA_OK;
    };
    let target = Arc::new(CSink { sink, user });
    player
        .session
        .set_event_sink(Some(Arc::new(move |message: &str| {
            // Ownership of the buffer crosses the boundary here: the session's
            // message is borrowed for this call, and the host may dispatch it later
            // (a Dart `NativeCallable.listener` runs on the isolate's event loop), so
            // the bytes are copied into an owned buffer the host must free.
            let bytes = owned_bytes(message.to_owned());
            // SAFETY: the caller's contract keeps `target` valid for as long as the
            // session can call this, and it takes ownership of `bytes`.
            unsafe { (target.sink)(bytes.data, bytes.len, target.user) }
        })));
    FF_MEDIA_OK
}

/// Reads the coarse state, returning `FF_PLAYBACK_ERROR` for a null handle.
///
/// # Safety
///
/// `player` must be null or point to a live player created by this ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_state(player: *const FfPlayer) -> u32 {
    // SAFETY: the caller guarantees a valid pointer when it is non-null.
    unsafe { player.as_ref() }.map_or(PlaybackState::Error, |player| player.session.state()) as u32
}

/// Registers a subscriber and returns `{connectionId, baseline}` as owned bytes.
///
/// # Safety
///
/// `player` must be a live handle, `client_id` must point to `client_id_len`
/// readable bytes, and `out` must point to writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_attach(
    player: *mut FfPlayer,
    client_id: *const u8,
    client_id_len: usize,
    out: *mut FfOwnedBytes,
) -> u32 {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let client_id = match unsafe { borrow_str(client_id, client_id_len, MAX_ID_BYTES) } {
        Ok(client_id) => client_id,
        Err(code) => return code,
    };
    guard(|| {
        *out = owned_bytes(player.session.attach(client_id));
        FF_MEDIA_OK
    })
}

/// Drops one subscriber. Playback is not affected, and an unknown connection id
/// is an idempotent success.
///
/// # Safety
///
/// `player` must be a live handle and `connection_id` must point to
/// `connection_id_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_detach(
    player: *mut FfPlayer,
    connection_id: *const u8,
    connection_id_len: usize,
) -> u32 {
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let connection_id = match unsafe { borrow_str(connection_id, connection_id_len, MAX_ID_BYTES) }
    {
        Ok(connection_id) => connection_id,
        Err(code) => return code,
    };
    guard(|| {
        // Detach is idempotent, so an unknown id is not an error either.
        let _ = player.session.detach(connection_id);
        FF_MEDIA_OK
    })
}

/// Configures the session-side restore record writer (docs/design/restore.md).
///
/// The session is the single writer of the record: it owns the queue, the order
/// it plays and the position, so it is also the one component that can write it
/// without a second opinion. `directory` is where the per-account file lives; an
/// empty directory turns the writer off and removes the record, and an empty
/// `account` files under `guest`. Nothing here starts playback: a host configures
/// the writer first and reads the file back to restore.
///
/// # Safety
///
/// `player` must be a live handle, and `directory`/`account` must each be null or
/// point to the number of readable bytes given as their length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_configure_checkpoint(
    player: *mut FfPlayer,
    directory: *const u8,
    directory_len: usize,
    account: *const u8,
    account_len: usize,
) -> u32 {
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let directory =
        match unsafe { borrow_str_allow_empty(directory, directory_len, MAX_PATH_BYTES) } {
            Ok(value) => value,
            Err(code) => return code,
        };
    let account = match unsafe { borrow_str_allow_empty(account, account_len, MAX_ID_BYTES) } {
        Ok(value) => value,
        Err(code) => return code,
    };
    guard(|| {
        player.session.configure_checkpoint(directory, account);
        FF_MEDIA_OK
    })
}

/// Rebuilds the session's queue from the restore record it holds (docs/design/restore.md).
///
/// The session owns the queue, the order it plays and the position, so it is also
/// the one component that can put them back without a client replaying commands:
/// this reads `directory`'s record for `account` and rebuilds them. Nothing is
/// started - the restored queue is paused - and a session that already holds a
/// queue is left alone, so a live session always wins over a file. Whether a
/// queue came back is visible in the snapshot an attach returns.
///
/// # Safety
///
/// `player` must be a live handle, and `directory`/`account` must each be null or
/// point to the number of readable bytes given as their length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_restore_checkpoint(
    player: *mut FfPlayer,
    directory: *const u8,
    directory_len: usize,
    account: *const u8,
    account_len: usize,
    out_status: *mut u32,
) -> u32 {
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let directory =
        match unsafe { borrow_str_allow_empty(directory, directory_len, MAX_PATH_BYTES) } {
            Ok(value) => value,
            Err(code) => return code,
        };
    let account = match unsafe { borrow_str_allow_empty(account, account_len, MAX_ID_BYTES) } {
        Ok(value) => value,
        Err(code) => return code,
    };
    guard(|| {
        let outcome = player.session.restore_checkpoint(directory, account);
        if !out_status.is_null() {
            // SAFETY: the caller promised writable storage for a non-null pointer.
            unsafe { *out_status = outcome as u32 };
        }
        FF_MEDIA_OK
    })
}

/// Removes `directory`'s record for `account`, deliberately (docs/design/restore.md).
///
/// Separate from [`ff_player_configure_checkpoint`]: stopping the writer with an
/// empty directory keeps the record, so an account switch does not delete the
/// queue the old account might come back to.
///
/// # Safety
///
/// `player` must be a live handle, and `directory`/`account` must each be null or
/// point to the number of readable bytes given as their length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_delete_checkpoint(
    player: *mut FfPlayer,
    directory: *const u8,
    directory_len: usize,
    account: *const u8,
    account_len: usize,
) -> u32 {
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let directory =
        match unsafe { borrow_str_allow_empty(directory, directory_len, MAX_PATH_BYTES) } {
            Ok(value) => value,
            Err(code) => return code,
        };
    let account = match unsafe { borrow_str_allow_empty(account, account_len, MAX_ID_BYTES) } {
        Ok(value) => value,
        Err(code) => return code,
    };
    guard(|| {
        player.session.delete_checkpoint(directory, account);
        FF_MEDIA_OK
    })
}

/// Forces the current state to disk, bypassing the position throttle (docs/design/restore.md).
///
/// Used before an account switch and on shutdown, so the last position is saved
/// even when it moved by less than the periodic step.
///
/// # Safety
///
/// `player` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_flush_checkpoint(player: *mut FfPlayer) -> u32 {
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    guard(|| {
        player.session.flush_checkpoint();
        FF_MEDIA_OK
    })
}

/// Latest snapshot as owned bytes.
///
/// # Safety
///
/// `player` must be a live handle and `out` must point to writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_snapshot(player: *mut FfPlayer, out: *mut FfOwnedBytes) -> u32 {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    guard(|| {
        *out = owned_bytes(player.session.snapshot_json());
        FF_MEDIA_OK
    })
}

/// Bounded playback diagnostics as owned bytes (docs/design/diagnostics.md).
///
/// The document contains counters, formats and stable codes only: no paths,
/// titles, credentials or media URLs.
///
/// # Safety
///
/// `player` must be a live handle and `out` must point to writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_diagnostics(
    player: *mut FfPlayer,
    out: *mut FfOwnedBytes,
) -> u32 {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    guard(|| {
        *out = owned_bytes(player.session.diagnostics_json());
        FF_MEDIA_OK
    })
}

/// Submits one command envelope and returns the `result` message as owned bytes.
///
/// `timeout_ms` bounds the wait for the session executor only; `0` means the
/// call never blocks. The command is either applied or not submitted at all, so
/// a [`FF_MEDIA_ERR_TIMEOUT`] never means "unknown outcome".
///
/// # Safety
///
/// `player` must be a live handle, `json` must point to `len` readable bytes,
/// and `out` must point to writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_execute(
    player: *mut FfPlayer,
    json: *const u8,
    len: usize,
    timeout_ms: u32,
    out: *mut FfOwnedBytes,
) -> u32 {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    // SAFETY: the caller guarantees a live handle when non-null.
    let Some(player) = (unsafe { player.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let command = match unsafe { borrow_str(json, len, MAX_COMMAND_BYTES) } {
        Ok(command) => command,
        Err(code) => return code,
    };
    // Reject a payload that is not a JSON object before it reaches the session:
    // a schema violation is a rejection with a code, this is not a message.
    if !matches!(
        serde_json::from_str::<serde_json::Value>(command),
        Ok(serde_json::Value::Object(_))
    ) {
        return FF_MEDIA_ERR_MALFORMED_MESSAGE;
    }
    guard(|| {
        let timeout = Duration::from_millis(u64::from(timeout_ms));
        match player.session.execute_json_timeout(command, timeout) {
            Some(reply) => {
                *out = owned_bytes(reply);
                FF_MEDIA_OK
            }
            None => FF_MEDIA_ERR_TIMEOUT,
        }
    })
}

/// The C ABI version and the session's must agree: hosts negotiate on one number.
const _: () = assert!(
    ABI_VERSION == fideflow_media_session::ABI_VERSION,
    "the C ABI version must match the session's"
);

#[cfg(test)]
mod tests {
    use super::{
        ABI_VERSION, FF_MEDIA_ERR_INVALID_ARGUMENT, FF_MEDIA_ERR_MALFORMED_MESSAGE,
        FF_MEDIA_ERR_NULL_HANDLE, FF_MEDIA_ERR_UNSUPPORTED, FF_MEDIA_OK, FfOwnedBytes, FfPlayer,
        MAX_COMMAND_BYTES, empty_bytes, ff_media_core_abi_version, ff_media_core_capabilities_json,
        ff_owned_bytes_free, ff_player_attach, ff_player_detach, ff_player_diagnostics,
        ff_player_execute, ff_player_free, ff_player_new, ff_player_set_event_sink,
        ff_player_snapshot, ff_player_state,
    };
    use serde_json::{Value, json};
    use std::ffi::c_void;
    use std::ptr;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    /// Copies a buffer this ABI returned and releases it.
    fn take(bytes: FfOwnedBytes) -> String {
        assert!(!bytes.data.is_null(), "the ABI returned no bytes");
        // SAFETY: the ABI just produced this live buffer with this length.
        let slice = unsafe { std::slice::from_raw_parts(bytes.data, bytes.len) };
        let text = String::from_utf8(slice.to_vec()).expect("UTF-8");
        // SAFETY: the buffer is released exactly once, here.
        unsafe { ff_owned_bytes_free(bytes) };
        text
    }

    /// A player plus the session id from its first snapshot.
    fn player_with_session() -> (*mut FfPlayer, String) {
        let player = ff_player_new();
        assert!(!player.is_null());
        let mut out = empty_bytes();
        // SAFETY: `player` is live and `out` is writable storage.
        assert_eq!(
            unsafe { ff_player_snapshot(player, &raw mut out) },
            FF_MEDIA_OK
        );
        let snapshot: Value = serde_json::from_str(&take(out)).expect("a snapshot");
        let session_id = snapshot["sessionId"]
            .as_str()
            .expect("a session id")
            .to_owned();
        (player, session_id)
    }

    fn command_with(session_id: &str, command_id: &str, kind: &str, payload: &str) -> String {
        format!(
            "{{\"schemaVersion\":1,\"kind\":\"{kind}\",\"clientId\":\"test\",\
             \"commandId\":\"{command_id}\",\"targetSessionId\":\"{session_id}\",\"payload\":{payload}}}"
        )
    }

    fn command(session_id: &str, kind: &str, payload: &str) -> String {
        command_with(session_id, "cmd-1", kind, payload)
    }

    /// Sends a command and returns `(code, reply)`.
    fn execute(player: *mut FfPlayer, json: &str) -> (u32, String) {
        let mut out = empty_bytes();
        // SAFETY: `player` is live, `json` is a live UTF-8 string, `out` is writable.
        let code =
            unsafe { ff_player_execute(player, json.as_ptr(), json.len(), 1_000, &raw mut out) };
        if code == FF_MEDIA_OK {
            (code, take(out))
        } else {
            (code, String::new())
        }
    }

    #[test]
    fn reports_contract_version() {
        assert_eq!(ff_media_core_abi_version(), ABI_VERSION);
    }

    #[test]
    fn capability_buffer_has_matching_release() {
        let bytes = ff_media_core_capabilities_json();
        assert!(!bytes.data.is_null());
        assert!(bytes.len > 0);
        let document: Value = serde_json::from_str(&take(bytes)).expect("capabilities JSON");
        assert_eq!(document["abiVersion"], ABI_VERSION);
        assert_eq!(document["controlTransport"], "bytes+json");
        assert_eq!(document["schemaVersion"], 1);
    }

    #[test]
    fn null_handles_and_arguments_are_reported_not_dereferenced() {
        let mut out = empty_bytes();
        // SAFETY: every call below passes null deliberately; the ABI must reject
        // each one without touching memory.
        unsafe {
            assert_eq!(
                ff_player_state(ptr::null()),
                fideflow_media_session::PlaybackState::Error as u32,
                "a null handle reads as the error state"
            );
            assert_eq!(
                ff_player_snapshot(ptr::null_mut(), &raw mut out),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(
                ff_player_attach(ptr::null_mut(), ptr::null(), 0, &raw mut out),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(
                ff_player_detach(ptr::null_mut(), ptr::null(), 0),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(
                ff_player_execute(ptr::null_mut(), ptr::null(), 0, 0, &raw mut out),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(
                ff_player_set_event_sink(ptr::null_mut(), None, ptr::null_mut()),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(
                ff_player_diagnostics(ptr::null_mut(), &raw mut out),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            // A null out-parameter is a contract violation the host must see.
            assert_eq!(
                ff_player_snapshot(ptr::null_mut(), ptr::null_mut()),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            // A null handle is safe to free.
            ff_player_free(ptr::null_mut());
        }
    }

    #[test]
    fn invalid_and_unsupported_arguments_are_distinguished() {
        let player = ff_player_new();
        // SAFETY: `player` is live for the whole test.
        unsafe {
            let mut out = empty_bytes();
            let empty: [u8; 0] = [];
            assert_eq!(
                ff_player_execute(player, empty.as_ptr(), 0, 0, &raw mut out),
                FF_MEDIA_ERR_INVALID_ARGUMENT,
                "an empty command is not a message"
            );
            let invalid = [0xff_u8, 0xfe, 0xfd];
            assert_eq!(
                ff_player_execute(player, invalid.as_ptr(), invalid.len(), 0, &raw mut out),
                FF_MEDIA_ERR_INVALID_ARGUMENT,
                "non-UTF-8 bytes are an invalid argument"
            );
            let client = [b'a'; 200];
            assert_eq!(
                ff_player_attach(player, client.as_ptr(), client.len(), &raw mut out),
                FF_MEDIA_ERR_UNSUPPORTED,
                "an over-long id is refused rather than truncated"
            );
            let oversized = vec![b'{'; MAX_COMMAND_BYTES + 1];
            assert_eq!(
                ff_player_execute(player, oversized.as_ptr(), oversized.len(), 0, &raw mut out),
                FF_MEDIA_ERR_UNSUPPORTED
            );
            ff_player_free(player);
        }
    }

    #[test]
    fn a_payload_that_is_not_a_json_object_is_never_submitted() {
        let (player, _) = player_with_session();
        // SAFETY: `player` is live; the strings are live UTF-8.
        unsafe {
            for text in ["not json", "[1,2,3]", "\"pause\""] {
                let mut out = empty_bytes();
                assert_eq!(
                    ff_player_execute(player, text.as_ptr(), text.len(), 1_000, &raw mut out),
                    FF_MEDIA_ERR_MALFORMED_MESSAGE,
                    "{text} must not reach the session"
                );
            }
            ff_player_free(player);
        }
    }

    #[test]
    fn execute_returns_schema_shaped_results_and_replays_idempotently() {
        let (player, session_id) = player_with_session();
        assert_eq!(
            // SAFETY: `player` is live and not threaded in this test.
            unsafe { ff_player_state(player) },
            fideflow_media_session::PlaybackState::Idle as u32
        );

        let pause = command(&session_id, "pause", "{}");
        let (code, reply) = execute(player, &pause);
        assert_eq!(code, FF_MEDIA_OK);
        let accepted: Value = serde_json::from_str(&reply).expect("a result");
        assert_eq!(accepted["schemaVersion"], 1);
        assert_eq!(accepted["kind"], "result");
        assert_eq!(accepted["commandId"], "cmd-1");
        assert_eq!(accepted["status"], "accepted");
        assert!(
            accepted["sessionRevision"].is_string(),
            "revisions are decimal strings"
        );

        // Same key, same payload: the stored answer, not a second execution.
        let (code, repeated) = execute(player, &pause);
        assert_eq!(code, FF_MEDIA_OK);
        assert_eq!(
            serde_json::from_str::<Value>(&repeated).expect("a result"),
            accepted
        );

        // Same key, different payload: refused, never re-run.
        let conflicting = command(&session_id, "play", "{}");
        let (code, reply) = execute(player, &conflicting);
        assert_eq!(code, FF_MEDIA_OK);
        let rejected: Value = serde_json::from_str(&reply).expect("a result");
        assert_eq!(rejected["status"], "rejected");
        assert_eq!(rejected["errorCode"], "idempotencyConflict");

        // A schema-legal command the session cannot honour is a rejection.
        let (code, reply) = execute(player, &command_with(&session_id, "cmd-2", "play", "{}"));
        assert_eq!(code, FF_MEDIA_OK);
        let rejected: Value = serde_json::from_str(&reply).expect("a result");
        assert_eq!(rejected["status"], "rejected");
        assert_eq!(rejected["errorCode"], "emptyQueue");

        // A command addressed to a different session is refused too.
        let (code, reply) = execute(player, &command_with("other", "cmd-3", "pause", "{}"));
        assert_eq!(code, FF_MEDIA_OK);
        let rejected: Value = serde_json::from_str(&reply).expect("a result");
        assert_eq!(rejected["errorCode"], "sessionMismatch");

        // SAFETY: the handle is released once, here.
        unsafe { ff_player_free(player) };
    }

    #[test]
    fn diagnostics_are_payload_free_and_complete() {
        let (player, session_id) = player_with_session();
        let mut out = empty_bytes();
        // SAFETY: `player` is live and `out` is writable storage.
        assert_eq!(
            unsafe { ff_player_diagnostics(player, &raw mut out) },
            FF_MEDIA_OK
        );
        let document: Value = serde_json::from_str(&take(out)).expect("diagnostics JSON");
        assert_eq!(document["kind"], "diagnostics");
        assert_eq!(document["sessionId"], session_id.as_str());
        assert_eq!(document["worker"]["state"], "idle");
        assert!(document["counters"]["framesConsumed"].is_number());
        // docs/design/diagnostics.md: no path, URL or title may appear anywhere in the document.
        let text = document.to_string();
        for forbidden in ["/Users/", "/tmp/", "file://", "http://", "https://"] {
            assert!(!text.contains(forbidden), "diagnostics leaked {forbidden}");
        }
        // SAFETY: the handle is released once, here.
        unsafe { ff_player_free(player) };
    }

    #[test]
    fn attach_returns_a_schema_shaped_baseline_and_detach_is_idempotent() {
        let (player, session_id) = player_with_session();
        let client_id = "flutter";
        let mut out = empty_bytes();
        // SAFETY: `player` is live, the id is a live string, `out` is writable.
        let code =
            unsafe { ff_player_attach(player, client_id.as_ptr(), client_id.len(), &raw mut out) };
        assert_eq!(code, FF_MEDIA_OK);
        let attachment: Value = serde_json::from_str(&take(out)).expect("an attachment");
        let connection_id = attachment["connectionId"]
            .as_str()
            .expect("a connection id")
            .to_owned();
        let baseline = &attachment["baseline"];
        assert_eq!(baseline["kind"], "snapshot");
        assert_eq!(baseline["sessionId"], session_id.as_str());
        for key in [
            "schemaVersion",
            "sessionRevision",
            "queueRevision",
            "generation",
            "phase",
            "playWhenReady",
            "buffering",
            "suppressionReasons",
            "isActuallyPlaying",
            "currentQueueItemId",
            "positionMs",
        ] {
            assert!(baseline.get(key).is_some(), "the baseline is missing {key}");
        }

        // SAFETY: `player` is live and both ids are live strings.
        unsafe {
            assert_eq!(
                ff_player_detach(player, connection_id.as_ptr(), connection_id.len()),
                FF_MEDIA_OK
            );
            let unknown = "conn-9999";
            assert_eq!(
                ff_player_detach(player, unknown.as_ptr(), unknown.len()),
                FF_MEDIA_OK,
                "detaching an unknown connection is idempotent"
            );
            ff_player_free(player);
        }
    }

    static SNAPSHOTS: AtomicUsize = AtomicUsize::new(0);

    /// Counts the snapshots the publisher hands over and releases each buffer.
    unsafe extern "C" fn count_snapshots(json: *mut u8, len: usize, user: *mut c_void) {
        let _ = user;
        // SAFETY: the registration transfers ownership of every event buffer to
        // this sink, which is the only owner and releases it exactly once.
        unsafe { ff_owned_bytes_free(FfOwnedBytes { data: json, len }) };
        if len > 0 {
            SNAPSHOTS.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[test]
    fn the_event_sink_receives_snapshots_from_the_publisher_thread() {
        let (player, session_id) = player_with_session();
        // SAFETY: the sink outlives the registration and `user` is unused.
        assert_eq!(
            unsafe { ff_player_set_event_sink(player, Some(count_snapshots), ptr::null_mut()) },
            FF_MEDIA_OK
        );
        let (code, _) = execute(player, &command(&session_id, "pause", "{}"));
        assert_eq!(code, FF_MEDIA_OK);

        let until = Instant::now() + Duration::from_secs(5);
        while SNAPSHOTS.load(Ordering::Relaxed) == 0 && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            SNAPSHOTS.load(Ordering::Relaxed) > 0,
            "the publisher never called the sink"
        );

        // SAFETY: clearing the sink and freeing must leave no callback behind.
        unsafe {
            assert_eq!(
                ff_player_set_event_sink(player, None, ptr::null_mut()),
                FF_MEDIA_OK
            );
            ff_player_free(player);
        }
        let after_clear = SNAPSHOTS.load(Ordering::Relaxed);
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(
            SNAPSHOTS.load(Ordering::Relaxed),
            after_clear,
            "a cleared sink must not be called again"
        );
    }
}

/// Input notifications carry IDs only; acquire can fail if cancellation won the race.
pub type FfInputSink = Option<unsafe extern "C" fn(u64, u64, u64, i64, *mut c_void)>;
struct InputSinkTarget {
    sink: unsafe extern "C" fn(u64, u64, u64, i64, *mut c_void),
    user: *mut c_void,
}
// SAFETY: registration requires a thread-safe callback and context surviving unregister.
unsafe impl Send for InputSinkTarget {}
unsafe impl Sync for InputSinkTarget {}
impl InputSinkTarget {
    fn notify(&self, request: u64, source: u64, reader: u64, offset: i64) {
        unsafe { (self.sink)(request, source, reader, offset, self.user) }
    }
}
#[repr(C)]
pub struct FfInputBuffer {
    pub lease: *mut fideflow_media_pipeline::input::InputLease,
    pub data: *mut u8,
    pub capacity: usize,
}

/// # Safety
/// Live player; callback/context remain valid until unregister returns. Callback must not reenter ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_input_set_sink(
    player: *mut FfPlayer,
    sink: FfInputSink,
    user: *mut c_void,
) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(player) = (unsafe { player.as_ref() }) else {
            return FF_MEDIA_ERR_NULL_HANDLE;
        };
        let sink = sink.map(|sink| {
            let target = Arc::new(InputSinkTarget { sink, user });
            Arc::new(move |request, source, reader, offset| {
                target.notify(request, source, reader, offset);
            }) as fideflow_media_pipeline::input::InputSink
        });
        player.session.input_registry().set_sink(sink);
        FF_MEDIA_OK
    }))
    .unwrap_or(FF_MEDIA_ERR_INTERNAL)
}
/// # Safety
/// Player must be live. IDs are nonzero and scoped to this player.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_input_register(player: *mut FfPlayer, source: u64) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(player) = (unsafe { player.as_ref() }) else {
            return FF_MEDIA_ERR_NULL_HANDLE;
        };
        if player.session.input_registry().register(source) {
            FF_MEDIA_OK
        } else {
            FF_MEDIA_ERR_INVALID_ARGUMENT
        }
    }))
    .unwrap_or(FF_MEDIA_ERR_INTERNAL)
}
/// # Safety
/// Player must be live. Revocation is idempotent and wakes blocked readers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_input_revoke(player: *mut FfPlayer, source: u64) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(player) = (unsafe { player.as_ref() }) else {
            return FF_MEDIA_ERR_NULL_HANDLE;
        };
        player.session.input_registry().revoke(source);
        FF_MEDIA_OK
    }))
    .unwrap_or(FF_MEDIA_ERR_INTERNAL)
}
/// # Safety
/// Live player and writable out; output is untouched on failure. One acquisition per request.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_player_input_acquire(
    player: *mut FfPlayer,
    request: u64,
    out: *mut FfInputBuffer,
) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(player) = (unsafe { player.as_ref() }) else {
            return FF_MEDIA_ERR_NULL_HANDLE;
        };
        if out.is_null() {
            return FF_MEDIA_ERR_INVALID_ARGUMENT;
        }
        let Some(mut lease) = player.session.input_registry().acquire(request) else {
            return FF_MEDIA_ERR_INVALID_ARGUMENT;
        };
        let data = lease.buffer.bytes.as_mut_ptr();
        let capacity = lease.buffer.bytes.len();
        unsafe {
            out.write(FfInputBuffer {
                lease: Box::into_raw(Box::new(lease)),
                data,
                capacity,
            });
        }
        FF_MEDIA_OK
    }))
    .unwrap_or(FF_MEDIA_ERR_INTERNAL)
}
/// # Safety
/// Lease is consumed exactly once, including invalid lengths. It may outlive `player_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_input_commit(
    lease: *mut fideflow_media_pipeline::input::InputLease,
    len: usize,
    total: i64,
    status: u32,
) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        if lease.is_null() {
            return FF_MEDIA_ERR_NULL_HANDLE;
        }
        let lease = unsafe { Box::from_raw(lease) };
        let valid = len <= lease.buffer.bytes.len() && total >= -1 && status <= 4;
        lease.complete(
            if valid { len } else { 0 },
            total,
            if valid { status } else { 3 },
        );
        if valid {
            FF_MEDIA_OK
        } else {
            FF_MEDIA_ERR_INVALID_ARGUMENT
        }
    }))
    .unwrap_or(FF_MEDIA_ERR_INTERNAL)
}
/// # Safety
/// Consumes a lease exactly once; no access to its memory is allowed afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_input_release(
    lease: *mut fideflow_media_pipeline::input::InputLease,
) -> u32 {
    unsafe { ff_input_commit(lease, 0, -1, 2) }
}

#[cfg(test)]
mod input_abi_tests {
    use super::*;
    use std::{ptr, sync::mpsc, thread};
    type Notice = (u64, u64, u64, i64);
    unsafe extern "C" fn notify(
        request: u64,
        source: u64,
        reader: u64,
        offset: i64,
        user: *mut c_void,
    ) {
        let sender = unsafe { &*user.cast::<mpsc::Sender<Notice>>() };
        let _ = sender.send((request, source, reader, offset));
    }
    #[test]
    fn acquired_memory_outlives_player_and_old_notifications_cannot_acquire() {
        let player = ff_player_new();
        assert!(!player.is_null());
        let (sender, receiver) = mpsc::channel::<Notice>();
        unsafe {
            assert_eq!(
                ff_player_input_set_sink(
                    player,
                    Some(notify),
                    (&raw const sender).cast_mut().cast()
                ),
                FF_MEDIA_OK
            );
            assert_eq!(ff_player_input_register(player, 17), FF_MEDIA_OK);
        }
        let registry = unsafe { &*player }.session.input_registry();
        let mut reader = registry.reader(17).unwrap();
        let worker =
            thread::spawn(move || reader.read(&mut [0; 16], &std::sync::atomic::AtomicI32::new(0)));
        let (request, source, _, offset) = receiver.recv().unwrap();
        assert_eq!((source, offset), (17, 0));
        let mut out = FfInputBuffer {
            lease: ptr::null_mut(),
            data: ptr::null_mut(),
            capacity: 0,
        };
        unsafe {
            assert_eq!(
                ff_player_input_acquire(player, request, &raw mut out),
                FF_MEDIA_OK
            );
            assert_eq!(out.capacity, 65536);
            let mut duplicate = FfInputBuffer {
                lease: ptr::null_mut(),
                data: ptr::null_mut(),
                capacity: 99,
            };
            assert_eq!(
                ff_player_input_acquire(player, request, &raw mut duplicate),
                FF_MEDIA_ERR_INVALID_ARGUMENT
            );
            assert_eq!(duplicate.capacity, 99);
            ff_player_free(player);
        }
        assert_eq!(worker.join().unwrap(), Err(-2));
        unsafe {
            *out.data = 42;
            assert_eq!(ff_input_commit(out.lease, 1, -1, 0), FF_MEDIA_OK);
        }
    }
    #[test]
    fn null_input_handles_are_rejected() {
        unsafe {
            assert_eq!(
                ff_player_input_register(ptr::null_mut(), 7),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(
                ff_player_input_acquire(ptr::null_mut(), 7, ptr::null_mut()),
                FF_MEDIA_ERR_NULL_HANDLE
            );
            assert_eq!(ff_input_release(ptr::null_mut()), FF_MEDIA_ERR_NULL_HANDLE);
        }
    }
}
