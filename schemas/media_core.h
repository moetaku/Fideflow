#ifndef FIDEFLOW_MEDIA_CORE_H
#define FIDEFLOW_MEDIA_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FF_MEDIA_CORE_ABI_VERSION 3u

/* Stable result codes. Zero is success; anything else is an error the caller
 * must not interpret as a rejection of the command it sent. A command the
 * session refused arrives as a `result` message with `"status":"rejected"` and
 * an `errorCode`, which is a *successful* call. */
#define FF_MEDIA_OK 0u
#define FF_MEDIA_ERR_NULL_HANDLE 1u
#define FF_MEDIA_ERR_INVALID_ARGUMENT 2u
#define FF_MEDIA_ERR_MALFORMED_MESSAGE 3u
#define FF_MEDIA_ERR_UNSUPPORTED 4u
#define FF_MEDIA_ERR_TIMEOUT 5u
#define FF_MEDIA_ERR_INTERNAL 6u

/* Argument limits, mirrored by the constants in
 * native/media_core/crates/media-ffi/src/lib.rs. */
#define FF_MEDIA_MAX_COMMAND_BYTES (1u << 20)
#define FF_MEDIA_MAX_ID_BYTES 128u

typedef struct ff_player ff_player_t;
typedef struct ff_input_lease ff_input_lease_t;
/* Notifications are asynchronous ID-only messages, dispatched from the decoder
 * thread. Do not reenter this ABI from the callback. offset=-1 requests length, -2 closes a reader, -3 resets it for seek.
 * Unregister is a callback barrier; queued host notifications must be discarded.
 * reader identifies an AVIO instance; request identifies a unique read generation. */
typedef void (*ff_input_sink_t)(uint64_t request, uint64_t source, uint64_t reader, int64_t offset, void *user);
typedef struct ff_input_buffer { ff_input_lease_t *lease; uint8_t *data; size_t capacity; } ff_input_buffer_t;
uint32_t ff_player_input_set_sink(ff_player_t *player, ff_input_sink_t sink, void *user);
uint32_t ff_player_input_register(ff_player_t *player, uint64_t source);
uint32_t ff_player_input_revoke(ff_player_t *player, uint64_t source);
/* Acquire once; may fail after cancellation. At most 64 KiB per lease, four retained blocks per reader.
 * Total native pool 1 MiB (inside the 8 MiB host input budget).
 * Write before commit; no access after commit/release. These consume the lease
 * even on invalid length/status. Outstanding leases may outlive player_free.
 * status: 0=data/length, 1=EOF, 2=cancelled, 3=I/O error, 4=timeout. total=-1 unknown. */
uint32_t ff_player_input_acquire(ff_player_t *player, uint64_t request, ff_input_buffer_t *out);
uint32_t ff_input_commit(ff_input_lease_t *lease, size_t len, int64_t total, uint32_t status);
uint32_t ff_input_release(ff_input_lease_t *lease);

/* Owned UTF-8 JSON bytes. Release exactly once with ff_owned_bytes_free. */
typedef struct ff_owned_bytes {
  uint8_t *data;
  size_t len;
} ff_owned_bytes_t;

typedef enum ff_playback_state {
  FF_PLAYBACK_IDLE = 0,
  FF_PLAYBACK_READY = 1,
  FF_PLAYBACK_PLAYING = 2,
  FF_PLAYBACK_PAUSED = 3,
  FF_PLAYBACK_ERROR = 4
} ff_playback_state_t;

/*
 * Event sink. The session calls it from its own publisher thread with a complete
 * UTF-8 JSON event (`{"kind":"snapshot", ...}`).
 *
 * The bytes are OWNED by the sink: the host must release them with
 * ff_owned_bytes_free exactly once. Ownership is transferred rather than
 * borrowed because a host may legitimately hand the pointer to another thread or
 * to a deferred dispatch (a Dart NativeCallable.listener runs on the isolate's
 * event loop, after this call has returned), and the buffer stays valid until
 * then.
 *
 * The sink must not call back into this ABI. It stays registered until it is
 * cleared or the player is freed, so the function and its `user` context must
 * outlive that. A host that never frees the buffer leaks it; a host that frees
 * it twice breaks the allocator, exactly like any other owned buffer here.
 */
