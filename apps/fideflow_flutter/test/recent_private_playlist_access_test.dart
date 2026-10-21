import 'dart:async';

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/catalog/playlist_detail_page.dart';
import 'package:fideflow/features/discovery/favorite_music_page.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const privateSummary = PlaylistSummary(
  id: PlaylistId('ncm-playlist-123'),
  title: '历史隐私歌单',
  subtitle: 'Owner',
  trackCount: 1,
  creatorId: UserId('ncm-user-1'),
  privacy: 10,
);

void main() {
  for (final logout in [false, true]) {
    testWidgets(
      'settings stays open after leaving private playlist logout=$logout',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repo = _AuthRepo();
        final auth = AuthController(repo);
        await auth.restoreSession();
        addTearDown(auth.dispose);
        addTearDown(repo.events.close);
        final player = BrowseAndPlayController(
          _Catalog(),
          FakeMediaController(),
        );
        await player.recentPlayback.record([
          RecentPlaybackEntry.fromPlaylist(privateSummary, DateTime.now()),
        ]);
        await tester.pumpWidget(
          FideflowApp(
            dependencies: AppDependencies.forTesting(
              homeController: player,
              authController: auth,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.library_music_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text('最近播放').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('歌单'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('历史隐私歌单'));
        await tester.pumpAndSettle();
        expect(find.text('隐私曲目'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);

        if (logout) {
          await auth.signOut();
        } else {
          repo.publish(const UserId('ncm-user-2'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.byType(PlaylistDetailPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
  testWidgets(
    'another account liked playlist opens the ordinary detail layout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const other = PlaylistSummary(
        id: PlaylistId('ncm-playlist-123'),
        title: '他人喜欢的音乐',
        subtitle: 'Other',
        trackCount: 1,
        creatorId: UserId('77'),
        specialType: 5,
        privacy: 0,
      );
      const own = PlaylistSummary(
        id: PlaylistId('ncm-playlist-1'),
        title: '我的喜欢',
        subtitle: 'Owner',
        trackCount: 1,
        creatorId: UserId('ncm-user-1'),
        specialType: 5,
        privacy: 0,
      );
      final repo = _AuthRepo()..playlists = [other, own];
      final auth = AuthController(repo);
      await auth.restoreSession();
      addTearDown(auth.dispose);
      addTearDown(repo.events.close);
      final player = BrowseAndPlayController(
        _Catalog(detailSummary: other),
        FakeMediaController(),
      );
      await tester.pumpWidget(
        FideflowApp(
          dependencies: AppDependencies.forTesting(
            homeController: player,
            authController: auth,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的音乐').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('我收藏的歌单'));
      await tester.pumpAndSettle();
      expect(find.text('他人喜欢的音乐'), findsOneWidget);
      await tester.tap(find.text('他人喜欢的音乐'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistDetailPage), findsOneWidget);
      expect(find.byType(FavoriteMusicPage), findsNothing);
      expect(
        tester
            .widget<PlaylistDetailPage>(find.byType(PlaylistDetailPage))
            .isFavoriteRole,
        isFalse,
      );
      expect(find.text('歌单'), findsOneWidget);
      expect(auth.current.likedPlaylist?.id, own.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
  for (final logout in [false, true]) {
    testWidgets(
      'private row refreshes locally while staying in history logout=$logout',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repo = _AuthRepo()..playlists = [privateSummary];
        final auth = AuthController(repo);
        await auth.restoreSession();
        addTearDown(auth.dispose);
        addTearDown(repo.events.close);
        final catalog = _Catalog();
        final player = BrowseAndPlayController(catalog, FakeMediaController());
        await player.recentPlayback.record([
          RecentPlaybackEntry.fromPlaylist(
            const PlaylistSummary(
              id: PlaylistId('ncm-playlist-123'),
              title: '历史隐私歌单',
              subtitle: 'Owner',
              trackCount: 1,
              creatorId: UserId('ncm-user-1'),
            ),
            DateTime.now(),
          ),
        ]);
        await tester.pumpWidget(
          FideflowApp(
            dependencies: AppDependencies.forTesting(
              homeController: player,
              authController: auth,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.library_music_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text('最近播放').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('歌单'));
        await tester.pumpAndSettle();
        expect(find.text('无权访问'), findsNothing);
        expect(catalog.privateDetailRequests, 0);
        expect(catalog.privateAccessRequests, 0);
        if (logout) {
          await auth.signOut();
        } else {
          repo.publish(const UserId('ncm-user-2'));
        }
        await tester.pumpAndSettle();
        expect(find.text('无权访问'), findsOneWidget);
        final collect = find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == '无权访问，无法收藏',
        );
        expect(tester.widget<IconButton>(collect).onPressed, isNull);
        expect(find.byType(PlaylistDetailPage), findsNothing);
        expect(catalog.privateDetailRequests, 0);
        expect(catalog.privateAccessRequests, 0);
        repo.publish(const UserId('ncm-user-1'));
        await tester.pumpAndSettle();
        expect(find.text('无权访问'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '收藏',
                ),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
  for (final logout in [false, true]) {
    for (final legacy in [false, true]) {
      testWidgets(
        'private history denies access after logout=$logout legacy=$legacy',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1280, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final repo = _AuthRepo();
          final auth = AuthController(repo);
          await auth.restoreSession();
          final catalog = _Catalog();
          final player = BrowseAndPlayController(
            catalog,
            FakeMediaController(),
          );
          addTearDown(auth.dispose);
          addTearDown(repo.events.close);
          final historySummary = legacy
              ? const PlaylistSummary(
                  id: PlaylistId('ncm-playlist-123'),
                  title: '历史隐私歌单',
                  subtitle: 'Owner',
                  trackCount: 1,
                  creatorId: UserId('ncm-user-1'),
                )
              : privateSummary;
          await player.recentPlayback.record([
            RecentPlaybackEntry.fromPlaylist(historySummary, DateTime.now()),
          ]);
          await tester.pumpWidget(
            FideflowApp(
              dependencies: AppDependencies.forTesting(
                homeController: player,
                authController: auth,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.library_music_outlined));
          await tester.pumpAndSettle();
          await tester.tap(find.text('最近播放').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('歌单'));
          await tester.pumpAndSettle();
          expect(find.text('无权访问'), findsNothing);
          await tester.tap(find.text('历史隐私歌单'));
          await tester.pumpAndSettle();
          expect(find.text('隐私曲目'), findsOneWidget);

          if (logout) {
            await auth.signOut();
          } else {
            repo.publish(const UserId('ncm-user-2'));
          }
          await tester.pumpAndSettle();
          expect(find.text('隐私曲目'), findsNothing);
          if (!legacy) expect(find.byType(PlaylistDetailPage), findsNothing);
          await tester.tap(find.byIcon(Icons.library_music_outlined));
          await tester.pumpAndSettle();
          await tester.tap(find.text('最近播放').first);
          await tester.pumpAndSettle();
          if (!legacy) {
            expect(find.text('无权访问'), findsOneWidget);
            expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
            final collect = find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '无权访问，无法收藏',
            );
            expect(tester.widget<IconButton>(collect).onPressed, isNull);
            final delete = find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '删除播放记录',
            );
            expect(tester.widget<IconButton>(delete).onPressed, isNotNull);
          }
          await tester.tap(find.text('历史隐私歌单'));
          await tester.pumpAndSettle();
          expect(find.text('私密歌单或无权访问'), findsOneWidget);
          expect(find.text('隐私曲目'), findsNothing);
          final denied = tester
              .widget<PlaylistDetailPage>(find.byType(PlaylistDetailPage))
              .detailController!;
          expect(denied.state.detail, isNull);
          expect(await denied.playAll(), isNull);
          await tester.tap(find.byIcon(Icons.library_music_outlined));
          await tester.pumpAndSettle();
          await tester.tap(find.text('最近播放').first);
          await tester.pumpAndSettle();
          if (!legacy) {
            expect(find.text('无权访问'), findsOneWidget);
            final disabledCollect = find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '无权访问，无法收藏',
            );
            expect(
              tester.widget<IconButton>(disabledCollect).onPressed,
              isNull,
            );
          } else {
            expect(find.text('正在确认权限'), findsNothing);
            expect(find.text('权限待确认'), findsNothing);
          }

          repo.publish(const UserId('1'));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.library_music_outlined));
          await tester.pumpAndSettle();
          await tester.tap(find.text('最近播放').first);
          await tester.pumpAndSettle();
          expect(find.text('无权访问'), findsNothing);
          await tester.tap(find.text('历史隐私歌单'));
          await tester.pumpAndSettle();
          expect(find.text('隐私曲目'), findsOneWidget);
          expect(find.text('私密歌单或无权访问'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  test('permission exception discards previously loaded tracks', () async {
    final catalog = _Catalog();
    final player = BrowseAndPlayController(catalog, FakeMediaController());
    addTearDown(player.dispose);
    final controller = CatalogDetailController(
      playlistId: privateSummary.id,
      catalog: catalog,
      playbackCoordinator: PlaybackIntentCoordinator(player: player),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.playableTracks, isNotEmpty);
    catalog.deny = true;
    await controller.load();
    expect(controller.state.isAccessDenied, isTrue);
    expect(controller.state.detail, isNull);
    expect(await controller.playAll(), isNull);
    catalog.deny = false;
    await controller.load();
    expect(controller.state.isAccessDenied, isFalse);
    expect(controller.state.playableTracks, isNotEmpty);
  });
}

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

  List<PlaylistSummary> playlists = [];
  AuthSession? session = const AuthSession(
    user: UserProfile(userId: UserId('ncm-user-1'), nickname: 'Owner'),
    authEpoch: 1,
  );
  final events = StreamController<AuthSession?>.broadcast();
  void publish(UserId? id) {
    session = id == null
        ? null
        : AuthSession(
            user: UserProfile(userId: id, nickname: id.value),
            authEpoch: 2,
          );
    events.add(session);
  }

  @override
  AuthSession? get currentSession => session;
  @override
  Stream<AuthSession?> get sessionChanges => events.stream;
  @override
  Future<AuthSession?> restoreSession() async => session;
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId id) async => playlists;
  @override
  Future<void> signOut() async => publish(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Catalog implements CatalogRepository {
  _Catalog({this.detailSummary = privateSummary});
  final PlaylistSummary detailSummary;
  final delegate = FakeCatalogRepository(latency: Duration.zero);
  bool deny = false;
  int privateDetailRequests = 0;
  int privateAccessRequests = 0;
  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => delegate.getHomeFeed(policy: policy);
  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (id != detailSummary.id) {
      return delegate.getPlaylist(id, policy: policy);
    }
    ++privateDetailRequests;
    return PlaylistDetail.fromTracks(
      summary: detailSummary,
      tracks: const [
        Track(
          id: TrackId('ncm-1234'),
          title: '隐私曲目',
          artists: [],
          album: Album(id: AlbumId('a'), title: 'Album'),
          duration: Duration(minutes: 3),
        ),
      ],
    );
  }

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    if (id == privateSummary.id) ++privateAccessRequests;
    if (deny) {
      throw const AppError(
        category: AppErrorCategory.permission,
        code: 'ncm.permissionDenied',
        retryable: false,
      );
    }
    // Simulate a provider returning a successful detail stub for a private ID.
    return delegate.getPlaylistAccess(id, policy: policy);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
