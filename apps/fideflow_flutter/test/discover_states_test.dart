import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

/// The discovery page's own states, section by section.
void main() {
  Future<void> useTallWindow(WidgetTester tester) async {
    await setTestViewport(tester, const Size(1280, 2200));
    addTearDown(() => setTestViewport(tester, null));
  }

  Future<void> pumpDiscover(
    WidgetTester tester,
    _ScriptedHomeFeed feed, {
    AuthController? authController,
  }) async {
    final controller = BrowseAndPlayController(
      feed,
      FakeMediaController(),
      homeFeed: feed,
    );
    await tester.pumpWidget(_home(controller, authController: authController));
    await tester.pumpAndSettle();
  }

  for (final width in [360.0, 440.0, 599.0, 600.0, 839.0, 840.0, 1280.0]) {
    testWidgets(
      'native desktop shell at $width',
      (tester) async {
        await setTestViewport(tester, Size(width, 900));
        addTearDown(() => setTestViewport(tester, null));
        await pumpDiscover(tester, _ScriptedHomeFeed());
        final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
        expect(sidebar, findsOneWidget);
        expect(tester.getSize(sidebar).width, width < 840 ? 80 : 200);
        expect(
          find.byKey(const ValueKey('mobile-bottom-navigation')),
          findsNothing,
        );
        expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'narrow desktop at large text keeps all shell controls reachable',
    (tester) async {
      await setTestViewport(tester, const Size(440, 560));
      addTearDown(() => setTestViewport(tester, null));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpDiscover(tester, _ScriptedHomeFeed());
      expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_double_arrow_right), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'collapsed sidebar buttons are square and blank areas drag the window',
    (tester) async {
      await setTestViewport(tester, const Size(599, 800));
      addTearDown(() => setTestViewport(tester, null));
      const channel = MethodChannel('fideflow/desktop');
      final commands = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'isMaximized') return false;
        commands.add(call.method);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pumpDiscover(tester, _ScriptedHomeFeed());
      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      final item = find.descendant(
        of: sidebar,
        matching: find.byIcon(Icons.queue_music_outlined),
      );
      final material = find
          .ancestor(of: item, matching: find.byType(Material))
          .first;
      expect(tester.getSize(material), const Size.square(48));
      final sidebarRect = tester.getRect(sidebar);
      for (final delta in [const Offset(0, 40), const Offset(40, 0)]) {
        final gesture = await tester.startGesture(
          sidebarRect.center,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(delta);
        await gesture.up();
        await tester.pumpAndSettle();
      }
      expect(commands, ['startDragging', 'startDragging']);
      commands.clear();
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(commands, isEmpty);
      final search = find.byType(TextField);
      expect(tester.getTopLeft(search).dy, lessThan(24));
      await tester.tap(search);
      await tester.enterText(search, '音乐');
      await tester.pumpAndSettle();
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'desktop expansion waits, coalesces and respects failure',
    (tester) async {
      await setTestViewport(tester, const Size(599, 900));
      addTearDown(() => setTestViewport(tester, null));
      const channel = MethodChannel('fideflow/desktop');
      var calls = 0;
      var result = Completer<bool>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) {
        if (call.method == 'isMaximized') return Future.value(false);
        expect(call.method, 'expandForSidebar');
        calls++;
        return result.future;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pumpDiscover(tester, _ScriptedHomeFeed());
      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      final expand = find.byIcon(Icons.keyboard_double_arrow_right);
      await tester.tap(expand);
      await tester.tap(expand);
      expect(calls, 1);
      result.complete(false);
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 80);
      result = Completer<bool>();
      await tester.tap(expand);
      await setTestViewport(tester, const Size(840, 900));
      await tester.pump();
      result.complete(true);
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 200);
      await setTestViewport(tester, const Size(839, 900));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 80);
      await setTestViewport(tester, const Size(1000, 900));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 80);
      expect(calls, 2);
      for (final width in [1000.0, 840.0]) {
        await setTestViewport(tester, Size(width, 900));
        await tester.pumpAndSettle();
        await tester.tap(expand);
        await tester.pumpAndSettle();
        expect(tester.getSize(sidebar).width, 200);
        expect(calls, 2, reason: 'Wide windows must expand without resizing');
        await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
        await tester.pumpAndSettle();
        expect(tester.getSize(sidebar).width, 80);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'desktop sidebar collapses, shows hover labels and opens settings',
    (tester) async {
      await setTestViewport(tester, const Size(1280, 800));
      addTearDown(() => setTestViewport(tester, null));
      await pumpDiscover(tester, _ScriptedHomeFeed());
      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      Finder inSidebar(Finder finder) =>
          find.descendant(of: sidebar, matching: finder);

      expect(inSidebar(find.text('点击登录')), findsOneWidget);
      expect(inSidebar(find.text('推荐')), findsNothing);
      expect(inSidebar(find.text('精选歌单')), findsOneWidget);
      expect(inSidebar(find.text('我的音乐')), findsOneWidget);
      expect(inSidebar(find.text('在线音乐')), findsNothing);
      expect(inSidebar(find.byIcon(Icons.favorite_border)), findsNothing);
      expect(inSidebar(find.byIcon(Icons.history_outlined)), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('点击登录')).dy,
        lessThan(tester.getTopLeft(inSidebar(find.text('精选歌单'))).dy),
      );

      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 80);
      expect(inSidebar(find.byType(Text)), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (final entry in {
        Icons.queue_music_outlined: '精选歌单',
        Icons.library_music_outlined: '我的音乐',
        Icons.settings_outlined: '设置',
        Icons.person_outline: '点击登录',
      }.entries) {
        await mouse.moveTo(tester.getCenter(inSidebar(find.byIcon(entry.key))));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(entry.value), findsOneWidget);
        await mouse.moveTo(const Offset(600, 0));
        await tester.pumpAndSettle();
      }
      await mouse.removePointer();
      await tester.tap(inSidebar(find.byIcon(Icons.settings_outlined)));
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsWidgets);
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 200);
      expect(inSidebar(find.text('我的音乐')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await setTestViewport(tester, const Size(800, 600));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 200);
      await tester.tap(inSidebar(find.byIcon(Icons.library_music_outlined)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('daily recommendation is hidden when unauthenticated', (
    tester,
  ) async {
    await useTallWindow(tester);
    final authRepo = _GuestAuthRepo();
    final authController = AuthController(authRepo);
    addTearDown(authRepo.dispose);

    await pumpDiscover(
      tester,
      _ScriptedHomeFeed(),
      authController: authController,
    );

    // Top card is hidden when unauthenticated
    expect(find.text('每日推荐'), findsNothing);
    // Old login prompt is removed from the content stream
    expect(find.text('登录网易云音乐账号，探索你的专属每日推荐音乐'), findsNothing);

    // Unauthenticated redirects to PlaylistSquarePage
    expect(find.text('官方'), findsOneWidget);

    authController.dispose();
  });

  testWidgets('daily recommendation is displayed when authenticated', (
    tester,
  ) async {
    await useTallWindow(tester);
    final authRepo = _AuthenticatedAuthRepo();
    final authController = AuthController(authRepo);
    await authController.restoreSession();
    addTearDown(authRepo.dispose);

    await pumpDiscover(
      tester,
      _ScriptedHomeFeed(),
      authController: authController,
    );

    // Top card is visible when authenticated
    expect(find.text('每日推荐'), findsOneWidget);
    final pageTitle = find.byWidgetPredicate(
      (widget) =>
          widget is Text && widget.data == '推荐' && widget.style?.fontSize == 24,
    );
    expect(pageTitle, findsOneWidget);
    await tester.tap(find.byIcon(Icons.library_music_outlined));
    await tester.pumpAndSettle();
    final libraryTitle = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == '我的音乐' &&
          widget.style?.fontSize == 24,
    );
    expect(libraryTitle, findsOneWidget);

    authController.dispose();
  });

  testWidgets('a failed playlist square retries on its own', (tester) async {
    await useTallWindow(tester);
    final catalog = _FailingSquareCatalog();
    final controller = BrowseAndPlayController(catalog, FakeMediaController());
    await tester.pumpWidget(_home(controller));
    await tester.pumpAndSettle();

    expect(find.textContaining('歌单加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    catalog.failSquare = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.textContaining('歌单加载失败'), findsNothing);
    expect(find.text('官方'), findsOneWidget);
  });
}

final class _FailingSquareCatalog
    implements
        CatalogRepository,
        CatalogSearchRepository,
        HomeFeedRepository,
        CatalogDetailRepository,
        RecommendRepository,
        PlaylistSquareRepository {
  final FakeCatalogRepository _inner = FakeCatalogRepository(
    latency: Duration.zero,
  );
  bool failSquare = true;

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (failSquare) {
      throw const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
    }
    return _inner.getSquarePlaylists(
      cat: cat,
      order: order,
      limit: limit,
      offset: offset,
      policy: policy,
    );
  }

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getHomeFeed(policy: policy);

  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getHomeSection(kind, policy: policy);

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getPlaylist(id, policy: policy);

  @override
  Future<Track> getTrack(TrackId id) => _inner.getTrack(id);

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) =>
      _inner.searchTracks(query);

  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) =>
      _inner.search(query);

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) => _inner.getAlbum(id);

  @override
  Future<ArtistDetail> getArtist(ArtistId id) => _inner.getArtist(id);

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getPlaylistTracks(
    id,
    limit: limit,
    offset: offset,
    policy: policy,
  );

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getPlaylistAccess(id, policy: policy);

  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getDailySongs(dateKey: dateKey, policy: policy);

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getRecommendedPlaylists(policy: policy);

  @override
  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getNewSongs(limit: limit, policy: policy);

  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getRecentListeningResources(policy: policy);

  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getCategoryTree(policy: policy);

  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getHotTags(policy: policy);

  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => _inner.getHighQualityPlaylist(cat, policy: policy);
}

