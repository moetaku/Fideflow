import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';

export 'package:fideflow_local_data/local_data.dart'
    show RecentKind, RecentPlaybackEntry;

final class RecentPlaybackController {
  RecentPlaybackController(this.store);
  final RecentPlaybackStore store;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  Map<RecentKind, List<RecentPlaybackEntry>> entries = {};
  String? error;
  bool loading = false;
  bool _disposed = false;
  Future<void> _tail = Future.value();
  Future<void>? _closeFuture;
  int _pending = 0;
  Future<void> _enqueue(Future<void> Function() operation) {
    if (_closeFuture != null) return Future.value();
    final previous = _pending == 0 ? null : _tail;
    ++_pending;
    final result = _perform(previous, operation);
    _tail = result;
    return result;
  }

  Future<void> _perform(
    Future<void>? previous,
    Future<void> Function() operation,
  ) async {
    if (previous != null) await previous;
    try {
      if (_disposed) return;
      await operation();
      error = null;
    } catch (_) {
      error = UiMessages.couldNotReadOrWriteLocalPlaybackHistory;
    } finally {
      --_pending;
      if (!_disposed) _changes.add(null);
    }
  }

  Future<void> _read() async {
    final next = <RecentKind, List<RecentPlaybackEntry>>{};
    for (final k in RecentKind.values) {
      next[k] = await store.read(k);
    }
    entries = next;
  }

  Future<void> load() => _enqueue(() async {
    loading = true;
    _changes.add(null);
    try {
      await _read();
    } finally {
      loading = false;
    }
  });
  Future<void> record(List<RecentPlaybackEntry> rows) => _enqueue(() async {
    await store.record(rows);
    await _read();
  });
  Future<void> updateTrackDetails(Track track) => _enqueue(() async {
    final rows = entries[RecentKind.song] ?? const <RecentPlaybackEntry>[];
    final previous = rows
        .where((e) => e.id == recentPlaybackId(RecentKind.song, track.id.value))
        .firstOrNull;
    if (previous == null) return;
    await store.record([RecentPlaybackEntry.song(track, previous.playedAt)]);
    await _read();
  });

  /// Enrich legacy history from metadata already available locally, preserving
  /// playback time and retaining known privacy when a summary omits it.
  Future<void> updatePlaylistDetails(List<PlaylistSummary> summaries) =>
      _enqueue(() async {
        final known = {
          for (final summary in summaries)
            recentPlaybackId(RecentKind.playlist, summary.id.value): summary,
        };
        final rows = await store.read(RecentKind.playlist);
        final updates = <RecentPlaybackEntry>[];
        for (final row in rows) {
          final previous = row.playlist;
          final next = known[row.id];
          if (previous == null || next == null) continue;
          final privacy = next.privacy ?? previous.privacy;
          final creator = next.creatorId ?? previous.creatorId;
          final special = next.specialType ?? previous.specialType;
          if (privacy == previous.privacy &&
              creator == previous.creatorId &&
              special == previous.specialType) {
            continue;
          }
          updates.add(
            RecentPlaybackEntry.fromPlaylist(
              PlaylistSummary(
                id: previous.id,
                title: previous.title,
                subtitle: previous.subtitle,
                trackCount: previous.trackCount,
                artworkUri: previous.artworkUri,
                description: previous.description,
                header: previous.header,
                creatorNickname: previous.creatorNickname,
                playCount: previous.playCount,
                recommendationText: previous.recommendationText,
                creatorId: creator,
                privacy: privacy,
                specialType: special,
              ),
              row.playedAt,
            ),
          );
        }
        if (updates.isEmpty) return;
        await store.record(updates);
        await _read();
      });
  Future<void> delete(RecentKind kind, List<String> ids) => _enqueue(() async {
    await store.delete(kind, ids);
    await _read();
  });
  Future<void> clear(RecentKind kind) => _enqueue(() async {
    await store.clear(kind);
    await _read();
  });
  Future<void> dispose() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_pending > 0) await _tail;
    _disposed = true;
    await store.close();
    unawaited(_changes.close());
  }
}
