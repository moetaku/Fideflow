import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'home_state.dart';
import 'playback_intent_coordinator.dart';

final class DailySongsState {
  const DailySongsState({
    this.status = LoadStatus.initial,
    required this.dateKey,
    this.read,
    this.error,
  });

  final LoadStatus status;
  final String dateKey;
  final DailySongsRead? read;
  final String? error;

  List<DailySongEntry> get songs => read?.snapshot.songs ?? const [];
  List<Track> get playableTracks => [
    for (final entry in songs)
      if (entry.track.availability != TrackAvailability.none) entry.track,
  ];

  DailySongsState copyWith({
    LoadStatus? status,
    String? dateKey,
    DailySongsRead? read,
    String? error,
    bool clearError = false,
  }) => DailySongsState(
    status: status ?? this.status,
    dateKey: dateKey ?? this.dateKey,
    read: read ?? this.read,
    error: clearError ? null : (error ?? this.error),
  );
}

final class DailySongsController {
  DailySongsController({
    required this.dateKey,
    required this.repository,
    required this.playbackCoordinator,
  }) : _state = DailySongsState(dateKey: dateKey);

  final String dateKey;
  final RecommendRepository repository;
  final PlaybackIntentCoordinator playbackCoordinator;

  final StreamController<DailySongsState> _states =
      StreamController<DailySongsState>.broadcast();
  late DailySongsState _state;
  bool _disposed = false;

  DailySongsState get state => _state;
  Stream<DailySongsState> get states => _states.stream;

  void _emit(DailySongsState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }

  Future<void> load({RefreshPolicy policy = RefreshPolicy.cacheFirst}) async {
    _emit(_state.copyWith(status: LoadStatus.loading, clearError: true));
    try {
      final result = await repository.getDailySongs(
        dateKey: dateKey,
        policy: policy,
      );
      _emit(_state.copyWith(status: LoadStatus.ready, read: result));
    } on AppError catch (e) {
      _emit(_state.copyWith(status: LoadStatus.failure, error: e.code));
    } catch (_) {
      _emit(_state.copyWith(status: LoadStatus.failure, error: 'unknown'));
    }
  }

  Future<CommandResult?> playAll() async {
    final tracks = _state.playableTracks;
    if (tracks.isEmpty) return null;
    return playbackCoordinator.replaceQueue(tracks: tracks, startIndex: 0);
  }

  Future<CommandResult?> playTrackAt(int index) async {
    final tracks = _state.playableTracks;
    if (index < 0 || index >= tracks.length) return null;
    return playbackCoordinator.replaceQueue(tracks: tracks, startIndex: index);
  }

  void dispose() {
    _disposed = true;
    _states.close();
  }
}