typedef void (*ff_event_sink_t)(uint8_t *json, size_t len, void *user);

uint32_t ff_media_core_abi_version(void);
/* Capabilities as JSON: abiVersion, controlTransport, idempotency window,
 * buffer watermarks, output format and the selected resampler engine. */
ff_owned_bytes_t ff_media_core_capabilities_json(void);
void ff_owned_bytes_free(ff_owned_bytes_t bytes);

/*
 * Handles are not bound to a thread: any thread may call the functions below,
 * and the session serialises them internally. Allocation and release are paired
 * and must happen exactly once per handle.
 *
 * No Rust panic crosses this boundary. Every call below catches one and returns
 * FF_MEDIA_ERR_INTERNAL; on a failure the out-parameter is left untouched and
 * must not be read.
 */
ff_player_t *ff_player_new(void);
/* Clears the event sink, stops output, joins the session's threads and frees the
 * handle, so no callback can run after this returns. */
void ff_player_free(ff_player_t *player);

/* Registers (or clears, with a null sink) the event destination. */
uint32_t ff_player_set_event_sink(ff_player_t *player, ff_event_sink_t sink, void *user);

/* Coarse state for hosts that only need to render a transport icon. A null
 * handle reads as FF_PLAYBACK_ERROR. */
uint32_t ff_player_state(const ff_player_t *player);

/*
 * Registers a subscriber and returns `{"connectionId":"...","baseline":{...}}`
 * as owned bytes. Registration and the baseline snapshot happen atomically
 * inside the session, so no event can be missed between the two.
 */
uint32_t ff_player_attach(ff_player_t *player, const uint8_t *client_id, size_t client_id_len,
                          ff_owned_bytes_t *out);
/* Drops one subscriber; playback is not affected. An unknown connection id is an
 * idempotent success. */
uint32_t ff_player_detach(ff_player_t *player, const uint8_t *connection_id,
                          size_t connection_id_len);

/*
 * Configures the session-side restore record writer (docs/design/restore.md).
 *
 * The session owns the queue, the order it plays and the position, so it is also
 * the single writer of the restore record: it writes the checkpoint for
 * `account` into `directory` as playback-<account>.json. That file is the same
 * shape packages/local_data reads (schemaVersion 2: accountId, mode, shuffleSeed,
 * currentItemId, positionMs, volume and the ordered `items` of entry identities
 * and track ids), so a host re-resolves those ids on the next launch. No URL,
 * header or credential is written.
 *
 * An empty directory stops writing *without* removing the record, and an empty
 * account files under `guest`. Use ff_player_delete_checkpoint to remove a record
 * deliberately. Configuring the writer never starts playback.
 */
uint32_t ff_player_configure_checkpoint(ff_player_t *player, const uint8_t *directory,
                                        size_t directory_len, const uint8_t *account,
                                        size_t account_len);

/*
 * Rebuilds the session's queue from the restore record it holds (docs/design/restore.md).
 *
 * The session owns the queue, the order it plays and the position, so it is also
 * the one component that can put them back without a client replaying commands:
 * this reads `directory`'s playback-<account>.json and rebuilds them. The restored
 * queue is paused and its sources are absent, so the session asks the host to
 * resolve the current item over the ordinary sourceRequest path (docs/design/provider.md). A
 * session that already holds a queue is left alone, because a live session wins
 * over a file, and a record that is missing or unreadable restores nothing.
 *
 * Whether a queue came back is visible in the snapshot an attach returns.
 *
 * When `out_status` is non-null it receives one of the FF_RESTORE_* values, so a
 * host can tell a missing record from a corrupt one (including a v1 record, which
 * this build does not migrate) and from a live queue that was left alone.
 */
