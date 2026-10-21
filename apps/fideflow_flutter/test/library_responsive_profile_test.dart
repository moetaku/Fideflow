import 'dart:async';

import 'package:fideflow/features/discovery/home_sidebar.dart';
import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MockAuthRepo implements AuthRepository {
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

  _MockAuthRepo({this.vipType = 11});

  final int vipType;
  final StreamController<AuthSession?> _sessions =
      StreamController<AuthSession?>.broadcast();
  AuthSession? _current;

  @override
  Stream<AuthSession?> get sessionChanges => _sessions.stream;

  @override
  AuthSession? get currentSession => _current;

  Future<void> signIn() async {
    _current = AuthSession(
      user: UserProfile(
        userId: const UserId('ncm-user-1'),
        nickname: 'VIP达人',
        vipType: vipType,
      ),
      authEpoch: 1,
    );
    _sessions.add(_current);
  }

  @override
  Future<QrCodeSession> createQrCodeSession() => throw UnimplementedError();

  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) async =>
      QrCodeScanStatus.unknown;

  @override
  Future<AuthSession> completeLogin(String unikey) =>
      throw UnimplementedError();

  @override
  Future<AuthSession?> restoreSession() async => _current;

  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async =>
      UserPlaylists([]);

  @override
  Future<void> signOut() async {
    _current = null;
    _sessions.add(null);
  }

  void dispose() => unawaited(_sessions.close());
}

