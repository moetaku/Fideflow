import 'dart:async';
import 'dart:convert';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'playback_cache.dart';
import 'playback_permissions.dart';

/// Complete the current track, then select upcoming entries in effective order.
List<Track> precacheTracks(PlaybackSnapshot snapshot, int count) {
  final current = snapshot.currentIndex;
  if (current == null || current < 0 || current >= snapshot.queue.length) {
    return const [];
  }
  final queue = snapshot.queue;
  final indexes = count == 0
      ? [
          ...List.generate(queue.length - current, (i) => current + i),
          ...List.generate(current, (i) => i),
        ]
      : [
          for (var i = current + 1; i < queue.length; i++) i,
          if (snapshot.mode != PlaybackMode.sequential &&
              !snapshot.isIntelligenceMode)
            for (var i = 0; i < current; i++) i,
        ].take(count).toList();
  final seen = <TrackId>{};
  return [
    if (seen.add(queue[current].id)) queue[current],
    for (final index in indexes)
      if (seen.add(queue[index].id)) queue[index],
  ];
}

final class AudioPrecacheCoordinator {
  AudioPrecacheCoordinator({
    required this.media,
    required this.quality,
    required this.resolver,
    required this.cache,
    required this.permissions,
  });
  final MediaController media;
  final QualityController quality;
  final CachedAudioResolver resolver;
  final PlaybackCache cache;
  final PlaybackPermissions permissions;
  PlaybackConnection? _connection;
  StreamSubscription<PlaybackSnapshot>? _snapshots;
  StreamSubscription<QualityState>? _qualities;
  PlaybackSnapshot? _snapshot;
  Timer? _timer;
  Future<void>? _running;
  String? _signature;
  String? _attemptSignature;
  final Set<String> _attempted = {};
  final Set<String> _clearedTracks = {};
  int _seekEpoch = 0;
  int _revision = 0;
  int _seekCheck = 0;
  int _clearEpoch = 0;
  bool _disposed = false;

  Future<void> initialize() async {
    await resolver.initialize();
    if (_disposed || _connection != null) return;
    _clearEpoch = cache.clearEpoch;
    _seekEpoch = resolver.foregroundSeekEpoch;
    cache.addListener(_changed);
    permissions.addListener(_changed);
    resolver.onAudioActivity = _activity;
    _qualities = quality.states.listen((_) => _changed());
    final connection = await media.attach();
    if (_disposed) {
      await media.detach(connection.id);
      return;
    }
    _connection = connection;
    _snapshots = connection.snapshots.listen((snapshot) {
      final previous = _snapshot;
      final moved =
          previous != null &&
          previous.currentTrack?.id == snapshot.currentTrack?.id &&
          ((snapshot.isSeeking &&
                  (!previous.isSeeking ||
                      snapshot.position != previous.position)) ||
              (snapshot.position - previous.position).abs() >
                  const Duration(seconds: 1));
      _snapshot = snapshot;
      _changed();
      if (moved) {
        final current = snapshot.currentTrack?.id.value;
        if (current != null && !_clearedTracks.contains(current)) {
          _attempted.remove(current);
        }
        unawaited(_reprioritize(snapshot));
      }
    });
    _snapshot = connection.baseline;
    _changed();
  }

  Future<void> _reprioritize(PlaybackSnapshot snapshot) async {
    final check = ++_seekCheck;
    final revision = _revision;
    final track = snapshot.currentTrack;
    final duration = snapshot.duration ?? track?.duration;
    final retained =
        track != null &&
        await resolver.precacheMatchesPlayback(
          track.id,
          snapshot.quality?.level ?? quality.preference,
          duration != null && duration > Duration.zero
              ? snapshot.position.inMicroseconds / duration.inMicroseconds
              : null,
        );
    if (_disposed || check != _seekCheck || revision != _revision) return;
    if (!retained) {
      _revision++;
      resolver.cancelPrecache();
      _timer?.cancel();
      _timer = null;
    }
    _schedule();
  }

