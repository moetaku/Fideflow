import 'dart:async';
import 'dart:math';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'auth_controller.dart';
import 'browse_and_play_controller.dart';

/// Owns recommendations, while the media session owns mode and queue identity.
final class IntelligenceModeController {
  IntelligenceModeController({
    required this.player,
    required this.repository,
    required this.auth,
    this.onChanged,
    this.onNotice,
    this.retryDelays = const [
      Duration(seconds: 3),
      Duration(seconds: 6),
      Duration(seconds: 12),
    ],
  }) {
    _owner = _account;
    _authSub = auth.states.listen((_) {
      if (_account != _owner) {
        final hadHeart = active || starting || _session != null;
        _owner = _account;
        invalidate();
        if (hadHeart) unawaited(player.clearQueue());
      }
    });
    _playSub = player.states.listen((state) => observe(state.playback));
  }

  final BrowseAndPlayController player;
  final IntelligenceRepository repository;
  final AuthController auth;
  final void Function()? onChanged;
  final void Function(String)? onNotice;
  final List<Duration> retryDelays;
  late final StreamSubscription<AuthState> _authSub;
  late final StreamSubscription<dynamic> _playSub;
  late (UserId?, int?) _owner;
  (UserId?, int?) get _account =>
      (auth.current.session?.user.userId, auth.current.session?.authEpoch);
  final List<Track> _candidates = [];
  final Set<TrackId> _seen = {};
  PlaylistId? _playlist;
  TrackId? _seed;
  String? _session;
  int _epoch = 0;
  int _intentEpoch = 0;
  int _counter = 0;
  bool _disposed = false;
  bool _advance = false;
  bool _sourceBlocked = false;
  int _sourceFailures = 0;
  TrackId? _failedTrack;
  PlaybackSnapshot? _lastSnapshot;
  Future<void>? _flight;
  Timer? _retryTimer;
  Completer<void>? _retryWait;
  bool loading = false;
  bool starting = false;
  String? errorCode;

  bool get active => player.current.playback.isIntelligenceMode;
  bool _valid(int epoch) => !_disposed && epoch == _epoch && _account == _owner;
  bool get _needsMore {
    final s = player.current.playback;
    return s.queue.length <= 1 ||
        s.queue.length - (s.currentIndex ?? -1) - 1 <= 3;
  }

  Future<void> _singleFlight(Future<void> Function() run) {
    if (_flight != null) return _flight!;
    final flightEpoch = _epoch;
    final done = Completer<void>();
    _flight = done.future;
    loading = true;
    onChanged?.call();
    unawaited(() async {
      try {
        await run();
      } catch (_) {
        if (_valid(flightEpoch)) {
          errorCode = 'intelligence.failed';
          onNotice?.call(errorCode!);
        }
      } finally {
        if (identical(_flight, done.future)) {
          _flight = null;
          loading = false;
          starting = false;
          onChanged?.call();
          if (!_disposed &&
              active &&
              errorCode == null &&
              !_sourceBlocked &&
              _needsMore) {
            scheduleMicrotask(() {
              if (active && errorCode == null && !_disposed) {
                unawaited(refill());
              }
            });
          }
        }
        done.complete();
      }
    }());
    return done.future;
  }

  Future<void> start() {
    if (active) return next();
    if (_flight != null) return _flight!;
    starting = true;
    final epoch = ++_epoch;
    final owner = _account;
    _owner = owner;
    return _singleFlight(() async {
      if (owner.$1 == null) {
        _fail('intelligence.loginRequired');
        return;
      }
      if (!auth.current.hasLoadedPlaylists) await auth.loadUserPlaylists();
      if (!_valid(epoch)) return;
      final liked = auth.current.likedPlaylist;
      if (liked == null ||
          (liked.specialType != 5 &&
              NcmKind.playlist.digitsOf(liked.id.value) !=
                  NcmKind.user.digitsOf(owner.$1!.value))) {
        _fail('intelligence.noSeed');
        return;
      }
      final before = player.current.playback;
      var seed = before.currentTrack;
      if (seed == null || !_usable(seed)) {
        final songs = await player.catalog.getPlaylistTracks(liked.id);
        if (!_valid(epoch)) return;
        seed = songs.items.where(_usable).firstOrNull;
      }
      if (seed == null) {
        _fail('intelligence.noSeed');
        return;
      }
      final tracks = await repository.getIntelligenceTracks(
        seed: seed.id,
        playlist: liked.id,
      );
      if (!_valid(epoch)) return;
      final unique = <TrackId>{};
      final usable = tracks
          .where((t) => _usable(t) && unique.add(t.id))
          .toList();
      if (usable.isEmpty) {
        _fail('intelligence.empty');
        return;
      }
      final session =
          'heart-${DateTime.now().microsecondsSinceEpoch}-${++_counter}';
      final initial = usable.take(50).toList();
      _session = session;
      _playlist = liked.id;
      _seed = seed.id;
      _seen
        ..clear()
        ..addAll(initial.map((t) => t.id));
      _candidates
        ..clear()
        ..addAll(usable.skip(50));
      errorCode = null;
      final result = await player.executeIntelligence(
        LoadQueue(
          commandId: 'heart-start-$session',
          tracks: initial,
          autoplay: true,
          quality: player.preferredQuality(),
          intelligenceSessionId: session,
          expectedQueueRevision: before.queueRevision,
        ),
      );
      if (!_valid(epoch)) return;
      if (!result.isAccepted) {
        _session = null;
        _candidates.clear();
        _fail('intelligence.failed');
      }
    });
  }

