import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'browse_and_play_controller.dart';

/// Uniquely identifies a member entry in a displayed playlist or table,
/// preventing row collision when duplicate tracks appear in the same list.
final class PlaybackMemberKey {
  const PlaybackMemberKey({required this.trackId, required this.ordinal});

  final TrackId trackId;
  final int ordinal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackMemberKey &&
          other.trackId == trackId &&
          other.ordinal == ordinal;

  @override
  int get hashCode => Object.hash(trackId, ordinal);

  @override
  String toString() => '${trackId.value}:$ordinal';
}

/// Frozen view of a playback selection from a playlist or list view.
final class PlaybackSelection {
  const PlaybackSelection({
    required this.memberKey,
    required this.track,
    required this.displayedOrder,
  });

  final PlaybackMemberKey memberKey;
  final Track track;
  final List<Track> displayedOrder;
}

/// Coordinates playback intent across pages and navigation routes.
/// Resolves concurrency, maintains application-level queue incarnation,
/// serializes queue additions, and manages insertion anchors for consecutive "play next" actions.
final class PlaybackIntentCoordinator {
  PlaybackIntentCoordinator({required this.player});

  final BrowseAndPlayController player;

  int _queueIncarnation = 0;
  int get queueIncarnation => _queueIncarnation;

  int _replaceSeq = 0;
  Future<void> _lastQueueOp = Future.value();
  String? _lastPlayNextAnchorId;
  String? get lastPlayNextAnchorId => _lastPlayNextAnchorId;

  /// Replaces the playback queue with [tracks] starting at [startIndex].
  /// Cancels / ignores earlier in-flight replace operations.
  Future<CommandResult> replaceQueue({
    required List<Track> tracks,
    int startIndex = 0,
    AudioQuality? quality,
    int? seed,
  }) async {
    final seq = ++_replaceSeq;
    _queueIncarnation++;
    _lastPlayNextAnchorId = null;

    final result = await player.playTracks(
      tracks,
      startIndex: startIndex,
      quality: quality,
      seed: seed,
    );
    if (seq != _replaceSeq) {
      return const CommandResult.rejected('playback.cancelled');
    }
    return result;
  }

  /// Plays a single track as a fresh 1-item queue.
  Future<CommandResult> playSingleTrack(
    Track track, {
    AudioQuality? quality,
  }) async {
    final seq = ++_replaceSeq;
    _queueIncarnation++;
    _lastPlayNextAnchorId = null;

    final result = await player.playSingleTrack(track, quality: quality);
    if (seq != _replaceSeq) {
      return const CommandResult.rejected('playback.cancelled');
    }
    return result;
  }

  /// Selects a specific queue item in the active queue.
  Future<void> playItem(int index) {
    _replaceSeq++;
    return player.playQueueItem(index);
  }

  /// Appends tracks to the queue. Serialized behind previous operations.
  Future<void> appendTracks(List<Track> tracks) {
    _lastQueueOp = _lastQueueOp.then((_) async {
      await player.addTracksToQueue(tracks);
    });
    return _lastQueueOp;
  }

  /// Inserts [tracks] to play next. If consecutive calls are made, maintains
  /// the insertion tail anchor so A then B play in sequence A, then B.
  Future<void> playNextTracks(List<Track> tracks) {
    _lastQueueOp = _lastQueueOp.then((_) async {
      await player.playNextTracks(tracks);
      if (tracks.isNotEmpty) {
        _lastPlayNextAnchorId = tracks.last.id.value;
      }
    });
    return _lastQueueOp;
  }
}
