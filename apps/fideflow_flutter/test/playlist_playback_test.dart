import 'dart:async';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/auth/login_dialog.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Playlist browsing and playback UI', () {
    testWidgets('batch selection plays and appends the selected tracks', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      await tester.tap(find.text('极光夜航').first);
      await tester.pumpAndSettle();
      expect(find.text('多选添加到歌单'), findsNothing);
      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 首'), findsOneWidget);
      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsWidgets);
      await tester.tap(checkboxes.at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 首'), findsOneWidget);
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(deps.homeController.current.playback.queue, hasLength(1));
      expect(find.byTooltip('暂停'), findsOneWidget);
      await tester.tap(find.text('添加到播放列表'));
      await tester.pumpAndSettle();
      expect(deps.homeController.current.playback.queue, hasLength(2));
      await tester.tap(checkboxes.first);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkboxes.first).value, isTrue);
      await tester.tap(checkboxes.first);
      await tester.pumpAndSettle();
      expect(find.text('已选 0 首'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets(
      'clicking playlist card opens detail and clicking 播放全部 starts playback',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Click a playlist card in the square page
        await tester.tap(find.text('极光夜航').first);
        await tester.pumpAndSettle();

        // Find the "播放全部" button on the playlist detail page
        final playAllButton = find.text('播放全部');
        expect(playAllButton, findsOneWidget);

        // Tap "播放全部"
        await tester.tap(playAllButton);
        await tester.pumpAndSettle();

        // Verify playback is now playing in PlayerBar
        expect(find.byTooltip('暂停'), findsOneWidget);
      },
    );

    testWidgets(
      'navigating to 我喜欢的音乐 shows login prompt when unauthenticated',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Open favorites from the library.
        await tester.tap(find.byIcon(Icons.library_music_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text('我喜欢的音乐'));
        await tester.pumpAndSettle();

        expect(find.byType(LoginDialog), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('点击登录'), findsWidgets);
      },
    );

    testWidgets('navigating to 我喜欢的音乐 shows tracks when authenticated', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();

      // Login first via auth controller
      await deps.authController.startQrLogin();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pumpAndSettle();

      expect(deps.authController.current.isAuthenticated, isTrue);

      // Open favorites from the library.
      await tester.tap(find.byIcon(Icons.library_music_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我喜欢的音乐'));
      await tester.pumpAndSettle();

      // Should show the user's favorite playlist title and load/play button
      expect(find.textContaining('喜欢的音乐'), findsWidgets);
    });

    testWidgets('navigating to 我喜欢的音乐 opens the playlist the service marked', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final deps = AppDependencies.create(environment: const {});
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();

      await deps.authController.startQrLogin();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.library_music_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我喜欢的音乐'));
      await tester.pumpAndSettle();

      // The account lists a favorited playlist first. A page that took the
      // first entry would open that one instead, and since the fake catalog
      // does not serve it, the failure would be the whole page.
      expect(find.textContaining('收藏的 4 首心动旋律'), findsOneWidget);
      expect(find.textContaining('内容暂时没有加载出来'), findsNothing);
    });

    testWidgets(
      'Playlist browsing shows partial loading indicator and allows retry when playlist is incomplete',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final catalog = _PartialCatalogRepository();
        final media = FakeMediaController();
        final controller = BrowseAndPlayController(catalog, media);
        final deps = AppDependencies.forTesting(
          homeController: controller,
          searchController: CatalogSearchController(catalog),
        );

        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Navigate to playlist page by tapping the playlist card
        await tester.tap(find.text('精选部分歌单'));
        await tester.pumpAndSettle();

        // Verifies the partial notice is displayed
        expect(find.textContaining('(部分加载)'), findsOneWidget);
        expect(find.textContaining('部分歌曲加载失败，仅显示前 1 首'), findsOneWidget);

        // Verifies the retry button is displayed and clickable
        final retryButton = find.text('重试');
        expect(retryButton, findsOneWidget);

        // The home prefetch is followed by a network refresh on detail entry.
        expect(catalog.getPlaylistCallCount, 2);
        await tester.tap(retryButton);
        await tester.pumpAndSettle();
        expect(catalog.getPlaylistCallCount, 3);
      },
    );

    testWidgets(
      'navigation history supports back and forward navigation via top bar buttons',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final deps = AppDependencies.create(environment: const {});
        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Initially on PlaylistSquarePage. Back button exists.
        expect(find.text('官方'), findsOneWidget);
        final backButton = find.byTooltip('后退');
        final forwardButton = find.byTooltip('前进');
        expect(backButton, findsOneWidget);
        expect(forwardButton, findsOneWidget);

        // Tap a playlist
        await tester.tap(find.text('极光夜航').first);
        await tester.pumpAndSettle();

        // Now on playlist page ("播放全部" is visible)
        expect(find.text('播放全部'), findsOneWidget);

        // Tap back button
        await tester.tap(backButton);
        await tester.pumpAndSettle();

        // Back to PlaylistSquarePage
        expect(find.text('官方'), findsOneWidget);

        // Tap forward button
        await tester.tap(forwardButton);
        await tester.pumpAndSettle();

        // Forward to playlist page
        expect(find.text('播放全部'), findsOneWidget);
      },
    );

    testWidgets(
      'opening playlist immediately renders header with loading indicator in track list',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final completer = Completer<PlaylistDetail>();
        final catalog = _DelayedCatalogRepository(completer);
        final media = FakeMediaController();
        final controller = BrowseAndPlayController(catalog, media);
        final deps = AppDependencies.forTesting(
          homeController: controller,
          searchController: CatalogSearchController(catalog),
          backend: PlaybackBackend.native,
        );

        await tester.pumpWidget(FideflowApp(dependencies: deps));
        await tester.pumpAndSettle();

        // Discover page shows playlist card
        expect(find.text('延迟加载歌单'), findsWidgets);

        // Tap the playlist card
        await tester.tap(find.text('延迟加载歌单').first);
        await tester.pump(); // Pump frame right away without settling

        // Immediately header is rendered
        expect(find.text('延迟加载歌单'), findsWidgets);
        expect(find.text('正在加载歌曲列表...'), findsOneWidget);

        // Now complete loading
        completer.complete(
          PlaylistDetail(
            summary: const PlaylistSummary(
              id: PlaylistId('playlist-delayed'),
              title: '延迟加载歌单',
              subtitle: '作者测试',
              trackCount: 10,
            ),
            tracks: [
              Track(
                id: const TrackId('t-1'),
                title: '延迟歌曲 1',
                artists: const [Artist(id: ArtistId('a-1'), name: '歌手 1')],
                album: const Album(id: AlbumId('al-1'), title: '专辑 1'),
                duration: const Duration(minutes: 3),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Loading is gone, tracks are displayed
        expect(find.text('正在加载歌曲列表...'), findsNothing);
        expect(find.text('延迟歌曲 1'), findsOneWidget);
        expect(find.text('播放全部'), findsOneWidget);
      },
    );
  });
}