  bool _usable(Track track) =>
      NcmKind.track.digitsOf(track.id.value) != null &&
      track.availability != TrackAvailability.none;

  void observe(PlaybackSnapshot snapshot) {
    if (identical(snapshot, _lastSnapshot) || _disposed) return;
    final previous = _lastSnapshot;
    _lastSnapshot = snapshot;
    if (_session != null && snapshot.intelligenceSessionId != _session) {
      // Startup publishes its new context only after the queue command succeeds.
      if (!starting) invalidate();
      return;
    }
    if (!active || _session == null) return;
    _seed = snapshot.currentTrack?.id ?? _seed;
    if (previous?.playWhenReady == true && !snapshot.playWhenReady) {
      cancelAdvance();
    }
    if (snapshot.status == PlaybackStatus.error &&
        snapshot.errorCode != null &&
        !_sourceBlocked &&
        (snapshot.failureKind == PlaybackFailureKind.source ||
            snapshot.failureKind == PlaybackFailureKind.decode)) {
      if (_failedTrack != snapshot.currentTrack?.id) {
        _failedTrack = snapshot.currentTrack?.id;
        _sourceFailures++;
        if (_sourceFailures > 3) {
          _sourceBlocked = true;
          cancelAdvance();
          unawaited(
            player.executeIntelligence(
              Pause(commandId: 'heart-failure-${++_counter}'),
            ),
          );
          errorCode = 'intelligence.sourceRestricted';
          onChanged?.call();
          onNotice?.call('intelligence.sourceRestricted');
        } else if (snapshot.playWhenReady) {
          unawaited(next());
        }
      }
    } else if (snapshot.isActuallyPlaying) {
      _sourceFailures = 0;
      _failedTrack = null;
    }
    if (!_sourceBlocked && errorCode == null && _needsMore) unawaited(refill());
  }

  Future<void> next() async {
    if (!active) return;
    final s = player.current.playback;
    if (s.currentIndex != null && s.currentIndex! + 1 < s.queue.length) {
      cancelAdvance();
      await player.executeIntelligence(
        SkipNext(
          commandId: 'heart-next-${++_counter}',
          expectedQueueRevision: s.queueRevision,
        ),
      );
      return;
    }
    _advance = true;
    await refill();
  }

  void cancelAdvance() {
    _advance = false;
    _intentEpoch++;
  }

  void removed(TrackId id) {
    _seen.add(id);
    _candidates.removeWhere((t) => t.id == id);
  }

  void resetSourceFailures() {
    if (errorCode == 'intelligence.sourceRestricted') errorCode = null;
    _sourceBlocked = false;
    _sourceFailures = 0;
    _failedTrack = null;
  }

  Future<void> retry() {
    if (_sourceBlocked) {
      resetSourceFailures();
      return player.retryCurrentItem();
    }
    if (loading) return _flight ?? Future.value();
    errorCode = null;
    _sourceBlocked = false;
    _sourceFailures = 0;
    _failedTrack = null;
    final s = player.current.playback;
    if (s.phase == WirePhase.ended || s.queue.isEmpty) _advance = true;
    return refill();
  }

