import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

final class SettingsAuthClient implements RemoteAuthClient {
  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {}
  @override
  Future<String> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async => throw UnsupportedError('phone login');
  @override
  Future<void> uploadDeviceName(String name, {required String cookie}) async {}

  final users = <String, UserProfile>{
    'a': const UserProfile(
      userId: UserId('ncm-user-1'),
      nickname: '很长的账号名称用于检查窄窗口布局不会溢出',
      vipType: 1,
    ),
    'b': const UserProfile(userId: UserId('ncm-user-2'), nickname: '账号 B'),
  };
  String next = 'a';
  String? cookie;
  bool failLogout = false;
  @override
  Future<QrCodeSession> createQrCodeSession() async =>
      const QrCodeSession(unikey: 'qr', qrUrl: 'https://music.163.com/qr');
  @override
  Future<({QrCodeScanStatus status, String? cookie})> checkQrCodeStatus(
    String unikey,
  ) async => (
    status: authorized
        ? QrCodeScanStatus.authorized
        : QrCodeScanStatus.waitingForScan,
    cookie: authorized ? next : null,
  );
  bool authorized = true;
  @override
  Future<UserProfile> getUserAccount({String? cookie}) async => users[cookie]!;
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(
    UserId id, {
    String? cookie,
    int limit = 30,
    int offset = 0,
  }) async => [];
  @override
  Future<void> logout({String? cookie}) async {
    if (failLogout) throw StateError('Offline');
  }

  @override
  void setCookie(String? value) {
    cookie = value;
  }
}

void main() {
  late SettingsAuthClient client;
  late CredentialCoordinator repo;
  late AuthController auth;
  late FakeMediaController media;
  setUp(() {
    client = SettingsAuthClient();
    media = FakeMediaController();
  });
  tearDown(() {
    auth.dispose();
    repo.dispose();
  });
  final exportedCookies = <String>[];
  Future<void> show(
    WidgetTester tester, {
    double width = 1000,
    bool enableExport = true,
    bool failExport = false,
  }) async {
    final desiredAuthorization = client.authorized;
    final desiredNext = client.next;
    client.authorized = true;
    repo = CredentialCoordinator(
      storage: InMemoryCredentialStorage(),
      authClient: client,
    );
    auth = AuthController(
      repo,
      debugSwitchToGuest: repo.switchToGuestForDebug,
      debugExportCookie: enableExport
          ? (account) => repo.exportCookieForDebug(account, (cookie) async {
              if (failExport) throw StateError('test-export-failed');
              exportedCookies.add(cookie);
            })
          : null,
      qrPollingInterval: const Duration(milliseconds: 20),
    );
    client.next = 'a';
    await repo.completeLogin('qr');
    client.next = 'b';
    await repo.completeLogin('qr');
    client.authorized = desiredAuthorization;
    client.next = desiredNext;
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            playback: await media.getSnapshot(),
            authController: auth,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'debug guest switch preserves saved accounts and can switch back',
    (tester) async {
      await show(tester);
      await tester.ensureVisible(find.text('切换到游客（Debug）'));
      await tester.tap(find.text('切换到游客（Debug）'));
      await tester.pumpAndSettle();
      expect(auth.current.session, isNull);
      expect(client.cookie, isNull);
      expect(repo.accounts, hasLength(2));
      expect(repo.accounts.every((account) => !account.needsLogin), isTrue);
      expect(find.text('未登录 · 以本地访客身份使用'), findsOneWidget);
      await auth.switchAccount(const UserId('ncm-user-2'));
      await tester.pumpAndSettle();
      expect(client.cookie, 'b');
      expect(auth.current.isAuthenticated, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'debug export uses the selected saved account without switching',
    (tester) async {
      await show(tester);
      final active = auth.current.session!.user.userId;
      await tester.tap(find.byTooltip('账号操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出 Cookie'));
      await tester.pumpAndSettle();
      expect(exportedCookies.last, 'a');
      expect(auth.current.session!.user.userId, active);
      expect(client.cookie, 'b');
      expect(find.text('Cookie 已复制到剪贴板'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
  testWidgets('account menu hides export without a debug exporter', (
    tester,
  ) async {
    await show(tester, enableExport: false);
    await tester.tap(find.byTooltip('账号操作').first);
    await tester.pumpAndSettle();
    expect(find.text('导出 Cookie'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('export failure shows a localized generic error', (tester) async {
    await show(tester, failExport: true);
    await tester.tap(find.byTooltip('账号操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 Cookie'));
    await tester.pumpAndSettle();
    expect(find.text('导出 Cookie 失败，请重新登录后重试'), findsOneWidget);
    expect(find.textContaining('test-export-failed'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('narrow account list switches and shows current membership', (
    tester,
  ) async {
    await show(tester, width: 380);
    expect(find.text('账号 B'), findsOneWidget);
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(auth.current.session!.user.userId, const UserId('ncm-user-1'));
    expect(find.text('当前使用 · 网易云 VIP 会员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets(
    'local removal confirms remote session remains and preserves current account',
    (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('账号操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('从本机移除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会注销远端会话'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(localizedTestValue(repo.accounts.single.user.nickname), '账号 B');
      expect(client.cookie, 'b');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
  testWidgets('failed logout retains current account and offers retry', (
    tester,
  ) async {
    client.failLogout = true;
    await show(tester);
    await tester.tap(find.byTooltip('账号操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出账号'));
    await tester.pumpAndSettle();
    expect(localizedTestValue(auth.current.session!.user.nickname), '账号 B');
    expect(repo.accounts, hasLength(2));
    expect(find.textContaining('账号操作失败'), findsWidgets);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('cancel adding an account preserves the active session', (
    tester,
  ) async {
    client.authorized = false;
    await show(tester);
    await tester.tap(find.text('添加账号'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(auth.current.isAuthenticated, isTrue);
    expect(localizedTestValue(auth.current.session!.user.nickname), '账号 B');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(auth.current.isAuthenticated, isTrue);
    expect(repo.accounts, hasLength(2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('adding an existing account switches once and closes QR dialog', (
    tester,
  ) async {
    client.next = 'a';
    await show(tester);
    await tester.tap(find.text('添加账号'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpAndSettle();
    expect(auth.current.session!.user.userId, const UserId('ncm-user-1'));
    expect(repo.accounts, hasLength(2));
    expect(find.text('登录网易云音乐'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