  void _changed() {
    if (_disposed || _snapshot == null) return;
    final snapshot = _snapshot!;
    final attemptSignature = jsonEncode([
      snapshot.sessionId,
      snapshot.queueRevision,
      snapshot.currentIndex,
      snapshot.mode.name,
      snapshot.intelligenceSessionId,
      snapshot.projectionVersion,
      quality.preference.name,
      resolver.account(),
      resolver.epoch(),
      permissions.generation,
      cache.autoCacheEnabled,
      cache.limitGb,
    ]);
    final signature = jsonEncode([attemptSignature, cache.autoCacheCount]);
    if (_clearEpoch != cache.clearEpoch) {
      _clearEpoch = cache.clearEpoch;
      _revision++;
      resolver.cancelPrecache();
      _timer?.cancel();
      // A clear must not immediately refill the same queue.
      _attempted.addAll(
        precacheTracks(snapshot, cache.autoCacheCount).map((t) => t.id.value),
      );
      _clearedTracks.addAll(_attempted);
    }
    if (_signature == signature) return;
    _signature = signature;
    _revision++;
    // Changing only the range keeps completed attempts, so growing the range
    // resolves only new tracks. Source context and capacity changes allow retry.
    if (_attemptSignature != attemptSignature) {
      _attemptSignature = attemptSignature;
      _attempted.clear();
      _clearedTracks.clear();
    }
    resolver.cancelPrecache();
    _timer?.cancel();
    _timer = null;
    _schedule();
  }

  void _activity() {
    if (_disposed) return;
    if (_seekEpoch != resolver.foregroundSeekEpoch) {
      _seekEpoch = resolver.foregroundSeekEpoch;
      final current = _snapshot?.currentTrack?.id.value;
      if (current != null && !_clearedTracks.contains(current)) {
        _attempted.remove(current);
      }
    }
    _schedule();
  }

  void _schedule() {
    if (!cache.autoCacheEnabled ||
        _disposed ||
        _snapshot == null ||
        !precacheTracks(
          _snapshot!,
          cache.autoCacheCount,
        ).any((t) => !_attempted.contains(t.id.value))) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    // Keep the earliest deadline; reads arriving faster than 300 ms must not
    // postpone the task forever.
    if (_timer?.isActive == true) return;
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (_running != null || resolver.foregroundBusy) {
        _schedule();
        return;
      }
      final task = _run(_revision);
      _running = task;
      unawaited(
        task.whenComplete(() {
          _running = null;
          if (!_disposed) _schedule();
        }),
      );
    });
  }

  Future<void> _run(int revision) async {
    bool valid() =>
        !_disposed && revision == _revision && cache.autoCacheEnabled;
    for (final track in precacheTracks(_snapshot!, cache.autoCacheCount)) {
      if (!valid() || resolver.foregroundBusy) return;
      if (_attempted.contains(track.id.value)) continue;
      final epoch = resolver.backgroundEpoch;
      try {
        final current = track.id == _snapshot!.currentTrack?.id;
        final duration =
            _snapshot!.duration ?? _snapshot!.currentTrack?.duration;
        final completed = await resolver.precache(
          track.id,
          current
              ? _snapshot!.quality?.level ?? quality.preference
              : quality.preference,
          valid: valid,
          prioritizePlayback: current,
          playbackFraction:
              current && duration != null && duration > Duration.zero
              ? _snapshot!.position.inMicroseconds / duration.inMicroseconds
              : null,
        );
        if (!valid() || epoch != resolver.backgroundEpoch) return;
        _attempted.add(track.id.value);
        // Capacity/disk exhaustion ends this cycle, rather than eviction churn.
        if (!completed) {
          _attempted.addAll(
            precacheTracks(
              _snapshot!,
              cache.autoCacheCount,
            ).map((t) => t.id.value),
          );
          return;
        }
      } catch (_) {
        if (!valid() || epoch != resolver.backgroundEpoch) return;
        _attempted.add(track.id.value);
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _revision++;
    _timer?.cancel();
    resolver.onAudioActivity = null;
    resolver.cancelPrecache();
    cache.removeListener(_changed);
    permissions.removeListener(_changed);
    await _snapshots?.cancel();
    await _qualities?.cancel();
    if (_connection != null) await media.detach(_connection!.id);
    await _running;
  }
}