final class _PartialCatalogRepository implements CatalogRepository {
  int getPlaylistCallCount = 0;

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const HomeFeed(
      greeting: '你好',
      playlists: [
        PlaylistSummary(
          id: PlaylistId('playlist-partial'),
          title: '精选部分歌单',
          subtitle: '测试作者',
          trackCount: 50,
        ),
      ],
    );
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    getPlaylistCallCount++;
    return PlaylistDetail(
      summary: const PlaylistSummary(
        id: PlaylistId('playlist-partial'),
        title: '精选部分歌单',
        subtitle: '测试作者',
        trackCount: 50,
      ),
      tracks: [
        Track(
          id: const TrackId('song-1'),
          title: '部分歌曲 1',
          artists: const [Artist(id: ArtistId('ar-1'), name: '歌手 1')],
          album: const Album(id: AlbumId('al-1'), title: '专辑 1'),
          duration: const Duration(minutes: 3),
        ),
      ],
      isPartial: true,
    );
  }

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const SearchResult(items: [], hasMore: false);
  }

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

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    return const SearchResult(items: [], hasMore: false);
  }

  @override
  Future<Track> getTrack(TrackId id) async {
    throw UnimplementedError();
  }
}

final class _DelayedCatalogRepository implements CatalogRepository {
  _DelayedCatalogRepository(this.completer);

  final Completer<PlaylistDetail> completer;

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const HomeFeed(
      greeting: '你好',
      playlists: [
        PlaylistSummary(
          id: PlaylistId('playlist-delayed'),
          title: '延迟加载歌单',
          subtitle: '作者测试',
          trackCount: 10,
        ),
      ],
    );
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => completer.future;

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const SearchResult(items: [], hasMore: false);
  }

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

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    return const SearchResult(items: [], hasMore: false);
  }

  @override
  Future<Track> getTrack(TrackId id) async {
    throw UnimplementedError();
  }
}
