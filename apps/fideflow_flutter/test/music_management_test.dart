import 'dart:async';

import 'package:fideflow/features/catalog/add_to_playlist.dart';
import 'package:fideflow/features/catalog/album_detail_page.dart';
import 'package:fideflow/features/catalog/artist_detail_page.dart';
import 'package:fideflow/features/catalog/music_track_actions.dart';
import 'package:fideflow/features/catalog/playlist_actions.dart';
import 'package:fideflow/features/catalog/playlist_detail_page.dart';
import 'package:fideflow/features/catalog/playlist_editor.dart';
import 'package:fideflow/features/catalog/widgets/sorting_bar.dart';
import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/features/discovery/favorite_music_page.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow/features/discovery/playlist_square_page.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';
import '../../../tooling/test_localization.dart';

void main() {
  late TestAuth repo;
  late AuthController auth;
  late TestCatalog catalog;
  late TestMusic music;
  late AccountMusicController controller;
  setUp(() async {
    repo = TestAuth();
    auth = AuthController(repo);
    catalog = TestCatalog();
    music = TestMusic(catalog);
    repo.playlists = () => [
      if (catalog.detail != null) catalog.detail!.summary,
    ];
    controller = AccountMusicController(
      repository: music,
      catalog: catalog,
      auth: auth,
    );
    repo.login();
    await flush();
  });
  tearDown(() async {
    controller.dispose();
    auth.dispose();
    await repo.events.close();
  });
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool settle = true,
    ThemeData? theme,
  }) async {
    var revision = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: StreamBuilder<void>(
          stream: controller.changes,
          builder: (_, _) => MusicManagementScope(
            controller: controller,
            revision: ++revision,
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('other users liked playlist has ordinary subscription actions', (
    tester,
  ) async {
    final other = playlist(creator: const UserId('43'), special: 5);
    catalog.detail = other;
    await mount(tester, MusicPlaylistActions(detail: other));
    expect(find.byTooltip('收藏'), findsOneWidget);
    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    expect(music.writes, 1);
    expect(find.text('操作成功'), findsOneWidget);
  });

  for (final page in ['artist', 'album', 'playlist', 'favorite']) {
    testWidgets('$page sorting follows the padded list width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      catalog.detail = playlist(special: 5, ids: [track1, track2]);
      repo.login(epoch: 2);
      await tester.pumpAndSettle();
      await auth.loadUserPlaylists();
      final player = BrowseAndPlayController(catalog, FakeMediaController());
      addTearDown(player.dispose);
      final details = _FavoriteDetails();
      final state = HomeState.initial().copyWith(
        selectedPlaylist: catalog.detail,
      );
      final child = switch (page) {
        'artist' => ArtistDetailPage(
          artistId: const ArtistId('ncm-artist-1'),
          detailRepository: details,
          state: state,
          controller: player,
        ),
        'album' => AlbumDetailPage(
          albumId: const AlbumId('ncm-album-1'),
          detailRepository: details,
          state: state,
          controller: player,
        ),
        'playlist' => PlaylistDetailPage(
          playlist: catalog.detail,
          state: state,
          controller: player,
        ),
        _ => FavoriteMusicPage(
          state: state,
          controller: player,
          authController: auth,
        ),
      };
      // Equivalent to the screenshots' content area beside a 232px sidebar,
      // plus both sides of the table and album-column breakpoints.
      for (final width in [
        550.0,
        570.0,
        640.0,
        647.0,
        648.0,
        670.0,
        688.0,
        702.0,
        640.0,
      ]) {
        await mount(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        );
        final listWidth = width - (width < 600 ? 32 : 48);
        final hasHeader = listWidth >= (page == 'album' ? 520 : 640);
        expect(
          find.byType(SortingBar),
          hasHeader ? findsNothing : findsOneWidget,
        );
        final headerTitle = find.descendant(
          of: find.byType(TrackTableHeader),
          matching: find.text('标题'),
        );
        expect(headerTitle, hasHeader ? findsOneWidget : findsNothing);
        final hasAlbum = page != 'album' && listWidth >= 640;
        expect(
          find.descendant(
            of: find.byType(TrackTableHeader),
            matching: find.text('专辑'),
          ),
          hasAlbum ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(of: find.byType(TrackRow), matching: find.text('测试')),
          hasAlbum ? findsNWidgets(2) : findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(TrackRow),
            matching: find.byType(MusicFavoriteButton),
          ),
          hasHeader ? findsNWidgets(2) : findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(TrackRow),
            matching: find.text('3:00'),
          ),
          hasHeader ? findsNWidgets(2) : findsNothing,
        );
        if (hasHeader) {
          await tester.tap(headerTitle);
          await tester.pumpAndSettle();
          final header = tester.widget<TrackTableHeader>(
            find.byType(TrackTableHeader),
          );
          expect(header.sortCriteria, TrackSortCriteria.title);
          // Return to default before the next resize.
          await tester.tap(headerTitle);
          await tester.pumpAndSettle();
          await tester.tap(headerTitle);
          await tester.pumpAndSettle();
        } else {
          final titleSort = find.descendant(
            of: find.byType(SortingBar),
            matching: find.text('歌曲名'),
          );
          await tester.tap(titleSort);
          await tester.pumpAndSettle();
          expect(
            tester.widget<SortingBar>(find.byType(SortingBar)).criteria,
            TrackSortCriteria.title,
          );
          await tester.tap(titleSort);
          await tester.pumpAndSettle();
          await tester.tap(titleSort);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final albumPage in [true, false]) {
    testWidgets(
      '${albumPage ? 'album' : 'artist'} favorite sort updates after likes change',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final player = BrowseAndPlayController(catalog, FakeMediaController());
        addTearDown(player.dispose);
        final details = _FavoriteDetails();
        music.liked.add(track2);
        await controller.loadFavorites();
        await mount(
          tester,
          albumPage
              ? AlbumDetailPage(
                  albumId: const AlbumId('ncm-album-1'),
                  detailRepository: details,
                  state: HomeState.initial(),
                  controller: player,
                )
              : ArtistDetailPage(
                  artistId: const ArtistId('ncm-artist-1'),
                  detailRepository: details,
                  state: HomeState.initial(),
                  controller: player,
                ),
        );
        List<TrackId> order() => tester
            .widgetList<TrackRow>(find.byType(TrackRow))
            .map((row) => row.track.id)
            .toList();
        final sort = find.descendant(
          of: find.byType(TrackTableHeader),
          matching: find.text('喜欢'),
        );
        await tester.tap(sort);
        await tester.pumpAndSettle();
        expect(order(), [track2, track1]);
        await tester.tap(sort);
        await tester.pumpAndSettle();
        expect(order(), [track1, track2]);
        await tester.tap(sort);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('取消喜欢'));
        await tester.pumpAndSettle();
        expect(order(), [track1, track2]);
        await tester.tap(find.byTooltip('喜欢').first);
        await tester.pumpAndSettle();
        expect(order(), [track1, track2]);
      },
    );
  }

  testWidgets('all favorite buttons update together and cancel liking', (
    tester,
  ) async {
    await mount(
      tester,
      const Row(
        children: [
          MusicFavoriteButton(track: track1),
          MusicFavoriteButton(track: track1),
        ],
      ),
    );
    expect(find.byTooltip('喜欢'), findsNWidgets(2));
    await tester.tap(find.byTooltip('喜欢').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消喜欢'), findsNWidgets(2));
    await tester.tap(find.byTooltip('取消喜欢').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('喜欢'), findsNWidgets(2));
    expect(music.writes, 2);
  });
  testWidgets('paused details refresh favorites without playback updates', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      FakeMediaController(),
    );
    await mount(tester, HomeScreen(controller: player));
    await player.playAll([track(track1)]);
    await player.togglePlayback();
    await tester.pumpAndSettle();
    expect(player.current.playback.isActuallyPlaying, isFalse);
    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text(zh(track1.value)),
      ),
    );
    await tester.pumpAndSettle();
    final page = find.byType(NowPlayingPage);
    Finder favorite(String tooltip) =>
        find.descendant(of: page, matching: find.byTooltip(zh(tooltip)));
    expect(favorite('喜欢'), findsOneWidget);
    await tester.tap(favorite('喜欢'));
    await tester.pumpAndSettle();
    expect(favorite('取消喜欢'), findsOneWidget);
    expect(controller.favorite(track1), FavoriteState.liked);
    // Wait for the operation snackbar to stop covering the bottom controls.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(favorite('取消喜欢'));
    await tester.pumpAndSettle();
    expect(favorite('喜欢'), findsOneWidget);
    expect(controller.favorite(track1), FavoriteState.unliked);
    expect(music.writes, 2);
  });
  testWidgets(
    'guest action opens login and successful login does not replay it',
    (tester) async {
      await auth.signOut();
      await mount(tester, const MusicFavoriteButton(track: track1));
      await tester.tap(find.byType(IconButton).first);
      await tester.pumpAndSettle();
      expect(find.text('登录网易云音乐'), findsOneWidget);
      expect(music.writes, 0);
      repo.login(epoch: 2);
      await tester.pumpAndSettle();
      expect(music.writes, 0);
    },
  );
  testWidgets('unknown favorite click reads instead of mutating', (
    tester,
  ) async {
    music.heldLikes = () async => throw StateError('offline');
    controller.dispose();
    controller = AccountMusicController(
      repository: music,
      catalog: catalog,
      auth: auth,
    );
    await mount(tester, const MusicFavoriteButton(track: track1));
    await tester.tap(find.byTooltip('喜欢状态未知，点击加载'));
    await tester.pumpAndSettle();
    expect(music.writes, 0);
    expect(find.text('喜欢列表加载失败，请重试'), findsOneWidget);
  });
  testWidgets('create form validates name and preserves text after failure', (
    tester,
  ) async {
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showPlaylistEditor(context, controller),
          child: const Text('创建'),
        ),
      ),
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('歌单名称不能为空'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '测试新歌单');
    music.error = const AppError(
      category: AppErrorCategory.permission,
      code: 'music.permissionDenied',
      retryable: false,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('测试新歌单'), findsOneWidget);
    expect(find.text('没有操作此歌单的权限'), findsOneWidget);
    music.error = null;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(localizedTestValue(catalog.detail!.summary.title), '测试新歌单');
  });
  testWidgets('creation reconciliation retains form and never creates twice', (
    tester,
  ) async {
    music.createOverride = () async {
      music.writes++;
      catalog.detail = playlist(
        id: const PlaylistId('ncm-playlist-9002'),
        name: '等待核对',
        ids: [],
      );
      repo.failLists = true;
      throw const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
    };
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showPlaylistEditor(context, controller),
          child: const Text('创建'),
        ),
      ),
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '等待核对');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('核对操作结果'), findsOneWidget);
    expect(music.writes, 1);
    repo.failLists = false;
    await tester.tap(find.text('核对操作结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(music.writes, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('playlist tag picker popover selects up to 3 tags and confirms', (
    tester,
  ) async {
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showPlaylistEditor(context, controller),
          child: const Text('创建'),
        ),
      ),
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('标签：'), findsOneWidget);
    expect(find.text('选择...'), findsOneWidget);

    await tester.tap(find.text('选择...'));
    await tester.pumpAndSettle();

    expect(find.text('语种'), findsOneWidget);
    expect(find.text('风格'), findsOneWidget);
    expect(find.text('场景'), findsOneWidget);

    expect(find.text('华语'), findsOneWidget);
    expect(find.text('欧美'), findsOneWidget);

    await tester.tap(find.text('华语'));
    await tester.tap(find.text('欧美'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2/3 个标签'), findsOneWidget);

    await tester.tap(find.text('风格'));
    await tester.pumpAndSettle();
    expect(find.text('流行'), findsOneWidget);
    await tester.tap(find.text('流行'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3/3 个标签'), findsOneWidget);

    expect(find.text('摇滚'), findsOneWidget);
    await tester.tap(find.text('摇滚'));
    await tester.pumpAndSettle();
    expect(find.text('标签最多选择3个'), findsOneWidget);
    expect(find.text('已选 3/3 个标签'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('华语'), findsOneWidget);
    expect(find.text('欧美'), findsOneWidget);
    expect(find.text('流行'), findsOneWidget);
    expect(find.text('修改标签'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('华语'), findsNothing);
    expect(find.text('欧美'), findsOneWidget);
    expect(find.text('流行'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '带标签歌单');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(localizedTestValue(catalog.detail!.summary.title), '带标签歌单');
    expect(catalog.detail!.header.tags, ['欧美', '流行']);
  });
  testWidgets('cancelling tag picker discards unconfirmed selection', (
    tester,
  ) async {
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showPlaylistEditor(context, controller),
          child: const Text('创建'),
        ),
      ),
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择...'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1/3 个标签'), findsOneWidget);

    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    expect(find.text('选择...'), findsOneWidget);
    expect(find.text('华语'), findsNothing);
  });
  for (final id in ['material-dark', 'material-light']) {
    for (final editing in [false, true]) {
      testWidgets(
        '$id playlist ${editing ? 'edit' : 'create'} fields have idle borders',
        (tester) async {
          final preset = themePresets.singleWhere((preset) => preset.id == id);
          await mount(
            tester,
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showPlaylistEditor(
                  context,
                  controller,
                  detail: editing ? playlist() : null,
                ),
                child: const Text('打开'),
              ),
            ),
            theme: FideflowTheme.build(preset),
          );
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          final fields = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(InputDecorator),
          );
          expect(fields, findsNWidgets(2));
          for (final field in tester.widgetList<InputDecorator>(fields)) {
            expect(field.isFocused, isFalse);
            final border = field.decoration.enabledBorder!;
            expect(border, isA<OutlineInputBorder>());
            expect(border.borderSide.style, BorderStyle.solid);
            expect(border.borderSide.width, greaterThan(0));
            expect(border.borderSide.color, preset[ThemeColorRole.border]);
            expect(border.borderSide.color, isNot(field.decoration.fillColor));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'playlist editor input floating labels stay inside box and do not collide',
    (tester) async {
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlaylistEditor(context, controller),
            child: const Text('创建'),
          ),
        ),
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      // 1. Focus Name field
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();

      final nameFieldRect = tester.getRect(find.byType(TextField).first);
      final nameLabelRect = tester.getRect(find.text('名称'));
      final nameHintRect = tester.getRect(find.text('请输入歌单名称'));

      expect(nameLabelRect.top >= nameFieldRect.top, isTrue);
      expect(nameLabelRect.bottom < nameHintRect.top, isTrue);

      // 2. Focus Description field
      await tester.tap(find.byType(TextField).at(1));
      await tester.pumpAndSettle();

      final descFieldRect = tester.getRect(find.byType(TextField).at(1));
      final descLabelRect = tester.getRect(find.text('简介（可清空）'));
      final descHintRect = tester.getRect(find.text('介绍一下这个歌单吧'));

      expect(descLabelRect.top >= descFieldRect.top, isTrue);
      expect(descLabelRect.bottom < descHintRect.top, isTrue);
    },
  );
  testWidgets('special and foreign playlists do not show management actions', (
    tester,
  ) async {
    await mount(tester, MusicPlaylistActions(detail: playlist(special: 5)));
    expect(find.text('删除歌单'), findsNothing);
    expect(find.text('编辑信息'), findsNothing);
    expect(find.text('调整顺序'), findsNothing);
    await mount(
      tester,
      MusicPlaylistTitleActions(detail: playlist(special: 5)),
    );
    expect(find.byTooltip('删除歌单'), findsNothing);
    expect(find.byTooltip('编辑信息'), findsNothing);
    await mount(
      tester,
      MusicPlaylistActions(detail: playlist(creator: const UserId('43'))),
    );
    expect(find.byTooltip('收藏'), findsOneWidget);
    expect(find.text('删除歌单'), findsNothing);
    await mount(
      tester,
      MusicPlaylistTitleActions(detail: playlist(creator: const UserId('43'))),
    );
    expect(find.byTooltip('删除歌单'), findsNothing);
    expect(find.byTooltip('编辑信息'), findsNothing);
  });
  testWidgets('delete requires named confirmation and cancel never writes', (
    tester,
  ) async {
    var deletedCalled = false;
    await mount(
      tester,
      MusicPlaylistTitleActions(
        detail: catalog.detail!,
        onDeleted: () => deletedCalled = true,
      ),
    );
    await tester.tap(find.byTooltip('删除歌单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('“测试歌单”，1 首歌曲'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(music.writes, 0);
    expect(deletedCalled, isFalse);
    await tester.tap(find.byTooltip('删除歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(music.writes, 1);
    expect(catalog.detail, isNull);
    expect(deletedCalled, isTrue);
    expect(find.text('删除成功'), findsOneWidget);
  });
  testWidgets(
    'PlaylistDetailPage delete button invokes onDeleted and shows 删除成功',
    (tester) async {
      var deletedCalled = false;
      await mount(
        tester,
        PlaylistDetailPage(
          playlist: catalog.detail,
          state: HomeState.initial(),
          controller: BrowseAndPlayController(catalog, FakeMediaController()),
          onDeleted: () => deletedCalled = true,
        ),
      );
      await tester.tap(find.byTooltip('删除歌单'));
      await tester.pumpAndSettle();
      expect(find.text('删除自建歌单？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(deletedCalled, isTrue);
      expect(find.text('删除成功'), findsOneWidget);
    },
  );
  testWidgets('account renewal invalidates an open deletion confirmation', (
    tester,
  ) async {
    await mount(tester, MusicPlaylistTitleActions(detail: catalog.detail!));
    await tester.tap(find.byTooltip('删除歌单'));
    await tester.pumpAndSettle();
    repo.login(epoch: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(music.writes, 0);
    expect(catalog.detail, isNotNull);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('playlist actions do not render 调整顺序 button', (tester) async {
    await mount(
      tester,
      MusicPlaylistActions(detail: playlist(complete: false)),
    );
    expect(find.text('调整顺序'), findsNothing);
    expect(find.text('完整加载后可排序'), findsNothing);
    catalog.detail = playlist(ids: [track1, track2]);
    await mount(tester, MusicPlaylistActions(detail: catalog.detail!));
    expect(find.text('调整顺序'), findsNothing);
  });
  testWidgets('target chooser searches and adds only to owned playlist', (
    tester,
  ) async {
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showAddToPlaylist(context, controller, [track2]),
          child: const Text('添加'),
        ),
      ),
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('测试歌单'), findsNothing);
    await tester.enterText(find.byType(TextField), '测试');
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试歌单'));
    await tester.pumpAndSettle();
    expect(music.lastTracks, [track2]);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('list metadata appears before songs and detail replaces it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      FakeMediaController(),
    );
    addTearDown(player.dispose);
    const summary = PlaylistSummary(
      id: PlaylistId('ncm-playlist-9'),
      title: '列表歌单',
      subtitle: '创建者',
      trackCount: 1,
      header: PlaylistHeaderMetadata(
        description: '列表简介',
        playCount: 300,
        subscribedCount: 42,
        creator: PlaylistCreator(nickname: '列表作者'),
      ),
    );
    await mount(
      tester,
      PlaylistDetailPage(
        initialSummary: summary,
        state: HomeState.initial(),
        controller: player,
      ),
      settle: false,
    );
    expect(find.text('列表简介'), findsOneWidget);
    expect(find.text('收藏 42 次'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await mount(
      tester,
      PlaylistDetailPage(
        initialSummary: summary,
        playlist: const PlaylistDetail(
          summary: summary,
          header: PlaylistHeaderMetadata(
            description: '远端简介',
            subscribedCount: 43,
          ),
        ),
        state: HomeState.initial(),
        controller: player,
      ),
    );
    expect(find.text('远端简介'), findsOneWidget);
    expect(find.text('列表简介'), findsNothing);
    expect(find.text('收藏 43 次'), findsOneWidget);
  });
  testWidgets('playlist detail management renders without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      FakeMediaController(),
    );
    addTearDown(player.dispose);
    await mount(
      tester,
      PlaylistDetailPage(
        playlist: catalog.detail,
        state: HomeState.initial(),
        controller: player,
      ),
    );
    expect(find.byTooltip('编辑信息'), findsOneWidget);
    expect(find.byTooltip('删除歌单'), findsOneWidget);
    expect(find.text('调整顺序'), findsNothing);
    expect(find.text('编辑信息'), findsNothing);
    expect(find.text('删除歌单'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('batch mode hides top header and cancel restores it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      FakeMediaController(),
    );
    addTearDown(player.dispose);
    await mount(
      tester,
      PlaylistDetailPage(
        playlist: catalog.detail,
        state: HomeState.initial(),
        controller: player,
      ),
    );
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.byTooltip('编辑信息'), findsOneWidget);

    // Enter batch mode
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();

    // Header is hidden
    expect(find.text('播放全部'), findsNothing);
    expect(find.byTooltip('编辑信息'), findsNothing);
    expect(find.text('完成'), findsOneWidget);

    // Cancel batch mode
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // Header is restored
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.byTooltip('编辑信息'), findsOneWidget);
  });

  testWidgets(
    'table header includes 喜欢, artist is under title, and 3-state sort cycles',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      addTearDown(player.dispose);

      final trackA = Track(
        id: const TrackId('ncm-1001'),
        title: 'Song Alpha',
        artists: const [Artist(id: ArtistId('ncm-a1'), name: 'Artist Z')],
        album: const Album(id: AlbumId('ncm-alb1'), title: 'Album 1'),
        duration: const Duration(minutes: 4),
      );
      final trackB = Track(
        id: const TrackId('ncm-1002'),
        title: 'Song Beta',
        artists: const [Artist(id: ArtistId('ncm-a2'), name: 'Artist A')],
        album: const Album(id: AlbumId('ncm-alb2'), title: 'Album 2'),
        duration: const Duration(minutes: 2),
      );
      final trackC = Track(
        id: const TrackId('ncm-1003'),
        title: 'Song Gamma',
        artists: const [Artist(id: ArtistId('ncm-a3'), name: 'Artist M')],
        album: const Album(id: AlbumId('ncm-alb3'), title: 'Album 3'),
        duration: const Duration(minutes: 3),
      );

      catalog.detail = PlaylistDetail(
        summary: const PlaylistSummary(
          id: playlistId,
          title: '测试歌单',
          subtitle: '',
          trackCount: 3,
          creatorId: user,
        ),
        tracks: [trackA, trackB, trackC],
        header: const PlaylistHeaderMetadata(),
        membershipComplete: true,
        detailsComplete: true,
      );

      // Set trackB as liked
      music.liked.add(trackB.id);
      await controller.loadFavorites();

      await mount(
        tester,
        PlaylistDetailPage(
          playlist: catalog.detail,
          state: HomeState.initial(),
          controller: player,
        ),
      );

      // SortingBar is removed
      expect(find.text('排序：'), findsNothing);

      // Headers are present (no separate 歌手 header)
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('歌手'), findsNothing);
      expect(find.text('专辑'), findsOneWidget);
      expect(find.text('喜欢'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);

      // Artists are displayed under titles in the list
      expect(find.text('Artist Z'), findsOneWidget);
      expect(find.text('Artist A'), findsOneWidget);
      expect(find.text('Artist M'), findsOneWidget);

      // Title maxLines is 1
      final titleText = tester.widget<Text>(find.text('Song Alpha'));
      expect(titleText.maxLines, 1);

      // Initial default order: Song Alpha, Song Beta, Song Gamma
      List<String?> getDisplayedTitles() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where(
            (t) => t == 'Song Alpha' || t == 'Song Beta' || t == 'Song Gamma',
          )
          .toList();

      expect(getDisplayedTitles(), ['Song Alpha', 'Song Beta', 'Song Gamma']);

      // 1) Test 3-state sort on 时长: 升序 -> 降序 -> 默认
      // Tap 1: 时长 升序 (2m: Beta, 3m: Gamma, 4m: Alpha)
      await tester.tap(find.text('时长'));
      await tester.pumpAndSettle();
      expect(getDisplayedTitles(), ['Song Beta', 'Song Gamma', 'Song Alpha']);

      // Tap 2: 时长 降序 (4m: Alpha, 3m: Gamma, 2m: Beta)
      await tester.tap(find.text('时长'));
      await tester.pumpAndSettle();
      expect(getDisplayedTitles(), ['Song Alpha', 'Song Gamma', 'Song Beta']);

      // Tap 3: 回到 默认排序 (Alpha, Beta, Gamma)
      await tester.tap(find.text('时长'));
      await tester.pumpAndSettle();
      expect(getDisplayedTitles(), ['Song Alpha', 'Song Beta', 'Song Gamma']);

      // 2) Test 喜欢 sort using stable partition:
      // Default order: Alpha (unliked), Beta (liked), Gamma (unliked)
      // Tap 1: 喜欢 升序 (liked first: Beta, then unliked maintaining default order: Alpha, Gamma)
      await tester.tap(find.text('喜欢'));
      await tester.pumpAndSettle();
      expect(getDisplayedTitles(), ['Song Beta', 'Song Alpha', 'Song Gamma']);

      // Tap 2: 喜欢 降序 (unliked first maintaining default order: Alpha, Gamma, then liked: Beta)
      await tester.tap(find.text('喜欢'));
      await tester.pumpAndSettle();
      expect(getDisplayedTitles(), ['Song Alpha', 'Song Gamma', 'Song Beta']);

      // Tap 3: 回到 默认排序 (Alpha, Beta, Gamma)
      await tester.tap(find.text('喜欢'));
      await tester.pumpAndSettle();
      expect(getDisplayedTitles(), ['Song Alpha', 'Song Beta', 'Song Gamma']);
    },
  );

  testWidgets(
    'deleting playlist in HomeScreen returns to previous page, prunes history stack and shows 删除成功',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final player = BrowseAndPlayController(
        _HomeCatalog(catalog),
        FakeMediaController(),
      );

      catalog.detail = PlaylistDetail(
        summary: const PlaylistSummary(
          id: playlistId,
          title: '我的测试歌单',
          subtitle: '测试副标题',
          trackCount: 1,
          creatorId: user,
        ),
        tracks: [track(track1)],
        header: const PlaylistHeaderMetadata(),
        membershipComplete: true,
        detailsComplete: true,
      );
      await auth.loadUserPlaylists();
      await tester.pump();

      var revision = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: MusicManagementScope(
            controller: controller,
            revision: ++revision,
            child: HomeScreen(
              controller: player,
              authController: auth,
              recommendRepository: _FakeRecommendRepo(),
              playlistSquareRepository: _FakeSquareRepo(),
              homeFeedRepository: _FakeHomeFeedRepo(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate to "我的音乐" (Library)
      await tester.tap(find.text('我的音乐').last);
      await tester.pumpAndSettle();
      expect(find.text('我的测试歌单'), findsWidgets);

      // Open "我的测试歌单"
      await tester.tap(find.text('我的测试歌单').first);
      await tester.pumpAndSettle();

      // Now on detail page: "播放全部" is shown
      expect(find.text('播放全部'), findsOneWidget);

      // Tap "删除歌单" button in title actions
      await tester.tap(find.byTooltip('删除歌单'));
      await tester.pumpAndSettle();

      // Confirm deletion in alert dialog
      expect(find.text('删除自建歌单？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // 1. Shows "删除成功"
      expect(find.text('删除成功'), findsOneWidget);

      // 2. Returns to previous page (no longer on PlaylistDetailPage)
      expect(find.text('播放全部'), findsNothing);

      // 3. History stack was pruned: forward button is disabled
      final forwardButton = find.ancestor(
        of: find.byTooltip('前进'),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(forwardButton).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'deletion finishing after navigation preserves current page and history',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final player = BrowseAndPlayController(
        _HomeCatalog(catalog),
        FakeMediaController(),
      );

      catalog.detail = PlaylistDetail(
        summary: const PlaylistSummary(
          id: playlistId,
          title: '我的测试歌单',
          subtitle: '测试副标题',
          trackCount: 1,
          creatorId: user,
        ),
        tracks: [track(track1)],
        header: const PlaylistHeaderMetadata(),
        membershipComplete: true,
        detailsComplete: true,
      );
      await auth.loadUserPlaylists();
      await tester.pump();

      var revision = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: MusicManagementScope(
            controller: controller,
            revision: ++revision,
            child: HomeScreen(
              controller: player,
              authController: auth,
              recommendRepository: _FakeRecommendRepo(),
              playlistSquareRepository: _FakeSquareRepo(),
              homeFeedRepository: _FakeHomeFeedRepo(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate to "我的音乐" (Library)
      await tester.tap(find.text('我的音乐').last);
      await tester.pumpAndSettle();
      expect(find.text('我的测试歌单'), findsWidgets);

      // Open "我的测试歌单"
      await tester.tap(find.text('我的测试歌单').first);
      await tester.pumpAndSettle();

      // Now on detail page: "播放全部" is shown
      expect(find.text('播放全部'), findsOneWidget);

      // Tap "删除歌单" button in title actions
      await tester.tap(find.byTooltip('删除歌单'));
      await tester.pumpAndSettle();

      final deletion = Completer<void>();
      music.hold = () => deletion.future;

      // Confirm deletion in alert dialog
      expect(find.text('删除自建歌单？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('精选歌单').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('后退'), findsOneWidget);
      deletion.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistSquarePage), findsOneWidget);

      // 1. Shows "删除成功"
      expect(find.text('删除成功'), findsOneWidget);

      // 2. Returns to previous page (no longer on PlaylistDetailPage)
      expect(find.text('播放全部'), findsNothing);

      // 3. History stack was pruned: forward button is disabled
      final forwardButton = find.ancestor(
        of: find.byTooltip('前进'),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(forwardButton).onPressed, isNull);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('后退'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('后退'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(find.text('播放全部'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('前进'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

final class _FakeRecommendRepo implements RecommendRepository {
  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const RecommendedPlaylists(playlists: []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeSquareRepo implements PlaylistSquareRepository {
  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    String cat = '全部',
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const SearchResult(items: [], totalCount: 0, hasMore: false);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHomeFeedRepo implements HomeFeedRepository {
  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(greeting: '你好', playlists: []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FavoriteDetails implements CatalogDetailRepository {
  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async => AlbumDetail(
    summary: AlbumSummary(
      id: id,
      title: '测试专辑',
      artistName: '测试歌手',
      trackCount: 2,
    ),
    tracks: [track(track1), track(track2)],
  );
  @override
  Future<ArtistDetail> getArtist(ArtistId id) async => ArtistDetail(
    summary: ArtistSummary(id: id, name: '测试歌手', trackCount: 2),
    tracks: [track(track1), track(track2)],
  );
}

final class _HomeCatalog implements CatalogRepository {
  _HomeCatalog(this.catalog);
  final TestCatalog catalog;
  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(greeting: '你好');
  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => catalog.getPlaylist(id, policy: policy);
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
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