Widget _home(
  BrowseAndPlayController controller, {
  AuthController? authController,
}) {
  return MaterialApp(
    theme: FideflowTheme.dark(),
    home: HomeScreen(controller: controller, authController: authController),
  );
}

final class _ScriptedHomeFeed implements CatalogRepository, HomeFeedRepository {
  bool toplistsAvailable = false;
  final List<HomeSectionKind> sectionRequests = [];

  static const _recommended = HomeSection(
    kind: HomeSectionKind.recommended,
    title: '推荐歌单',
    playlists: [
      PlaylistSummary(
        id: PlaylistId('ncm-playlist-morning'),
        title: '晨间精选',
        subtitle: '编辑精选',
        trackCount: 2,
      ),
    ],
  );

  static const _daily = HomeSection(
    kind: HomeSectionKind.dailyRecommendations,
    title: '每日推荐',
    status: HomeSectionStatus.requiresAuth,
    requiresAuth: true,
  );

  static const _toplistsFailed = HomeSection(
    kind: HomeSectionKind.toplists,
    title: '排行榜',
    status: HomeSectionStatus.failed,
    errorCode: 'network.timeout',
  );

  static const _toplistsReady = HomeSection(
    kind: HomeSectionKind.toplists,
    title: '排行榜',
    playlists: [
      PlaylistSummary(
        id: PlaylistId('ncm-top-1'),
        title: '云音乐飙升榜',
        subtitle: '每天更新',
        trackCount: 100,
      ),
    ],
  );

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => HomeFeed(
    greeting: '晚上好，去听一段极光',
    sections: [
      _recommended,
      _daily,
      toplistsAvailable ? _toplistsReady : _toplistsFailed,
    ],
  );

  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    sectionRequests.add(kind);
    return switch (kind) {
      HomeSectionKind.recommended => _recommended,
      HomeSectionKind.dailyRecommendations => _daily,
      HomeSectionKind.topPlaylists => const HomeSection(
        kind: HomeSectionKind.topPlaylists,
        title: '网友精选碟',
        playlists: [],
      ),
      HomeSectionKind.recentPlaylists => const HomeSection(
        kind: HomeSectionKind.recentPlaylists,
        title: '最近播放歌单',
        playlists: [],
      ),
      HomeSectionKind.toplists =>
        toplistsAvailable ? _toplistsReady : _toplistsFailed,
    };
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const PlaylistDetail(
    summary: PlaylistSummary(
      id: PlaylistId('ncm-playlist-morning'),
      title: '晨间精选',
      subtitle: '编辑精选',
      trackCount: 2,
    ),
    tracks: [
      Track(
        id: TrackId('ncm-track-1'),
        title: '归途',
        artists: [Artist(id: ArtistId('ncm-artist-1'), name: '候鸟')],
        album: Album(id: AlbumId('ncm-album-1'), title: '晨间精选'),
        duration: Duration(minutes: 3, seconds: 42),
      ),
    ],
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

final class _GuestAuthRepo implements AuthRepository {
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {}
  @override
  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async => completeLogin('phone');

  final StreamController<AuthSession?> _sessions =
      StreamController<AuthSession?>.broadcast();

  @override
  Stream<AuthSession?> get sessionChanges => _sessions.stream;

  @override
  AuthSession? get currentSession => null;

  @override
  Future<QrCodeSession> createQrCodeSession() => throw UnimplementedError();

  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> completeLogin(String unikey) =>
      throw UnimplementedError();

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async =>
      const [];

  @override
  Future<void> signOut() async {}

  void dispose() => unawaited(_sessions.close());
}

final class _AuthenticatedAuthRepo implements AuthRepository {
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {}
  @override
  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async => completeLogin('phone');

  final StreamController<AuthSession?> _sessions =
      StreamController<AuthSession?>.broadcast();

  static const _session = AuthSession(
    user: UserProfile(userId: UserId('u1'), nickname: 'Aurora'),
    authEpoch: 1,
  );

  @override
  Stream<AuthSession?> get sessionChanges => _sessions.stream;

  @override
  AuthSession? get currentSession => _session;

  @override
  Future<QrCodeSession> createQrCodeSession() => throw UnimplementedError();

  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> completeLogin(String unikey) =>
      throw UnimplementedError();

  @override
  Future<AuthSession?> restoreSession() async => _session;

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async =>
      const [];

  @override
  Future<void> signOut() async {}

  void dispose() => unawaited(_sessions.close());
}