uint32_t ff_player_restore_checkpoint(ff_player_t *player, const uint8_t *directory,
                                      size_t directory_len, const uint8_t *account,
                                      size_t account_len, uint32_t *out_status);

/* Restore outcomes reported through ff_player_restore_checkpoint's out_status. */
#define FF_RESTORE_RESTORED 0u
#define FF_RESTORE_NO_CHECKPOINT 1u
#define FF_RESTORE_INVALID_CHECKPOINT 2u
#define FF_RESTORE_LIVE_QUEUE_PRESENT 3u

/* Removes `directory`'s record for `account`, deliberately. Separate from
 * ff_player_configure_checkpoint: stopping the writer with an empty directory
 * keeps the record, so an account switch does not delete the old account's queue. */
uint32_t ff_player_delete_checkpoint(ff_player_t *player, const uint8_t *directory,
                                     size_t directory_len, const uint8_t *account,
                                     size_t account_len);

/* Forces the current state to disk, bypassing the position throttle. Used before
 * an account switch and on shutdown, so the last position is saved even when it
 * moved by less than the periodic step. */
uint32_t ff_player_flush_checkpoint(ff_player_t *player);

/* Latest snapshot as owned bytes. */
uint32_t ff_player_snapshot(ff_player_t *player, ff_owned_bytes_t *out);

/* Bounded playback diagnostics as owned bytes (docs/design/diagnostics.md): counters, formats, the
 * device name and stable codes only. No paths, titles, credentials or media
 * URLs. */
uint32_t ff_player_diagnostics(ff_player_t *player, ff_owned_bytes_t *out);

/*
 * Submits one command envelope (schema: schemas/media-control.v1.schema.json) and
 * returns the operation result as owned bytes. `accepted` means the control
 * plane accepted the command, not that audio started.
 *
 * `timeout_ms` bounds the wait for the session executor; `0` means the call
 * never blocks. The deadline covers the executor lock only - planning never
 * waits for a source, the decoder or the audio device - so a FF_MEDIA_ERR_TIMEOUT
 * means the command was not submitted at all, never "outcome unknown".
 *
 * Argument failures are reported precisely:
 *   FF_MEDIA_ERR_INVALID_ARGUMENT  null, empty, non-UTF-8, or an id longer than
 *                                  FF_MEDIA_MAX_ID_BYTES
 *   FF_MEDIA_ERR_UNSUPPORTED       longer than FF_MEDIA_MAX_COMMAND_BYTES
 *   FF_MEDIA_ERR_MALFORMED_MESSAGE valid UTF-8 that is not a JSON object
 * A JSON object that violates the schema is *not* an error code: the session
 * answers with a `result` whose `status` is `rejected`.
 */
uint32_t ff_player_execute(ff_player_t *player, const uint8_t *json, size_t len,
                           uint32_t timeout_ms, ff_owned_bytes_t *out);

/* Additive ABI 3 capability: capabilities_json.ncmHost.schemaVersion == 1.
 * Requests/completions follow ncm-host.v1.schema.json. Sink buffers are owned
 * by the receiver and released with ff_owned_bytes_free. No callback reentry.
 * Clear/free waits for active callbacks; cancelled requests emit no completion. */
typedef struct FfNcmHost ff_ncm_host_t;
uint32_t ff_ncm_host_new(ff_ncm_host_t **out);
uint32_t ff_ncm_host_submit(ff_ncm_host_t *host, const uint8_t *json, size_t len);
uint32_t ff_ncm_host_cancel(ff_ncm_host_t *host, const uint8_t *id, size_t len);
uint32_t ff_ncm_host_set_event_sink(ff_ncm_host_t *host, ff_event_sink_t sink, void *user);
uint64_t ff_ncm_host_deliveries(const ff_ncm_host_t *host);
void ff_ncm_host_free(ff_ncm_host_t *host);

#ifdef __cplusplus
}
#endif

#endif
