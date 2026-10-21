import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/features/discovery/recent_playback_page.dart';
import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';
import '../../../tooling/test_localization.dart';

void main() {
  late BrowseAndPlayController player;
  late TestAuth repo;
  late AuthController auth;
  late AccountMusicController music;
  late TestMusic remote;
  setUp(() async {
    player = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      FakeMediaController(),
    );
    await player.initialize();
    repo = TestAuth();
    auth = AuthController(repo);
    final catalog = TestCatalog();
    remote = TestMusic(catalog);
    music = AccountMusicController(
      repository: remote,
      catalog: catalog,
      auth: auth,
    );
    await player.recentPlayback.record([
      RecentPlaybackEntry.song(track(track1), DateTime(2026, 10, 7, 10)),
      RecentPlaybackEntry.song(track(track2), DateTime(2026, 10, 7, 9)),
      RecentPlaybackEntry.fromPlaylist(
        playlist(creator: const UserId('other')).summary,
        DateTime(2026, 10, 7),
      ),
      RecentPlaybackEntry.fromAlbum(
        const AlbumSummary(
          id: AlbumId('ncm-album-1'),
          title: '历史专辑',
          artistName: 'Artist',
          trackCount: 1,
        ),
        DateTime(2026, 10, 7),
      ),
    ]);
  });
  tearDown(() async {
    await player.dispose();
    music.dispose();
    auth.dispose();
    await repo.events.close();
  });
  Future<void> mount(
    WidgetTester tester, {
    ValueChanged<PlaylistSummary>? openPlaylist,
    ValueChanged<AlbumSummary>? openAlbum,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    var revision = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StreamBuilder<void>(
          stream: music.changes,
          builder: (_, _) => MusicManagementScope(
            controller: music,
            revision: ++revision,
            child: Scaffold(
              body: RecentPlaybackPage(
                controller: player,
                clock: () => DateTime(2026, 10, 7, 12),
                playback: player.current.playback,
                onOpenPlaylist: openPlaylist ?? (_) {},
                onOpenAlbum: openAlbum,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'playback time uses local calendar day and date across year boundaries',
    () {
      final today = DateTime(2026, 10, 7, 12);
      expect(
        formatRecentPlaybackTime(DateTime(2026, 10, 7, 9, 5), now: today),
        '09:05',
      );
      expect(
        formatRecentPlaybackTime(DateTime(2026, 10, 6, 23, 59), now: today),
        '2026-10-06',
      );
      expect(
        formatRecentPlaybackTime(
          DateTime(2025, 12, 31, 23, 59),
          now: DateTime(2026, 1, 1),
        ),
        '2025-12-31',
      );
      expect(
        formatRecentPlaybackTime(
          DateTime(2026, 10, 7, 9, 5).toUtc(),
          now: today,
        ),
        '09:05',
      );
    },
  );
  testWidgets(
    'another account liked playlist can be collected without claiming ownership',
    (tester) async {
      final other = playlist(
        creator: const UserId('other'),
        special: 5,
        name: '其他账号喜欢的音乐',
      );
      (music.catalog as TestCatalog).detail = other;
      await player.recentPlayback.record([
        RecentPlaybackEntry.fromPlaylist(other.summary, DateTime.now()),
      ]);
      await tester.runAsync(() async {
        repo.login();
        await flush();
      });
      await mount(tester);
      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收藏'));
      await tester.pumpAndSettle();
      expect(remote.writes, 1);
      expect(find.text('此歌单已在你的音乐库中'), findsNothing);
      expect(find.text('操作成功'), findsOneWidget);
    },
  );
  testWidgets(
    'recent songs replace duration with time and collections show counts',
    (tester) async {
      await player.recentPlayback.record([
        RecentPlaybackEntry.song(track(track2), DateTime(2026, 10, 6, 9)),
        RecentPlaybackEntry.fromAlbum(
          const AlbumSummary(
            id: AlbumId('ncm-album-1'),
            title: '历史专辑',
            artistName: 'Artist',
            trackCount: 12,
          ),
          DateTime(2026, 10, 6, 20),
        ),
      ]);
      await mount(tester);
      expect(find.text('播放时间'), findsOneWidget);
      expect(find.text('时长'), findsNothing);
      expect(find.text('03:00'), findsNothing);
      expect(find.text('10:00'), findsOneWidget);
      expect(find.text('2026-10-06'), findsOneWidget);
      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();
      expect(find.text('歌曲数'), findsOneWidget);
      expect(find.text('1首'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      await tester.tap(find.text('专辑'));
      await tester.pumpAndSettle();
      expect(find.text('歌曲数'), findsOneWidget);
      expect(find.text('12首'), findsOneWidget);
      expect(find.text('2026-10-06'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('guest has unliked rows and collecting asks for login', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('喜欢'), findsOneWidget);
    expect(find.byTooltip('喜欢'), findsNWidgets(2));
    await tester.tap(find.text('收藏全部'));
    await tester.pumpAndSettle();
    expect(find.text('登录网易云音乐'), findsWidgets);
    expect(remote.writes, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
  testWidgets(
    'collection login prompts and album subscription use current account',
    (tester) async {
      await mount(tester);
      for (final category in ['歌单', '专辑']) {
        await tester.tap(find.text(zh(category)));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('收藏'));
        await tester.pumpAndSettle();
        expect(find.text('登录网易云音乐'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      expect(remote.writes, 0);
      await tester.runAsync(() async {
        repo.login();
        await flush();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收藏'));
      await tester.pumpAndSettle();
      expect(music.isAlbumSubscribed(const AlbumId('ncm-album-1')), isTrue);
      expect(find.byTooltip('取消收藏'), findsOneWidget);
      await tester.tap(find.byTooltip('取消收藏'));
      await tester.pumpAndSettle();
      expect(music.isAlbumSubscribed(const AlbumId('ncm-album-1')), isFalse);
      expect(remote.writes, 2);
    },
  );
  testWidgets('logged in likes update and sign-out removes liked state', (
    tester,
  ) async {
    remote.liked.add(track1);
    await tester.runAsync(() async {
      repo.login();
      await flush();
    });
    await mount(tester);
    expect(find.byTooltip('取消喜欢'), findsOneWidget);
    await tester.tap(find.byTooltip('取消喜欢'));
    await tester.pumpAndSettle();
    expect(music.favorite(track1), FavoriteState.unliked);
    expect(remote.writes, 1);
    await music.setLiked(track1, true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消喜欢'), findsOneWidget);
    await tester.runAsync(() async {
      await auth.signOut();
      await flush();
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消喜欢'), findsNothing);
    expect(find.byTooltip('喜欢'), findsNWidgets(2));
  });
  testWidgets(
    'batch select enqueue delete and clear work as a local playlist',
    (tester) async {
      await mount(tester);
      expect(find.text('添加到播放列表'), findsNothing);
      await tester.tap(find.text('播放全部'));
      await tester.pumpAndSettle();
      expect(player.current.playback.queue, hasLength(2));
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('添加到播放列表'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 首'), findsOneWidget);
      await tester.tap(find.text('添加到播放列表'));
      await tester.pumpAndSettle();
      expect(player.current.playback.queue, hasLength(3));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(TrackRow), findsOneWidget);
      expect(player.current.playback.queue, hasLength(3));
      await tester.tap(find.text('清空列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(find.text('暂无播放记录'), findsOneWidget);
    },
  );
  testWidgets('collection categories navigate and deletion stays local', (
    tester,
  ) async {
    PlaylistSummary? openedPlaylist;
    AlbumSummary? openedAlbum;
    await mount(
      tester,
      openPlaylist: (p) => openedPlaylist = p,
      openAlbum: (a) => openedAlbum = a,
    );
    await tester.tap(find.text('歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试歌单'));
    await tester.pumpAndSettle();
    expect(openedPlaylist?.id, playlistId);
    await tester.tap(find.byTooltip('删除播放记录'));
    await tester.pumpAndSettle();
    expect(find.text('暂无播放记录'), findsOneWidget);
    expect(remote.writes, 0);
    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史专辑'));
    await tester.pumpAndSettle();
    expect(openedAlbum?.id, const AlbumId('ncm-album-1'));
  });
  testWidgets(
    'selected tab and scroll offset survive navigating away and returning',
    (tester) async {
      final manyPlaylists = List.generate(
        40,
        (i) => RecentPlaybackEntry.fromPlaylist(
          PlaylistSummary(
            id: PlaylistId('pl-$i'),
            title: '歌单 $i',
            subtitle: 'Creator',
            creatorNickname: 'Creator',
            trackCount: 10,
          ),
          DateTime(2026, 10, 7, 10),
        ),
      );
      await player.recentPlayback.record(manyPlaylists);

      var showRecent = true;
      await tester.binding.setSurfaceSize(const Size(1280, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                if (showRecent) {
                  return RecentPlaybackPage(
                    controller: player,
                    clock: () => DateTime(2026, 10, 7, 12),
                    playback: player.current.playback,
                    onOpenPlaylist: (_) => setState(() => showRecent = false),
                    onOpenAlbum: (_) => setState(() => showRecent = false),
                  );
                }
                return Column(
                  children: [
                    const Text('详情页面'),
                    ElevatedButton(
                      onPressed: () => setState(() => showRecent = true),
                      child: const Text('返回上一页'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();
      expect(find.text('歌单 0'), findsOneWidget);

      final scrollable = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      );
      await tester.scrollUntilVisible(
        find.text('歌单 25'),
        300,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('歌单 25'), findsOneWidget);

      await tester.tap(find.text('歌单 25'));
      await tester.pumpAndSettle();
      expect(find.text('详情页面'), findsOneWidget);
      expect(find.byType(RecentPlaybackPage), findsNothing);

      await tester.tap(find.text('返回上一页'));
      await tester.pumpAndSettle();

      expect(find.byType(RecentPlaybackPage), findsOneWidget);
      expect(find.text('歌单 25'), findsOneWidget);

      final scrollableAfterReturn = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      );
      await tester.scrollUntilVisible(
        find.text('最近播放'),
        -300,
        scrollable: scrollableAfterReturn,
      );
      await tester.pumpAndSettle();
      expect(find.text('最近播放'), findsOneWidget);
      expect(find.text('歌单'), findsOneWidget);
    },
  );
}
