import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:fideflow_domain/domain.dart';

import 'controller.dart';
import 'diagnostics.dart';
import 'models.dart';
import 'wire_codes.dart';

/// Deterministic control-plane fake. No network or audio I/O is performed.
///
/// It mirrors the native session's *observable* contract rather than its
/// implementation: `queue` is always the effective order the mode produced, a
/// jump is a position in that order, and a mode change bumps the queue revision.
/// That is what lets a page test drive the shell that the native host serves.
///
/// The queue is a list of entries addressed by index, mirroring the native
/// session's `queueItemId`s. A track queued twice is therefore two entries that
/// can be removed one at a time, and the current item is an entry index rather
/// than a track identity (docs/design/playback.md).
final class FakeMediaController
    implements MediaController, QualitySwitchableMediaController {
  final BoundedDiagnostics diagnostics = BoundedDiagnostics();
  final Map<String, StreamController<PlaybackSnapshot>> _connections = {};
  final LinkedHashMap<String, _CompletedCommand> _completed = LinkedHashMap();
  PlaybackSnapshot _current = PlaybackSnapshot.idle(
    playbackEffects: const PlaybackEffects(supported: true),
  );
  int _nextConnection = 0;
  String? _interruptionId, _lastInterruptionId;
  bool _resumeAfterInterruption = false;
  int _playIntentVersion = 0, _interruptedIntentVersion = 0;

  /// The authoritative queue, in the order it was loaded. Entries are addressed
  /// by index, so a track that is queued twice is two entries that are removed
  /// one at a time; the published order is derived from this plus the mode.
  final List<Track> _queue = [];

  /// Shuffle's permutation of `_queue` indices; empty in the other modes.
  List<int> _order = [];

  /// The seed the current shuffle order was built from, or null when the mode
  /// holds no seeded order. Published in the snapshot, so a client can persist
  /// the order it heard and restore exactly that one.
  int? _shuffleSeed;

  /// Seeds handed out so far, for an order the caller did not pin.
  int _seedCounter = 0;

  /// The level future loads resolve at, mirroring the host's own preference.
  AudioQuality _preferredQuality = AudioQuality.standard;

  /// The quality of the entry that is playing, as the fake "confirmed" it.
  ///
  /// The fake performs no I/O, so there is no gap between resolving a source and
  /// opening it: a source it was handed is confirmed immediately. That is what
  /// makes it a usable stand-in for the UI while the native host keeps the real
  /// pending/confirmed distinction.
  PlaybackQuality? _quality;

  /// Updates the shared preference and the quality of the current entry.
  ///
  /// Mirrors the native host's contract: the preference applies even when there
  /// is nothing playing, the current entry is only re-resolved when there is one,
  /// and the outcome reports the two separately.
  @override
  Future<QualitySwitchOutcome> setQuality({
    required AudioQuality preference,
  }) async {
    _preferredQuality = preference;
    if (_currentTrack == null) {
      return QualitySwitchOutcome(preferenceApplied: true);
    }
    if (_current.status == PlaybackStatus.paused) {
      return const QualitySwitchOutcome(preferenceApplied: true);
    }
    _quality = PlaybackQuality(level: preference, confirmed: true);
    _publish();
    return QualitySwitchOutcome(
      preferenceApplied: true,
      currentSwitchStarted: _current.status != PlaybackStatus.paused,
    );
  }

  /// The level this controller resolves later loads at.
  AudioQuality get preferredQuality => _preferredQuality;

  /// Index into `_queue` of the item that is playing, or null.
  int? _index;

  @override
  Future<PlaybackConnection> attach() async {
    final id = 'fake-connection-${++_nextConnection}';
    // Single-subscription streams retain events emitted before the first listen.
    final events = StreamController<PlaybackSnapshot>();
    _connections[id] = events;
    return PlaybackConnection(
      id: id,
      baseline: _current,
      snapshots: events.stream,
    );
  }

  @override
  Future<void> detach(String connectionId) async {
    await _connections.remove(connectionId)?.close();
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async => _current;

  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    if (_connections.isEmpty) {
      diagnostics.record('media.notAttached', _current.sessionRevision);
      return const CommandResult.rejected('media.notAttached');
    }
    final now = DateTime.now();
    _completed.removeWhere(
      (_, entry) =>
          now.difference(entry.finishedAt) >= const Duration(minutes: 10),
    );
    final key =
        '${_current.sessionId}\u0000${command.clientId}\u0000${command.commandId}';
    final fingerprint = _fingerprint(command);
    final previous = _completed[key];
    if (previous != null) {
      if (previous.fingerprint != fingerprint) {
        diagnostics.record('command.idConflict', _current.sessionRevision);
      }
      return previous.fingerprint == fingerprint
          ? previous.result
          : const CommandResult.rejected('command.idConflict');
    }

    final result = _apply(command);
    if (result.isAccepted &&
        command is! SetInterruption &&
        switch (command) {
          Play() ||
          Pause() ||
          Stop() ||
          ClearQueue() ||
          LoadQueue() ||
          SkipNext() ||
          SkipPrevious() ||
          PlayItem() ||
          Seek() ||
          RemoveFromQueue() ||
          PlayNext() ||
          AddToQueue() ||
          RefillIntelligence() ||
          ExitIntelligence() ||
          ReportSourceFailure() => true,
          _ => false,
        }) {
      _playIntentVersion++;
    }
    if (!result.isAccepted) {
      diagnostics.record(result.errorCode!, _current.sessionRevision);
    }
    _completed[key] = _CompletedCommand(fingerprint, result, now);
    if (_completed.length > 1024) _completed.remove(_completed.keys.first);
    return result;
  }

  /// Simulates the natural end of the item that is playing.
  ///
  /// Nothing ends by itself here — the fake performs no I/O — so a test that
  /// covers "the queue carries on by itself" calls this and then sees the same
  /// mode rules the native session applies.
  void completeCurrentItem() {
    if (_queue.isEmpty) return;
    _step(_Advance.natural);
  }

  /// Simulates an item failing to open or decode, the way the native session
  /// reports it: a stable code, the queue kept, and the play intent cleared.
  void reportFailure(
    String code, {
    PlaybackFailureKind kind = PlaybackFailureKind.source,
  }) {
    _publish(
      status: PlaybackStatus.error,
      phase: WirePhase.error,
      errorCode: code,
      failureKind: kind,
      playWhenReady: _intelligenceSessionId != null && _current.playWhenReady,
    );
  }

  /// The published order of `_queue` indices: shuffle's own permutation when it
  /// covers the queue, the queue's own order otherwise.
  List<int> get _playOrder =>
      _current.mode == PlaybackMode.shuffle && _order.length == _queue.length
      ? _order
      : [for (var i = 0; i < _queue.length; i++) i];

  Track? get _currentTrack {
    final index = _index;
    return index == null || index < 0 || index >= _queue.length
        ? null
        : _queue[index];
  }

  String? _intelligenceSessionId;

  CommandResult _apply(PlaybackCommand command) {
    if (command.expectedQueueRevision != null &&
        command.expectedQueueRevision != _current.queueRevision) {
      return const CommandResult.rejected('queue.revisionConflict');
    }

    switch (command) {
      case LoadQueue(
        :final tracks,
        :final startIndex,
        :final autoplay,
        :final seed,
        :final quality,
        :final intelligenceSessionId,
      ):
        if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) {
          return const CommandResult.rejected('queue.invalid');
        }
        if (intelligenceSessionId != null && tracks.length > 50) {
          return const CommandResult.rejected('queue.invalid');
        }
        _intelligenceSessionId = intelligenceSessionId;
        // A load names the quality it wants; that is also the preference the
        // next resolution uses, exactly as the native host records it.
        _preferredQuality = quality;
        _quality = PlaybackQuality(level: quality, confirmed: true);
        _install(
          tracks,
          startIndex: startIndex,
          autoplay: autoplay,
          seed: seed,
          mode: intelligenceSessionId == null ? null : PlaybackMode.sequential,
        );
      case RefillIntelligence(
        :final sessionId,
        :final tracks,
        :final evictCount,
        :final advance,
        :final autoplay,
      ):
        if ((command.expectedSessionRevision != null &&
                command.expectedSessionRevision != _current.sessionRevision) ||
            _intelligenceSessionId != sessionId ||
            tracks.isEmpty ||
            evictCount < 0 ||
            evictCount > (_index ?? 0) ||
            _queue.length - evictCount + tracks.length > 50) {
          return const CommandResult.rejected('queue.invalid');
        }
        final firstNew = _queue.length - evictCount;
        _queue.removeRange(0, evictCount);
        if (_index != null) _index = _index! - evictCount;
        _queue.addAll(tracks);
        if (firstNew == 0 || advance) {
          _index = firstNew;
          _publish(
            queueRevision: _current.queueRevision + 1,
            position: Duration.zero,
            status: autoplay ? PlaybackStatus.playing : PlaybackStatus.paused,
            playWhenReady: autoplay,
          );
        } else {
          _publish(queueRevision: _current.queueRevision + 1);
        }
      case ExitIntelligence(:final sessionId):
        if (sessionId != _intelligenceSessionId) {
          return const CommandResult.rejected('queue.invalid');
        }
        _intelligenceSessionId = null;
        _publish(queueRevision: _current.queueRevision + 1);
      case Play():
        if (_currentTrack == null) {
          if (_intelligenceSessionId != null) {
            _publish(status: PlaybackStatus.idle, playWhenReady: true);
            return CommandResult.accepted(_current.sessionRevision);
          }
          return const CommandResult.rejected('playback.queueEmpty');
        }
        if (_current.status == PlaybackStatus.paused) {
          _quality = PlaybackQuality(level: _preferredQuality, confirmed: true);
        }
        // A new play intent is also how a failed item is retried, so it clears the
        // code the session reported for it.
        _publish(
          status: PlaybackStatus.playing,
          playWhenReady: true,
          clearError: true,
        );
      case SetInterruption(
        :final interruptionId,
        :final active,
        :final allowResume,
      ):
        if (active) {
          if (_interruptionId != null ||
              _lastInterruptionId == interruptionId) {
            return CommandResult.accepted(_current.sessionRevision);
          }
          _resumeAfterInterruption =
              _current.playWhenReady &&
              _currentTrack != null &&
              _current.errorCode == null;
          _interruptedIntentVersion = _playIntentVersion;
          _interruptionId = interruptionId;
          _publish();
        } else {
          if (_interruptionId != interruptionId) {
            return CommandResult.accepted(_current.sessionRevision);
          }
          _interruptionId = null;
          _lastInterruptionId = interruptionId;
          final resume =
              allowResume &&
              _resumeAfterInterruption &&
              _interruptedIntentVersion == _playIntentVersion &&
              _current.playWhenReady &&
              _current.errorCode == null;
          _resumeAfterInterruption = false;
          _publish(
            status: resume
                ? PlaybackStatus.playing
                : _current.status == PlaybackStatus.error
                ? PlaybackStatus.error
                : _currentTrack == null
                ? PlaybackStatus.idle
                : PlaybackStatus.paused,
            playWhenReady: resume,
          );
        }
      case Pause():
        _publish(status: PlaybackStatus.paused, playWhenReady: false);
      case SkipNext():
        if (_queue.isEmpty) {
          return const CommandResult.rejected('playback.queueEmpty');
        }
        if ((_current.mode == PlaybackMode.sequential ||
                _intelligenceSessionId != null) &&
            _index == _queue.length - 1) {
          return const CommandResult.rejected('queueBoundary');
        }
        _step(_Advance.manual);
      case SkipPrevious():
        if (_queue.isEmpty) {
          return const CommandResult.rejected('playback.queueEmpty');
        }
        if ((_current.mode == PlaybackMode.sequential ||
                _intelligenceSessionId != null) &&
            _index == 0) {
          return const CommandResult.rejected('queueBoundary');
        }
        _step(_Advance.manual, backwards: true);
      case PlayItem(:final index):
        if (_queue.isEmpty) {
          return const CommandResult.rejected('playback.queueEmpty');
        }
        if (index < 0 || index >= _queue.length) {
          return const CommandResult.rejected('queue.invalid');
        }
        // A jump does not change the queue, so the revision that describes it
        // stays where it is, exactly as the native session does.
        _index = _playOrder[index];
        _publish(
          status: PlaybackStatus.playing,
          position: Duration.zero,
          playWhenReady: true,
        );
      case PlayNext(:final tracks, :final exitIntelligence):
        if (_intelligenceSessionId != null && !exitIntelligence) {
          return const CommandResult.rejected('queue.invalid');
        }
        if (tracks.isEmpty) {
          return const CommandResult.rejected('queue.invalid');
        }
        if (exitIntelligence) _intelligenceSessionId = null;
        if (_queue.isEmpty || _index == null) {
          _install(tracks, startIndex: 0, autoplay: true);
        } else {
          _insertEntries(tracks, playNext: true);
        }
      case AddToQueue(:final tracks, :final exitIntelligence):
        if (_intelligenceSessionId != null && !exitIntelligence) {
          return const CommandResult.rejected('queue.invalid');
        }
        if (tracks.isEmpty) {
          return const CommandResult.rejected('queue.invalid');
        }
        if (exitIntelligence) _intelligenceSessionId = null;
        if (_queue.isEmpty || _index == null) {
          _install(tracks, startIndex: 0, autoplay: true);
        } else {
          _insertEntries(tracks, playNext: false);
        }
      case RemoveFromQueue(:final index):
        if (_queue.isEmpty) {
          return const CommandResult.rejected('playback.queueEmpty');
        }
        if (index < 0 || index >= _queue.length) {
          return const CommandResult.rejected('queue.invalid');
        }
        _removeEntry(_playOrder[index]);
      case SetMode(:final mode, :final seed):
        if (_intelligenceSessionId != null &&
            mode != PlaybackMode.sequential &&
            mode != PlaybackMode.repeatOne) {
          return const CommandResult.rejected('queue.invalid');
        }
        if (mode == PlaybackMode.shuffle) {
          _rebuildShuffle(seed: seed, keepFirst: _index);
        } else {
          _order = [];
          _shuffleSeed = null;
        }
        // The order a client renders changed, so the revision that describes
        // the queue changes with it, exactly as the native session does.
        _publish(mode: mode, queueRevision: _current.queueRevision + 1);
      case Seek(:final position):
        final track = _currentTrack;
        if (track == null) {
          return const CommandResult.rejected('playback.queueEmpty');
        }
        final clamped = position < Duration.zero
            ? Duration.zero
            : position > track.duration
            ? track.duration
            : position;
        _publish(position: clamped);
      case RefreshOutputDevices():
        _publish();
      case SetOutputConfiguration():
        return const CommandResult.rejected('outputUnavailable');
      case SetPlaybackEffects(
        :final fadeEnabled,
        :final volumeNormalizationEnabled,
      ):
        _publish(
          playbackEffects: PlaybackEffects(
            supported: true,
            fadeEnabled: fadeEnabled,
            volumeNormalizationEnabled: volumeNormalizationEnabled,
          ),
        );
      case SetTransientGain(:final permille):
        if (permille < 0 || permille > 1000) {
          return const CommandResult.rejected('malformedCommand');
        }
      case SetVolume(:final permille):
        // The gain touches no queue fact, so only the session revision moves —
        // exactly what the native planner does.
        _publish(volume: permille);
      case Stop():
        // The queue and the current item stay: stopping is not unloading, and a
        // later `play` restarts the item the session was on (docs/design/playback.md 6.2).
        _publish(
          status: command.permissionExpired
              ? PlaybackStatus.error
              : command.offlineGap
              ? PlaybackStatus.paused
              : PlaybackStatus.idle,
          phase: command.permissionExpired
              ? WirePhase.error
              : command.offlineGap
              ? WirePhase.paused
              : WirePhase.idle,
          position: _current.position,
          playWhenReady: false,
          errorCode: command.permissionExpired
              ? 'playback.vipExpired'
              : command.offlineGap
              ? 'playback.offlineGap'
              : null,
          clearError: !command.permissionExpired && !command.offlineGap,
        );
      case ClearQueue():
        _intelligenceSessionId = null;
        // The queue is dropped, and the revision that describes it moves: an
        // item of it can never be started again (docs/design/accounts.md).
        _queue.clear();
        _order = [];
        _shuffleSeed = null;
        _index = null;
        _quality = null;
        _publish(
          status: PlaybackStatus.idle,
          phase: WirePhase.idle,
          queueRevision: _current.queueRevision + 1,
          position: Duration.zero,
          playWhenReady: false,
          clearError: true,
        );
      case ReportSourceFailure(:final errorCode):
        if (_intelligenceSessionId == null) {
          return const CommandResult.rejected('staleGeneration');
        }
        reportFailure(errorCode);
      case ProvideSource():
        // Parity with native planner: accept provided source
        return CommandResult.accepted(_current.sessionRevision);
    }
    return CommandResult.accepted(_current.sessionRevision);
  }

  /// Replaces the queue and selects `startIndex`, the way `loadQueue` does.
  ///
  /// Also the path an edit takes when it lands on an empty queue: the entries
  /// are installed, the first is selected and playback starts (docs/design/playback.md).
  void _install(
    List<Track> tracks, {
    int startIndex = 0,
    required bool autoplay,
    int? seed,
    PlaybackMode? mode,
  }) {
    _queue
      ..clear()
      ..addAll(tracks);
    _index = startIndex;
    if ((mode ?? _current.mode) == PlaybackMode.shuffle) {
      // A seeded load lets the seed name the opener as well as the order; an
      // unseeded one still starts on the row the caller named (docs/design/playback.md).
      if (seed != null) {
        _startSeededShuffle(seed);
      } else {
        _rebuildShuffle(keepFirst: startIndex);
      }
    } else {
      _order = [];
      _shuffleSeed = null;
    }
    _publish(
      mode: mode,
      status: autoplay ? PlaybackStatus.playing : PlaybackStatus.ready,
      queueRevision: _current.queueRevision + 1,
      playWhenReady: autoplay,
      phase: WirePhase.ready,
      clearError: true,
    );
  }

  /// Adds entries to the queue, immediately after the current item or at the end.
  ///
  /// The current item never moves, so this is a queue fact only: the revision
  /// moves, the generation does not (docs/design/playback.md).
  void _insertEntries(List<Track> tracks, {required bool playNext}) {
    final current = _index!;
    final entries = List<Track>.of(tracks);
    if (_current.mode == PlaybackMode.shuffle) {
      if (_order.length != _queue.length) _rebuildShuffle(keepFirst: current);
      final insertAt = playNext ? _order.indexOf(current) + 1 : _order.length;
      final start = _queue.length;
      _queue.addAll(entries);
      _order.insertAll(insertAt, [
        for (var i = start; i < start + entries.length; i++) i,
      ]);
    } else if (playNext) {
      final position = current + 1;
      _queue.insertAll(position, entries);
    } else {
      _queue.addAll(entries);
    }
    _publish(queueRevision: _current.queueRevision + 1);
  }

  /// Drops one entry by its identity, keeping the current item where it can.
  ///
  /// Removing what is playing selects its successor by the forward rule and
  /// keeps the play intent; removing the last entry is the `clearQueue` state
  /// (docs/design/playback.md).
  void _removeEntry(int target) {
    final wasCurrent = _index == target;
    final wasPlaying = _current.playWhenReady;
    // Decided before the queue changes, by the forward rule a manual skip uses:
    // repeatOne must not repeat the entry being removed.
    final successor = wasCurrent && _queue.length > 1
        ? _successorIndex(target)
        : null;
    _queue.removeAt(target);
    _forgetIndex(target);
    if (_queue.isEmpty) {
      _index = null;
      _order = [];
      _publish(
        status: PlaybackStatus.idle,
        phase: WirePhase.idle,
        queueRevision: _current.queueRevision + 1,
        position: Duration.zero,
        playWhenReady: _intelligenceSessionId != null ? wasPlaying : false,
        clearError: true,
      );
      return;
    }
    if (wasCurrent) {
      if (successor == null) {
        _index = target > 0 ? target - 1 : null;
        _publish(
          status: PlaybackStatus.ready,
          phase: WirePhase.ended,
          queueRevision: _current.queueRevision + 1,
          position: Duration.zero,
          playWhenReady: wasPlaying,
          clearError: true,
        );
        return;
      }
      final next = successor > target ? successor - 1 : successor;
      _index = next;
      _publish(
        status: wasPlaying ? PlaybackStatus.playing : PlaybackStatus.paused,
        queueRevision: _current.queueRevision + 1,
        position: Duration.zero,
        playWhenReady: wasPlaying,
        clearError: true,
      );
      return;
    }
    _publish(queueRevision: _current.queueRevision + 1);
  }

  /// The index that follows `current` by the forward rule, before a removal.
  int? _successorIndex(int current) {
    if (_intelligenceSessionId != null ||
        _current.mode == PlaybackMode.sequential) {
      return current + 1 < _queue.length ? current + 1 : null;
    }
    if (_current.mode == PlaybackMode.shuffle) {
      final order = _playOrder;
      final position = order.indexOf(current);
      if (position >= 0 && position + 1 < order.length) {
        return order[position + 1];
      }
      // The entry is last in the permutation: wrapping restarts from its head.
      return order.firstWhere((index) => index != current);
    }
    return (current + 1) % _queue.length;
  }

  /// Adjusts the stored shuffle order, history and current index after `index`
  /// leaves `_queue`, so they keep naming the same entries.
  void _forgetIndex(int index) {
    _order = [
      for (final item in _order)
        if (item != index) (item > index ? item - 1 : item),
    ];
    if (_index != null && _index! > index) _index = _index! - 1;
  }

  /// Moves one item, by the current mode's rules.
  void _step(_Advance reason, {bool backwards = false}) {
    if (_queue.isEmpty || _index == null) return;
    final current = _index!;

    // Repeating is about how an item *ends*: a manual skip still walks the queue.
    if (reason == _Advance.natural && _current.mode == PlaybackMode.repeatOne) {
      _restart(current);
      return;
    }
    if (_current.mode == PlaybackMode.shuffle) {
      final order = _playOrder;
      // Adjacent navigation through the published list (docs/design/boundaries.md): previous is the
      // entry before the current one, not the last one visited. Both ends wrap and
      // the permutation is kept as it is (issue 12).
      if (order.length <= 1) {
        _restart(current);
        return;
      }
      final position = order.indexOf(current);
      final target = backwards
          ? order[(position - 1 + order.length) % order.length]
          : order[(position + 1) % order.length];
      _restart(target);
      return;
    }
    if (_current.mode == PlaybackMode.sequential ||
        _intelligenceSessionId != null) {
      final next = current + (backwards ? -1 : 1);
      if (next < 0 || next >= _queue.length) {
        if (reason == _Advance.natural) {
          _publish(
            status: PlaybackStatus.ready,
            phase: WirePhase.ended,
            position: _currentTrack?.duration,
          );
        }
        return;
      }
      final intent = _current.playWhenReady;
      _index = next;
      _publish(
        status: intent ? PlaybackStatus.playing : PlaybackStatus.paused,
        position: Duration.zero,
        playWhenReady: intent,
      );
      return;
    }
    final next = backwards
        ? (current - 1 + _queue.length) % _queue.length
        : (current + 1) % _queue.length;
    _restart(next);
  }

  /// Replays one item of the queue from its start.
  void _restart(int index) {
    _index = index;
    _publish(
      status: PlaybackStatus.playing,
      position: Duration.zero,
      playWhenReady: true,
    );
  }

  /// Builds the shuffled order: the item at `keepFirst` first, the rest permuted.
  ///
  /// [pinCurrent] is what a seeded load turns off: nothing is pinned then, so the
  /// seed decides the whole permutation instead of this client deciding its head.
  void _rebuildShuffle({int? seed, int? keepFirst, bool pinCurrent = true}) {
    final resolved = seed ?? _nextShuffleSeed();
    _shuffleSeed = resolved;
    final first = pinCurrent ? (keepFirst ?? _index) : null;
    final rest = [
      for (var i = 0; i < _queue.length; i++)
        if (i != first) i,
    ]..shuffle(Random(resolved));
    _order = [
      if (first != null && first >= 0 && first < _queue.length) first,
      ...rest,
    ];
  }

  /// Builds a shuffle order for `seed` over the whole queue and selects its head.
  ///
  /// The mirror of the native `loadQueue` with a seed: the same seed replays the
  /// same order and the same first track, with the session as the only owner of
  /// that decision (docs/design/playback.md).
  void _startSeededShuffle(int seed) {
    _rebuildShuffle(seed: seed, pinCurrent: false);
    _index = _order.isEmpty ? null : _order.first;
  }

  /// A fresh seed for an order the caller did not pin, mirroring the session
  /// deriving one rather than asking the caller for something it does not know.
  int _nextShuffleSeed() => ++_seedCounter;

  String _fingerprint(PlaybackCommand command) => switch (command) {
    LoadQueue(:final tracks, :final startIndex, :final autoplay, :final seed) =>
      jsonEncode({
        'kind': 'loadQueue',
        'tracks': _tracksFingerprint(tracks),
        'startIndex': startIndex,
        'autoplay': autoplay,
        'seed': seed,
        'quality': command.quality.name,
        'intelligenceSessionId': command.intelligenceSessionId,
        'expectedQueueRevision': command.expectedQueueRevision,
      }),
    RefillIntelligence() =>
      'refill:${command.sessionId}:${command.evictCount}:${command.advance}:${command.autoplay}:${command.expectedSessionRevision}:${jsonEncode(_tracksFingerprint(command.tracks))}:${command.expectedQueueRevision}',
    ExitIntelligence() =>
      'exit:${command.sessionId}:${command.expectedQueueRevision}',
    ReportSourceFailure() =>
      'sourceFailed:${command.targetQueueItemId}:${command.expectedGeneration}:${command.errorCode}',
    Play() => 'play',
    Pause() => 'pause',
    SetInterruption() =>
      'interruption:${command.interruptionId}:${command.active}:${command.allowResume}',
    SkipNext() => 'next:${command.expectedQueueRevision}',
    SkipPrevious() => 'previous:${command.expectedQueueRevision}',
    PlayItem(:final index) => 'item:$index:${command.expectedQueueRevision}',
    PlayNext(:final tracks) =>
      'playNext:${command.exitIntelligence}:${jsonEncode(_tracksFingerprint(tracks))}'
          ':${command.expectedQueueRevision}',
    AddToQueue(:final tracks) =>
      'append:${command.exitIntelligence}:${jsonEncode(_tracksFingerprint(tracks))}'
          ':${command.expectedQueueRevision}',
    RemoveFromQueue(:final index) =>
      'remove:$index:${command.expectedQueueRevision}',
    SetMode(:final mode, :final seed) => 'mode:${mode.name}:$seed',
    Seek(:final position) => 'seek:${position.inMicroseconds}',
    RefreshOutputDevices() => 'refreshOutputDevices',
    SetOutputConfiguration(
      :final deviceUid,
      :final exclusive,
      :final resamplingEnabled,
      :final targetSampleRate,
    ) =>
      'output:$deviceUid:$exclusive:$resamplingEnabled:$targetSampleRate',
    SetPlaybackEffects(:final fadeEnabled, :final volumeNormalizationEnabled) =>
      'effects:$fadeEnabled:$volumeNormalizationEnabled',
    SetVolume(:final permille) => 'volume:$permille',
    SetTransientGain(:final permille) => 'transientGain:$permille',
    Stop() => 'stop',
    ClearQueue() => 'clearQueue',
    ProvideSource(
      :final targetQueueItemId,
      :final sourceUri,
      :final expiresAt,
      :final expectedGeneration,
      :final normalizationGainDb,
      :final normalizationPeak,
    ) =>
      'provideSource:$targetQueueItemId:${sourceUri.toString()}'
          ':${expiresAt?.toUtc().millisecondsSinceEpoch}'
          ':$expectedGeneration:$normalizationGainDb:$normalizationPeak',
  };

  List<Map<String, Object?>> _tracksFingerprint(List<Track> tracks) => [
    for (final track in tracks)
      {
        'id': track.id.value,
        'title': track.title,
        'artists': [
          for (final artist in track.artists)
            {'id': artist.id.value, 'name': artist.name},
        ],
        'album': {
          'id': track.album.id.value,
          'title': track.album.title,
          'artworkUri': track.album.artworkUri?.toString(),
        },
        'durationUs': track.duration.inMicroseconds,
      },
  ];

  /// Publishes the authoritative state as a fresh snapshot.
  ///
  /// The queue and current index are derived from the internal entries and the
  /// mode, so every command changes identity state and the projection together.
  void _publish({
    PlaybackStatus? status,
    Duration? position,
    bool? playWhenReady,
    PlaybackMode? mode,
    WirePhase? phase,
    String? errorCode,
    PlaybackFailureKind? failureKind,
    int? volume,
    PlaybackEffects? playbackEffects,
    int? queueRevision,
    bool clearError = false,
  }) {
    final requestedStatus = status ?? _current.status;
    final resolvedStatus =
        _interruptionId != null && requestedStatus == PlaybackStatus.playing
        ? PlaybackStatus.paused
        : requestedStatus;
    final resolvedMode = mode ?? _current.mode;
    final order =
        resolvedMode == PlaybackMode.shuffle && _order.length == _queue.length
        ? _order
        : [for (var i = 0; i < _queue.length; i++) i];
    final queue = [for (final index in order) _queue[index]];
    final current = _index;
    final currentPosition = current == null ? null : order.indexOf(current);
    _current = PlaybackSnapshot(
      sessionId: _current.sessionId,
      intelligenceSessionId: _intelligenceSessionId,
      sessionRevision: _current.sessionRevision + 1,
      queueRevision: queueRevision ?? _current.queueRevision,
      status: resolvedStatus,
      queue: queue,
      currentIndex: currentPosition == null || currentPosition < 0
          ? null
          : currentPosition,
      position: position ?? _current.position,
      playWhenReady: playWhenReady ?? _current.playWhenReady,
      phase: phase ?? (queue.isEmpty ? WirePhase.idle : WirePhase.ready),
      mode: resolvedMode,
      errorCode: clearError ? null : errorCode ?? _current.errorCode,
      failureKind: clearError
          ? PlaybackFailureKind.other
          : failureKind ??
                (errorCode == null
                    ? _current.failureKind
                    : PlaybackFailureKind.other),
      // The fake has no buffer and no device, so "playing" here means what the
      // intent says it means; the native session derives the same flag instead.
      isActuallyPlaying:
          resolvedStatus == PlaybackStatus.playing && _interruptionId == null,
      suppressionReasons: _interruptionId == null
          ? const []
          : const ['interruption'],
      volume: volume ?? _current.volume,
      playbackEffects: playbackEffects ?? _current.playbackEffects,
      // A seeded order only describes a queue that exists: an empty one has no
      // permutation for a client to persist, exactly as the native snapshot
      // refuses to report one after the queue is cleared (docs/design/playback.md).
      shuffleSeed: resolvedMode == PlaybackMode.shuffle && _queue.isNotEmpty
          ? _shuffleSeed
          : null,
      quality: _queue.isEmpty ? null : _quality,
    );
    for (final events in _connections.values) {
      events.add(_current);
    }
  }
}

/// Why the fake moved to another item: the point the mode rules branch on.
///
/// It is deliberately *not* a command: a reason is not an intent a page can
/// send, and keeping it out of the sealed command hierarchy means a new wire
/// command cannot be mistaken for one.
enum _Advance { natural, manual }

final class _CompletedCommand {
  const _CompletedCommand(this.fingerprint, this.result, this.finishedAt);
  final String fingerprint;
  final CommandResult result;
  final DateTime finishedAt;
}