void main() {
  testWidgets('Library quick cards localize subtitles and favorite count', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget build(Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: FideflowTheme.dark(),
      home: Scaffold(
        body: LibraryPage(
          feed: const HomeFeed(greeting: '', playlists: []),
          onOpenPlaylist: (_) {},
          isCompact: true,
        ),
      ),
    );

    await tester.pumpWidget(build(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Favorite music'), findsOneWidget);
    expect(find.text('Local playback history'), findsOneWidget);
    expect(find.text('本地播放历史'), findsNothing);

    await tester.pumpWidget(build(const Locale('zh', 'Hans')));
    await tester.pumpAndSettle();
    expect(find.text('喜欢的音乐'), findsOneWidget);
    expect(find.text('本地播放历史'), findsOneWidget);
  });

  testWidgets(
    'in compact layout, LibraryPage shows profile banner with themed VIP badge',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repo = _MockAuthRepo(vipType: 11);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: LibraryPage(
              feed: const HomeFeed(greeting: '', playlists: []),
              onOpenPlaylist: (_) {},
              authController: auth,
              isCompact: true,
            ),
          ),
        ),
      );
      await repo.signIn();
      await tester.pumpAndSettle();

      expect(find.text('VIP达人'), findsOneWidget);
      final vipTextFinder = find.text('VIP');
      expect(vipTextFinder, findsOneWidget);
      final vipText = tester.widget<Text>(vipTextFinder);
      expect(
        vipText.style?.color,
        AppColors.of(tester.element(vipTextFinder)).warning,
      );

      final vipContainerFinder = find
          .ancestor(of: vipTextFinder, matching: find.byType(Container))
          .first;
      final vipContainer = tester.widget<Container>(vipContainerFinder);
      final decoration = vipContainer.decoration as BoxDecoration?;
      final colors = AppColors.of(tester.element(vipTextFinder));
      expect(decoration?.color, colors.warning.withValues(alpha: .12));
      expect((decoration?.border as Border?)?.top.color, colors.warning);
    },
  );

  testWidgets(
    'in medium layout (isCompact: false), LibraryPage does not show profile banner',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repo = _MockAuthRepo(vipType: 11);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: LibraryPage(
              feed: const HomeFeed(greeting: '', playlists: []),
              onOpenPlaylist: (_) {},
              authController: auth,
              isCompact: false,
            ),
          ),
        ),
      );
      await repo.signIn();
      await tester.pumpAndSettle();

      expect(find.text('账号管理 / 切换'), findsNothing);
      expect(find.text('VIP达人'), findsNothing);
    },
  );

  testWidgets(
    'when isCompact is omitted, LibraryPage infers banner visibility from MediaQuery',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(720, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _MockAuthRepo(vipType: 11);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: LibraryPage(
              feed: const HomeFeed(greeting: '', playlists: []),
              onOpenPlaylist: (_) {},
              authController: auth,
            ),
          ),
        ),
      );
      await repo.signIn();
      await tester.pumpAndSettle();

      expect(find.text('VIP达人'), findsNothing);

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();

      expect(find.text('VIP达人'), findsOneWidget);
    },
  );

  testWidgets(
    'HomeSidebar displays user account with themed VIP badge and warning text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repo = _MockAuthRepo(vipType: 11);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: HomeSidebar(
              selectedDestination: 'library',
              onSelected: (_) {},
              onOpenSettings: () {},
              onToggleCollapsed: () {},
              settingsSelected: false,
              collapsed: false,
              width: 200,
              authController: auth,
            ),
          ),
        ),
      );
      await repo.signIn();
      await tester.pumpAndSettle();

      expect(find.text('VIP达人'), findsOneWidget);

      final vipTextFinder = find.text('VIP');
      expect(vipTextFinder, findsOneWidget);

      final vipContainerFinder = find
          .ancestor(of: vipTextFinder, matching: find.byType(Container))
          .first;
      final vipContainer = tester.widget<Container>(vipContainerFinder);
      final decoration = vipContainer.decoration as BoxDecoration?;
      final colors = AppColors.of(tester.element(vipTextFinder));
      expect(decoration?.color, colors.warning.withValues(alpha: .12));
      expect((decoration?.border as Border?)?.top.color, colors.warning);
    },
  );

  testWidgets(
    'HomeSidebar right-aligns VIP beside nickname and opens actions on avatar',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repo = _MockAuthRepo(vipType: 11);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: HomeSidebar(
              selectedDestination: 'library',
              onSelected: (_) {},
              onOpenSettings: () {},
              onToggleCollapsed: () {},
              settingsSelected: false,
              collapsed: false,
              width: 200,
              authController: auth,
            ),
          ),
        ),
      );
      await repo.signIn();
      await tester.pumpAndSettle();

      final nicknameRect = tester.getRect(find.text('VIP达人'));
      final vipRect = tester.getRect(find.text('VIP'));
      expect(vipRect.center.dy, nicknameRect.center.dy);
      final accountCardRect = tester.getRect(
        find
            .ancestor(of: find.text('VIP达人'), matching: find.byType(Container))
            .last,
      );
      expect(vipRect.right, lessThan(accountCardRect.right));
      expect(find.byIcon(Icons.more_vert), findsNothing);

      await tester.tap(find.byType(CircleAvatar));
      await tester.pumpAndSettle();
      expect(find.text('退出登录'), findsOneWidget);
      final avatarRect = tester.getRect(find.byType(CircleAvatar));
      final menuRect = tester.getRect(
        find
            .ancestor(of: find.text('退出登录'), matching: find.byType(Material))
            .first,
      );
      expect(menuRect.top, greaterThanOrEqualTo(avatarRect.bottom));
    },
  );

  testWidgets('collapsed HomeSidebar still shows avatar as account action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repo = _MockAuthRepo(vipType: 11);
    final auth = AuthController(repo);
    addTearDown(auth.dispose);
    addTearDown(repo.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: HomeSidebar(
            selectedDestination: 'library',
            onSelected: (_) {},
            onOpenSettings: () {},
            onToggleCollapsed: () {},
            settingsSelected: false,
            collapsed: true,
            width: 68,
            authController: auth,
          ),
        ),
      ),
    );
    await repo.signIn();
    await tester.pumpAndSettle();

    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    final avatarMenu = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    expect(avatarMenu.child, isA<CircleAvatar>());
    final accountContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.byType(CircleAvatar),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(accountContainer.decoration, isNull);
    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    expect(find.text('退出登录'), findsOneWidget);
  });
}
