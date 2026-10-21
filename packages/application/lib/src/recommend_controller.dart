import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'home_state.dart';
import 'playback_intent_coordinator.dart';

final class RecommendState {
  const RecommendState({
    this.status = LoadStatus.initial,
    required this.dateKey,
    this.dailySnapshot,
    this.recommendedPlaylists,
    this.newSongs = const [],
    this.recentListening,
    this.error,
    this.heroPlayLoading = false,
  });

  final LoadStatus status;
  final String dateKey;
  final DailySongsSnapshot? dailySnapshot;
  final RecommendedPlaylists? recommendedPlaylists;
  final List<Track> newSongs;
  final ListenResources? recentListening;
  final String? error;
  final bool heroPlayLoading;

  RecommendState copyWith({
    LoadStatus? status,
    String? dateKey,
    DailySongsSnapshot? dailySnapshot,
    bool clearDailySnapshot = false,
    RecommendedPlaylists? recommendedPlaylists,
    List<Track>? newSongs,
    ListenResources? recentListening,
    String? error,
    bool clearError = false,
    bool? heroPlayLoading,
  }) => RecommendState(
    status: status ?? this.status,
    dateKey: dateKey ?? this.dateKey,
    dailySnapshot: clearDailySnapshot
        ? null
        : (dailySnapshot ?? this.dailySnapshot),
    recommendedPlaylists: recommendedPlaylists ?? this.recommendedPlaylists,
    newSongs: newSongs ?? this.newSongs,
    recentListening: recentListening ?? this.recentListening,
    error: clearError ? null : (error ?? this.error),
    heroPlayLoading: heroPlayLoading ?? this.heroPlayLoading,
  );
}

final class RecommendController {
  RecommendController({
    required this.repository,
    required this.playbackCoordinator,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _state = RecommendState(dateKey: _currentDateKey());
  }

  final RecommendRepository repository;
  final PlaybackIntentCoordinator playbackCoordinator;
  final DateTime Function() _now;

  final StreamController<RecommendState> _states =
      StreamController<RecommendState>.broadcast();
  late RecommendState _state;
  Timer? _midnightTimer;
  bool _disposed = false;
  int _generation = 0;
  int _accountGeneration = 0;
  Uri? _heartbeatArtworkUri;

  Uri? get heartbeatArtworkUri => _heartbeatArtworkUri;

  void setHeartbeatArtworkUri(Uri uri) {
    if (_heartbeatArtworkUri != null) return;
    _heartbeatArtworkUri = uri;
    _emit(_state.copyWith());
  }

  void resetAccount() {
    _generation++;
    _accountGeneration++;
    _midnightTimer?.cancel();
    _heartbeatArtworkUri = null;
    _emit(RecommendState(dateKey: _currentDateKey()));
  }

  RecommendState get state => _state;
  Stream<RecommendState> get states => _states.stream;

  String _currentDateKey() {
    final n = _now().toLocal();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  void _emit(RecommendState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }

  void _scheduleMidnightCheck() {
    _midnightTimer?.cancel();
    final now = _now().toLocal();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1, 0, 0, 1);
    final diff = nextMidnight.difference(now);
    _midnightTimer = Timer(diff, () {
      if (_disposed) return;
      final newDateKey = _currentDateKey();
      if (newDateKey != _state.dateKey) {
        load(policy: RefreshPolicy.forceRefresh);
      }
      _scheduleMidnightCheck();
    });
  }

  Future<void> load({RefreshPolicy policy = RefreshPolicy.cacheFirst}) async {
    final generation = ++_generation;
    final dateKey = _currentDateKey();
    _emit(
      _state.copyWith(
        status: LoadStatus.loading,
        dateKey: dateKey,
        clearDailySnapshot: dateKey != _state.dateKey,
        clearError: true,
      ),
    );
    _scheduleMidnightCheck();

    try {
      final results = await Future.wait([
        repository.getRecommendedPlaylists(policy: policy),
        repository.getNewSongs(limit: 12, policy: policy),
        repository
            .getRecentListeningResources(policy: policy)
            .catchError((_) => const ListenResources()),
        repository
            .getDailySongs(dateKey: dateKey, policy: policy)
            .then<DailySongsSnapshot?>((r) => r.snapshot, onError: (_) => null),
      ]);

      if (_disposed || generation != _generation) return;
      final playlists = results[0] as RecommendedPlaylists;
      final newSongs = results[1] as List<Track>;
      final recent = results[2] as ListenResources;
      final dailySnapshot = results[3] as DailySongsSnapshot?;

      _emit(
        _state.copyWith(
          status: LoadStatus.ready,
          recommendedPlaylists: playlists,
          newSongs: newSongs,
          recentListening: recent,
          dailySnapshot: dailySnapshot,
          clearDailySnapshot: dailySnapshot == null,
        ),
      );
    } on AppError catch (e) {
      if (_disposed || generation != _generation) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: e.code));
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: 'unknown'));
    }
  }

  /// Plays the daily recommendation hero card.
  ///
  /// CRITICAL: Uses [RefreshPolicy.forceRefresh]. Playback is ONLY started
  /// on successful network response. On failure or empty result, current playback
  /// queue is PRESERVED UNTOUCHED (never falls back to stale cache auto-play).
  Future<CommandResult?> playDailySongsHero() async {
    if (_state.heroPlayLoading) return null;
    final generation = _accountGeneration;
    _emit(_state.copyWith(heroPlayLoading: true));

    try {
      final read = await repository.getDailySongs(
        dateKey: _currentDateKey(),
        policy: RefreshPolicy.forceRefresh,
      );
      if (_disposed || generation != _accountGeneration) return null;
      final tracks = read.snapshot.tracks
          .where((t) => t.availability != TrackAvailability.none)
          .toList();

      if (tracks.isEmpty) {
        _emit(
          _state.copyWith(
            heroPlayLoading: false,
            error: 'recommend.emptyDaily',
          ),
        );
        return const CommandResult.rejected('recommend.emptyDaily');
      }

      _emit(
        _state.copyWith(dailySnapshot: read.snapshot, heroPlayLoading: false),
      );

      return await playbackCoordinator.replaceQueue(
        tracks: tracks,
        startIndex: 0,
      );
    } catch (e) {
      if (_disposed || generation != _accountGeneration) return null;
      _emit(
        _state.copyWith(
          heroPlayLoading: false,
          error: e is AppError ? e.code : 'network.unreachable',
        ),
      );
      return CommandResult.rejected(
        e is AppError ? e.code : 'network.unreachable',
      );
    }
  }

  void dispose() {
    _disposed = true;
    _midnightTimer?.cancel();
    _states.close();
  }
}
