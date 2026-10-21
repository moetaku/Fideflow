import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/search/search_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The search page's states that are not "a list of results": a filter that
/// empties the page it was applied to, and a page that fails to load and is
/// then retried.
void main() {
  Future<void> useDesktopSize(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Future<void> pumpSearch(WidgetTester tester, _ScriptedSearch feed) async {
    final home = BrowseAndPlayController(feed, FakeMediaController());
    final search = CatalogSearchController(feed);
    addTearDown(search.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(
          controller: home,
          searchController: search,
          prefetchPlaylist: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Starlight');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('the playable-only filter says what it hid, not that nothing '
      'was found', (tester) async {
    await useDesktopSize(tester);
    final feed = _ScriptedSearch([
      (_) async => _page([
        _track('t-preview', '试听曲', availability: TrackAvailability.preview),
        _track('t-none', '无音源曲', availability: TrackAvailability.none),
      ], hasMore: true),
    ]);

    await pumpSearch(tester, feed);

    expect(find.text('试听曲'), findsOneWidget);
    expect(find.text('无音源曲'), findsOneWidget);

    await tester.tap(find.text('只看可播放'));
    await tester.pumpAndSettle();

    // The filter is the reason the page is empty, and the page says so: the
    // rows it hid are still known to the result set.
    expect(find.text('已加载 2 首歌曲中无匹配项，可继续加载更多'), findsOneWidget);
    expect(find.text('试听曲'), findsNothing);
    expect(find.text('无音源曲'), findsNothing);
    expect(find.text('未搜索到相关歌曲'), findsNothing);
    expect(find.widgetWithText(FilledButton, '加载更多'), findsOneWidget);

    await tester.tap(find.text('只看可播放'));
    await tester.pumpAndSettle();

    expect(find.text('试听曲'), findsOneWidget);
    expect(find.text('无音源曲'), findsOneWidget);
  });

  testWidgets(
    'a failed page keeps its rows and asks for the same range again',
    (tester) async {
      await useDesktopSize(tester);
      final feed = _ScriptedSearch([
        (_) async =>
            _page([_track('t-1', '第一首'), _track('t-2', '第二首')], hasMore: true),
        (_) async => throw const AppError(
          category: AppErrorCategory.network,
          code: 'network.timeout',
          retryable: true,
        ),
        (_) async => _page([_track('t-3', '第三首')], hasMore: false),
      ]);

      await pumpSearch(tester, feed);
      expect(find.text('第一首'), findsOneWidget);
      expect(find.text('第二首'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, '加载更多'));
      await tester.pumpAndSettle();

      // The failure is reported next to the rows it could not extend, and the
      // rows themselves are untouched.
      expect(find.text('加载更多失败: network.timeout'), findsOneWidget);
      expect(find.text('第一首'), findsOneWidget);
      expect(find.text('第二首'), findsOneWidget);
      expect(find.text('第三首'), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(SearchPage),
          matching: find.widgetWithText(TextButton, '重试'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('第三首'), findsOneWidget);
      expect(find.text('加载更多失败: network.timeout'), findsNothing);
      expect(find.text('已显示全部结果'), findsOneWidget);
      // The retry asks for the range the failed request asked for: no row is
      // skipped and none is requested twice in a different shape.
      expect(feed.offsets, [0, 2, 2]);
    },
  );
}

Track _track(
  String id,
  String title, {
  TrackAvailability availability = TrackAvailability.full,
}) => Track(
  id: TrackId(id),
  title: title,
  artists: [Artist(id: ArtistId('artist-$id'), name: '歌手')],
  album: Album(id: AlbumId('album-$id'), title: '专辑'),
  duration: const Duration(minutes: 3, seconds: 20),
  availability: availability,
  maxPotentialQuality: TrackQuality.high,
);

SearchResult<CatalogItem> _page(List<Track> tracks, {required bool hasMore}) =>
    SearchResult(
      items: [for (final track in tracks) TrackItem(track)],
      hasMore: hasMore,
      totalCount: 40,
    );

/// Answers search pages from a script, one entry per request, so a page can be
/// made to fail and then answered on the retry.
final class _ScriptedSearch
    implements CatalogRepository, CatalogSearchRepository {
  _ScriptedSearch(this._pages);

  final List<Future<SearchResult<CatalogItem>> Function(SearchQuery query)>
  _pages;

  /// The offset of every request, in order: what the controller asked the
  /// service for, rather than what it happens to be showing.
  final List<int> offsets = [];

  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) {
    final index = offsets.length;
    offsets.add(query.offset);
    final page = _pages[index < _pages.length ? index : _pages.length - 1];
    return page(query);
  }

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(
    greeting: '你好',
    playlists: [
      PlaylistSummary(
        id: PlaylistId('ncm-playlist-morning'),
        title: '晨间精选',
        subtitle: '编辑精选',
        trackCount: 2,
      ),
    ],
  );

  /// Never reached by these tests, which do not prefetch or browse a playlist.
  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw const AppError(
    category: AppErrorCategory.provider,
    code: 'ncm.playlistNotFound',
    retryable: false,
  );

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
