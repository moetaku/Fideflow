import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';
import '../../../tooling/test_localization.dart';

void main() {
  testWidgets(
    'subscribing to another liked playlist refreshes collected library',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = TestAuth();
      final auth = AuthController(repo);
      final other = playlist(
        creator: const UserId('77'),
        special: 5,
        name: '他人喜欢的音乐',
      );
      final catalog = TestCatalog()..detail = other;
      final remote = TestMusic(catalog);
      final music = AccountMusicController(
        repository: remote,
        catalog: catalog,
        auth: auth,
      );
      repo.playlists = () => [
        playlist(
          id: const PlaylistId('ncm-playlist-42'),
          special: 5,
          name: '我的喜欢',
        ).summary,
        if (remote.writes > 0) other.summary,
      ];
      addTearDown(() {
        music.dispose();
        auth.dispose();
        repo.events.close();
      });
      await tester.runAsync(() async {
        repo.login();
        await flush();
      });
      var revision = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: StreamBuilder<void>(
              stream: music.changes,
              builder: (_, _) => MusicManagementScope(
                controller: music,
                revision: ++revision,
                child: LibraryPage(
                  feed: const HomeFeed(greeting: '', playlists: []),
                  authController: auth,
                  onOpenPlaylist: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('我收藏的歌单'));
      await tester.pumpAndSettle();
      expect(find.text('他人喜欢的音乐'), findsNothing);
      final result = await tester.runAsync(
        () => music.subscribe(other.summary.id, true),
      );
      expect(result!.success, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('他人喜欢的音乐'), findsOneWidget);
      expect(localizedTestValue(auth.current.likedPlaylist?.title), '我的喜欢');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'tabs isolate account collections, navigate and reset on logout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(540, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = TestAuth();
      final auth = AuthController(repo);
      final catalog = TestCatalog();
      final musicRepo = TestMusic(catalog)
        ..albums = {const AlbumId('ncm-album-12345')};
      repo.playlists = () => [
        playlist(
          name: '自建',
          privacy: 10,
          playCount: 88,
          subtitle: '创建者: 萌宅',
        ).summary,
        playlist(
          id: const PlaylistId('ncm-playlist-9002'),
          name: '收藏',
          creator: const UserId('77'),
          playCount: 15000,
          subtitle: '创建者: 外部达人',
        ).summary,
        playlist(
          id: const PlaylistId('ncm-playlist-9003'),
          name: '未知',
          creator: null,
        ).summary,
        playlist(
          id: const PlaylistId('ncm-playlist-9005'),
          name: '他人喜欢的音乐',
          creator: const UserId('77'),
          special: 5,
        ).summary,
        playlist(
          id: const PlaylistId('ncm-playlist-9004'),
          name: '喜欢',
          creator: null,
          special: 5,
        ).summary,
      ];
      final music = AccountMusicController(
        repository: musicRepo,
        catalog: catalog,
        auth: auth,
      );
      addTearDown(() {
        music.dispose();
        auth.dispose();
        repo.events.close();
      });
      PlaylistSummary? openedPlaylist;
      AlbumSummary? openedAlbum;
      repo.login();
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: StreamBuilder<void>(
              stream: music.changes,
              builder: (context, snapshot) => MusicManagementScope(
                controller: music,
                revision: DateTime.now().microsecondsSinceEpoch,
                child: LibraryPage(
                  feed: const HomeFeed(greeting: '', playlists: []),
                  authController: auth,
                  onOpenPlaylist: (p) => openedPlaylist = p,
                  onOpenAlbum: (a) => openedAlbum = a,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自建'), findsOneWidget);
      expect(find.text('喜欢'), findsNothing);
      expect(find.text('我喜欢的音乐'), findsOneWidget);
      expect(find.text('归属待确认'), findsOneWidget);
      expect(find.text('收藏'), findsNothing);
      expect(find.text('他人喜欢的音乐'), findsNothing);
      expect(find.text('创建歌单'), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      expect(find.text('88'), findsOneWidget);
      expect(find.text('创建者: 萌宅'), findsNothing);
      expect(find.text('萌宅'), findsNothing);
      await tester.tap(find.text('创建歌单'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自建'));
      expect(localizedTestValue(openedPlaylist?.title), '自建');
      await tester.tap(find.text('我收藏的歌单'));
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('他人喜欢的音乐'), findsOneWidget);
      await tester.tap(find.text('他人喜欢的音乐'));
      expect(localizedTestValue(openedPlaylist?.title), '他人喜欢的音乐');
      expect(find.text('自建'), findsNothing);
      expect(find.text('创建歌单'), findsNothing);
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      expect(find.text('1.5万'), findsOneWidget);
      expect(find.text('外部达人'), findsOneWidget);
      expect(find.text('创建者: 外部达人'), findsNothing);
      await tester.tap(find.text('我收藏的专辑'));
      await tester.pumpAndSettle();
      expect(find.text('测试专辑'), findsOneWidget);
      await tester.tap(find.text('测试专辑'));
      expect(openedAlbum?.id, const AlbumId('ncm-album-12345'));
      musicRepo.heldAlbums = () async => throw StateError('offline');
      await music.loadAlbumSubscriptions();
      await tester.pumpAndSettle();
      expect(find.text('专辑收藏更新失败，当前显示上次加载的内容'), findsOneWidget);
      expect(find.text('测试专辑'), findsOneWidget);
      musicRepo.heldAlbums = null;
      musicRepo.albums.clear();
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(find.text('还没有收藏的专辑'), findsOneWidget);
      repo.playlists = () => [
        for (var i = 0; i < 30; i++)
          playlist(
            id: PlaylistId('ncm-playlist-${10000 + i}'),
            name: '自建$i',
          ).summary,
      ];
      await auth.loadUserPlaylists();
      await tester.tap(find.text('我创建的歌单'));
      await tester.pumpAndSettle();
      final list = find.byType(ListView).hitTestable();
      await tester.drag(list, const Offset(0, -400));
      await tester.pumpAndSettle();
      final offset = tester.widget<ListView>(list).controller!.offset;
      expect(offset, greaterThan(0));
      await tester.tap(find.text('我收藏的歌单'));
      await tester.pumpAndSettle();
      expect(find.text('还没有收藏的歌单'), findsOneWidget);
      await tester.tap(find.text('我创建的歌单'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListView>(find.byType(ListView).hitTestable())
            .controller!
            .offset,
        closeTo(offset, 1),
      );
      repo.login(id: '43', epoch: 2);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListView>(find.byType(ListView).hitTestable())
            .controller!
            .offset,
        0,
      );
      expect(find.text('还没有创建的歌单'), findsOneWidget);
      await auth.signOut();
      await tester.pumpAndSettle();
      expect(find.text('登录后查看你创建的歌单'), findsOneWidget);
      expect(find.text('测试专辑'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
