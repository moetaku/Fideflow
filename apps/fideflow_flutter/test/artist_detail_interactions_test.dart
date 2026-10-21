import 'package:fideflow/features/catalog/artist_detail_page.dart';
import 'package:fideflow/features/catalog/widgets/sorting_bar.dart';
import 'package:fideflow/features/catalog/widgets/track_table.dart';
import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';

final class _TestArtistDetails implements CatalogDetailRepository {
  _TestArtistDetails(this.detail);
  final ArtistDetail detail;

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async => throw UnimplementedError();

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async => detail;
}

void main() {
  const artistId = ArtistId('ncm-artist-12345');
  const albumId1 = AlbumId('ncm-album-1');
  const albumId2 = AlbumId('ncm-album-2');

  final artistSummary = ArtistSummary(
    id: artistId,
    name: '测试歌手',
    trackCount: 3,
    albumCount: 2,
  );

  final tracks = [
    const Track(
      id: TrackId('ncm-track-1'),
      title: 'B 歌曲',
      artists: [Artist(id: artistId, name: '测试歌手')],
      album: Album(id: albumId2, title: 'Z 专辑'),
      duration: Duration(minutes: 3),
    ),
    const Track(
      id: TrackId('ncm-track-2'),
      title: 'A 歌曲',
      artists: [Artist(id: artistId, name: '测试歌手')],
      album: Album(id: albumId1, title: 'A 专辑'),
      duration: Duration(minutes: 4),
    ),
    const Track(
      id: TrackId('ncm-track-3'),
      title: 'C 歌曲',
      artists: [Artist(id: artistId, name: '测试歌手')],
      album: Album(id: albumId2, title: 'M 专辑'),
      duration: Duration(minutes: 2),
    ),
  ];

  final artistDetail = ArtistDetail(summary: artistSummary, tracks: tracks);

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
              child: ArtistDetailPage(
                artistId: artistId,
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
    'Artist detail page removes top-left back button and SortingBar',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
      final details = _TestArtistDetails(artistDetail);
      final controller = BrowseAndPlayController(
        fakeRepo,
        FakeMediaController(),
      );
      addTearDown(controller.dispose);

      await mount(tester, detailRepo: details, controller: controller);

      // 1. Verify in-page back button is NOT rendered
      expect(find.byTooltip('返回'), findsNothing);

      // 2. Verify artist metadata
      expect(find.text('测试歌手'), findsWidgets);
      expect(find.text('单曲 3 · 专辑 2'), findsOneWidget);

      // 3. Verify SortingBar is removed in wide layout
      expect(find.text('排序'), findsNothing);
      expect(find.text('热门单曲 (3首)'), findsOneWidget);
    },
  );

  testWidgets(
    'Artist detail table header clicks switch sorting mode in wide layout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
      final details = _TestArtistDetails(artistDetail);
      final controller = BrowseAndPlayController(
        fakeRepo,
        FakeMediaController(),
      );
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
    },
  );

  testWidgets(
    'Artist detail renders SortingBar when the list is narrower than 600',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeRepo = FakeCatalogRepository(latency: Duration.zero);
      final details = _TestArtistDetails(artistDetail);
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
      expect(find.text('专辑'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);
      expect(find.text('喜欢'), findsOneWidget);
      // '歌手' chip is excluded for artist detail
      expect(
        find.descendant(of: find.byType(SortingBar), matching: find.text('歌手')),
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
