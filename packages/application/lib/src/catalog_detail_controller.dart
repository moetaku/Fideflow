import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

import 'home_state.dart';
import 'playback_intent_coordinator.dart';

final class CatalogDetailState {
  const CatalogDetailState({
    this.status = LoadStatus.initial,
    required this.playlistId,
    this.detail,
    this.accessVerdict,
    this.isFavoriteRole = false,
    this.error,
  });

  final LoadStatus status;
  final PlaylistId playlistId;
  final PlaylistDetail? detail;
  final PlaylistAccessVerdict? accessVerdict;
  final bool isFavoriteRole;
  final String? error;

  List<Track> get playableTracks => detail?.queueCandidates ?? const [];

  bool get isAccessDenied =>
      accessVerdict?.state == PlaylistAccessState.accessDenied;

  CatalogDetailState copyWith({
    LoadStatus? status,
    PlaylistId? playlistId,
    PlaylistDetail? detail,
    PlaylistAccessVerdict? accessVerdict,
    bool? isFavoriteRole,
    String? error,
    bool clearError = false,
  }) => CatalogDetailState(
    status: status ?? this.status,
    playlistId: playlistId ?? this.playlistId,
    detail: detail ?? this.detail,
    accessVerdict: accessVerdict ?? this.accessVerdict,
    isFavoriteRole: isFavoriteRole ?? this.isFavoriteRole,
    error: clearError ? null : (error ?? this.error),
  );
}

final class CatalogDetailController {
  CatalogDetailController({
    required this.playlistId,
    required this.catalog,
    required this.playbackCoordinator,
    this.isFavoriteRole = false,
    this.initialSummary,
    this.currentUserId,
    PlaylistDetail? initialDetail,
  }) : _state = CatalogDetailState(
         status: initialDetail != null ? LoadStatus.ready : LoadStatus.initial,
         playlistId: playlistId,
         detail: initialDetail,
         isFavoriteRole: isFavoriteRole,
       );

  final PlaylistId playlistId;
  final CatalogRepository catalog;
  final PlaybackIntentCoordinator playbackCoordinator;
  final bool isFavoriteRole;
  final PlaylistSummary? initialSummary;
  final UserId? Function()? currentUserId;

  final StreamController<CatalogDetailState> _states =
      StreamController<CatalogDetailState>.broadcast();
  late CatalogDetailState _state;
  bool _disposed = false;
  int _loadGeneration = 0;

  CatalogDetailState get state => _state;
  Stream<CatalogDetailState> get states => _states.stream;

  void _emit(CatalogDetailState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }

  Future<void> load({RefreshPolicy policy = RefreshPolicy.networkFirst}) async {
    final generation = ++_loadGeneration;
    if (_deniedForCurrentUser(initialSummary) ||
        _deniedForCurrentUser(_state.detail?.summary)) {
      _denyAccess();
      return;
    }
    _emit(_state.copyWith(status: LoadStatus.loading, clearError: true));

    try {
      PlaylistAccessVerdict? verdict;
      if (!isFavoriteRole) {
        try {
          verdict = await catalog.getPlaylistAccess(playlistId, policy: policy);
          if (_disposed || generation != _loadGeneration) return;
          if (verdict.state == PlaylistAccessState.accessDenied) {
            _denyAccess(verdict);
            return;
          }
        } on AppError catch (e) {
          if (_disposed || generation != _loadGeneration) return;
          if (e.category == AppErrorCategory.permission ||
              e.code == 'ncm.permissionDenied' ||
              e.category == AppErrorCategory.authentication) {
            _denyAccess();
            return;
          }
        }
      }

      final content = await catalog.getPlaylist(playlistId, policy: policy);
      if (_disposed || generation != _loadGeneration) return;
      // Legacy history may lack privacy metadata; validate the fetched summary
      // too, before exposing content or making it available to playback.
      if (_deniedForCurrentUser(content.summary)) {
        _denyAccess();
        return;
      }
      // Cached membership has no account evidence. Preserve the evidence from
      // the access request instead of discarding its already fetched response.
      final evidence =
          content.accountState?.subscription != null &&
              content.accountState!.subscription != SubscriptionEvidence.unknown
          ? content.accountState
          : verdict?.accountState ?? content.accountState;
      final detail = PlaylistDetail(
        summary: content.summary,
        header: content.header,
        accountState: evidence,
        entries: content.entries,
        membershipComplete: content.membershipComplete,
        detailsComplete: content.detailsComplete,
        membershipInferred: content.membershipInferred,
      );
      if (_disposed || generation != _loadGeneration) return;
      _emit(
        CatalogDetailState(
          status: LoadStatus.ready,
          playlistId: playlistId,
          isFavoriteRole: isFavoriteRole,
          detail: detail,
          accessVerdict: verdict,
        ),
      );
    } on AppError catch (e) {
      if (_disposed || generation != _loadGeneration) return;
      if (e.category == AppErrorCategory.permission ||
          e.code == 'ncm.permissionDenied') {
        _denyAccess();
        return;
      }
      _emit(_state.copyWith(status: LoadStatus.failure, error: e.code));
    } catch (_) {
      if (_disposed || generation != _loadGeneration) return;
      _emit(_state.copyWith(status: LoadStatus.failure, error: 'unknown'));
    }
  }

  bool _deniedForCurrentUser(PlaylistSummary? summary) {
    if (summary?.privacy != 10 || currentUserId == null) return false;
    final user = currentUserId!();
    final creator = summary!.creatorId;
    return user == null ||
        creator == null ||
        NcmKind.user.canonical(user.value) !=
            NcmKind.user.canonical(creator.value);
  }

  void _denyAccess([PlaylistAccessVerdict? verdict]) {
    final now = DateTime.now().toUtc();
    _emit(
      CatalogDetailState(
        status: LoadStatus.failure,
        playlistId: playlistId,
        isFavoriteRole: isFavoriteRole,
        error: 'ncm.permissionDenied',
        accessVerdict:
            verdict ??
            PlaylistAccessVerdict(
              namespace: 'ncm',
              target: playlistId,
              state: PlaylistAccessState.accessDenied,
              evidenceMode: currentUserId?.call() == null
                  ? RequestAuthMode.anonymous
                  : RequestAuthMode.establishedSession,
              evidenceKind: 'privatePlaylistOwnerCheck',
              fetchedAt: now,
              freshUntil: now,
            ),
      ),
    );
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
