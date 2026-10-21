import 'dart:async';

import 'package:fideflow/features/catalog/album_detail_page.dart';
import 'package:fideflow/features/catalog/widgets/sorting_bar.dart';
import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';

final class _TestDetails implements CatalogDetailRepository {
  _TestDetails(this.detail);
  final AlbumDetail detail;

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async => detail;

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async =>
      throw UnimplementedError();
}

void main() {
  const albumId = AlbumId('ncm-album-12345');
  const artistId = ArtistId('ncm-artist-1');

  final albumSummary = AlbumSummary(
    id: albumId,
    title: '测试专辑',
    artistName: '测试歌手',
    trackCount: 3,
    publishTime: DateTime(2023, 5, 20, 10, 30),
  );

  final tracks = [
    const Track(
      id: TrackId('ncm-track-1'),
      title: 'B 歌曲',
      artists: [Artist(id: artistId, name: '测试歌手')],
      album: Album(id: albumId, title: '测试专辑'),
      duration: Duration(minutes: 3),
    ),
    const Track(
      id: TrackId('ncm-track-2'),
      title: 'A 歌曲',
      artists: [Artist(id: artistId, name: '测试歌手')],
      album: Album(id: albumId, title: '测试专辑'),
      duration: Duration(minutes: 4),
    ),
    const Track(
      id: TrackId('ncm-track-3'),
      title: 'C 歌曲',
      artists: [Artist(id: artistId, name: '测试歌手')],
      album: Album(id: albumId, title: '测试专辑'),
      duration: Duration(minutes: 2),
    ),
  ];

  final albumDetail = AlbumDetail(summary: albumSummary, tracks: tracks);

  late TestAuth repo;
  late AuthController auth;
  late TestCatalog catalog;
  late TestMusic music;
  late AccountMusicController musicCtrl;

  setUp(() async {
    repo = TestAuth();
    auth = AuthController(repo);
    catalog = TestCatalog();
    music = TestMusic(catalog);
    repo.playlists = () => [];
    musicCtrl = AccountMusicController(
      repository: music,
      catalog: catalog,
      auth: auth,
    );
    repo.login();
    await flush();
  });

  tearDown(() async {
    musicCtrl.dispose();
    auth.dispose();
    await repo.events.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    required CatalogDetailRepository detailRepo,
    required BrowseAndPlayController controller,
  }) async {
    var revision = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: StreamBuilder<void>(
            stream: musicCtrl.changes,
            builder: (_, _) => MusicManagementScope(
              controller: musicCtrl,
              revision: ++revision,
              child: AlbumDetailPage(
                albumId: albumId,
                detailRepository: detailRepo,
                state: controller.current,
                controller: controller,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Album detail page removes top-left back button and renders action toolbar',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
      final details = _TestDetails(albumDetail);
      final controller = BrowseAndPlayController(
        fakeRepo,
        FakeMediaController(),
      );
      addTearDown(controller.dispose);

      await mount(tester, detailRepo: details, controller: controller);

      // 1. Verify in-page back button is NOT rendered
      expect(find.byTooltip('返回'), findsNothing);

      // 2. Verify album metadata & formatted date YYYY-MM-DD
      expect(find.text('测试专辑'), findsOneWidget);
      expect(find.text('测试歌手'), findsWidgets);
      expect(find.text('共 3 首歌曲 · 2023-05-20'), findsOneWidget);

      // 3. Verify action toolbar buttons
      expect(find.text('播放全部'), findsOneWidget);
      expect(find.byTooltip('收藏'), findsOneWidget);
      expect(find.byTooltip('分享专辑链接'), findsOneWidget);

      // 4. Verify SortingBar is removed
      expect(find.text('排序'), findsNothing);
    },
  );

  testWidgets('Album detail page track table removes album column', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final details = _TestDetails(albumDetail);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);

    await mount(tester, detailRepo: details, controller: controller);

    // Header has '#' and '标题', but NO '专辑' column
    expect(find.text('#'), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('喜欢'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    // '专辑' is only in the tag badge, not as a table column header
    expect(find.widgetWithText(TrackTableHeader, '专辑'), findsNothing);

    // Track rows show titles
    expect(find.text('B 歌曲'), findsOneWidget);
    expect(find.text('A 歌曲'), findsOneWidget);
    expect(find.text('C 歌曲'), findsOneWidget);

    // TrackRow has showAlbum == false
    final rows = tester.widgetList<TrackRow>(find.byType(TrackRow)).toList();
    expect(rows, hasLength(3));
    expect(rows.every((row) => row.showAlbum == false), isTrue);
  });

  testWidgets('Clicking table header switches sorting mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final details = _TestDetails(albumDetail);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);

    await mount(tester, detailRepo: details, controller: controller);

    // Initial order: B, A, C
    var rowTitles = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((r) => r.track.title)
        .toList();
    expect(rowTitles, ['B 歌曲', 'A 歌曲', 'C 歌曲']);

    // Tap '标题' -> sort title ascending: A, B, C
    await tester.tap(find.text('标题'));
    await tester.pumpAndSettle();

    rowTitles = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((r) => r.track.title)
        .toList();
    expect(rowTitles, ['A 歌曲', 'B 歌曲', 'C 歌曲']);

    // Tap '标题' again -> sort title descending: C, B, A
    await tester.tap(find.text('标题'));
    await tester.pumpAndSettle();

    rowTitles = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((r) => r.track.title)
        .toList();
    expect(rowTitles, ['C 歌曲', 'B 歌曲', 'A 歌曲']);

    // Tap '时长' -> sort duration ascending: C (2min), B (3min), A (4min)
    await tester.tap(find.text('时长'));
    await tester.pumpAndSettle();

    rowTitles = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((r) => r.track.title)
        .toList();
    expect(rowTitles, ['C 歌曲', 'B 歌曲', 'A 歌曲']);
  });

  testWidgets('Sharing album copies standard link to clipboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final details = _TestDetails(albumDetail);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);

    await mount(tester, detailRepo: details, controller: controller);

    final shareBtn = find.byTooltip('分享专辑链接');
    expect(shareBtn, findsOneWidget);
    await tester.tap(shareBtn);
    await tester.pump();

    expect(writes, ['https://music.163.com/album?id=12345']);
    expect(find.text('已复制专辑链接'), findsOneWidget);
  });

  testWidgets('Existing collection renders collected and can be removed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    music.albums = {albumId};
    await musicCtrl.loadAlbumSubscriptions();
    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);
    await mount(
      tester,
      detailRepo: _TestDetails(albumDetail),
      controller: controller,
    );
    expect(find.byTooltip('已收藏'), findsOneWidget);
    await tester.tap(find.byTooltip('已收藏'));
    await tester.pumpAndSettle();
    expect(music.albums, isEmpty);
    expect(find.byTooltip('收藏'), findsOneWidget);
  });

  testWidgets('Loading collection disables writes until status is known', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final held = Completer<Set<AlbumId>>();
    music.heldAlbums = () => held.future;
    final read = musicCtrl.loadAlbumSubscriptions();
    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);
    await mount(
      tester,
      detailRepo: _TestDetails(albumDetail),
      controller: controller,
    );
    final button = tester.widget<IconButton>(
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '加载收藏中'),
    );
    expect(button.onPressed, isNull);
    expect(music.writes, 0);
    held.complete({albumId});
    await read;
    await tester.pumpAndSettle();
    expect(find.byTooltip('已收藏'), findsOneWidget);
  });

  testWidgets('Collection load failure offers a read-only retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    music.heldAlbums = () async => throw StateError('offline');
    await musicCtrl.loadAlbumSubscriptions();
    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);
    await mount(
      tester,
      detailRepo: _TestDetails(albumDetail),
      controller: controller,
    );
    expect(find.byTooltip('重试加载收藏'), findsOneWidget);
    music.heldAlbums = null;
    music.albums = {albumId};
    await tester.tap(find.byTooltip('重试加载收藏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('已收藏'), findsOneWidget);
    expect(music.writes, 0);
  });

  testWidgets('Tapping 收藏 toggles collection state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
    final details = _TestDetails(albumDetail);
    final controller = BrowseAndPlayController(fakeRepo, FakeMediaController());
    addTearDown(controller.dispose);

    await mount(tester, detailRepo: details, controller: controller);

    final collectBtn = find.byTooltip('收藏');
    expect(collectBtn, findsOneWidget);

    await tester.tap(collectBtn);
    await tester.pumpAndSettle();

    expect(find.byTooltip('已收藏'), findsOneWidget);
    expect(musicCtrl.isAlbumSubscribed(albumId), isTrue);

    await tester.tap(find.byTooltip('已收藏'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('收藏'), findsOneWidget);
    expect(musicCtrl.isAlbumSubscribed(albumId), isFalse);
  });

  testWidgets(
    'Album detail renders SortingBar when the list is narrower than 520',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(550, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
      final details = _TestDetails(albumDetail);
      final controller = BrowseAndPlayController(
        fakeRepo,
        FakeMediaController(),
      );
      addTearDown(controller.dispose);

      await mount(tester, detailRepo: details, controller: controller);

      // Below the table breakpoint, SortingBar is visible with label '排序'
      expect(find.text('排序'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('歌曲名'), findsOneWidget);
      expect(find.text('歌手'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);
      expect(find.text('喜欢'), findsOneWidget);
      // '专辑' chip is excluded for album detail
      expect(
        find.descendant(of: find.byType(SortingBar), matching: find.text('专辑')),
        findsNothing,
      );

      // TrackTableHeader column headers are NOT rendered
      expect(find.text('#'), findsNothing);

      // Tap '歌曲名' chip -> sort title ascending: A, B, C
      await tester.tap(find.text('歌曲名'));
      await tester.pumpAndSettle();

      var rowTitles = tester
          .widgetList<TrackRow>(find.byType(TrackRow))
          .map((r) => r.track.title)
          .toList();
      expect(rowTitles, ['A 歌曲', 'B 歌曲', 'C 歌曲']);

      // Tap '歌曲名' again -> sort title descending: C, B, A
      await tester.tap(find.text('歌曲名'));
      await tester.pumpAndSettle();

      rowTitles = tester
          .widgetList<TrackRow>(find.byType(TrackRow))
          .map((r) => r.track.title)
          .toList();
      expect(rowTitles, ['C 歌曲', 'B 歌曲', 'A 歌曲']);
    },
  );
}
