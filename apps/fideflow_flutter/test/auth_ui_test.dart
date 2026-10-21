import 'dart:async';

import 'package:fideflow/features/auth/login_dialog.dart';
import 'package:fideflow/features/discovery/favorite_music_page.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support/test_viewport.dart';

// Minimal 1x1 transparent PNG
final kMockPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

final class FakeCatalog implements CatalogRepository {
  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(
    greeting: '你好',
    playlists: [
      PlaylistSummary(
        id: PlaylistId('feed-p1'),
        title: '精选歌单一',
        subtitle: '编辑精选',
        trackCount: 5,
      ),
    ],
  );

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const PlaylistDetail(
    summary: PlaylistSummary(
      id: PlaylistId('feed-p1'),
      title: '精选歌单一',
      subtitle: '编辑精选',
      trackCount: 1,
    ),
    tracks: [
      Track(
        id: TrackId('t1'),
        title: '曲目一',
        artists: [Artist(id: ArtistId('a1'), name: '歌手一')],
        album: Album(id: AlbumId('al1'), title: '专辑一'),
        duration: Duration(minutes: 3),
      ),
    ],
  );

  @override
  Future<Track> getTrack(TrackId id) async => throw UnimplementedError();

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

final class FakeAuthRepo implements AuthRepository {
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

  final StreamController<AuthSession?> _controller =
      StreamController<AuthSession?>.broadcast();

  AuthSession? _current;
  QrCodeScanStatus nextStatus = QrCodeScanStatus.waitingForScan;
  List<PlaylistSummary> playlists = [];
  bool failPlaylists = false;
  bool failSignOut = false;
  bool failRestore = false;
  bool includeQrImage = true;

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  @override
  AuthSession? get currentSession => _current;

  @override
  Future<QrCodeSession> createQrCodeSession() async => QrCodeSession(
    unikey: 'test-unikey-999',
    qrUrl: 'https://music.163.com/qr',
    qrImageBytes: includeQrImage ? kMockPng : null,
  );

  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) async => nextStatus;

