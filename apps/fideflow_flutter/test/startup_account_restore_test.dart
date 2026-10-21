import 'dart:async';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/recommend_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _StartupStorage implements SecureCredentialStorage {
  final values = InMemoryCredentialStorage();
  String? failWrite;
  @override
  Future<String?> read(String key) => values.read(key);
  @override
  Future<void> write(String key, String value) {
    if (key == failWrite) {
      return Future.error(StateError('Storage unavailable'));
    }
    return values.write(key, value);
  }

  @override
  Future<void> delete(String key) => values.delete(key);
}

final class _StartupClient implements RemoteAuthClient {
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

  final verified = Completer<UserProfile>();
  @override
  Future<UserProfile> getUserAccount({String? cookie}) => verified.future;
  @override
  void setCookie(String? cookie) {}
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(
    UserId id, {
    String? cookie,
    int limit = 30,
    int offset = 0,
  }) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CountingSquare implements PlaylistSquareRepository {
  final delegate = FakeCatalogRepository(latency: Duration.zero);
  int categories = 0;
  int tags = 0;
  int playlists = 0;
  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    categories++;
    return delegate.getCategoryTree(policy: policy);
  }

  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    tags++;
    return delegate.getHotTags(policy: policy);
  }

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    playlists++;
    return delegate.getSquarePlaylists(
      cat: cat,
      order: order,
      limit: limit,
      offset: offset,
      policy: policy,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('saved account opens recommendations after transition finishes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _StartupStorage();
    await storage.write('session_token', 'synthetic-token');
    final client = _StartupClient();
    final repo = CredentialCoordinator(storage: storage, authClient: client);
    final auth = AuthController(repo);
    addTearDown(auth.dispose);
    addTearDown(repo.dispose);
    final restoring = auth.restoreSession();
    // Authentication timing is controlled by verified; catalog timing is irrelevant to this transition.
    final square = _CountingSquare();
    final deps = AppDependencies.forTesting(
      playlistSquareRepository: square,
      authController: auth,
      homeController: BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      ),
    );
    await tester.pumpWidget(FideflowApp(dependencies: deps));
    await tester.pump();
    expect([square.categories, square.tags, square.playlists], [0, 0, 0]);
    client.verified.complete(
      const UserProfile(userId: UserId('ncm-user-1'), nickname: '中文昵称'),
    );
    await tester.pumpAndSettle();
    await restoring;

    expect([square.categories, square.tags, square.playlists], [1, 1, 1]);
    expect(auth.current.isAuthenticated, isTrue);
    expect(find.byType(RecommendPage), findsOneWidget);
    expect(find.text('登录恢复失败'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fails in [false, true]) {
    testWidgets('square loads once after restore failure=$fails', (
      tester,
    ) async {
      final storage = _StartupStorage();
      await storage.write('session_token', 'synthetic-token');
      final client = _StartupClient();
      final repo = CredentialCoordinator(storage: storage, authClient: client);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);
      final restoring = auth.restoreSession();
      final square = _CountingSquare();
      final deps = AppDependencies.forTesting(
        authController: auth,
        playlistSquareRepository: square,
        homeController: BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          FakeMediaController(),
        ),
      );
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pump();
      expect([square.categories, square.tags, square.playlists], [0, 0, 0]);
      if (fails) {
        client.verified.completeError(StateError('Restore failed'));
      } else {
        // A rejected saved credential settles as a guest session.
        client.verified.completeError(
          const AppError(
            category: AppErrorCategory.authentication,
            code: 'auth.unauthenticated',
            retryable: false,
          ),
        );
      }
      await tester.pumpAndSettle();
      await restoring;
      expect([square.categories, square.tags, square.playlists], [1, 1, 1]);
      expect(
        auth.current.status,
        fails ? AuthStatus.restoreError : AuthStatus.unauthenticated,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'failed startup persistence retains recovery state and can retry',
    (tester) async {
      final storage = _StartupStorage()..failWrite = 'accounts_v1';
      await storage.write('session_token', 'synthetic-token');
      final client = _StartupClient();
      client.verified.complete(
        const UserProfile(userId: UserId('ncm-user-1'), nickname: '中文昵称'),
      );
      final repo = CredentialCoordinator(storage: storage, authClient: client);
      final auth = AuthController(repo);
      addTearDown(auth.dispose);
      addTearDown(repo.dispose);
      await auth.restoreSession();
      await tester.pump();

      expect(auth.current.status, AuthStatus.restoreError);
      expect(auth.current.errorCode, 'auth.restoreFailed');
      expect(await storage.read('session_token'), 'synthetic-token');
      expect(repo.currentSession, isNull);
      storage.failWrite = null;
      await auth.restoreSession();
      await tester.pump();

      expect(auth.current.isAuthenticated, isTrue);
      expect(auth.current.errorCode, isNull);
    },
  );

  testWidgets('guest checkpoint failure preserves recovery state', (
    tester,
  ) async {
    final storage = _StartupStorage();
    await storage.write(
      'accounts_v1',
      '{"version":1,"active":null,"accounts":[]}',
    );
    var failRestore = true;
    final repo = CredentialCoordinator(
      storage: storage,
      authClient: _StartupClient(),
      restorePlayback: (_) async {
        if (failRestore) throw StateError('Checkpoint unavailable');
      },
    );
    final auth = AuthController(repo);
    addTearDown(auth.dispose);
    addTearDown(repo.dispose);
    await auth.restoreSession();
    await tester.pump();

    expect(auth.current.status, AuthStatus.restoreError);
    failRestore = false;
    await auth.restoreSession();
    await tester.pump();
    expect(auth.current.status, AuthStatus.unauthenticated);
    expect(auth.current.errorCode, isNull);
  });
}
