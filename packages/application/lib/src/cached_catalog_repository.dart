import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';

/// The canonical id of [id], so a cache lookup cannot miss because one caller
/// spelled the id differently from another (design §4).
///
/// The spelling is [NcmKind]'s, which the provider that mints these ids parses
/// by the same rule: `123`, `ncm-123` and `ncm-playlist-123` name one record
/// instead of three cached copies of it.
TrackId canonicalTrackId(TrackId id) =>
    TrackId(NcmKind.track.canonical(id.value));

/// The canonical id of a playlist id.
PlaylistId canonicalPlaylistId(PlaylistId id) =>
    PlaylistId(NcmKind.playlist.canonical(id.value));

/// The canonical key for a search page (design §4).
///
/// Only meaningless surrounding whitespace is normalized: the keywords are
/// otherwise kept as typed, because a service may treat them differently.
String searchCacheKey(SearchQuery query) =>
    '${query.keywords.trim()}|${query.type}|${query.offset}|${query.limit}';

/// The account context a cached read belongs to (design §2, §9).
final class CatalogCacheContext {
  const CatalogCacheContext({
    required this.namespace,
    required this.accountId,
    this.accountEpoch = 0,
  });

  /// Separates provider deployments (docs/design/provider.md, docs/design/provider.md).
  final String namespace;

  /// The account the private partitions belong to; a signed-out launch uses
  /// `guest`, never an empty string, so it can never collide with "public".
  final String accountId;

  /// The credential owner's monotonic epoch (docs/design/accounts.md).
  final int accountEpoch;

  /// The partition for display data that is the same for everybody: track
  /// details and public playlist snapshots (design §2).
  CacheScope get publicScope => CacheScope.public(namespace: namespace);

  /// The partition for data that belongs to one account: user playlists and
  /// search pages.
  CacheScope get accountScope =>
      CacheScope(namespace: namespace, accountId: accountId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogCacheContext &&
          other.namespace == namespace &&
          other.accountId == accountId &&
          other.accountEpoch == accountEpoch;

  @override
  int get hashCode => Object.hash(namespace, accountId, accountEpoch);

  @override
  String toString() =>
      'CatalogCacheContext($namespace, $accountId, epoch $accountEpoch)';
}

/// Which cached record an update is about.
enum CatalogResource { playlist, track, playlistTracks, search }

/// A background refresh finished, successfully or not (design §3, §9).
final class CatalogInvalidation {
  const CatalogInvalidation({
    required this.resource,
    required this.key,
    this.error,
  });

  final CatalogResource resource;

  /// The canonical key of the affected record.
  final String key;

  /// Set when the refresh failed: the previous value and its freshness are
  /// still in place, and the failure is reported here rather than as a notice
  /// per row (design §9).
  final AppError? error;

