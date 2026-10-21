import 'dart:async';

import 'package:fideflow_domain/domain.dart';

import 'auth_controller.dart';

enum FavoriteState { unknown, liked, unliked }

enum MusicOperationStatus { succeeded, failed, pending }

final class MusicOperationResult {
  const MusicOperationResult(
    this.message, {
    this.status = MusicOperationStatus.failed,
    this.playlist,
  });
  final String message;
  final MusicOperationStatus status;
  bool get success => status == MusicOperationStatus.succeeded;
  bool get pending => status == MusicOperationStatus.pending;
  final PlaylistSummary? playlist;
}

/// One account's mutations and shared favorite state. No playback commands.
final class AccountMusicController {
  AccountMusicController({
    required this.repository,
    required this.catalog,
    required this.auth,
    this.invalidatePlaylist,
    PlaylistSquareRepository? categoryRepository,
  }) : categoryRepository =
           categoryRepository ??
           (repository is PlaylistSquareRepository
               ? repository as PlaylistSquareRepository
               : null) {
    _subscription = auth.states.listen((_) => _accountChanged());
    _accountChanged();
  }
  final AccountMusicRepository repository;
  final PlaylistSquareRepository? categoryRepository;
  Future<PlaylistCategoryTree?> loadCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => categoryRepository?.getCategoryTree(policy: policy);
  final CatalogRepository catalog;
  final AuthController auth;
  final Future<void> Function(PlaylistId)? invalidatePlaylist;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  late final StreamSubscription<AuthState> _subscription;
  final Set<String> _busy = {};
  final Map<String, Future<bool?> Function()> _pending = {};
  final Map<PlaylistId, PlaylistDetail> details = {};
  final Set<PlaylistId> deletedPlaylists = {};
  final Map<String, ({PlaylistId? id, bool deleted, bool favorites})>
  _pendingRefresh = {};
  Set<TrackId>? _liked;
  int _likesGeneration = 0;
  String? _account;
  bool _disposed = false;
  String? favoriteError;
  PlaylistSummary? _reconciledCreated;
  String? get accountKey => _account;
  bool get authenticated =>
      auth.current.isAuthenticated && !auth.current.isSigningOut;
  List<String> get pendingKeys => List.unmodifiable(_pending.keys);
  bool busy(String key) => _busy.contains(key) || _pending.containsKey(key);
  String playlistKey(PlaylistId id) =>
      'playlist:${NcmKind.playlist.canonical(id.value)}';
  Set<AlbumId>? _subscribedAlbums;
  List<AlbumSummary> _albumSummaries = const [];
  List<AlbumSummary> get subscribedAlbums => _albumSummaries;
  int _albumsGeneration = 0;
  bool loadingAlbumSubscriptions = false;
  String? albumSubscriptionError;
  bool get albumSubscriptionsLoaded => _subscribedAlbums != null;
  bool isAlbumSubscribed(AlbumId id) =>
      _subscribedAlbums?.contains(AlbumId(NcmKind.album.canonical(id.value))) ??
      false;
  String albumKey(AlbumId id) => 'album:${NcmKind.album.canonical(id.value)}';
  FavoriteState favorite(TrackId id) => !authenticated
      ? FavoriteState.unliked
      : _liked == null
      ? FavoriteState.unknown
      : _liked!.contains(TrackId(NcmKind.track.canonical(id.value)))
      ? FavoriteState.liked
      : FavoriteState.unliked;
  bool isRemoteTrack(TrackId id) => NcmKind.track.digitsOf(id.value) != null;
  bool owns(PlaylistSummary p) =>
      p.creatorId != null &&
      NcmKind.user.canonical(p.creatorId!.value) ==
          NcmKind.user.canonical(auth.current.session?.user.userId.value ?? '');
  bool special(PlaylistSummary p) =>
      p.specialType == 5 ||
      auth.current.userPlaylists.any(
        (known) =>
            known.specialType == 5 &&
            NcmKind.playlist.canonical(known.id.value) ==
                NcmKind.playlist.canonical(p.id.value),
      ) ||
      (owns(p) &&
          NcmKind.playlist.digitsOf(p.id.value) != null &&
          NcmKind.playlist.digitsOf(p.id.value) ==
              NcmKind.user.digitsOf(
                auth.current.session?.user.userId.value ?? '',
              ));
  PlaylistId? get likedPlaylistId {
    for (final p in auth.current.userPlaylists) {
      if (owns(p) && special(p)) return p.id;
    }
    return null;
  }

