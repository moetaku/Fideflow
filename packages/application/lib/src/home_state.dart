import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

enum LoadStatus { initial, loading, ready, failure }

/// A message the user should see once.
///
/// A page cannot deduplicate a string, and a rejected command is an event rather
/// than a state: [id] increases for every new notice, so a listener shows each
/// one exactly once — even two failures with the same code.
final class PlaybackNotice {
  const PlaybackNotice({required this.id, required this.code});

  final int id;
  final String code;
}

final class HomeState {
  const HomeState({
    required this.status,
    required this.playback,
    this.feed,
    this.selectedPlaylist,
    this.errorCode,
    this.notice,
  });

  factory HomeState.initial() =>
      HomeState(status: LoadStatus.initial, playback: PlaybackSnapshot.idle());

  final LoadStatus status;
  final HomeFeed? feed;
  final PlaylistDetail? selectedPlaylist;
  final PlaybackSnapshot playback;

  /// Why the *content* could not be loaded; the page owns that whole screen.
  final String? errorCode;

  /// The newest command or playback failure the user has not been shown yet.
  final PlaybackNotice? notice;

  HomeState copyWith({
    LoadStatus? status,
    HomeFeed? feed,
    PlaylistDetail? selectedPlaylist,
    PlaybackSnapshot? playback,
    String? errorCode,
    PlaybackNotice? notice,
    bool clearError = false,
    bool clearSelectedPlaylist = false,
    bool clearFeed = false,
  }) => HomeState(
    status: status ?? this.status,
    feed: clearFeed ? null : feed ?? this.feed,
    selectedPlaylist: clearSelectedPlaylist
        ? null
        : selectedPlaylist ?? this.selectedPlaylist,
    playback: playback ?? this.playback,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    notice: notice ?? this.notice,
  );
}
