import 'dart:async';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/daily_songs_page.dart';
import 'package:fideflow/features/discovery/playlist_square_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';
import 'support/test_viewport.dart';

void main() {
  testWidgets(
    'logout reloads the square after an old Host request is cancelled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final authRepo = _ManagedAuthRepo()..session = session('A', 1);
      final auth = AuthController(authRepo);
      addTearDown(auth.dispose);
      addTearDown(authRepo.close);
      await auth.restoreSession();
      final square = _SquareRepo();
      authRepo.beforeSignOut = () => square.first.completeError(
        const AppError(
          category: AppErrorCategory.authentication,
          code: 'auth.epochMismatch',
          retryable: false,
        ),
      );
      final deps = AppDependencies.forTesting(
        authController: auth,
        playlistSquareRepository: square,
      );
      await tester.pumpWidget(FideflowApp(dependencies: deps));
      await tester.pumpAndSettle();
      expect(square.calls, 1);
      final logout = auth.signOut();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        square.calls,
        1,
        reason: 'wait until the credential transition settles',
      );
      authRepo.finish.complete();
      await logout;
      await tester.pumpAndSettle();
      final page = tester.widget<PlaylistSquarePage>(
        find.byType(PlaylistSquarePage),
      );
      expect(page.controller.state.status, LoadStatus.ready);
      expect(page.controller.state.error, isNull);
      expect(page.controller.state.playlists.single.title, '游客精选');
      expect(square.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [390.0, 1280.0]) {
    for (final transition in [
      'switch account',
      'new epoch',
      'logout and login',
    ]) {
      testWidgets(
        'daily songs reload after $transition on the same date at $width',
        (tester) async {
          await setTestViewport(tester, Size(width, 1400));
          addTearDown(() => setTestViewport(tester, null));
          final authRepo = _AuthRepo()..session = session('A', 1);
          final auth = AuthController(authRepo);
          addTearDown(auth.dispose);
          addTearDown(authRepo.close);
          await auth.restoreSession();
          final recommend = _RecommendRepo(() => authRepo.session);
          final deps = AppDependencies.forTesting(
            authController: auth,
            recommendRepository: recommend,
          );
          await tester.pumpWidget(FideflowApp(dependencies: deps));
          await tester.pumpAndSettle();
          await tester.tap(find.text('每日推荐'));
          await tester.pumpAndSettle();
          final oldController = tester
              .widget<DailySongsPage>(find.byType(DailySongsPage))
              .controller;
          final date = oldController.dateKey;
          expect(find.text('A-1 的推荐'), findsOneWidget);

          // Ordinary auth updates for the same owner must preserve the page.
          authRepo.publish(session('A', 1));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<DailySongsPage>(find.byType(DailySongsPage))
                .controller,
            same(oldController),
          );

          if (transition == 'logout and login') {
            await auth.signOut();
            await tester.pumpAndSettle();
            expect(find.byType(DailySongsPage), findsNothing);
          }
          final nextId = transition == 'new epoch' ? 'A' : 'B';
          authRepo.publish(session(nextId, 2));
          await tester.pumpAndSettle();
          // A different owner leaves the old private route. Reopen it under the
          // newly selected account instead of carrying its history across.
          expect(find.byType(DailySongsPage), findsNothing);
          await tester.tap(find.text('推荐').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('每日推荐'));
          await tester.pumpAndSettle();
          final newController = tester
              .widget<DailySongsPage>(find.byType(DailySongsPage))
              .controller;
          expect(newController, isNot(same(oldController)));
          expect(newController.dateKey, date);
          expect(find.text(zh('$nextId-2 的推荐')), findsOneWidget);
          expect(find.text('A-1 的推荐'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}

AuthSession session(String id, int epoch) => AuthSession(
  user: UserProfile(userId: UserId(id), nickname: id),
  authEpoch: epoch,
);

class _AuthRepo implements AuthRepository {
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

  AuthSession? session;
  final changes = StreamController<AuthSession?>.broadcast();
  void publish(AuthSession? next) {
    session = next;
    changes.add(next);
  }

  Future<void> close() => changes.close();
  @override
  AuthSession? get currentSession => session;
  @override
  Stream<AuthSession?> get sessionChanges => changes.stream;
  @override
  Future<AuthSession?> restoreSession() async => session;
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async => [];
  void Function()? beforeSignOut;
  @override
  Future<void> signOut() async {
    beforeSignOut?.call();
    publish(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecommendRepo implements RecommendRepository {
  _RecommendRepo(this.currentSession);
  final AuthSession? Function() currentSession;
  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final owner = currentSession();
    final now = DateTime.now();
    return DailySongsRead(
      snapshot: DailySongsSnapshot(
        namespace: 'ncm',
        accountId: owner?.user.userId.value ?? 'guest',
        dateKey: dateKey!,
        songs: [
          DailySongEntry(
            ordinal: 0,
            track: Track(
              id: const TrackId('ncm-1234'),
              title: '${owner?.user.nickname}-${owner?.authEpoch} 的推荐',
              artists: const [],
              album: const Album(id: AlbumId('album'), title: '专辑'),
              duration: const Duration(minutes: 3),
            ),
          ),
        ],
        fetchedAt: now,
        staleUntil: now.add(const Duration(hours: 6)),
        retainUntil: now.add(const Duration(days: 7)),
      ),
      source: DailySongsSource.network,
      refreshedAt: now,
    );
  }

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const RecommendedPlaylists();
  @override
  Future<List<Track>> getNewSongs({
    int limit = 12,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => [];
  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const ListenResources();
}

class _SquareRepo implements PlaylistSquareRepository {
  final first = Completer<SearchResult<PlaylistSummary>>();
  int calls = 0;
  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const PlaylistCategoryTree();
  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => [];
  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => null;
  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (++calls == 1) return first.future;
    return const SearchResult(
      items: [
        PlaylistSummary(
          id: PlaylistId('guest'),
          title: '游客精选',
          subtitle: '',
          trackCount: 0,
        ),
      ],
      hasMore: false,
    );
  }
}

class _ManagedAuthRepo extends _AuthRepo implements MultiAccountRepository {
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

  final transitions = StreamController<bool>.broadcast();
  final finish = Completer<void>();
  @override
  List<SavedAccount> get accounts => [];
  @override
  Stream<List<SavedAccount>> get accountChanges => const Stream.empty();
  @override
  Stream<bool> get transitionChanges => transitions.stream;
  @override
  void cancelPendingLogin() {}
  @override
  Future<void> signOut() async {
    transitions.add(true);
    beforeSignOut?.call();
    publish(null);
    await finish.future;
    transitions.add(false);
  }

  @override
  Future<void> close() async {
    await super.close();
    await transitions.close();
  }
}