  @override
  Future<AuthSession> completeLogin(String unikey) async {
    final session = const AuthSession(
      user: UserProfile(
        userId: UserId('ncm-user-888'),
        nickname: '测试达人',
        vipType: 1,
      ),
      authEpoch: 1,
    );
    _current = session;
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession?> restoreSession() async {
    if (failRestore) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'provider.deviceIdUnavailable',
        retryable: true,
      );
    }
    return _current;
  }

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async {
    if (failPlaylists) throw StateError('playlist request failed');
    return playlists;
  }

  @override
  Future<void> signOut() async {
    if (failSignOut) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'auth.logoutUnverified',
        retryable: true,
      );
    }
    _current = null;
    _controller.add(null);
  }

  void dispose() {
    _controller.close();
  }
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'guest favorites requests login without navigating at width $width',
      (tester) async {
        await setTestViewport(tester, Size(width, 844));
        addTearDown(() => setTestViewport(tester, null));
        final catalog = FakeCatalog();
        final home = BrowseAndPlayController(catalog, FakeMediaController());
        final repo = FakeAuthRepo();
        final auth = AuthController(repo);
        addTearDown(() {
          home.dispose();
        });
        addTearDown(auth.dispose);
        addTearDown(repo.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            home: HomeScreen(controller: home, authController: auth),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('推荐'), findsNothing);
        if (width < 600) {
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'mobile-navigation-',
                  ),
            ),
            findsNWidgets(2),
          );
        }
        await tester.tap(find.byIcon(Icons.library_music_outlined));
        await tester.pumpAndSettle();
        if (width < 600) {
          // One content heading plus the bottom tab, with no toolbar title.
          expect(find.text('我的音乐'), findsNWidgets(2));
        }
        await tester.tap(find.text('我喜欢的音乐'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(LoginDialog), findsOneWidget);
        expect(find.byType(FavoriteMusicPage), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('我喜欢的音乐'), findsOneWidget);
        expect(find.byType(FavoriteMusicPage), findsNothing);

        await repo.completeLogin('test-unikey-999');
        await tester.pumpAndSettle();
        if (width < 600) {
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'mobile-navigation-',
                  ),
            ),
            findsNWidgets(3),
          );
        }
        if (width < 600) {
          await tester.tap(
            find.byKey(const ValueKey('mobile-navigation-nav.library')),
          );
        } else {
          await tester.tap(find.byIcon(Icons.library_music_outlined));
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('我喜欢的音乐'));
        await tester.pumpAndSettle();
        expect(find.byType(LoginDialog), findsNothing);
        expect(find.byType(FavoriteMusicPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        width < 600 ? TargetPlatform.android : TargetPlatform.linux,
      ),
    );
  }

  testWidgets('QR URL is rendered when the provider returns no image', (
    tester,
  ) async {
    final authRepo = FakeAuthRepo()..includeQrImage = false;
    final controller = AuthController(authRepo);
    addTearDown(controller.dispose);
    addTearDown(authRepo.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LoginDialog(controller: controller)),
      ),
    );
    await controller.startQrLogin();
    await tester.pump();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('二维码生成中'), findsNothing);
    controller.cancelQrLogin();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('AccountCard renders guest view and opens LoginDialog on click', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(1280, 800));
    addTearDown(() => setTestViewport(tester, null));

    final catalog = FakeCatalog();
    final media = FakeMediaController();
    final homeController = BrowseAndPlayController(catalog, media);
    final authRepo = FakeAuthRepo();
    final authController = AuthController(authRepo);

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(
          controller: homeController,
          authController: authController,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify guest card is visible
    expect(find.text('点击登录'), findsOneWidget);
    expect(find.text('登录以同步歌单'), findsNothing);

    // Tap account card to open QR login dialog
    await tester.tap(find.text('点击登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify dialog opened
    expect(find.byType(LoginDialog), findsOneWidget);
    expect(find.text('登录网易云音乐'), findsOneWidget);
    expect(find.text('请使用网易云音乐 App 扫码登录'), findsOneWidget);

    // Cancel dialog
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginDialog), findsNothing);

    authController.dispose();
    authRepo.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('restore failure preserves a retry path in the account card', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(1280, 800));
    addTearDown(() => setTestViewport(tester, null));
    final authRepo = FakeAuthRepo()
      ..failRestore = true
      .._current = const AuthSession(
        user: UserProfile(userId: UserId('ncm-user-888'), nickname: '测试达人'),
        authEpoch: 1,
      );
    final authController = AuthController(authRepo);

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(
          controller: BrowseAndPlayController(
            FakeCatalog(),
            FakeMediaController(),
          ),
          authController: authController,
        ),
      ),
    );
    await authController.restoreSession();
    await tester.pumpAndSettle();
    expect(find.text('登录恢复失败'), findsOneWidget);
    expect(find.text('凭据已保留，点击重试'), findsOneWidget);

    authRepo.failRestore = false;
    await tester.tap(find.text('登录恢复失败'));
    await tester.pumpAndSettle();
    expect(find.text('测试达人'), findsOneWidget);
    expect(find.text('点击登录'), findsNothing);

    authController.dispose();
    authRepo.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'QR login flow transitions to scanned, then authenticated and updates UI',
    (tester) async {
      await setTestViewport(tester, const Size(1280, 800));
      addTearDown(() => setTestViewport(tester, null));

      final catalog = FakeCatalog();
      final media = FakeMediaController();
      final homeController = BrowseAndPlayController(catalog, media);
      final authRepo = FakeAuthRepo();
      authRepo.playlists = const [
        PlaylistSummary(
          id: PlaylistId('ncm-playlist-my-fav'),
          title: '我的专属红心歌单',
          subtitle: '网易云音乐',
          trackCount: 30,
        ),
      ];
      final authController = AuthController(
        authRepo,
        qrPollingInterval: const Duration(milliseconds: 20),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: HomeScreen(
            controller: homeController,
            authController: authController,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap account card
      await tester.tap(find.text('点击登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Simulate scanned state
      authRepo.nextStatus = QrCodeScanStatus.waitingForConfirmation;
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('扫码成功'), findsOneWidget);
      expect(find.text('请在手机上点击确认以完成登录'), findsOneWidget);

      // Simulate authorized state
      authRepo.nextStatus = QrCodeScanStatus.authorized;
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      // Dialog should have closed automatically
      expect(find.byType(LoginDialog), findsNothing);

      // AccountCard should now display authenticated user
      expect(find.text('测试达人'), findsOneWidget);
      expect(find.text('VIP'), findsOneWidget);
      expect(find.text('网易云 VIP 会员'), findsNothing);

      // Navigate to '我的音乐' via icon
      await tester.tap(find.byIcon(Icons.library_music_outlined));
      await tester.pumpAndSettle();

      // Verify user's personal playlist is displayed
      expect(find.text('我的专属红心歌单'), findsOneWidget);
      expect(find.text('已同步 测试达人 的网易云音乐个人歌单'), findsNothing);
      expect(find.text('128'), findsNothing);
      expect(find.text('36h'), findsNothing);

      // The account menu remains available while the sidebar is collapsed.
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(CircleAvatar).first);
      await tester.pumpAndSettle();
      expect(find.text('退出登录'), findsOneWidget);

      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();

      // Verify reverted back to guest state
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-sidebar')),
          matching: find.text('点击登录'),
        ),
        findsOneWidget,
      );
      expect(find.text('登录以同步歌单'), findsNothing);

      authController.dispose();
      authRepo.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('personal playlists show failure, retry, then an empty state', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(1280, 800));
    addTearDown(() => setTestViewport(tester, null));

    final catalog = FakeCatalog();
    final homeController = BrowseAndPlayController(
      catalog,
      FakeMediaController(),
    );
    final authRepo = FakeAuthRepo()..failPlaylists = true;
    final authController = AuthController(authRepo);
    addTearDown(authController.dispose);
    addTearDown(authRepo.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(
          controller: homeController,
          authController: authController,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await authRepo.completeLogin('test-unikey-999');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.library_music_outlined));
    await tester.pumpAndSettle();

    expect(find.text('个人歌单加载失败，请重试'), findsOneWidget);
    expect(find.text('精选歌单一'), findsNothing);
    expect(find.text('128'), findsNothing);

    await tester.tap(find.text('我喜欢的音乐'));
    await tester.pumpAndSettle();
    expect(find.text('个人歌单加载失败，请重试'), findsOneWidget);
    expect(find.text('暂无歌单'), findsNothing);
    await tester.tap(find.byIcon(Icons.library_music_outlined));
    await tester.pumpAndSettle();

    authRepo.failPlaylists = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(find.text('还没有创建的歌单'), findsOneWidget);
    expect(find.text('精选歌单一'), findsNothing);
    expect(find.text('个人歌单加载失败，请重试'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('failed remote logout keeps the account visible for retry', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(1280, 800));
    addTearDown(() => setTestViewport(tester, null));

    final authRepo = FakeAuthRepo()..failSignOut = true;
    final authController = AuthController(authRepo);
    addTearDown(authController.dispose);
    addTearDown(authRepo.dispose);
    final homeController = BrowseAndPlayController(
      FakeCatalog(),
      FakeMediaController(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(
          controller: homeController,
          authController: authController,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await authRepo.completeLogin('test-unikey-999');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    expect(find.text('测试达人'), findsOneWidget);
    expect(find.text('点击登录'), findsNothing);
    expect(find.textContaining('退出未完成'), findsOneWidget);

    authRepo.failSignOut = false;
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    expect(find.text('点击登录'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
