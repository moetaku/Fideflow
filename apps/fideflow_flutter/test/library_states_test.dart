import 'dart:async';

import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The library page's account states: a personal-playlist sync that fails, and
/// one that comes back incomplete.
///
/// Both are states the page has to *describe* rather than resolve: a failure
/// keeps the lists the user already has, and a partial answer keeps the ones it
/// did send while saying that more were expected.
void main() {
  Future<void> useTallWindow(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Future<void> pumpLibrary(WidgetTester tester, AuthController auth) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: Scaffold(
          body: LibraryPage(
            feed: _feed,
            onOpenPlaylist: (_) {},
            authController: auth,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pumps the page for a guest, then announces the login, so the page is seen
  /// to move from the signed-out state to the account's lists.
  Future<void> pumpSignedInLibrary(
    WidgetTester tester,
    AuthController auth,
    _ScriptedAuthRepo repo,
  ) async {
    await pumpLibrary(tester, auth);
    await repo.signIn();
    await tester.pumpAndSettle();
  }

  testWidgets('a partial personal-playlist load names what it did show', (
    tester,
  ) async {
    await useTallWindow(tester);
    final repo = _ScriptedAuthRepo(playlists: [_lateNight, _morningWalk])
      ..partial = true;
    final auth = AuthController(repo);
    addTearDown(auth.dispose);
    addTearDown(repo.dispose);

    await pumpSignedInLibrary(tester, auth, repo);

    expect(repo.playlistRequests, 1);
    expect(find.text('歌单列表未完全载入，当前显示 2 个歌单'), findsOneWidget);
    expect(find.text('已同步 测试达人 的网易云音乐个人歌单'), findsNothing);
    // The lists sent are still usable, and the local feed is not what an
    // account's library shows.
    expect(find.text('深夜精选'), findsOneWidget);
    expect(find.text('清晨散步'), findsOneWidget);
    expect(find.text('本机收藏'), findsNothing);

    repo
      ..partial = false
      ..playlists = [_lateNight, _morningWalk, _midnightRadio];
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    // The reload is a real second request, and the notice goes away with it.
    expect(repo.playlistRequests, 2);
    expect(find.text('歌单列表未完全载入，当前显示 2 个歌单'), findsNothing);
    expect(find.text('午夜电台'), findsOneWidget);
  });

  testWidgets('a failed sync keeps the lists it already had', (tester) async {
    await useTallWindow(tester);
    final repo = _ScriptedAuthRepo(playlists: [_lateNight, _morningWalk]);
    final auth = AuthController(repo);
    addTearDown(auth.dispose);
    addTearDown(repo.dispose);

    await pumpSignedInLibrary(tester, auth, repo);
    expect(find.text('已同步 测试达人 的网易云音乐个人歌单'), findsNothing);

    repo.failPlaylists = true;
    await auth.loadUserPlaylists();
    await tester.pumpAndSettle();

    // The list section reports the failure, and the
    // lists from the last successful sync stay on screen.
    expect(find.text('测试达人 的网易云音乐个人歌单同步失败'), findsNothing);
    expect(find.text('个人歌单更新失败，当前显示上次加载的内容'), findsOneWidget);
    expect(find.text('深夜精选'), findsOneWidget);
    expect(find.text('清晨散步'), findsOneWidget);
    // The empty-list wording belongs to the other failure, not to this one.
    expect(find.text('个人歌单加载失败，请重试'), findsNothing);
    expect(find.text('还没有个人歌单'), findsNothing);

    repo
      ..failPlaylists = false
      ..playlists = [_lateNight, _morningWalk, _midnightRadio];
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(find.text('个人歌单更新失败，当前显示上次加载的内容'), findsNothing);
    expect(find.text('已同步 测试达人 的网易云音乐个人歌单'), findsNothing);
    expect(find.text('午夜电台'), findsOneWidget);
  });

  testWidgets(
    'a signed-out page shows login guidance and no account collections',
    (tester) async {
      await useTallWindow(tester);
      final repo = _ScriptedAuthRepo()..failPlaylists = true;
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);

      await pumpLibrary(tester, auth);

      expect(find.text('跨设备同步你的收藏与播放记录'), findsOneWidget);
      expect(find.text('本机收藏'), findsNothing);
      expect(find.text('我创建的歌单'), findsOneWidget);
      await tester.tap(find.text('我收藏的专辑'));
      await tester.pumpAndSettle();
      expect(find.text('登录后查看你收藏的专辑'), findsOneWidget);
      expect(find.text('点击登录'), findsOneWidget);
      expect(find.textContaining('的网易云音乐个人歌单'), findsNothing);
      expect(
        repo.playlistRequests,
        0,
        reason: 'a page with no account has nothing to sync',
      );
    },
  );
}

const _feed = HomeFeed(
  greeting: '晚上好',
  playlists: [
    PlaylistSummary(
      id: PlaylistId('local-1'),
      title: '本机收藏',
      subtitle: '本机',
      trackCount: 3,
    ),
  ],
);

const _lateNight = PlaylistSummary(
  id: PlaylistId('ncm-playlist-late'),
  title: '深夜精选',
  subtitle: '网易云音乐',
  trackCount: 12,
);

const _morningWalk = PlaylistSummary(
  id: PlaylistId('ncm-playlist-morning'),
  title: '清晨散步',
  subtitle: '网易云音乐',
  trackCount: 8,
);

const _midnightRadio = PlaylistSummary(
  id: PlaylistId('ncm-playlist-radio'),
  title: '午夜电台',
  subtitle: '网易云音乐',
  trackCount: 20,
);

/// An account whose answers the test scripts: signed in on demand, with the
/// personal-playlist fetch able to fail, to come back partial, or to send more
/// lists than before.
final class _ScriptedAuthRepo implements AuthRepository {
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

  _ScriptedAuthRepo({this.playlists = const []});

  final StreamController<AuthSession?> _sessions =
      StreamController<AuthSession?>.broadcast();

  AuthSession? _current;
  List<PlaylistSummary> playlists;
  bool partial = false;
  bool failPlaylists = false;
  int playlistRequests = 0;

  @override
  Stream<AuthSession?> get sessionChanges => _sessions.stream;

  @override
  AuthSession? get currentSession => _current;

  /// Announces a completed login the way the real repository does: through the
  /// session stream, not a callback.
  Future<void> signIn() async {
    _current = const AuthSession(
      user: UserProfile(userId: UserId('ncm-user-1'), nickname: '测试达人'),
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
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async {
    playlistRequests++;
    if (failPlaylists) {
      throw const AppError(
        category: AppErrorCategory.network,
        code: 'network.unreachable',
        retryable: true,
      );
    }
    return UserPlaylists(playlists, isPartial: partial);
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _sessions.add(null);
  }

  void dispose() => unawaited(_sessions.close());
}
