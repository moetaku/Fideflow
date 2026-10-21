import 'playback_checkpoint.dart';

/// Where a checkpoint is kept, keyed by account.
///
/// The account is part of every call rather than an implementation detail: the
/// same store serves a signed-out launch (`guest`) and a signed-in one without
/// ever reading another account's queue, which is what "account switching
/// isolates the data" means at this boundary.
abstract interface class PlaybackCheckpointStore {
  /// The checkpoint stored for [account], or null when there is none.
  Future<PlaybackCheckpoint?> read(String account);

  /// Stores [PlaybackCheckpoint] under its own `accountId`.
  Future<void> write(PlaybackCheckpoint checkpoint);

  /// Drops [account]'s checkpoint, so a cleared queue is not restored.
  Future<void> clear(String account);
}

/// A store that keeps checkpoints in memory only.
///
/// For tests and for the fake backend, where a restart is a new process anyway.
final class InMemoryPlaybackCheckpointStore implements PlaybackCheckpointStore {
  final Map<String, PlaybackCheckpoint> _byAccount = {};

  @override
  Future<PlaybackCheckpoint?> read(String account) async => _byAccount[account];

  @override
  Future<void> write(PlaybackCheckpoint checkpoint) async {
    _byAccount[checkpoint.accountId] = checkpoint;
  }

  @override
  Future<void> clear(String account) async {
    _byAccount.remove(account);
  }
}
