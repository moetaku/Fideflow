import 'package:fideflow_domain/domain.dart';

import 'lyrics.dart';

/// Deterministic development data that exercises the same domain boundary as a
/// real NCM provider without requiring credentials or network access.
final class FakeCatalogRepository
    implements
        CatalogRepository,
        CatalogSearchRepository,
        HomeFeedRepository,
        CatalogDetailRepository,
        LyricsRepository,
        RecommendRepository,
        PlaylistSquareRepository,
        AccountMusicRepository {
  FakeCatalogRepository({this.latency = const Duration(milliseconds: 180)});

  final Duration latency;
  UserId _activeAccount = const UserId('ncm-user-fake');
  int _accountEpoch = 0;
  final Map<String, _DemoAccountData> _accounts = {};
  void activateAccount(UserId? id) {
    _accountEpoch++;
    _activeAccount = id ?? const UserId('guest');
  }

  void _requireAccount(int epoch) {
    if (epoch != _accountEpoch) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.epochMismatch',
        retryable: false,
      );
    }
  }

  void clearAccount(UserId id) {
    _accounts.remove(id.value);
  }

  _DemoAccountData get _account => _accounts.putIfAbsent(
    _activeAccount.value,
    () => _newAccount(_activeAccount),
  );
  _DemoAccountData _newAccount(UserId owner) {
    final state = _DemoAccountData();
    final summary = PlaylistSummary(
      id: PlaylistId('ncm-playlist-900000'),
      title: '我的体验歌单',
      subtitle: '体验账号',
      trackCount: 2,
      creatorId: owner,
      privacy: 0,
    );
    state.managed[summary.id] = PlaylistDetail.fromTracks(
      summary: summary,
      tracks: [
        for (var i = 0; i < 2; i++)
          Track(
            id: TrackId('ncm-${1001 + i}'),
            title: _tracks[i].title,
            artists: _tracks[i].artists,
            album: _tracks[i].album,
            duration: _tracks[i].duration,
          ),
      ],
    );
    return state;
  }

  Map<PlaylistId, PlaylistDetail> get _managed => _account.managed;
  Set<PlaylistId> get _deleted => _account.deleted;
  Set<TrackId> get _liked => _account.liked;
  bool get _favoriteTouched => _account.favoriteTouched;
  set _favoriteTouched(bool value) {
    _account.favoriteTouched = value;
  }

  Map<PlaylistId, bool> get _subscriptionOverrides =>
      _account.subscriptionOverrides;
  Set<PlaylistId> get _subscribed => _account.subscribed;
  Set<AlbumId> get _subscribedAlbums => _account.subscribedAlbums;
  int _nextPlaylist = 900000;
  PlaylistSummary get fakeLikedSummary => PlaylistSummary(
    id: const PlaylistId('playlist-acoustic'),
    title: '我喜欢的音乐',
    subtitle: '体验账号',
    trackCount: _favoriteTouched ? _liked.length : 4,
    specialType: 5,
    creatorId: _activeAccount,
  );
  List<PlaylistSummary> get managedUserPlaylists => [
    ..._managed.values.map((p) => p.summary),
    for (final p in _playlists)
      if (_subscribed.contains(p.id)) p,
  ];
  PlaylistDetail _replaceManaged(
    PlaylistId id, {
    String? name,
    String? description,
    List<String>? tags,
    List<Track>? tracks,
  }) {
    final p = _managed[id]!;
    final members = tracks ?? p.tracks;
    final summary = PlaylistSummary(
      id: id,
      title: name ?? p.summary.title,
      subtitle: p.summary.subtitle,
      trackCount: members.length,
      description: description ?? p.summary.description,
      creatorId: p.summary.creatorId,
      privacy: p.summary.privacy,
      specialType: p.summary.specialType,
    );
    return _managed[id] = PlaylistDetail.fromTracks(
      summary: summary,
      tracks: members,
      header: PlaylistHeaderMetadata(
        creator: PlaylistCreator(userId: summary.creatorId),
        description: summary.description,
        tags: tags ?? p.header.tags,
      ),
    );
  }

  @override
  Future<Set<TrackId>> getLikedTrackIds(UserId user) async =>
      Set.unmodifiable(_liked);
  @override
  Future<void> setTrackLiked(TrackId track, bool liked) async {
    _favoriteTouched = true;
    liked ? _liked.add(track) : _liked.remove(track);
  }

  @override
  Future<void> setPlaylistSubscribed(
    PlaylistId playlist,
    bool subscribed,
  ) async {
    _subscriptionOverrides[playlist] = subscribed;
    subscribed ? _subscribed.add(playlist) : _subscribed.remove(playlist);
  }

  @override
  Future<Set<AlbumId>> getSubscribedAlbumIds() async =>
      Set.unmodifiable(_subscribedAlbums);

  @override
  Future<List<AlbumSummary>> getSubscribedAlbums() async => [
    for (final album in _albums)
      if (_subscribedAlbums.contains(album.id)) album,
  ];

  @override
  Future<void> setAlbumSubscribed(AlbumId album, bool subscribed) async {
    subscribed ? _subscribedAlbums.add(album) : _subscribedAlbums.remove(album);
  }

  @override
  Future<PlaylistSummary> createPlaylist(
    String name, {
    bool isPrivate = false,
  }) async {
    final summary = PlaylistSummary(
      id: PlaylistId(NcmKind.playlist.id('${++_nextPlaylist}')),
      title: name.trim(),
      subtitle: '体验账号',
      trackCount: 0,
      creatorId: _activeAccount,
      privacy: isPrivate ? 10 : 0,
    );
    _managed[summary.id] = PlaylistDetail.fromTracks(
      summary: summary,
      tracks: [],
    );
    return summary;
  }

  @override
  Future<void> updatePlaylistName(PlaylistId playlist, String name) async {
    _replaceManaged(playlist, name: name);
  }

  @override
  Future<void> updatePlaylistDescription(
    PlaylistId playlist,
    String description,
  ) async {
    _replaceManaged(playlist, description: description);
  }

  @override
  Future<void> updatePlaylistTags(
    PlaylistId playlist,
    List<String> tags,
  ) async {
    _replaceManaged(playlist, tags: tags);
  }

  @override
  Future<void> changePlaylistTracks(
    PlaylistId playlist,
    List<TrackId> tracks, {
    required bool add,
  }) async {
    final epoch = _accountEpoch;
    final old = _managed[playlist]!.tracks;
    final members = add
        ? [
            ...old,
            for (final id in tracks)
              if (!old.any((t) => t.id == id)) await getTrack(id),
          ]
        : old.where((t) => !tracks.contains(t.id)).toList();
    _requireAccount(epoch);
    _replaceManaged(playlist, tracks: members);
  }

  @override
  Future<void> deletePlaylist(PlaylistId playlist) async {
    _managed.remove(playlist);
    _deleted.add(playlist);
  }

  @override
  Future<void> reorderPlaylist(
    PlaylistId playlist,
    List<TrackId> tracks,
  ) async {
    final old = _managed[playlist]!.tracks;
    _replaceManaged(
      playlist,
      tracks: [for (final id in tracks) old.firstWhere((t) => t.id == id)],
    );
  }

  static const _auroral = Artist(
    id: ArtistId('artist-aurora'),
    name: 'Auroral Ensemble',
  );
  static const _lumi = Artist(id: ArtistId('artist-lumi'), name: 'Lumi');
  static const _atlas = Artist(id: ArtistId('artist-atlas'), name: 'Atlas Run');

  static const _midnight = Album(
    id: AlbumId('album-midnight'),
    title: 'Midnight Signals',
  );
  static const _softLight = Album(
    id: AlbumId('album-soft-light'),
    title: 'Soft Light',
  );
  static const _city = Album(
    id: AlbumId('album-city'),
    title: 'City Fragments',
  );

  static const _nightDrive = PlaylistSummary(
    id: PlaylistId('playlist-night-drive'),
    title: '极光夜航',
    subtitle: '合成器、星光与安静的公路',
    trackCount: 6,
  );
  static const _dailyMix = PlaylistSummary(
    id: PlaylistId('playlist-daily-mix'),
    title: '每日私人漫游',
    subtitle: '从熟悉的旋律开始今天',
    trackCount: 5,
  );
  static const _focus = PlaylistSummary(
    id: PlaylistId('playlist-focus'),
    title: '专注白噪点',
    subtitle: '留一点空间给思绪',
    trackCount: 4,
  );
  static const _cityPop = PlaylistSummary(
    id: PlaylistId('playlist-city-pop'),
    title: '城市落日放映厅',
    subtitle: '下班之后，让节拍慢下来',
    trackCount: 5,
  );
  static const _acoustic = PlaylistSummary(
    id: PlaylistId('playlist-acoustic'),
    title: '不插电的周末',
    subtitle: '木吉他和刚晒好的被单',
    trackCount: 4,
  );

  static const _tracks = [
    Track(
      id: TrackId('track-starlight'),
      title: 'Starlight Receiver',
      artists: [_auroral],
      album: _midnight,
      duration: Duration(minutes: 3, seconds: 48),
    ),
    Track(
      id: TrackId('track-greenline'),
      title: 'Green Line',
      artists: [_auroral, _lumi],
      album: _midnight,
      duration: Duration(minutes: 4, seconds: 12),
    ),
    Track(
      id: TrackId('track-polaris'),
      title: 'Polaris',
      artists: [_auroral],
      album: _midnight,
      duration: Duration(minutes: 3, seconds: 21),
    ),
    Track(
      id: TrackId('track-afterglow'),
      title: 'Afterglow',
      artists: [_auroral],
      album: _midnight,
      duration: Duration(minutes: 5, seconds: 2),
    ),
    Track(
      id: TrackId('track-window-seat'),
      title: '靠窗的位置',
      artists: [_lumi],
      album: _softLight,
      duration: Duration(minutes: 3, seconds: 36),
    ),
    Track(
      id: TrackId('track-last-train'),
      title: '末班电车',
      artists: [_atlas],
      album: _city,
      duration: Duration(minutes: 4, seconds: 8),
    ),
  ];

  static const _playlists = [
    _nightDrive,
    _dailyMix,
    _focus,
    _cityPop,
    _acoustic,
  ];

  static const _recommendedSection = HomeSection(
    kind: HomeSectionKind.recommended,
    title: '推荐歌单',
    playlists: [_nightDrive, _dailyMix],
  );
  static const _dailySection = HomeSection(
    kind: HomeSectionKind.dailyRecommendations,
    title: '每日推荐',
    playlists: [_focus, _cityPop],
  );
  static const _topPlaylistsSection = HomeSection(
    kind: HomeSectionKind.topPlaylists,
    title: '网友精选碟',
    playlists: [_acoustic],
  );
  static const _recentPlaylistsSection = HomeSection(
    kind: HomeSectionKind.recentPlaylists,
    title: '最近播放歌单',
    playlists: [_dailyMix, _focus],
  );
  static const _toplistsSection = HomeSection(
    kind: HomeSectionKind.toplists,
    title: '排行榜',
    playlists: [_nightDrive, _focus],
  );

  static const _homeSections = [
    _recommendedSection,
    _dailySection,
    _recentPlaylistsSection,
    _topPlaylistsSection,
    _toplistsSection,
  ];

  static final _albums = [
    AlbumSummary(
      id: const AlbumId('album-midnight'),
      title: 'Midnight Signals',
      artistName: 'Auroral Ensemble',
      trackCount: 4,
    ),
    AlbumSummary(
      id: const AlbumId('album-soft-light'),
      title: 'Soft Light',
      artistName: 'Lumi',
      trackCount: 1,
    ),
    AlbumSummary(
      id: const AlbumId('album-city'),
      title: 'City Fragments',
      artistName: 'Atlas Run',
      trackCount: 1,
    ),
  ];

  static final _artists = [
    ArtistSummary(
      id: const ArtistId('artist-aurora'),
      name: 'Auroral Ensemble',
      trackCount: 4,
      albumCount: 1,
    ),
    ArtistSummary(
      id: const ArtistId('artist-lumi'),
      name: 'Lumi',
      trackCount: 1,
      albumCount: 1,
    ),
    ArtistSummary(
      id: const ArtistId('artist-atlas'),
      name: 'Atlas Run',
      trackCount: 1,
      albumCount: 1,
    ),
  ];

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    return const HomeFeed(
      greeting: '晚上好，去听一段极光',
      sections: _homeSections,
      playlists: _playlists,
    );
  }

  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    return _homeSections.firstWhere(
      (s) => s.kind == kind,
      orElse: () => _recommendedSection,
    );
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final epoch = _accountEpoch;
    await Future<void>.delayed(latency);
    _requireAccount(epoch);
    if (id.value == 'playlist-acoustic' && _favoriteTouched) {
      final summary = fakeLikedSummary;
      final tracks = await Future.wait(_liked.map(getTrack));
      _requireAccount(epoch);
      return PlaylistDetail.fromTracks(summary: summary, tracks: tracks);
    }
    if (_managed.containsKey(id)) {
      final p = _managed[id]!;
      return PlaylistDetail.fromTracks(
        summary: p.summary,
        tracks: p.tracks,
        header: p.header,
        accountState: PlaylistAccountState(
          accountId: 'ncm-user-fake',
          subscription: (_subscriptionOverrides[id] ?? false)
              ? SubscriptionEvidence.subscribed
              : SubscriptionEvidence.unsubscribed,
        ),
      );
    }
    if (_deleted.contains(id)) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.notFound',
        retryable: false,
      );
    }
    PlaylistSummary? summary;
    for (final item in _playlists) {
      if (item.id == id) summary = item;
    }
    if (summary == null) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.notFound',
        retryable: false,
      );
    }
    final offset = _playlists.indexOf(summary);
    final rotated = [..._tracks.skip(offset), ..._tracks.take(offset)];
    final loadedTracks = List<Track>.unmodifiable(
      rotated.take(summary.trackCount),
    );
    final header = PlaylistHeaderMetadata(
      creator: const PlaylistCreator(nickname: 'Auroral Curators'),
      createTime: DateTime(2025, 1, 1),
      tags: const ['精选', '官方'],
      description: summary.description ?? summary.subtitle,
      playCount: 128000,
      subscribedCount: 4200,
      shareCount: 350,
      declaredTrackCount: summary.trackCount,
    );
    final accountState = PlaylistAccountState(
      accountId: _activeAccount.value,
      subscription: (_subscriptionOverrides[id] ?? true)
          ? SubscriptionEvidence.subscribed
          : SubscriptionEvidence.unsubscribed,
      fetchedAt: DateTime.now().toUtc(),
      freshUntil: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    return PlaylistDetail.fromTracks(
      summary: summary,
      header: header,
      accountState: accountState,
      tracks: loadedTracks,
    );
  }

  @override
  Future<Track> getTrack(TrackId id) async {
    await Future<void>.delayed(latency);
    if (NcmKind.track.digitsOf(id.value) != null) {
      final source =
          _tracks[(int.parse(NcmKind.track.digitsOf(id.value)!) - 1001).abs() %
              _tracks.length];
      return Track(
        id: id,
        title: source.title,
        artists: source.artists,
        album: source.album,
        duration: source.duration,
      );
    }
    return _tracks.firstWhere(
      (track) => track.id == id,
      orElse: () => throw const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.notFound',
        retryable: false,
      ),
    );
  }

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    await Future<void>.delayed(latency);
    final normalized = query.keywords.trim().toLowerCase();
    final matches = normalized.isEmpty
        ? _tracks
        : _tracks
              .where(
                (t) =>
                    t.title.toLowerCase().contains(normalized) ||
                    t.artistLabel.toLowerCase().contains(normalized) ||
                    t.album.title.toLowerCase().contains(normalized),
              )
              .toList();
    final start = query.offset.clamp(0, matches.length);
    final end = (start + query.limit).clamp(0, matches.length);
    final page = matches.sublist(start, end);
    return SearchResult(
      items: page,
      hasMore: end < matches.length,
      totalCount: matches.length,
    );
  }

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final epoch = _accountEpoch;
    final detail = await getPlaylist(id, policy: policy);
    _requireAccount(epoch);
    final start = offset.clamp(0, detail.tracks.length);
    final end = (start + limit).clamp(0, detail.tracks.length);
    final page = detail.tracks.sublist(start, end);
    return SearchResult(
      items: page,
      hasMore: end < detail.tracks.length,
      totalCount: detail.tracks.length,
    );
  }

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    final now = DateTime.now().toUtc();
    return PlaylistAccessVerdict(
      namespace: 'ncm',
      target: id,
      state: PlaylistAccessState.publicConfirmed,
      evidenceMode: RequestAuthMode.anonymous,
      evidenceKind: 'fake',
      fetchedAt: now,
      freshUntil: now.add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) async {
    await Future<void>.delayed(latency);
    final normalized = query.keywords.trim().toLowerCase();
    switch (query.searchType) {
      case SearchType.track:
        final matches = normalized.isEmpty
            ? _tracks
            : _tracks
                  .where(
                    (t) =>
                        t.title.toLowerCase().contains(normalized) ||
                        t.artistLabel.toLowerCase().contains(normalized) ||
                        t.album.title.toLowerCase().contains(normalized),
                  )
                  .toList();
        final start = query.offset.clamp(0, matches.length);
        final end = (start + query.limit).clamp(0, matches.length);
        final page = matches.sublist(start, end);
        return SearchResult(
          items: [for (final t in page) TrackItem(t)],
          hasMore: end < matches.length,
          totalCount: matches.length,
        );

      case SearchType.album:
        final matches = normalized.isEmpty
            ? _albums
            : _albums
                  .where(
                    (a) =>
                        a.title.toLowerCase().contains(normalized) ||
                        a.artistName.toLowerCase().contains(normalized),
                  )
                  .toList();
        final start = query.offset.clamp(0, matches.length);
        final end = (start + query.limit).clamp(0, matches.length);
        final page = matches.sublist(start, end);
        return SearchResult(
          items: [for (final a in page) AlbumItem(a)],
          hasMore: end < matches.length,
          totalCount: matches.length,
        );

      case SearchType.artist:
        final matches = normalized.isEmpty
            ? _artists
            : _artists
                  .where((a) => a.name.toLowerCase().contains(normalized))
                  .toList();
        final start = query.offset.clamp(0, matches.length);
        final end = (start + query.limit).clamp(0, matches.length);
        final page = matches.sublist(start, end);
        return SearchResult(
          items: [for (final a in page) ArtistItem(a)],
          hasMore: end < matches.length,
          totalCount: matches.length,
        );

      case SearchType.playlist:
        final matches = normalized.isEmpty
            ? _playlists
            : _playlists
                  .where(
                    (p) =>
                        p.title.toLowerCase().contains(normalized) ||
                        p.subtitle.toLowerCase().contains(normalized),
                  )
                  .toList();
        final start = query.offset.clamp(0, matches.length);
        final end = (start + query.limit).clamp(0, matches.length);
        final page = matches.sublist(start, end);
        return SearchResult(
          items: [for (final p in page) PlaylistItem(p)],
          hasMore: end < matches.length,
          totalCount: matches.length,
        );
    }
  }

  /// Word-level content, so the player's per-word sweep has something to drive
  /// offline. The line tuples start at zero; the word offsets inside the second
  /// line are relative to it, which is the shape the parser normalizes.
  static const _starlightYrc =
      '[0,2000](0,900,0)星光(900,1100,0)落下来\n'
      '[2000,2000](0,1000,0)沿着(1000,1000,0)夜航';

  static const _starlightLrc =
      '[00:00.00]星光落下来\n'
      '[00:02.00]沿着夜航';

  static const _starlightTranslation =
      '[00:00.00]Starlight falls down\n'
      '[00:02.00]Sailing through the night';

  /// Line-level content with a romanization and no word timings. The empty line
  /// is deliberate: a timestamp with no text must not become a row.
  static const _greenlineLrc =
      '[00:11.00]绿线穿过城市\n'
      '[00:15.50]车窗外的灯\n'
      '[00:20.00]\n'
      '[00:24.25]我们在末班车上';

  static const _greenlineRoman =
      '[00:11.00]lü xian chuan guo cheng shi\n'
      '[00:15.50]che chuang wai de deng\n'
      '[00:24.25]wo men zai mo ban che shang';

  /// The four outcomes a lyric read can have, keyed deterministically by track
  /// so a widget test can drive each one without a network.
  @override
  Future<LyricTimeline> getLyrics(TrackId id) async {
    await Future<void>.delayed(latency);
    return switch (id.value) {
      'track-starlight' => parseNcmLyrics(
        lrc: _starlightLrc,
        yrc: _starlightYrc,
        translation: _starlightTranslation,
        instrumental: false,
      ),
      'track-greenline' => parseLrcSheet(
        _greenlineLrc,
        transliteration: _greenlineRoman,
      ),
      'track-polaris' => const LyricTimeline.instrumental(),
      _ => const LyricTimeline.unavailable(),
    };
  }

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async {
    await Future<void>.delayed(latency);
    final summary = _albums.firstWhere(
      (a) => a.id == id,
      orElse: () => throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.albumNotFound',
        retryable: false,
      ),
    );
    final albumTracks = _tracks.where((t) => t.album.id == id).toList();
    return AlbumDetail(summary: summary, tracks: albumTracks, isPartial: false);
  }

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async {
    await Future<void>.delayed(latency);
    final summary = _artists.firstWhere(
      (a) => a.id == id,
      orElse: () => throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.artistNotFound',
        retryable: false,
      ),
    );
    final artistTracks = _tracks
        .where((t) => t.artists.any((a) => a.id == id))
        .toList();
    return ArtistDetail(
      summary: summary,
      tracks: artistTracks,
      isPartial: false,
    );
  }

  // --- RecommendRepository ---

  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final epoch = _accountEpoch;
    await Future<void>.delayed(latency);
    _requireAccount(epoch);
    final now = DateTime.now().toUtc();
    final effectiveDateKey =
        dateKey ??
        '${now.toLocal().year}-${now.toLocal().month.toString().padLeft(2, '0')}-${now.toLocal().day.toString().padLeft(2, '0')}';
    final entries = [
      for (var i = 0; i < _tracks.length; i++)
        DailySongEntry(
          ordinal: i,
          track: _tracks[i],
          reason: i % 2 == 0 ? '根据你喜欢的风格推荐' : null,
        ),
    ];
    final snapshot = DailySongsSnapshot(
      namespace: 'ncm',
      accountId: _activeAccount.value,
      dateKey: effectiveDateKey,
      songs: entries,
      fetchedAt: now,
      staleUntil: now.add(const Duration(hours: 12)),
      retainUntil: now.add(const Duration(days: 7)),
    );
    return DailySongsRead(
      snapshot: snapshot,
      source: DailySongsSource.network,
      refreshedAt: now,
    );
  }

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    return RecommendedPlaylists(playlists: _playlists, isFallback: false);
  }

  @override
  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    return _tracks.take(limit).toList();
  }

  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    final now = DateTime.now();
    final resources = <ListenResource>[
      for (var i = 0; i < _playlists.take(5).length; i++)
        ListenResource(
          resourceId: _playlists[i].id.value,
          target: PlaylistListenTarget(_playlists[i].id),
          title: _playlists[i].title,
          tag: '歌单',
          coverUrl: _playlists[i].artworkUri,
          playOrUpdateTime: now.subtract(Duration(hours: i * 2 + 1)),
        ),
      if (_albums.isNotEmpty)
        ListenResource(
          resourceId: _albums.first.id.value,
          target: AlbumListenTarget(_albums.first.id),
          title: _albums.first.title,
          tag: '专辑',
          coverUrl: _albums.first.artworkUri,
          playOrUpdateTime: now.subtract(const Duration(days: 1)),
        ),
    ];
    return ListenResources(title: '最近常听', resources: resources);
  }

  // --- PlaylistSquareRepository ---

  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    return const PlaylistCategoryTree(
      all: PlaylistTag(name: '全部歌单'),
      categories: {'0': '语种', '1': '风格', '2': '场景', '3': '情感', '4': '主题'},
      sub: [
        PlaylistTag(name: '华语', category: 0, hot: true),
        PlaylistTag(name: '流行', category: 1, hot: true),
        PlaylistTag(name: '摇滚', category: 1, hot: true),
        PlaylistTag(name: '民谣', category: 1, hot: false),
        PlaylistTag(name: '电子', category: 1, hot: true),
        PlaylistTag(name: '夜晚', category: 2, hot: true),
        PlaylistTag(name: '学习', category: 2, hot: false),
        PlaylistTag(name: '治愈', category: 3, hot: true),
        PlaylistTag(name: '放松', category: 3, hot: false),
      ],
    );
  }

  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    return const [
      PlaylistTag(name: '华语', category: 0, hot: true),
      PlaylistTag(name: '流行', category: 1, hot: true),
      PlaylistTag(name: '摇滚', category: 1, hot: true),
      PlaylistTag(name: '电子', category: 1, hot: true),
      PlaylistTag(name: '夜晚', category: 2, hot: true),
      PlaylistTag(name: '治愈', category: 3, hot: true),
    ];
  }

  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    await Future<void>.delayed(latency);
    if (_playlists.isEmpty) return null;
    return HighQualityPlaylist(
      summary: _playlists.first,
      tag: cat,
      copywriter: '官方甄选精品歌单',
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
    await Future<void>.delayed(latency);
    final start = offset.clamp(0, _playlists.length);
    final end = (start + limit).clamp(0, _playlists.length);
    final page = _playlists.sublist(start, end);
    return SearchResult(
      items: page,
      hasMore: end < _playlists.length,
      totalCount: _playlists.length,
    );
  }
}

final class _DemoAccountData {
  final managed = <PlaylistId, PlaylistDetail>{};
  final deleted = <PlaylistId>{};
  final liked = <TrackId>{
    for (var i = 0; i < 4; i++) TrackId('ncm-${1001 + i}'),
  };
  bool favoriteTouched = false;
  final subscriptionOverrides = <PlaylistId, bool>{};
  final subscribed = <PlaylistId>{};
  final subscribedAlbums = <AlbumId>{};
}
