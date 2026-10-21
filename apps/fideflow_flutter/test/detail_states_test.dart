import 'package:fideflow/features/catalog/album_detail_page.dart';
import 'package:fideflow/features/catalog/artist_detail_page.dart';
import 'package:fideflow/features/catalog/playlist_detail_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The detail pages' own states: a fetch that fails, the retry that follows it,
/// and the partial playlist that has to say what is missing without losing what
/// it already has.
///
/// The album and artist pages own their request outright, so a scripted detail
/// repository is what makes "fails, then answers" reachable. The playlist page
/// draws whatever the controller holds, so its states are made through the
/// controller — the same path a retry from inside the page travels.
void main() {
  Future<void> useTallWindow(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// A controller for the pages that need one for their callbacks. It is never
  /// initialized, so its catalog only has to exist: the album and artist pages
  /// own their own fetch, and the playlist cases build their own scripted one.
  BrowseAndPlayController newController() {
    final controller = BrowseAndPlayController(
      _ScriptedCatalog(),
      FakeMediaController(),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('a failed album load stays until its retry answers', (
    tester,
  ) async {
    await useTallWindow(tester);
    final controller = newController();
    final details = _ScriptedDetails()
      ..albumErrors = [
        const AppError(
          category: AppErrorCategory.provider,
          code: 'network.timeout',
          retryable: true,
        ),
      ];

    await tester.pumpWidget(
      _page(
        AlbumDetailPage(
          albumId: _Fixtures.albumId,
          detailRepository: details,
          state: controller.current,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(details.albumRequests, [_Fixtures.albumId]);
    expect(find.text('加载专辑失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // A failure is not a loading state: nothing spins behind the message.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('共 3 首歌曲'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    // The retry is a second request, not a re-render of the failure.
    expect(details.albumRequests.length, 2);
    expect(find.text('加载专辑失败'), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(find.text('共 3 首歌曲'), findsOneWidget);
    expect(find.text('归途'), findsOneWidget);
    // The retried album arrives with something to play, not an empty table.
    expect(find.text('此专辑暂无可播放歌曲'), findsNothing);
  });

  testWidgets('an album failure without a code names its own', (tester) async {
    await useTallWindow(tester);
    final details = _ScriptedDetails()..albumThrowsStateErrorOnce = true;

    await tester.pumpWidget(
      _page(
        AlbumDetailPage(
          albumId: _Fixtures.albumId,
          detailRepository: details,
          state: HomeState.initial(),
          controller: newController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A plain exception carries no provider code, so the page falls back to its
    // own: the message is never empty and never a raw exception.
    expect(find.text('加载专辑失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('加载专辑失败'), findsNothing);
    expect(find.text('归途'), findsOneWidget);
  });

  testWidgets('a failed artist load retries into the whole page', (
    tester,
  ) async {
    await useTallWindow(tester);
    final details = _ScriptedDetails()
      ..artistErrors = [
        const AppError(
          category: AppErrorCategory.provider,
          code: 'provider.unavailable',
          retryable: true,
        ),
      ];

    await tester.pumpWidget(
      _page(
        ArtistDetailPage(
          artistId: _Fixtures.artistId,
          detailRepository: details,
          state: HomeState.initial(),
          controller: newController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(details.artistRequests, [_Fixtures.artistId]);
    expect(find.text('加载歌手失败'), findsOneWidget);
    expect(find.text('候鸟'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(details.artistRequests.length, 2);
    expect(find.text('加载歌手失败'), findsNothing);
    expect(find.text('候鸟'), findsWidgets);
    expect(find.text('单曲 3 · 专辑 1'), findsOneWidget);
    expect(find.text('热门单曲 (3首)'), findsOneWidget);
    expect(find.text('归途'), findsOneWidget);
  });

  testWidgets('a partial playlist announces what is missing', (tester) async {
    await useTallWindow(tester);

    await tester.pumpWidget(
      _page(
        PlaylistDetailPage(
          playlist: _Fixtures.partialPlaylist,
          state: HomeState.initial(),
          controller: newController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('5 / 12 首歌曲 (部分加载) · 网友精选'),
      findsOneWidget,
      reason: 'the count line has to read as a subset of the whole playlist',
    );
    expect(find.text('部分歌曲加载失败，仅显示前 5 首'), findsOneWidget);
    // Playing and sorting are both confined to the rows that are here, and the
    // page says so rather than offering the whole playlist it cannot serve.
    expect(find.text('播放当前已加载 5 首'), findsOneWidget);
    expect(find.text('（仅按当前已加载曲目排序）'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // The page is ready: the only retry on it belongs to the banner.
    expect(find.text('重试加载'), findsNothing);
  });

  testWidgets('a complete playlist carries no partial banner', (tester) async {
    await useTallWindow(tester);

    await tester.pumpWidget(
      _page(
        PlaylistDetailPage(
          playlist: _Fixtures.completePlaylist,
          state: HomeState.initial(),
          controller: newController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('12 首歌曲 · 网友精选'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.textContaining('部分加载'), findsNothing);
    expect(find.textContaining('部分歌曲加载失败'), findsNothing);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('the partial banner reloads, and a failed reload keeps the rows', (
    tester,
  ) async {
    await useTallWindow(tester);
    final catalog = _ScriptedCatalog();
    final controller = BrowseAndPlayController(catalog, FakeMediaController());
    addTearDown(controller.dispose);

    await controller.selectPlaylist(_Fixtures.playlistId);
    await tester.pumpWidget(_playlistHost(controller));
    await tester.pumpAndSettle();

    expect(catalog.playlistRequests, [_Fixtures.playlistId]);
    expect(find.text('部分歌曲加载失败，仅显示前 5 首'), findsOneWidget);
    expect(find.text('重试加载'), findsNothing);

    // The reload the banner offers is the one that fails: the rows the user was
    // reading stay, and the page offers a page-level retry instead of blanking.
    catalog.failNextPlaylist = true;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(catalog.playlistRequests.length, 2);
    expect(find.text('归途'), findsOneWidget);
    expect(find.text('部分歌曲加载失败，仅显示前 5 首'), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);

    catalog.complete = true;
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();

    expect(catalog.playlistRequests.length, 3);
    expect(find.text('12 首歌曲 · 网友精选'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.textContaining('部分加载'), findsNothing);
    expect(find.text('重试加载'), findsNothing);
  });
}

Widget _page(Widget child) => MaterialApp(
  theme: FideflowTheme.dark(),
  home: Scaffold(body: child),
);

/// Hosts the playlist page the way the app does: it draws the detail the
/// controller holds, so a retry pressed inside the page travels the real path
/// and its result reaches the page.
Widget _playlistHost(BrowseAndPlayController controller) => MaterialApp(
  theme: FideflowTheme.dark(),
  home: Scaffold(
    body: StreamBuilder<HomeState>(
      stream: controller.states,
      initialData: controller.current,
      builder: (context, snapshot) {
        final state = snapshot.data ?? controller.current;
        return PlaylistDetailPage(
          playlist: state.selectedPlaylist!,
          state: state,
          controller: controller,
        );
      },
    ),
  ),
);

/// The one album, artist and playlist the pages below are built from.
abstract final class _Fixtures {
  static const albumId = AlbumId('ncm-album-1');
  static const artistId = ArtistId('ncm-artist-1');
  static const playlistId = PlaylistId('ncm-playlist-late');

  static const _summary = PlaylistSummary(
    id: playlistId,
    title: '深夜精选',
    subtitle: '网友精选',
    trackCount: 12,
  );

  static const _albumSummary = AlbumSummary(
    id: albumId,
    title: '极光',
    artistName: '候鸟',
    trackCount: 3,
  );

  static const _artistSummary = ArtistSummary(
    id: artistId,
    name: '候鸟',
    trackCount: 3,
    albumCount: 1,
  );

  static const tracks = [
    Track(
      id: TrackId('ncm-track-1'),
      title: '归途',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3, seconds: 40),
    ),
    Track(
      id: TrackId('ncm-track-2'),
      title: '夜航',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 4, seconds: 12),
    ),
    Track(
      id: TrackId('ncm-track-3'),
      title: '潮汐',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 2, seconds: 58),
    ),
  ];

  static const AlbumDetail album = AlbumDetail(
    summary: _albumSummary,
    tracks: tracks,
  );

  static const ArtistDetail artist = ArtistDetail(
    summary: _artistSummary,
    tracks: tracks,
  );

  /// Five of the summary's twelve songs: what a paged fetch leaves behind when
  /// completing the list fails.
  static const PlaylistDetail partialPlaylist = PlaylistDetail(
    summary: _summary,
    tracks: [...tracks, _fourth, _fifth],
    isPartial: true,
  );

  static const PlaylistDetail completePlaylist = PlaylistDetail(
    summary: _summary,
    tracks: [...tracks, _fourth, _fifth, ..._rest],
  );

  static const _fourth = Track(
    id: TrackId('ncm-track-4'),
    title: '灯塔',
    artists: [Artist(id: artistId, name: '候鸟')],
    album: Album(id: albumId, title: '极光'),
    duration: Duration(minutes: 3, seconds: 5),
  );

  static const _fifth = Track(
    id: TrackId('ncm-track-5'),
    title: '雪线',
    artists: [Artist(id: artistId, name: '候鸟')],
    album: Album(id: albumId, title: '极光'),
    duration: Duration(minutes: 3, seconds: 33),
  );

  static const _rest = [
    Track(
      id: TrackId('ncm-track-6'),
      title: '深海来信',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
    Track(
      id: TrackId('ncm-track-7'),
      title: '暖流',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
    Track(
      id: TrackId('ncm-track-8'),
      title: '季风',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
    Track(
      id: TrackId('ncm-track-9'),
      title: '极昼',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
    Track(
      id: TrackId('ncm-track-10'),
      title: '星轨',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
    Track(
      id: TrackId('ncm-track-11'),
      title: '晨雾',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
    Track(
      id: TrackId('ncm-track-12'),
      title: '白夜',
      artists: [Artist(id: artistId, name: '候鸟')],
      album: Album(id: albumId, title: '极光'),
      duration: Duration(minutes: 3),
    ),
  ];
}

/// A detail repository whose next answer is scripted: failures first, the
/// fixture after that, with every request recorded.
final class _ScriptedDetails implements CatalogDetailRepository {
  final List<AlbumId> albumRequests = [];
  final List<ArtistId> artistRequests = [];

  /// The failures the album fetch answers with, oldest first.
  List<AppError> albumErrors = [];

  List<AppError> artistErrors = [];

  /// Whether the next album fetch throws something that is not an [AppError].
  bool albumThrowsStateErrorOnce = false;

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async {
    albumRequests.add(id);
    if (albumThrowsStateErrorOnce) {
      albumThrowsStateErrorOnce = false;
      throw StateError('unexpected response shape');
    }
    if (albumErrors.isNotEmpty) throw albumErrors.removeAt(0);
    return _Fixtures.album;
  }

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async {
    artistRequests.add(id);
    if (artistErrors.isNotEmpty) throw artistErrors.removeAt(0);
    return _Fixtures.artist;
  }
}

/// The catalog behind the playlist page, with its own answer scripted so a
/// reload can be made to succeed or fail on demand.
final class _ScriptedCatalog implements CatalogRepository {
  final List<PlaylistId> playlistRequests = [];

  /// The answer the next playlist fetch gives, before it is consumed.
  bool failNextPlaylist = false;

  /// Whether the playlist is served whole.
  bool complete = false;

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    playlistRequests.add(id);
    if (failNextPlaylist) {
      failNextPlaylist = false;
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'network.timeout',
        retryable: true,
      );
    }
    return complete ? _Fixtures.completePlaylist : _Fixtures.partialPlaylist;
  }

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(greeting: '晚上好');

  @override
  Future<Track> getTrack(TrackId id) => throw UnimplementedError();

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async =>
      const SearchResult(items: [], hasMore: false, totalCount: 0);

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const SearchResult(items: [], hasMore: false, totalCount: 0);

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => PlaylistAccessVerdict(
    namespace: 'ncm',
    target: id,
    state: PlaylistAccessState.publicConfirmed,
    evidenceMode: RequestAuthMode.anonymous,
    evidenceKind: 'test',
    fetchedAt: DateTime.now(),
    freshUntil: DateTime.now().add(const Duration(hours: 1)),
  );
}