  bool editable(PlaylistSummary p) =>
      authenticated &&
      NcmKind.playlist.digitsOf(p.id.value) != null &&
      owns(p) &&
      !special(p);
  List<PlaylistSummary> get targets =>
      auth.current.userPlaylists.where(editable).toList();
  void _emit() {
    if (!_disposed) _changes.add(null);
  }

  void _accountChanged() {
    final session = auth.current.session;
    final key = authenticated && session != null
        ? '${session.user.userId.value}:${session.authEpoch}'
        : null;
    if (key == _account) return;
    _account = key;
    _liked = null;
    favoriteError = null;
    _reconciledCreated = null;
    _likesGeneration++;
    _busy.clear();
    _pending.clear();
    _pendingRefresh.clear();
    details.clear();
    deletedPlaylists.clear();
    _subscribedAlbums = null;
    _albumSummaries = const [];
    _albumsGeneration++;
    loadingAlbumSubscriptions = false;
    albumSubscriptionError = null;
    _emit();
    if (key != null) {
      unawaited(loadFavorites());
      unawaited(loadAlbumSubscriptions());
    }
  }

  void _ensure(String? owner) {
    final session = auth.current.session;
    final live = session == null
        ? null
        : '${session.user.userId.value}:${session.authEpoch}';
    if (owner == null ||
        owner != _account ||
        owner != live ||
        !authenticated ||
        _disposed) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.required',
        retryable: false,
      );
    }
  }

  Future<void> loadFavorites() async {
    final owner = _account;
    final user = auth.current.session?.user.userId;
    if (owner == null || user == null) return;
    final generation = ++_likesGeneration;
    try {
      final liked = await repository.getLikedTrackIds(user);
      _ensure(owner);
      if (generation != _likesGeneration) return;
      _liked = {
        for (final id in liked) TrackId(NcmKind.track.canonical(id.value)),
      };
      favoriteError = null;
    } catch (_) {
      if (owner != _account || generation != _likesGeneration) return;
      favoriteError = UiMessages.couldNotLoadFavoriteTracksPleaseTryAgain;
    }
    _emit();
  }

  Future<bool> _readAlbumSubscriptions(String owner) async {
    final generation = ++_albumsGeneration;
    loadingAlbumSubscriptions = true;
    _emit();
    try {
      final albums = await repository.getSubscribedAlbums();
      _ensure(owner);
      if (generation != _albumsGeneration) return false;
      _subscribedAlbums = {
        for (final album in albums)
          AlbumId(NcmKind.album.canonical(album.id.value)),
      };
      _albumSummaries = List.unmodifiable(albums);
      albumSubscriptionError = null;
      return true;
    } catch (_) {
      if (owner == _account && generation == _albumsGeneration) {
        albumSubscriptionError =
            UiMessages.couldNotLoadAlbumSubscriptionsPleaseTryAgain;
      }
      rethrow;
    } finally {
      if (owner == _account && generation == _albumsGeneration) {
        loadingAlbumSubscriptions = false;
        _emit();
      }
    }
  }

  Future<void> loadAlbumSubscriptions() async {
    final owner = _account;
    if (owner == null) return;
    try {
      await _readAlbumSubscriptions(owner);
    } catch (_) {
      // The UI exposes the load error and allows a read-only retry.
    }
  }

  Future<PlaylistDetail> fresh(PlaylistId id) async {
    final owner = _account;
    _ensure(owner);
    final detail = await catalog.getPlaylist(
      id,
      policy: RefreshPolicy.forceRefresh,
    );
    _ensure(owner);
    details[id] = detail;
    _emit();
    return detail;
  }

  Future<PlaylistDetail> _owned(PlaylistId id, String? owner) async {
    _ensure(owner);
    final p = await fresh(id);
    _ensure(owner);
    if (!editable(p.summary)) {
      throw const AppError(
        category: AppErrorCategory.permission,
        code: 'music.permissionDenied',
        retryable: false,
      );
    }
    return p;
  }

  Future<void> _refresh(
    PlaylistId? id,
    String? owner, {
    bool deleted = false,
    bool favorites = false,
  }) async {
    _ensure(owner);
    var failed = false;
    if (id != null) {
      details.remove(id);
      if (deleted) {
        deletedPlaylists.add(id);
        _emit();
      }
      try {
        await invalidatePlaylist?.call(id);
      } catch (_) {
        failed = true;
      }
      _ensure(owner);
      if (!deleted) {
        try {
          await fresh(id);
        } catch (_) {
          failed = true;
        }
        _ensure(owner);
      }
    }
    await auth.loadUserPlaylists();
    _ensure(owner);
    failed = failed || auth.current.playlistLoadFailed;
    if (favorites) {
      await loadFavorites();
      _ensure(owner);
      failed = failed || favoriteError != null;
    }
    if (failed) throw StateError('music refresh failed');
  }

  Future<MusicOperationResult> _run(
    String key,
    Future<void> Function(String owner, void Function() markMutation) action,
    Future<bool?> Function(String owner) check, {
    PlaylistId? id,
    bool deleted = false,
    bool favorites = false,
    String successMessage = UiMessages.operationSucceeded,
  }) async {
    final owner = _account;
    if (owner == null || !authenticated) {
      return const MusicOperationResult(UiMessages.signInFirst);
    }
    if (busy(key)) {
      return const MusicOperationResult(
        UiMessages.theOperationIsInProgressOrItsResult,
      );
    }
    _busy.add(key);
    _emit();
    var sent = false;
    try {
      await action(owner, () => sent = true);
      _ensure(owner);
      try {
        await _refresh(id, owner, deleted: deleted, favorites: favorites);
      } catch (_) {
        _ensure(owner);
        return const MusicOperationResult(
          UiMessages.operationSucceededButRefreshFailedRefreshThePage,
          status: MusicOperationStatus.succeeded,
        );
      }
      return MusicOperationResult(
        successMessage,
        status: MusicOperationStatus.succeeded,
      );
    } catch (e) {
      if (owner != _account || _disposed) {
        return const MusicOperationResult(
          UiMessages.accountChangedThePreviousOperationSResultWas,
        );
      }
      if (sent &&
          e is AppError &&
          (e.category == AppErrorCategory.network ||
              e.code == 'music.invalidResponse' ||
              e.code == 'provider.schemaChanged' ||
              e.code == 'ncm.upstreamError')) {
        _pending[key] = () => check(owner);
        _pendingRefresh[key] = (id: id, deleted: deleted, favorites: favorites);
        if (id != null) {
          try {
            await invalidatePlaylist?.call(id);
          } catch (_) {}
        }
        _ensure(owner);
        // Never issue another mutation: reconcile by reading only.
        return await _reconcile(
          key,
          owner,
          id: id,
          deleted: deleted,
          favorites: favorites,
        );
      }
      return MusicOperationResult(musicErrorMessage(e));
    } finally {
      if (owner == _account) {
        _busy.remove(key);
        _emit();
      }
    }
  }

  Future<MusicOperationResult> _reconcile(
    String key,
    String owner, {
    PlaylistId? id,
    bool deleted = false,
    bool favorites = false,
  }) async {
    try {
      _ensure(owner);
      final answer = await _pending[key]!();
      _ensure(owner);
      if (answer == null) {
        return const MusicOperationResult(
          UiMessages.resultPendingVerifyLaterItWillNotBe,
          status: MusicOperationStatus.pending,
        );
      }
      _pending.remove(key);
      final refresh = _pendingRefresh.remove(key);
      try {
        await _refresh(
          refresh?.id ?? id,
          owner,
          deleted: (refresh?.deleted ?? deleted) && answer,
          favorites: refresh?.favorites ?? favorites,
        );
      } catch (_) {
        _ensure(owner);
        return MusicOperationResult(
          answer
              ? UiMessages.verifiedSuccessfullyButRefreshFailedRefreshThePage
              : UiMessages.theExpectedStateWasNotReachedAndRefresh,
          status: answer
              ? MusicOperationStatus.succeeded
              : MusicOperationStatus.failed,
        );
      }
      return MusicOperationResult(
        answer
            ? UiMessages.verifiedOperationSucceeded
            : UiMessages.verifiedTheRemoteStateHasNotChangedYou,
        status: answer
            ? MusicOperationStatus.succeeded
            : MusicOperationStatus.failed,
      );
    } catch (_) {
      return const MusicOperationResult(
        UiMessages.resultPendingVerificationFailedVerifyLater,
        status: MusicOperationStatus.pending,
      );
    }
  }

  Future<MusicOperationResult> reconcile(String key) async {
    final owner = _account;
    if (owner == null || !_pending.containsKey(key) || _busy.contains(key)) {
      return const MusicOperationResult(UiMessages.noOperationsToVerify);
    }
    _busy.add(key);
    _emit();
    try {
      final result = await _reconcile(key, owner);
      _emit();
      return MusicOperationResult(
        result.message,
        status: result.status,
        playlist: key == 'create' ? _reconciledCreated : null,
      );
    } finally {
      if (_account == owner) {
        _busy.remove(key);
        _emit();
      }
    }
  }

  Future<MusicOperationResult> setLiked(TrackId track, bool liked) {
    if (!isRemoteTrack(track)) {
      return Future.value(
        const MusicOperationResult(
          UiMessages.onlyNeteaseCloudMusicTracksAreSupported,
        ),
      );
    }
    final canonical = TrackId(NcmKind.track.canonical(track.value));
    return _run(
      'likes',
      (owner, mark) async {
        _ensure(owner);
        ++_likesGeneration;
        mark();
        await repository.setTrackLiked(canonical, liked);
        _ensure(owner);
        if (_liked != null) {
          _liked = {..._liked!};
          liked ? _liked!.add(canonical) : _liked!.remove(canonical);
          _emit();
        }
      },
      (owner) async {
        final ids = await repository.getLikedTrackIds(
          auth.current.session!.user.userId,
        );
        _ensure(owner);
        _liked = {
          for (final id in ids) TrackId(NcmKind.track.canonical(id.value)),
        };
        _emit();
        return _liked!.contains(canonical) == liked;
      },
      id: likedPlaylistId,
      favorites: true,
    );
  }

  Future<MusicOperationResult> subscribe(PlaylistId id, bool subscribed) =>
      _run(
        playlistKey(id),
        (owner, mark) async {
          final p = await fresh(id);
          _ensure(owner);
          if (p.summary.privacy == 10 ||
              owns(p.summary) ||
              NcmKind.playlist.canonical(id.value) ==
                  NcmKind.playlist.canonical(likedPlaylistId?.value ?? '')) {
            throw const AppError(
              category: AppErrorCategory.permission,
              code: 'music.permissionDenied',
              retryable: false,
            );
          }
          mark();
          await repository.setPlaylistSubscribed(id, subscribed);
        },
        (owner) async {
          final p = await fresh(id);
          _ensure(owner);
          final state = p.accountState?.subscription;
          if (state == null || state == SubscriptionEvidence.unknown) {
            return null;
          }
          return (state == SubscriptionEvidence.subscribed) == subscribed;
        },
        id: id,
      );

  Future<MusicOperationResult> subscribeAlbum(AlbumId id, bool subscribed) {
    if (NcmKind.album.digitsOf(id.value) == null) {
      return Future.value(
        const MusicOperationResult(
          UiMessages.onlyNeteaseCloudMusicAlbumsAreSupported,
        ),
      );
    }
    final canonical = AlbumId(NcmKind.album.canonical(id.value));
    return _run(
      albumKey(id),
      (owner, mark) async {
        _ensure(owner);
        if (!albumSubscriptionsLoaded || albumSubscriptionError != null) {
          if (!await _readAlbumSubscriptions(owner)) {
            throw StateError('album subscription read superseded');
          }
        }
        _ensure(owner);
        mark();
        ++_albumsGeneration;
        loadingAlbumSubscriptions = false;
        await repository.setAlbumSubscribed(canonical, subscribed);
        _ensure(owner);
        ++_albumsGeneration;
        loadingAlbumSubscriptions = false;
        if (subscribed) {
          _subscribedAlbums?.add(canonical);
        } else {
          _subscribedAlbums?.remove(canonical);
        }
        if (!subscribed) {
          _albumSummaries = List.unmodifiable(
            subscribedAlbums.where(
              (a) => NcmKind.album.canonical(a.id.value) != canonical.value,
            ),
          );
        }
        _emit();
        await loadAlbumSubscriptions();
      },
      (owner) async {
        _ensure(owner);
        if (!await _readAlbumSubscriptions(owner)) return null;
        _ensure(owner);
        return isAlbumSubscribed(canonical) == subscribed;
      },
    );
  }

  Future<MusicOperationResult> create(
    String name, {
    bool isPrivate = false,
  }) async {
    if (name.trim().isEmpty) {
      return const MusicOperationResult(UiMessages.playlistNameCannotBeEmpty);
    }
    PlaylistSummary? created;
    _reconciledCreated = null;
    Set<PlaylistId>? before;
    final result = await _run(
      'create',
      (owner, mark) async {
        await auth.loadUserPlaylists();
        _ensure(owner);
        if (!auth.current.playlistLoadFailed &&
            !auth.current.isUserPlaylistsPartial) {
          before = auth.current.userPlaylists.map((p) => p.id).toSet();
        }
        mark();
        created = await repository.createPlaylist(
          name.trim(),
          isPrivate: isPrivate,
        );
        _ensure(owner);
      },
      (owner) async {
        await auth.loadUserPlaylists();
        _ensure(owner);
        if (before == null ||
            auth.current.playlistLoadFailed ||
            auth.current.isUserPlaylistsPartial) {
          return null;
        }
        final matches = auth.current.userPlaylists
            .where(
              (p) =>
                  !before!.contains(p.id) &&
                  owns(p) &&
                  p.title == name.trim() &&
                  p.privacy == (isPrivate ? 10 : 0),
            )
            .toList();
        if (matches.length != 1) return null;
        created = matches.single;
        _reconciledCreated = created;
        return true;
      },
    );
    return MusicOperationResult(
      result.message,
      status: result.status,
      playlist: created,
    );
  }

  Future<MusicOperationResult> changeTracks(
    PlaylistId id,
    List<TrackId> tracks, {
    required bool add,
  }) async {
    if (tracks.isEmpty) {
      return const MusicOperationResult(UiMessages.selectTracksFirst);
    }
    if (tracks.any((t) => !isRemoteTrack(t))) {
      return const MusicOperationResult(
        UiMessages.onlyNeteaseCloudMusicTracksAreSupported,
      );
    }
    final requested = {
      for (final t in tracks) TrackId(NcmKind.track.canonical(t.value)),
    };
    var duplicates = 0;
    final result = await _run(
      playlistKey(id),
      (owner, mark) async {
        final p = await _owned(id, owner);
        if (!p.membershipComplete || p.membershipInferred) {
          throw const AppError(
            category: AppErrorCategory.provider,
            code: 'music.incomplete',
            retryable: false,
          );
        }
        final existing = {
          for (final e in p.entries)
            TrackId(NcmKind.track.canonical(e.trackId.value)),
        };
        final ids = requested
            .where((t) => add ? !existing.contains(t) : existing.contains(t))
            .toList();
        duplicates = requested.length - ids.length;
        if (ids.isNotEmpty) {
          _ensure(owner);
          mark();
          await repository.changePlaylistTracks(id, ids, add: add);
        }
      },
      (owner) async {
        final p = await fresh(id);
        if (!p.membershipComplete) return null;
        final ids = {
          for (final e in p.entries)
            TrackId(NcmKind.track.canonical(e.trackId.value)),
        };
        return add
            ? requested.every(ids.contains)
            : requested.every((t) => !ids.contains(t));
      },
      id: id,
    );
    return MusicOperationResult(
      result.success && duplicates > 0
          ? UiMessages.skippedTracks(
              (result.message).toString(),
              (duplicates).toString(),
              (add
                      ? UiMessages.tracksAlreadyPresent
                      : UiMessages.tracksNotPresent)
                  .toString(),
            )
          : result.message,
      status: result.status,
    );
  }

  Future<MusicOperationResult> delete(PlaylistId id) async {
    return _run(
      playlistKey(id),
      (owner, mark) async {
        await _owned(id, owner);
        _ensure(owner);
        mark();
        await repository.deletePlaylist(id);
      },
      (owner) async {
        await auth.loadUserPlaylists();
        _ensure(owner);
        if (auth.current.playlistLoadFailed ||
            auth.current.isUserPlaylistsPartial) {
          return null;
        }
        return !auth.current.userPlaylists.any((p) => p.id == id);
      },
      id: id,
      deleted: true,
      successMessage: UiMessages.deleted,
    );
  }

  Future<MusicOperationResult> reorder(
    PlaylistId id,
    List<TrackId> ordered, {
    List<TrackId>? expectedOrder,
  }) => _run(
    playlistKey(id),
    (owner, mark) async {
      final p = await _owned(id, owner);
      final before = p.entries
          .map((e) => NcmKind.track.canonical(e.trackId.value))
          .toList();
      final after = ordered
          .map((e) => NcmKind.track.canonical(e.value))
          .toList();
      if ((expectedOrder != null &&
              before.join(',') !=
                  expectedOrder
                      .map((t) => NcmKind.track.canonical(t.value))
                      .join(',')) ||
          !p.membershipComplete ||
          p.membershipInferred ||
          !p.detailsComplete ||
          p.missingCount > 0 ||
          before.toSet().length != before.length ||
          before.length != after.length ||
          after.toSet().length != after.length ||
          !before.toSet().containsAll(after)) {
        throw const AppError(
          category: AppErrorCategory.provider,
          code: 'music.orderConflict',
          retryable: false,
        );
      }
      _ensure(owner);
      mark();
      await repository.reorderPlaylist(id, ordered);
    },
    (owner) async {
      final p = await fresh(id);
      if (!p.membershipComplete) return null;
      return p.entries.map((e) => e.trackId.value).join(',') ==
          ordered.map((e) => e.value).join(',');
    },
    id: id,
  );

  Future<MusicOperationResult> edit(
    PlaylistId id, {
    required String name,
    required String description,
    required List<String> tags,
  }) async {
    if (name.trim().isEmpty) {
      return const MusicOperationResult(UiMessages.playlistNameCannotBeEmpty);
    }
    final messages = <String>[];
    var failed = false;
    final result = await _run(
      playlistKey(id),
      (owner, mark) async {
        final p = await _owned(id, owner);
        final edits = <(String, Future<void> Function())>[
          if (p.summary.title != name.trim())
            (
              UiMessages.name,
              () => repository.updatePlaylistName(id, name.trim()),
            ),
          if ((p.header.description ?? p.summary.description ?? '') !=
              description)
            (
              UiMessages.description2,
              () => repository.updatePlaylistDescription(id, description),
            ),
          if (p.header.tags.join(';') != tags.join(';'))
            (UiMessages.tags2, () => repository.updatePlaylistTags(id, tags)),
        ];
        for (final (label, action) in edits) {
          _ensure(owner);
          try {
            mark();
            await action();
            _ensure(owner);
            messages.add(UiMessages.succeeded((label).toString()));
          } catch (e) {
            messages.add('$label：${musicErrorMessage(e)}');
            if (e is AppError &&
                e.category == AppErrorCategory.authentication) {
              rethrow;
            }
            if (e is AppError &&
                (e.category == AppErrorCategory.network ||
                    e.code == 'music.invalidResponse' ||
                    e.code == 'provider.schemaChanged' ||
                    e.code == 'ncm.upstreamError')) {
              rethrow;
            }
            failed = true;
          }
        }
      },
      (owner) async {
        final p = await fresh(id);
        return p.summary.title == name.trim() &&
            (p.header.description ?? p.summary.description ?? '') ==
                description &&
            p.header.tags.join(';') == tags.join(';');
      },
      id: id,
    );
    return MusicOperationResult(
      messages.isEmpty
          ? result.message
          : UiMessages.composedText4(
              (messages.join('；')).toString(),
              (failed && result.success
                      ? UiMessages.remoteInformationRefreshed
                      : result.message)
                  .toString(),
            ),
      status: failed && result.success
          ? MusicOperationStatus.failed
          : result.status,
    );
  }

  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _changes.close();
  }
}

String musicErrorMessage(Object error) {
  if (error is! AppError) return UiMessages.operationFailedRefreshAndTryAgain;
  if (error.category == AppErrorCategory.authentication) {
    return UiMessages.signInAgain2;
  }
  if (error.category == AppErrorCategory.permission) {
    return UiMessages.youDoNotHavePermissionToModifyThis;
  }
  return switch (error.code) {
    'auth.required' || 'auth.expired' => UiMessages.signInAgain2,
    'music.permissionDenied' ||
    'ncm.permissionDenied' => UiMessages.youDoNotHavePermissionToModifyThis,
    'music.incomplete' =>
      UiMessages.playlistTracksAreNotFullyLoadedRetryLoading,
    'music.orderConflict' =>
      UiMessages.thePlaylistChangedOrTracksAreMissingReload,
    'network.timeout' => UiMessages.resultPending,
    'music.invalidResponse' =>
      UiMessages.unexpectedServiceResponseResultPending,
    _ => UiMessages.operationFailed((error.code).toString()),
  };
}