  Future<void> refill() {
    if (!active || _session == null || _sourceBlocked) return Future.value();
    final epoch = _epoch;
    final session = _session!;
    return _singleFlight(() async {
      errorCode = null;
      if (_candidates.isEmpty) {
        for (var attempt = 0; ; attempt++) {
          try {
            final tracks = await repository.getIntelligenceTracks(
              seed: _seed!,
              playlist: _playlist!,
            );
            if (!_valid(epoch)) return;
            final unique = {..._seen};
            _candidates.addAll(
              tracks.where((t) => _usable(t) && unique.add(t.id)),
            );
            if (_candidates.isEmpty) {
              _fail('intelligence.empty');
              return;
            }
            break;
          } catch (_) {
            if (!_valid(epoch)) return;
            if (attempt >= retryDelays.length) {
              _fail('intelligence.failed');
              return;
            }
            final wait = Completer<void>();
            _retryWait = wait;
            _retryTimer = Timer(retryDelays[attempt], () {
              if (!wait.isCompleted) wait.complete();
            });
            await wait.future;
            if (!_valid(epoch)) return;
          }
        }
      }
      for (var conflict = 0; conflict < 3 && _valid(epoch); conflict++) {
        final s = player.current.playback;
        if (s.intelligenceSessionId != session) return;
        final history = s.currentIndex ?? 0;
        final count = min(_candidates.length, 50 - s.queue.length + history);
        if (count <= 0) return;
        final tracks = _candidates.take(count).toList();
        final advance =
            _advance || (s.phase == WirePhase.ended && s.playWhenReady);
        final intentEpoch = _intentEpoch;
        final result = await player.executeIntelligence(
          RefillIntelligence(
            commandId: 'heart-refill-${++_counter}',
            sessionId: session,
            tracks: tracks,
            evictCount: max(0, s.queue.length + count - 50),
            advance: advance,
            autoplay: s.playWhenReady,
            expectedQueueRevision: s.queueRevision,
            expectedSessionRevision: s.sessionRevision,
          ),
        );
        if (!_valid(epoch)) return;
        if (result.isAccepted) {
          _seen.addAll(tracks.map((t) => t.id));
          final consumed = tracks.map((t) => t.id).toSet();
          _candidates.removeWhere((t) => consumed.contains(t.id));
          if (!advance &&
              _advance &&
              intentEpoch == _intentEpoch &&
              player.current.playback.playWhenReady) {
            _advance = false;
            final current = player.current.playback;
            await player.executeIntelligence(
              SkipNext(
                commandId: 'heart-pending-next-${++_counter}',
                expectedQueueRevision: current.queueRevision,
              ),
            );
          } else if (intentEpoch == _intentEpoch) {
            _advance = false;
          }
          return;
        }
      }
      if (_valid(epoch)) _fail('intelligence.failed');
    });
  }

  Future<void> exit() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final s = player.current.playback;
      if (s.intelligenceSessionId == null) {
        invalidate();
        return;
      }
      final result = await player.executeIntelligence(
        ExitIntelligence(
          commandId: 'heart-exit-${++_counter}',
          sessionId: s.intelligenceSessionId!,
          expectedQueueRevision: s.queueRevision,
        ),
      );
      if (result.isAccepted) {
        invalidate();
        return;
      }
    }
    onNotice?.call('intelligence.failed');
  }

  void _fail(String code) {
    errorCode = code;
    onChanged?.call();
    onNotice?.call(code);
  }

  /// Suspend recommendations while an ordinary queue replacement is decided.
  /// A rejected replacement can resume the existing heart context and buffers.
  void suspendForReplacement() {
    if (starting || !active) {
      invalidate();
      return;
    }
    _epoch++;
    cancelAdvance();
    _retryTimer?.cancel();
    if (_retryWait case final wait? when !wait.isCompleted) wait.complete();
    _retryWait = null;
    _flight = null;
    loading = false;
    errorCode = null;
    onChanged?.call();
  }

  void resumeAfterReplacementFailure() {
    if (active && _needsMore && !_sourceBlocked) unawaited(refill());
  }

  void invalidate() {
    _epoch++;
    cancelAdvance();
    _session = null;
    _candidates.clear();
    _seen.clear();
    _retryTimer?.cancel();
    if (_retryWait case final wait? when !wait.isCompleted) wait.complete();
    _retryWait = null;
    _flight = null;
    loading = false;
    starting = false;
    errorCode = null;
    _sourceFailures = 0;
    _sourceBlocked = false;
    onChanged?.call();
  }

  Future<void> dispose() async {
    _disposed = true;
    invalidate();
    await _authSub.cancel();
    await _playSub.cancel();
  }
}