  @override
  String toString() =>
      'CatalogInvalidation($resource, $key, error: ${error?.code})';
}

/// A catalog that reports what its background refreshes did (design §3).
abstract interface class CatalogUpdateSource {
  Stream<CatalogInvalidation> get invalidations;
}

/// The caching decorator over a remote catalog (design §3, §4, §5).
///
/// It owns the policy layer and nothing else: freshness decisions, request
/// merging, generation checks and the list-response backfill. The store behind
/// it owns persistence, and the provider behind that owns the protocol.
///
/// Readings are steered by [RefreshPolicy]:
///
/// * [RefreshPolicy.cacheFirst] returns fresh cache at once, returns stale
///   cache at once and refreshes behind it, and waits for the network only on a
///   miss.
/// * [RefreshPolicy.networkFirst] tries the network and falls back to a
///   displayable snapshot.
/// * [RefreshPolicy.forceRefresh] fetches past the freshness check and never
///   clears the screen first; a failure is reported without moving fresh times.
/// * [RefreshPolicy.localOnly] never touches the network and throws
///   [AppError] `cache.miss` when there is nothing to show. The startup path
///   uses it, because waiting on a network there is exactly what must not
///   happen (design §6).
///
/// It decorates one provider — the NCM side in this composition — so the app's
/// routing layer decides which ids ever reach it.
final class CachedCatalogRepository
    implements
        CatalogRepository,
        CatalogSearchRepository,
        HomeFeedRepository,
        CatalogDetailRepository,
        TrackBatchReader,
        CatalogUpdateSource,
        RecommendRepository,
        PlaylistSquareRepository {
  CachedCatalogRepository({
    required this.remote,
    required this.store,
    required this.accountContext,
    DateTime Function()? now,
    this.backgroundRefresh = true,
  }) : _now = now ?? DateTime.now,
       _batch = remote is TrackBatchReader ? remote as TrackBatchReader : null;

  /// The provider this decorator caches. It may also implement
  /// [TrackBatchReader], which is what turns a queue-wide labelling into a few
  /// requests instead of one per song (design §7).
  final CatalogRepository remote;

  final MetadataCacheStore store;

  /// The account context a read belongs to, resolved per call so an account
  /// switch is picked up without rebuilding this object (design §2).
  final CatalogCacheContext Function() accountContext;
  final DateTime Function() _now;

  /// Whether a stale read may start a refresh behind the caller. Tests turn it
  /// off to keep the timing deterministic.
  final bool backgroundRefresh;
  final Map<String, int> _resourceVersions = {};
  final Set<String> _dirtyPlaylists = {};
  String _playlistVersionKey(PlaylistId id) {
    final context = accountContext();
    return '${context.namespace}:${context.accountId}:${canonicalPlaylistId(id).value}';
  }

  Future<void> invalidatePlaylist(PlaylistId id) async {
    final canonical = canonicalPlaylistId(id);
    final resource = _playlistVersionKey(canonical);
    _resourceVersions[resource] = (_resourceVersions[resource] ?? 0) + 1;
    _dirtyPlaylists.add(resource);
    for (final key in _requestCounters.keys.toList()) {
      if (key == 'playlist:${canonical.value}' ||
          key.startsWith('playlist-tracks:${canonical.value}:')) {
        _requestCounters[key] = _requestCounters[key]! + 1;
      }
    }
    final cache = store;
    if (cache is PlaylistCacheInvalidator) {
      await (cache as PlaylistCacheInvalidator).invalidatePlaylistSnapshot(
        accountContext().accountScope,
        canonical,
      );
    }
  }

  final TrackBatchReader? _batch;
  final StreamController<CatalogInvalidation> _updates =
      StreamController<CatalogInvalidation>.broadcast();

  /// In-flight network work, keyed by the canonical key of what it produces.
  final Map<String, Future<Object?>> _inFlight = {};

  /// The newest request started per key, so an earlier request that answers
  /// later is dropped instead of overwriting it (design §4).
  final Map<String, int> _requestCounters = {};

  @override
  Stream<CatalogInvalidation> get invalidations => _updates.stream;

  void dispose() {
    _updates.close();
  }

  // -------------------------------------------------------------------------
  // CatalogRepository
  // -------------------------------------------------------------------------

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is HomeFeedRepository) {
      final sections = await Future.wait([
        getHomeSection(HomeSectionKind.recommended, policy: policy),
        getHomeSection(HomeSectionKind.dailyRecommendations, policy: policy),
        getHomeSection(HomeSectionKind.recentPlaylists, policy: policy),
      ]);
      final hour = _now().hour;
      final greeting = hour < 12
          ? UiMessages.goodMorning
          : (hour < 18 ? UiMessages.goodAfternoon : UiMessages.goodEvening);
      return HomeFeed(greeting: greeting, sections: sections);
    }
    return remote.getHomeFeed(policy: policy);
  }

  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final context = accountContext();
    final isAccountScoped =
        kind == HomeSectionKind.recommended ||
        kind == HomeSectionKind.dailyRecommendations ||
        kind == HomeSectionKind.recentPlaylists;
    final scope = isAccountScoped ? context.accountScope : context.publicScope;
    if (isAccountScoped && context.accountId == 'guest') {
      return HomeSection(
        kind: kind,
        title: switch (kind) {
          HomeSectionKind.recommended => UiMessages.recommendedPlaylists,
          HomeSectionKind.dailyRecommendations =>
            UiMessages.dailyRecommendations,
          HomeSectionKind.recentPlaylists => UiMessages.recentlyPlayedPlaylists,
          _ => '',
        },
        status: HomeSectionStatus.requiresAuth,
        requiresAuth: true,
      );
    }
    final key = 'home-section:${scope.accountId ?? 'public'}:${kind.name}';

    if (policy == RefreshPolicy.forceRefresh) {
      return _singleFlight(key, () => _fetchHomeSection(context, kind, scope));
    }

    final cached = await store.readHomeSections(scope);
    final cachedSection = cached[kind];

    if (policy == RefreshPolicy.localOnly) {
      if (cachedSection == null) _miss();
      return cachedSection;
    }

    if (cachedSection != null) {
      if (policy == RefreshPolicy.networkFirst) {
        try {
          return await _singleFlight(
            key,
            () => _fetchHomeSection(context, kind, scope),
          );
        } on AppError {
          return cachedSection;
        }
      }
      return cachedSection;
    }

    return _singleFlight(key, () => _fetchHomeSection(context, kind, scope));
  }

  Future<HomeSection> _fetchHomeSection(
    CatalogCacheContext context,
    HomeSectionKind kind,
    CacheScope scope,
  ) async {
    HomeSection section;
    if (remote is HomeFeedRepository) {
      section = await (remote as HomeFeedRepository).getHomeSection(kind);
    } else {
      final feed = await remote.getHomeFeed();
      section = feed.sections.firstWhere(
        (s) => s.kind == kind,
        orElse: () => HomeSection(
          kind: kind,
          title: kind.name,
          playlists: kind == HomeSectionKind.recommended
              ? feed.playlists
              : const [],
          status: HomeSectionStatus.ready,
        ),
      );
    }

    if (section.status == HomeSectionStatus.ready && !section.requiresAuth) {
      await store.commitHomeSection(scope, kind, section);
    }
    return section;
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final resource = _playlistVersionKey(id);
    final version = _resourceVersions[resource] ?? 0;
    if (policy == RefreshPolicy.localOnly &&
        _dirtyPlaylists.contains(resource)) {
      _miss();
    }
    final context = accountContext();
    final result = await _getPlaylist(
      id,
      policy: _dirtyPlaylists.contains(resource)
          ? RefreshPolicy.forceRefresh
          : policy,
    );
    if ((_resourceVersions[resource] ?? 0) != version ||
        accountContext() != context) {
      _invalidated();
    }
    return result;
  }

  Future<PlaylistDetail> _getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final context = accountContext();
    final canonical = canonicalPlaylistId(id);
    final key = canonical.value;
    final ticket = _readTicket(context);

    if (policy == RefreshPolicy.forceRefresh) {
      return _singleFlight(
        'playlist:$key',
        () => _fetchPlaylist(context, canonical, key),
      );
    }

    final snapshot = await store.readPlaylistSnapshot(
      _playlistScope(context),
      canonical,
    );

    if (policy == RefreshPolicy.localOnly) {
      if (snapshot == null) _miss();
      return _assemblePlaylist(context, snapshot, allowNetwork: false);
    }

    if (snapshot != null) {
      if (policy == RefreshPolicy.networkFirst) {
        try {
          return await _singleFlight(
            'playlist:$key',
            () => _fetchPlaylist(context, canonical, key),
          );
        } on AppError catch (error) {
          // The old snapshot is still browsable; its own refresh reports the
          // failure on the stream (design §5) — provided it is still this
          // account's snapshot (design §9).
          _ensureFallbackAllowed(ticket, error);
          return _assemblePlaylist(context, snapshot, allowNetwork: false);
        }
      }
      if (snapshot.envelope.freshnessAt(_now()) != CacheFreshness.fresh) {
        _refreshBehind(
          CatalogResource.playlist,
          key,
          () => _singleFlight(
            'playlist:$key',
            () => _fetchPlaylist(context, canonical, key),
          ),
        );
      }
      return _assemblePlaylist(context, snapshot, allowNetwork: true);
    }

    return _singleFlight(
      'playlist:$key',
      () => _fetchPlaylist(context, canonical, key),
    );
  }

  @override
  Future<Track> getTrack(
    TrackId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
    bool refreshCached = true,
    bool requireDetail = false,
  }) async {
    final context = accountContext();
    final canonical = canonicalTrackId(id);
    final key = 'track:${canonical.value}';
    final ticket = _readTicket(context);

    if (policy == RefreshPolicy.forceRefresh) {
      return _singleFlight(key, () => _fetchTrack(context, canonical));
    }

    final cached = await _cachedTracks(context, [canonical]);
    final record = cached[canonical];
    final now = _now();

    if (policy == RefreshPolicy.localOnly) {
      if (record == null) _miss();
      return record.track;
    }

    if (record != null && requireDetail && !record.isDetail) {
      return _singleFlight(key, () => _fetchTrack(context, canonical));
    }

    if (record != null &&
        policy == RefreshPolicy.cacheFirst &&
        !refreshCached) {
      return record.track;
    }

    if (record != null && record.freshnessAt(now) == CacheFreshness.fresh) {
      return record.track;
    }

    if (record != null && policy == RefreshPolicy.cacheFirst) {
      _refreshBehind(
        CatalogResource.track,
        key,
        () => _singleFlight(key, () => _fetchTrack(context, canonical)),
      );
      return record.track;
    }

    try {
      return await _singleFlight(key, () => _fetchTrack(context, canonical));
    } on AppError catch (error) {
      if (record != null && policy == RefreshPolicy.networkFirst) {
        _ensureFallbackAllowed(ticket, error);
        return record.track;
      }
      rethrow;
    }
  }

  /// Reads several tracks at once, serving what is fresh and asking only for
  /// what is missing or stale (design §7). With [refreshCached] disabled,
  /// cacheFirst reads keep existing labels and fetch missing identities or
  /// summary records when [requireDetail] is true. Detail lookups complete
  /// before returning, even when optional metadata is empty.
  @override
  Future<Map<TrackId, Track>> getTracks(
    Iterable<TrackId> ids, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
    bool refreshCached = true,
    bool requireDetail = false,
  }) async {
    final context = accountContext();
    final wanted = <TrackId, TrackId>{};
    for (final id in ids) {
      final canonical = canonicalTrackId(id);
      wanted[canonical] = canonical;
    }
    if (wanted.isEmpty) return const {};
    final canonicalIds = wanted.keys.toList();

    final cached = await _cachedTracks(context, canonicalIds);
    final now = _now();
    final result = <TrackId, Track>{};
    final behind = <TrackId>[];
    final blocking = <TrackId>[];

    for (final id in canonicalIds) {
      final record = cached[id];
      if (policy != RefreshPolicy.localOnly &&
          record != null &&
          requireDetail &&
          !record.isDetail) {
        blocking.add(id);
        continue;
      }
      if (record != null &&
          policy == RefreshPolicy.cacheFirst &&
          !refreshCached) {
        result[id] = record.track;
        continue;
      }
      if (policy != RefreshPolicy.forceRefresh &&
          record != null &&
          record.freshnessAt(now) == CacheFreshness.fresh) {
        result[id] = record.track;
        continue;
      }
      if (policy == RefreshPolicy.localOnly) {
        if (record != null) result[id] = record.track;
        continue;
      }
      if (record != null) {
        // A stale label is displayed first; only cacheFirst may defer the
        // refresh behind the caller (design §5).
        result[id] = record.track;
        (policy == RefreshPolicy.cacheFirst ? behind : blocking).add(id);
        continue;
      }
      blocking.add(id);
    }

    if (behind.isNotEmpty) {
      final key = _batchKey(behind);
      // The batch's canonical key is its id set, so identical simultaneous
      // calls share one round of requests and a caller that walks away does not
      // cancel the work the others are still waiting for (design §9).
      _refreshBehind(
        CatalogResource.track,
        key,
        () => _singleFlight(key, () => _fetchTracks(context, behind)),
      );
    }
    if (blocking.isNotEmpty) {
      final key = _batchKey(blocking);
      result.addAll(
        await _singleFlight(key, () => _fetchTracks(context, blocking)),
      );
    }
    return result;
  }

  static String _batchKey(Iterable<TrackId> ids) =>
      'batch:${(ids.map((id) => id.value).toList()..sort()).join(',')}';

  @override
  Future<SearchResult<Track>> searchTracks(
    SearchQuery query, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final context = accountContext();
    final queryKey = searchCacheKey(query);
    final key = 'search:$queryKey';
    final scope = context.accountScope;
    final ticket = _readTicket(context);

    if (policy == RefreshPolicy.forceRefresh) {
      return _singleFlight(key, () => _fetchSearch(context, query, queryKey));
    }

    final page = await store.readSearchPage(
      scope: scope,
      queryKey: queryKey,
      offset: query.offset,
    );

    if (policy == RefreshPolicy.localOnly) {
      if (page == null) _miss();
      return _assembleSearch(context, page, allowNetwork: false);
    }

    if (page != null) {
      if (policy == RefreshPolicy.networkFirst) {
        try {
          return await _singleFlight(
            key,
            () => _fetchSearch(context, query, queryKey),
          );
        } on AppError catch (error) {
          _ensureFallbackAllowed(ticket, error);
          return _assembleSearch(context, page, allowNetwork: false);
        }
      }
      if (page.envelope.freshnessAt(_now()) != CacheFreshness.fresh) {
        _refreshBehind(
          CatalogResource.search,
          key,
          () =>
              _singleFlight(key, () => _fetchSearch(context, query, queryKey)),
        );
      }
      return _assembleSearch(context, page, allowNetwork: true);
    }

    return _singleFlight(key, () => _fetchSearch(context, query, queryKey));
  }

  @override
  Future<SearchResult<CatalogItem>> search(
    SearchQuery query, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final searchType = query.searchType;
    final remoteSearch = remote is CatalogSearchRepository
        ? remote as CatalogSearchRepository
        : null;

    if (remoteSearch != null) {
      if (searchType == SearchType.track) {
        final trackRes = await searchTracks(query, policy: policy);
        return SearchResult<CatalogItem>(
          items: [for (final t in trackRes.items) TrackItem(t)],
          hasMore: trackRes.hasMore,
          totalCount: trackRes.totalCount,
        );
      }

      final queryKey = searchCacheKey(query);
      final key = 'search:$queryKey';
      final context = accountContext();
      final ticket = _readTicket(context);
      return _singleFlight(key, () async {
        final result = await remoteSearch.search(query);
        _ensurePartitionCurrent(ticket);
        final at = _now();
        final entities = <CatalogEntitySummary>[];
        for (final item in result.items) {
          switch (item) {
            case AlbumItem(:final album):
              entities.add(
                CatalogEntitySummary(
                  scope: context.publicScope,
                  kind: 'album',
                  entityId: album.id.value,
                  summaryJson: encodeAlbumSummary(album),
                  envelope: CacheEnvelope.fresh(
                    scope: context.publicScope,
                    at: at,
                    window: CacheContentKind.albumSummary.window,
                  ),
                ),
              );
            case ArtistItem(:final artist):
              entities.add(
                CatalogEntitySummary(
                  scope: context.publicScope,
                  kind: 'artist',
                  entityId: artist.id.value,
                  summaryJson: encodeArtistSummary(artist),
                  envelope: CacheEnvelope.fresh(
                    scope: context.publicScope,
                    at: at,
                    window: CacheContentKind.artistSummary.window,
                  ),
                ),
              );
            case PlaylistItem():
              break;
            case TrackItem():
              break;
          }
        }
        if (entities.isNotEmpty) {
          await store.putCatalogEntities(entities);
        }
        _ensurePartitionCurrent(ticket);
        return result;
      });
    }

    if (searchType == SearchType.track) {
      final trackRes = await searchTracks(query, policy: policy);
      return SearchResult<CatalogItem>(
        items: [for (final t in trackRes.items) TrackItem(t)],
        hasMore: trackRes.hasMore,
        totalCount: trackRes.totalCount,
      );
    }

    _unsupported('search.${searchType.name}.unsupported');
  }

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async {
    final context = accountContext();
    final canonicalId = NcmKind.album.canonical(id.value);
    final key = 'album:$canonicalId';

    return _singleFlight(key, () async {
      try {
        if (remote is CatalogDetailRepository) {
          final detail = await (remote as CatalogDetailRepository).getAlbum(id);
          final summaryJson = encodeAlbumSummary(detail.summary);
          await store.putCatalogEntities([
            CatalogEntitySummary(
              scope: context.publicScope,
              kind: 'album',
              entityId: canonicalId,
              summaryJson: summaryJson,
              envelope: CacheEnvelope.fresh(
                scope: context.publicScope,
                at: _now(),
                window: CacheContentKind.albumSummary.window,
              ),
            ),
          ]);
          await _writeTracks(context, detail.tracks);
          return detail;
        }
        _unsupported('album.detail.unsupported');
      } on AppError {
        final cached = await store.readCatalogEntities(
          context.publicScope,
          'album',
          [canonicalId],
        );
        final entity = cached[canonicalId];
        if (entity != null) {
          final summary = decodeAlbumSummary(entity.summaryJson);
          if (summary != null) {
            return AlbumDetail(
              summary: summary,
              tracks: const [],
              isPartial: true,
            );
          }
        }
        rethrow;
      }
    });
  }

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async {
    final context = accountContext();
    final canonicalId = NcmKind.artist.canonical(id.value);
    final key = 'artist:$canonicalId';

    return _singleFlight(key, () async {
      try {
        if (remote is CatalogDetailRepository) {
          final detail = await (remote as CatalogDetailRepository).getArtist(
            id,
          );
          final summaryJson = encodeArtistSummary(detail.summary);
          await store.putCatalogEntities([
            CatalogEntitySummary(
              scope: context.publicScope,
              kind: 'artist',
              entityId: canonicalId,
              summaryJson: summaryJson,
              envelope: CacheEnvelope.fresh(
                scope: context.publicScope,
                at: _now(),
                window: CacheContentKind.artistSummary.window,
              ),
            ),
          ]);
          await _writeTracks(context, detail.tracks);
          return detail;
        }
        _unsupported('artist.detail.unsupported');
      } on AppError {
        final cached = await store.readCatalogEntities(
          context.publicScope,
          'artist',
          [canonicalId],
        );
        final entity = cached[canonicalId];
        if (entity != null) {
          final summary = decodeArtistSummary(entity.summaryJson);
          if (summary != null) {
            return ArtistDetail(
              summary: summary,
              tracks: const [],
              isPartial: true,
            );
          }
        }
        rethrow;
      }
    });
  }

  Never _unsupported(String operation) => throw AppError(
    category: AppErrorCategory.provider,
    code: 'provider.unsupported',
    retryable: false,
    diagnosticId: operation,
  );

  /// One page of a playlist's songs.
  ///
  /// A complete, displayable snapshot already holds every ordinal, so a page is
  /// served from it rather than asked for again; anything the snapshot does not
  /// cover is read from the provider and its songs backfilled (design §7).
  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final resource = _playlistVersionKey(id);
    final version = _resourceVersions[resource] ?? 0;
    if (policy == RefreshPolicy.localOnly &&
        _dirtyPlaylists.contains(resource)) {
      _miss();
    }
    final context = accountContext();
    final result = await _getPlaylistTracks(
      id,
      limit: limit,
      offset: offset,
      policy: _dirtyPlaylists.contains(resource)
          ? RefreshPolicy.forceRefresh
          : policy,
    );
    if ((_resourceVersions[resource] ?? 0) != version ||
        accountContext() != context) {
      _invalidated();
    }
    return result;
  }

  Future<SearchResult<Track>> _getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final context = accountContext();
    final canonical = canonicalPlaylistId(id);

    if (policy != RefreshPolicy.forceRefresh && offset >= 0 && limit > 0) {
      final snapshot = await store.readPlaylistSnapshot(
        _playlistScope(context),
        canonical,
      );
      if (snapshot != null &&
          (snapshot.isComplete ||
              snapshot.entryTrackIds.length > offset + limit)) {
        final slice = snapshot.entryTrackIds.skip(offset).take(limit).toList();
        final cached = await _cachedTracks(context, slice);
        final result = <TrackId, Track>{};
        final needed = <TrackId>[];
        for (final trackId in slice) {
          final record = cached[trackId];
          if (record != null) {
            result[trackId] = record.track;
          }
          if (policy != RefreshPolicy.localOnly && record == null) {
            needed.add(trackId);
          }
        }
        if (needed.isNotEmpty) {
          result.addAll(await _fetchTracks(context, needed));
        }
        return SearchResult(
          items: [
            for (final trackId in slice)
              if (result[trackId] != null) result[trackId]!,
          ],
          hasMore:
              snapshot.entryTrackIds.length > offset + limit ||
              !snapshot.isComplete,
          totalCount: snapshot.totalCount,
        );
      }
      if (policy == RefreshPolicy.localOnly) _miss();
    }
    if (policy == RefreshPolicy.localOnly) _miss();

    final key = 'playlist-tracks:${canonical.value}:$limit:$offset';
    return _singleFlight(key, () async {
      final page = await remote.getPlaylistTracks(
        canonical,
        limit: limit,
        offset: offset,
      );
      await _writeTracks(context, page.items);
      return page;
    });
  }

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return remote.getPlaylistAccess(id, policy: policy);
  }

  // -------------------------------------------------------------------------
  // Reads and writes
  // -------------------------------------------------------------------------

  Track _publicTrack(Track track) => Track(
    id: track.id,
    title: track.title,
    artists: track.artists,
    album: track.album,
    duration: track.duration,
    maxPotentialQuality: track.objectiveQuality ?? TrackQuality.unknown,
    fee: track.fee,
    alias: track.alias,
    translationNames: track.translationNames,
    objectiveQuality: track.objectiveQuality,
    audioSpecs: track.audioSpecs,
  );

  Future<Map<TrackId, CachedTrack>> _cachedTracks(
    CatalogCacheContext context,
    Iterable<TrackId> ids,
  ) async {
    final ticket = _readTicket(context);
    final wanted = ids.toList();
    final shared = await store.readTracks(context.publicScope, wanted);
    final private = await store.readTracks(
      context.accountScope,
      wanted,
      includeExpired: true,
    );
    _ensurePartitionCurrent(ticket);
    final values = <TrackId, CachedTrack>{};
    for (final entry in shared.entries) {
      final record = entry.value;
      final own = private[entry.key];
      // Legacy shared permission ceilings are unsafe across account switches.
      final groups = {...record.groups}
        ..remove(TrackFieldGroup.availability)
        ..remove(TrackFieldGroup.maxPotentialQuality);
      final objectiveEnvelope = record.groups[TrackFieldGroup.objectiveQuality];
      if (record.track.objectiveQuality != null && objectiveEnvelope != null) {
        groups[TrackFieldGroup.maxPotentialQuality] = objectiveEnvelope;
      }
      var clean = CachedTrack(
        track: _publicTrack(record.track),
        groups: groups,
        envelope: record.envelope,

        isDetail: record.isDetail,
      );
      final at = _now();
      for (final group in [
        TrackFieldGroup.availability,
        if (clean.track.objectiveQuality == null)
          TrackFieldGroup.maxPotentialQuality,
      ]) {
        if (own != null &&
            own.knows(group) &&
            own.freshnessOf(group, at) != CacheFreshness.miss) {
          clean = mergeCachedTrack(
            clean,
            CachedTrack(
              track: own.track,
              groups: {group: own.groups[group]!},
              envelope: clean.envelope,

              isDetail: clean.isDetail,
            ),
          );
        } else {
          // Keep shared metadata displayable while account permissions refresh.
          clean = CachedTrack(
            track: clean.track,
            groups: {
              ...clean.groups,
              group: CacheEnvelope(
                scope: context.accountScope,
                fetchedAt: at,
                freshUntil: at,
                staleUntil: at.add(
                  CacheContentKind.trackDetail.window.maxStale,
                ),
              ),
            },
            envelope: clean.envelope,

            isDetail: clean.isDetail,
          );
        }
      }
      values[entry.key] = clean;
    }
    return values;
  }

  /// The normalized entity for [track], naming only the field groups the
  /// provider actually carried (design §4).
  CachedTrack _trackRecord(
    Track track, {
    required CacheScope scope,
    required DateTime at,
    bool isDetail = false,
  }) {
    CacheEnvelope envelopeFor(CacheContentKind kind) =>
        CacheEnvelope.fresh(scope: scope, at: at, window: kind.window);

    return CachedTrack(
      track: track,
      isDetail: isDetail,
      groups: {
        for (final group in TrackFieldGroup.values)
          if (trackHasValueFor(track, group) ||
              (group == TrackFieldGroup.translationNames && isDetail))
            group: envelopeFor(
              group == TrackFieldGroup.artwork
                  ? CacheContentKind.artwork
                  : CacheContentKind.trackDetail,
            ),
      },
      envelope: envelopeFor(CacheContentKind.trackDetail),
    );
  }

  Future<void> _writeTracks(
    CatalogCacheContext context,
    Iterable<Track> tracks, {
    bool isDetail = false,
  }) async {
    final ticket = _readTicket(context);
    _ensurePartitionCurrent(ticket);
    final at = _now();
    final values = tracks.toList();
    if (values.isEmpty) return;
    await store.putTracks([
      for (final track in values)
        _trackRecord(
          _publicTrack(track),
          scope: context.publicScope,

          isDetail: isDetail,
          at: at,
        ),
    ]);
    _ensurePartitionCurrent(ticket);
    final unknownIds = [
      for (final track in values)
        if (!trackHasValueFor(track, TrackFieldGroup.availability) ||
            (track.objectiveQuality == null &&
                !trackHasValueFor(track, TrackFieldGroup.maxPotentialQuality)))
          canonicalTrackId(track.id),
    ];
    final existing = unknownIds.isEmpty
        ? const <TrackId, CachedTrack>{}
        : await store.readTracks(
            context.accountScope,
            unknownIds,
            includeExpired: true,
          );
    _ensurePartitionCurrent(ticket);
    final records = <CachedTrack>[];
    for (final track in values) {
      final own = existing[canonicalTrackId(track.id)];
      final groups = <TrackFieldGroup, CacheEnvelope>{};
      for (final group in [
        TrackFieldGroup.availability,
        if (track.objectiveQuality == null) TrackFieldGroup.maxPotentialQuality,
      ]) {
        // Sparse responses neither replace nor renew existing evidence.
        // Cache unknown briefly only when there is no unexpired evidence.
        if (trackHasValueFor(track, group) ||
            own == null ||
            own.freshnessOf(group, at) == CacheFreshness.miss) {
          groups[group] = CacheEnvelope.fresh(
            scope: context.accountScope,
            at: at,
            window: CacheContentKind.playlistAccess.window,
          );
        }
      }
      if (groups.isNotEmpty) {
        records.add(
          CachedTrack(
            track: track,
            groups: groups,
            envelope: CacheEnvelope.fresh(
              scope: context.accountScope,
              at: at,
              window: CacheContentKind.trackDetail.window,
            ),
          ),
        );
      }
    }
    await store.putTracks(records);
  }

  /// The partition a playlist snapshot belongs to.
  ///
  /// Even a summary with public privacy metadata can carry account-dependent
  /// subscription and access data. Whole playlist snapshots therefore belong
  /// to the account that asked for them, and nothing an account cached can be read back
  /// by another account or by a signed-out launch (design §2, §9).
  CacheScope _playlistScope(CatalogCacheContext context) =>
      context.accountScope;

  Future<PlaylistDetail> _fetchPlaylist(
    CatalogCacheContext context,
    PlaylistId id,
    String key,
  ) async {
    final resourceKey = 'playlist:$key';
    final ticket = _beginFetch(resourceKey);
    final existing = await store.readPlaylistSnapshot(
      _playlistScope(context),
      id,
    );
    final detail = await remote.getPlaylist(id);
    // A result from an account or a cache generation that is gone is refused
    // rather than published: writing nothing is not enough, because the caller
    // would still render another account's playlist (design §9).
    _ensurePartitionCurrent(ticket);
    final canCommit = _isCurrent(ticket, resourceKey);
    if (!canCommit) _invalidated();

    if (canCommit) {
      await _writeTracks(context, detail.tracks);
    }

    if (detail.isPartial && (existing?.isComplete ?? false)) {
      // A refresh that could not be completed must not replace a complete
      // offline list with a shorter one. The songs it did carry are still worth
      // keeping, the snapshot is not replaced, and the failure is reported
      // (design §4, §9).
      _incompleteRefresh();
    }

    if (canCommit) {
      if (!_isCurrent(ticket, resourceKey)) _invalidated();
      await store.commitPlaylistSnapshot(
        PlaylistSnapshot(
          summary: detail.summary,
          header: detail.header,
          entryTrackIds: [
            for (final track in detail.tracks) canonicalTrackId(track.id),
          ],
          isComplete: !detail.isPartial && !detail.membershipInferred,
          totalCount: detail.summary.trackCount,
          generation: _nextPlaylistGeneration(id),
          envelope: CacheEnvelope.fresh(
            scope: _playlistScope(context),
            at: _now(),
            window: CacheContentKind.playlistEntries.window,
          ),
        ),
      );
    }
    _dirtyPlaylists.remove(_playlistVersionKey(id));
    return detail;
  }

  Future<PlaylistDetail> _assemblePlaylist(
    CatalogCacheContext context,
    PlaylistSnapshot snapshot, {
    required bool allowNetwork,
  }) async {
    final entries = snapshot.entryTrackIds;
    final records = await _cachedTracks(context, entries);
    var cached = {
      for (final entry in records.entries) entry.key: entry.value.track,
    };
    final missing = {
      for (final id in entries)
        if (records[id] == null) id,
    };
    if (allowNetwork && missing.isNotEmpty) {
      cached = {...cached, ...await _fetchTracks(context, missing.toList())};
    }
    final tracks = [
      for (final id in entries)
        if (cached[id] != null) cached[id]!,
    ];
    return PlaylistDetail(
      summary: snapshot.summary,
      header: snapshot.header,
      tracks: tracks,
      isPartial: !snapshot.isComplete || tracks.length < entries.length,
    );
  }

  Future<Track> _fetchTrack(CatalogCacheContext context, TrackId id) async {
    final key = 'track:${id.value}';
    final ticket = _beginFetch(key);
    final Track track;
    try {
      track = await remote.getTrack(id);
    } on AppError catch (error) {
      // An explicit "no such song" is worth remembering for minutes; a timeout
      // or a 5xx is not, because it says nothing about the song (design §9).
      if (error.code == 'ncm.trackNotFound' && _isCurrent(ticket, key)) {
        await store.putAbsentTracks([
          AbsentTrackRecord(
            trackId: id,
            envelope: CacheEnvelope.fresh(
              scope: context.publicScope,
              at: _now(),
              window: CacheContentKind.absentTrack.window,
            ),
          ),
        ]);
      }
      rethrow;
    }
    _ensurePartitionCurrent(ticket);
    if (_isCurrent(ticket, key)) {
      await _writeTracks(context, [track], isDetail: true);
    }
    return track;
  }

  /// Reads the ids that are missing or stale, in as few requests as the
  /// provider allows (design §7).
  Future<Map<TrackId, Track>> _fetchTracks(
    CatalogCacheContext context,
    List<TrackId> ids,
  ) async {
    final absent = await store.readAbsentTracks(context.publicScope, ids);
    final now = _now();
    final result = <TrackId, Track>{};
    final wanted = <TrackId>[];
    for (final id in ids) {
      final record = absent[id];
      // A believable absence is an answer, not a reason to ask again.
      if (record != null && record.isBelievableAt(now)) continue;
      wanted.add(id);
    }
    if (wanted.isEmpty) return result;

    final batch = _batch;
    if (batch == null) {
      for (final id in wanted) {
        try {
          result[id] = await _fetchTrack(context, id);
        } on AppError catch (error) {
          if (error.code != 'ncm.trackNotFound') rethrow;
        }
      }
      return result;
    }

    final key = _batchKey(wanted);
    final ticket = _beginFetch(key);
    final fetched = await batch.getTracks(wanted);
    _ensurePartitionCurrent(ticket);
    if (!_isCurrent(ticket, key)) return fetched;
    // An id the provider did not answer stays absent: a batch omitting an id
    // does not prove the song is gone, so no negative record is written
    // (design §9).
    await _writeTracks(context, [
      for (final id in wanted)
        if (fetched[id] != null) fetched[id]!,
    ], isDetail: true);
    for (final entry in fetched.entries) {
      result[entry.key] = entry.value;
    }
    return result;
  }

  Future<SearchResult<Track>> _fetchSearch(
    CatalogCacheContext context,
    SearchQuery query,
    String queryKey,
  ) async {
    final key = 'search:$queryKey';
    final ticket = _beginFetch(key);
    final page = await remote.searchTracks(query);
    _ensurePartitionCurrent(ticket);
    if (!_isCurrent(ticket, key)) return page;

    await _writeTracks(context, page.items);
    final generation = _nextPlaylistGeneration(PlaylistId('search:$queryKey'));
    await store.putSearchPage(
      queryKey: queryKey,
      page: CachedIdPage<TrackId>(
        ids: [for (final track in page.items) canonicalTrackId(track.id)],
        offset: query.offset,
        limit: query.limit,
        hasMore: page.hasMore,
        isComplete: true,
        generation: generation,
        envelope: CacheEnvelope.fresh(
          scope: context.accountScope,
          at: _now(),
          window: CacheContentKind.searchResults.window,
        ),
      ),
    );
    await store.pruneIdPages(
      scope: context.accountScope,
      queryKey: queryKey,
      generation: generation,
      kind: 'search',
    );
    return page;
  }

  Future<SearchResult<Track>> _assembleSearch(
    CatalogCacheContext context,
    CachedIdPage<TrackId> page, {
    required bool allowNetwork,
  }) async {
    final records = await _cachedTracks(context, page.ids);
    var cached = {
      for (final entry in records.entries) entry.key: entry.value.track,
    };
    final missing = {
      for (final id in page.ids)
        if (records[id] == null) id,
    };
    if (allowNetwork && missing.isNotEmpty) {
      cached = {...cached, ...await _fetchTracks(context, missing.toList())};
    }
    return SearchResult(
      items: [
        for (final id in page.ids)
          if (cached[id] != null) cached[id]!,
      ],
      hasMore: page.hasMore,
    );
  }

  // -------------------------------------------------------------------------
  // Scheduling and generation
  // -------------------------------------------------------------------------

  /// Starts a refresh behind the caller and reports what it did.
  void _refreshBehind(
    CatalogResource resource,
    String key,
    Future<void> Function() refresh,
  ) {
    if (!backgroundRefresh) return;
    unawaited(() async {
      try {
        await refresh();
        _emit(CatalogInvalidation(resource: resource, key: key));
      } on AppError catch (error) {
        _emit(CatalogInvalidation(resource: resource, key: key, error: error));
      }
    }());
  }

  void _emit(CatalogInvalidation update) {
    if (!_updates.isClosed) _updates.add(update);
  }

  /// Merges concurrent work for the same canonical key (design §9).
  ///
  /// Callers that stop listening do not cancel the shared request, so one
  /// subscriber walking away cannot take the result from the others.
  ///
  /// The merge key is the resource *plus the partition it is read for*: two
  /// accounts searching the same words, or the same account on either side of a
  /// cache clear, are two different requests and must not share one answer.
  Future<T> _singleFlight<T>(String key, Future<T> Function() body) {
    final flight = _flightKey(key);
    final existing = _inFlight[flight];
    if (existing != null) return existing as Future<T>;
    // A block body, not an arrow: an arrow would *return* the removed future,
    // and `whenComplete` awaits a returned future — which here is the very
    // future being completed, deadlocking it.
    final future = body().whenComplete(() {
      _inFlight.remove(flight);
    });
    _inFlight[flight] = future;
    return future;
  }

  /// The in-flight key for [key]: the resource plus the partition reading it.
  String _flightKey(String key) {
    final context = accountContext();
    return '$key@${context.namespace}:${context.accountId}:'
        '${context.accountEpoch}#${store.cacheGeneration}:${_flightResourceVersion(key)}';
  }

  int _flightResourceVersion(String key) {
    final parts = key.split(':');
    if (parts.length < 2 ||
        (parts.first != 'playlist' && parts.first != 'playlist-tracks')) {
      return 0;
    }
    return _resourceVersions[_playlistVersionKey(PlaylistId(parts[1]))] ?? 0;
  }

  _RequestTicket _beginFetch(String key) {
    if (_requestCounters.length > 512) {
      // Keep the map bounded; counters for keys with nothing in flight cannot
      // be needed again, and dropping a counter only costs one redundant
      // fetch.
      _requestCounters.removeWhere((key, _) => !_inFlight.containsKey(key));
    }
    final request = (_requestCounters[key] ?? 0) + 1;
    _requestCounters[key] = request;
    return _RequestTicket(accountContext(), store.cacheGeneration, request);
  }

  /// Whether a result may still be written and published (design §9).
  bool _isCurrent(_RequestTicket ticket, String key) {
    final context = accountContext();
    return context.accountEpoch == ticket.context.accountEpoch &&
        context.accountId == ticket.context.accountId &&
        store.cacheGeneration == ticket.cacheGeneration &&
        (_requestCounters[key] ?? 0) == ticket.requestGeneration;
  }

  /// Whether the partition [ticket] was started in is still the live one.
  ///
  /// This is [_isCurrent] without the request counter: a result that a *newer
  /// request for the same resource* has superseded may still be handed back, but
  /// one from an account or a cache generation that no longer exists may not.
  bool _sharesPartition(_RequestTicket ticket) {
    final context = accountContext();
    return context.namespace == ticket.context.namespace &&
        context.accountId == ticket.context.accountId &&
        context.accountEpoch == ticket.context.accountEpoch &&
        store.cacheGeneration == ticket.cacheGeneration;
  }

  /// Refuses to publish a result whose account or cache generation is gone: the
  /// caller retries instead of rendering another account's answer (design §9).
  void _ensurePartitionCurrent(_RequestTicket ticket) {
    if (_sharesPartition(ticket)) return;
    _invalidated();
  }

  /// The partition a read was started in, so a fallback that answers it can
  /// prove it is still the live one (design §9).
  ///
  /// The request counter is deliberately left out: a fallback asks *whose*
  /// stored value this is, not which read is the newest.
  _RequestTicket _readTicket(CatalogCacheContext context) =>
      _RequestTicket(context, store.cacheGeneration, 0);

  /// Refuses a fallback the failure does not justify (design §9).
  ///
  /// A network or provider failure says nothing about the stored value, so the
  /// value stays usable. An answer refused because its partition moved says
  /// everything: the value was read for an account or a cache generation that
  /// is gone, and handing it back puts another account's content on screen.
  /// Clearing the old account's own records is no protection here — the public
  /// entities a stale page would be assembled from outlive that partition.
  void _ensureFallbackAllowed(_RequestTicket ticket, AppError error) {
    if (error.code == 'cache.invalidated' || !_sharesPartition(ticket)) {
      _invalidated();
    }
  }

  int _nextPlaylistGeneration(PlaylistId id) =>
      (_playlistGenerations[id.value] =
          (_playlistGenerations[id.value] ?? 0) + 1);

  final Map<String, int> _playlistGenerations = {};

  Never _miss() => throw const AppError(
    category: AppErrorCategory.storage,
    code: 'cache.miss',
    retryable: true,
    diagnosticId: 'cache.miss',
  );

  /// A result produced for an account or a cache generation that has since
  /// moved: it is refused rather than handed to the caller, who retries
  /// (design §9).
  Never _invalidated() => throw const AppError(
    category: AppErrorCategory.storage,
    code: 'cache.invalidated',
    retryable: true,
    diagnosticId: 'cache.invalidated',
  );

  /// A refresh the provider could only answer in part, on top of a complete
  /// snapshot that therefore stays (design §4).
  Never _incompleteRefresh() => throw const AppError(
    category: AppErrorCategory.provider,
    code: 'cache.playlistRefreshIncomplete',
    retryable: true,
    diagnosticId: 'cache.playlistRefreshIncomplete',
  );

  // -------------------------------------------------------------------------
  // RecommendRepository
  // -------------------------------------------------------------------------

  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! RecommendRepository) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.unsupported',
        retryable: false,
      );
    }
    final context = accountContext();
    final ticket = _readTicket(context);
    final scope = context.accountScope;
    final localNow = _now().toLocal();
    final effectiveDateKey =
        dateKey ??
        '${localNow.year}-${localNow.month.toString().padLeft(2, '0')}-${localNow.day.toString().padLeft(2, '0')}';

    Future<DailySongsRead> fetch(RefreshPolicy refreshPolicy) =>
        _fetchDailySongs(ticket, effectiveDateKey, refreshPolicy);

    if (policy == RefreshPolicy.forceRefresh) {
      return fetch(policy);
    }

    final cached = await store.readDailySongs(scope, effectiveDateKey);
    _ensurePartitionCurrent(ticket);
    if (policy == RefreshPolicy.localOnly) {
      if (cached == null) _miss();
      return DailySongsRead(
        snapshot: cached,
        source: DailySongsSource.cache,
        refreshedAt: cached.fetchedAt,
      );
    }

    if (cached != null) {
      final isFresh = _now().isBefore(cached.staleUntil);
      if (isFresh) {
        return DailySongsRead(
          snapshot: cached,
          source: DailySongsSource.cache,
          refreshedAt: cached.fetchedAt,
        );
      }
      if (policy == RefreshPolicy.networkFirst) {
        try {
          return await fetch(policy);
        } on AppError catch (error) {
          _ensureFallbackAllowed(ticket, error);
          return DailySongsRead(
            snapshot: cached,
            source: DailySongsSource.cache,
            refreshFailed: true,
            refreshedAt: cached.fetchedAt,
          );
        }
      }
      if (backgroundRefresh) {
        unawaited(
          _singleFlight<void>('daily-songs:$effectiveDateKey', () async {
            await fetch(RefreshPolicy.forceRefresh);
          }).catchError((Object _) {}),
        );
      }
      return DailySongsRead(
        snapshot: cached,
        source: DailySongsSource.cache,
        refreshedAt: cached.fetchedAt,
      );
    }

    return fetch(policy);
  }

  Future<DailySongsRead> _fetchDailySongs(
    _RequestTicket ticket,
    String dateKey,
    RefreshPolicy policy,
  ) async {
    final read = await (remote as RecommendRepository).getDailySongs(
      dateKey: dateKey,
      policy: policy,
    );
    _ensurePartitionCurrent(ticket);
    // The cache owns the authenticated account identity. Provider payloads
    // cannot choose the partition in which private recommendations are stored.
    final incoming = read.snapshot;
    final snapshot = DailySongsSnapshot(
      namespace: ticket.context.namespace,
      accountId: ticket.context.accountId,
      dateKey: incoming.dateKey,
      songs: incoming.songs,
      fetchedAt: incoming.fetchedAt,
      staleUntil: incoming.staleUntil,
      retainUntil: incoming.retainUntil,
      snapshotGeneration: incoming.snapshotGeneration,
    );
    await store.putDailySongs(snapshot);
    _ensurePartitionCurrent(ticket);
    return DailySongsRead(
      snapshot: snapshot,
      source: read.source,
      refreshFailed: read.refreshFailed,
      refreshedAt: read.refreshedAt,
    );
  }

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! RecommendRepository) {
      return const RecommendedPlaylists();
    }
    return (remote as RecommendRepository).getRecommendedPlaylists(
      policy: policy,
    );
  }

  @override
  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! RecommendRepository) {
      return const [];
    }
    return (remote as RecommendRepository).getNewSongs(
      limit: limit,
      policy: policy,
    );
  }

  CatalogCacheContext? _recentListeningContext;
  ListenResources? _cachedRecentListening;
  DateTime? _recentListeningFetchedAt;

  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! RecommendRepository) {
      return const ListenResources();
    }
    final context = accountContext();
    final ticket = _readTicket(context);
    final recRepo = remote as RecommendRepository;

    if (_recentListeningContext != context) {
      _recentListeningContext = context;
      _cachedRecentListening = null;
      _recentListeningFetchedAt = null;
    }

    final isCacheValid =
        _cachedRecentListening != null &&
        _recentListeningFetchedAt != null &&
        _now().difference(_recentListeningFetchedAt!) <
            const Duration(minutes: 5);

    if (policy == RefreshPolicy.cacheFirst && isCacheValid) {
      return _cachedRecentListening!;
    }

    if (policy == RefreshPolicy.localOnly) {
      if (_cachedRecentListening != null) {
        return _cachedRecentListening!;
      }
      return const ListenResources();
    }

    final fresh = await recRepo.getRecentListeningResources(policy: policy);
    _ensurePartitionCurrent(ticket);
    _cachedRecentListening = fresh;
    _recentListeningFetchedAt = _now();
    return fresh;
  }

  // -------------------------------------------------------------------------
  // PlaylistSquareRepository
  // -------------------------------------------------------------------------

  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! PlaylistSquareRepository) {
      return const PlaylistCategoryTree();
    }
    return (remote as PlaylistSquareRepository).getCategoryTree(policy: policy);
  }

  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! PlaylistSquareRepository) {
      return const [];
    }
    return (remote as PlaylistSquareRepository).getHotTags(policy: policy);
  }

  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! PlaylistSquareRepository) {
      return null;
    }
    return (remote as PlaylistSquareRepository).getHighQualityPlaylist(
      cat,
      policy: policy,
    );
  }

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (remote is! PlaylistSquareRepository) {
      return const SearchResult(items: [], hasMore: false, totalCount: 0);
    }
    return (remote as PlaylistSquareRepository).getSquarePlaylists(
      cat: cat,
      order: order,
      limit: limit,
      offset: offset,
      policy: policy,
    );
  }
}

final class _RequestTicket {
  const _RequestTicket(
    this.context,
    this.cacheGeneration,
    this.requestGeneration,
  );

  final CatalogCacheContext context;
  final int cacheGeneration;
  final int requestGeneration;
}
