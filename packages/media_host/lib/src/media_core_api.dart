/// The stable result codes of the C ABI, mirrored one-for-one from
/// `schemas/media_core.h`. `tooling/check_contracts.py` checks the header and the
/// Rust implementation against each other; this list is the Dart view of the
/// same contract.
abstract final class MediaCoreCode {
  /// The call succeeded. A rejected *command* is still a success at this level:
  /// it arrives as a `result` message with `status: rejected`.
  static const int ok = 0;
  static const int nullHandle = 1;
  static const int invalidArgument = 2;
  static const int malformedMessage = 3;
  static const int unsupported = 4;
  static const int timeout = 5;
  static const int internal = 6;

  /// A stable diagnostic code for a transport-level failure.
  static String name(int code) => switch (code) {
    ok => 'media.ok',
    nullHandle => 'media.nullHandle',
    invalidArgument => 'media.invalidArgument',
    malformedMessage => 'media.malformedMessage',
    unsupported => 'media.unsupported',
    timeout => 'media.timeout',
    internal => 'media.internal',
    _ => 'media.unknownCode',
  };
}

/// A transport-level failure: the command was not applied and may be retried as
/// a whole, unlike a rejection, which the session already considered.
final class MediaCoreException implements Exception {
  const MediaCoreException(this.code, {this.detail});

  /// One of the [MediaCoreCode] values.
  final int code;

  /// Optional, payload-free context for diagnostics.
  final String? detail;

  /// The stable diagnostic code, e.g. `media.timeout`.
  String get diagnosticCode => MediaCoreCode.name(code);

  /// Whether waiting and resubmitting the same command could succeed.
  bool get isRetryable =>
      code == MediaCoreCode.timeout || code == MediaCoreCode.internal;

  @override
  String toString() =>
      'MediaCoreException($diagnosticCode'
      '${detail == null ? '' : ': $detail'})';
}

/// What a session-side restore did (docs/design/restore.md, issue 8).
///
/// The status is separate from the transport result: a corrupt record is a
/// *successful* call that restored nothing, so a host can tell it apart from a
/// missing record or a live queue it deliberately left alone.
enum RestoreStatus {
  /// A record was found and the queue was rebuilt.
  restored,

  /// There was no record for this account.
  noCheckpoint,

  /// A record existed but could not be trusted (including a v1 file).
  invalidCheckpoint,

  /// The session already held a queue, so the record was not applied.
  liveQueuePresent,

  /// A code this build does not know.
  unknown;

  /// Maps the ABI's numeric status onto this enum.
  static RestoreStatus fromCode(int code) => switch (code) {
    0 => restored,
    1 => noCheckpoint,
    2 => invalidCheckpoint,
    3 => liveQueuePresent,
    _ => unknown,
  };
}

/// The control surface of the native media session.
///
/// Every method exchanges schema JSON with the library, so this interface is also
/// how a test drives the host without a dylib: `FakeMediaCoreApi` records the
/// envelopes and replays canned snapshots.
abstract interface class MediaCoreApi {
  /// ABI version the library reports.
  int get abiVersion;

  /// Capabilities document (`capabilities_json`), already decoded.
  Map<String, Object?> capabilities();

  /// Registers the event destination. Every event buffer is owned by the sink,
  /// so the implementation copies the bytes and releases them.
  void setEventSink(void Function(String message)? sink);

  /// Registers a subscriber; returns the raw attachment JSON
  /// (`{connectionId, baseline}`).
  String attach(String clientId);

  /// Drops one subscriber. Idempotent.
  void detach(String connectionId);

  /// Latest snapshot, as schema JSON.
  String snapshot();

  /// Bounded diagnostics, as JSON (docs/design/diagnostics.md).
  String diagnostics();

  /// Submits one command envelope and returns the `result` message as JSON.
  ///
  /// Throws [MediaCoreException] for a transport failure; a command the session
  /// refused comes back as a normal result with `status: rejected`.
  String execute(String command, {int timeoutMs = 2000});

  /// Points the session-side restore record writer at `directory` for `account`
  /// (docs/design/restore.md).
  ///
  /// The session owns the queue, the order it plays and the position, so it is
  /// the single writer of that file: it writes `playback-<account>.json` in the
  /// shape `packages/local_data` reads. An empty [directory] stops writing
  /// *without* removing the record; an empty [account] files under `guest`. Use
  /// [deleteCheckpoint] to remove a record deliberately.
  void configureCheckpoint({
    required String directory,
    required String account,
  });

  /// Removes [directory]'s record for [account], deliberately (docs/design/restore.md).
  ///
  /// Separate from [configureCheckpoint] on purpose: an account switch stops
  /// writing for the old account but keeps the queue it might come back to.
  void deleteCheckpoint({required String directory, required String account});

  /// Forces the current state to disk, bypassing the position throttle (docs/design/restore.md).
  ///
  /// Used before an account switch and on shutdown, so the last position is saved
  /// even when it moved by less than the periodic step.
  void flushCheckpoint();

  /// Rebuilds the session's queue from the record [directory] holds for [account]
  /// (docs/design/restore.md).
  ///
  /// The session owns the queue, the order it plays and the position, so it is
  /// also the one component that can put them back without a client replaying a
  /// command. The restored queue is paused and its sources are absent, so the
  /// session asks the host to resolve the current item over the ordinary
  /// `sourceRequest` path. A session that already holds a queue is left alone, and
  /// a record that is missing or unreadable restores nothing; the returned
  /// [RestoreStatus] says which of those happened (issue 8).
  RestoreStatus restoreCheckpoint({
    required String directory,
    required String account,
  });

  /// Clears the event sink, stops playback and releases the handle. No callback
  /// runs afterwards.
  void close();
}

/// Hosts with asynchronous data-plane shutdown must drain it before freeing
/// the native player. The synchronous surface remains available to older hosts.
abstract interface class AsyncMediaCoreApi {
  Future<void> closeAsync();
}
