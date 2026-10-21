import 'package:fideflow/app/appearance.dart';
import 'package:fideflow/features/discovery/library_page.dart';
import 'package:fideflow/features/search/search_page.dart';
import 'package:fideflow/features/settings/appearance_settings.dart';
import 'package:fideflow/shared/widgets/collection_card.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';
import 'support/appearance_doubles.dart';

void main() {
  void useResizableView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  void expectFullRow(WidgetTester tester, double width) {
    final rects = find
        .byType(CollectionCard)
        .evaluate()
        .map((element) => tester.getRect(find.byWidget(element.widget)))
        .toList();
    expect(rects, isNotEmpty);
    final row = rects
        .where((rect) => (rect.top - rects.first.top).abs() < 0.01)
        .toList();
    final padding = AppBreakpoints.pagePadding(AppBreakpoints.ofWidth(width));
    expect(row.last.right, closeTo(width - padding.right, 0.01));
    for (var i = 1; i < row.length; i++) {
      expect(row[i].width, closeTo(row.first.width, 0.01));
      expect(
        row[i].left - row[i - 1].right,
        closeTo(width < 600 ? 12 : 20, 0.01),
      );
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'library cards resize to fill rows on both sides of column transitions',
    (tester) async {
      useResizableView(tester);
      final repo = TestAuth();
      final auth = AuthController(repo);
      repo.playlists = () => List.generate(
        18,
        (i) => playlist(
          id: PlaylistId('ncm-playlist-${1000 + i}'),
          name: '歌单$i',
        ).summary,
      );
      addTearDown(auth.dispose);
      addTearDown(repo.events.close);
      await tester.runAsync(() async {
        repo.login();
        await flush();
      });
      PlaylistId? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: LibraryPage(
              feed: const HomeFeed(greeting: '', playlists: []),
              authController: auth,
              onOpenPlaylist: (summary) => opened = summary.id,
            ),
          ),
        ),
      );
      for (final width in [
        320.0,
        390.0,
        540.0,
        599.0,
        600.0,
        779.0,
        780.0,
        795.0,
        796.0,
        1000.0,
        1280.0,
      ]) {
        tester.view.physicalSize = Size(width, 1200);
        await tester.pumpAndSettle();
        expectFullRow(tester, width);
      }
      await tester.tap(find.byType(CollectionCard).first);
      expect(opened, const PlaylistId('ncm-playlist-1000'));
    },
  );

  for (final type in [
    SearchType.playlist,
    SearchType.album,
    SearchType.artist,
  ]) {
    testWidgets('search ${type.name} cards fill the row after resizing', (
      tester,
    ) async {
      useResizableView(tester);
      final catalog = _GridCatalog();
      final search = CatalogSearchController(catalog);
      final home = BrowseAndPlayController(catalog, FakeMediaController());
      addTearDown(search.dispose);
      await search.search('grid', type: type);
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: SearchPage(
              query: 'grid',
              searchController: search,
              state: home.current,
              onPlay: (_, _) {},
              onOpenPlaylist: (_) {},
            ),
          ),
        ),
      );
      for (final width in [390.0, 540.0, 780.0, 796.0, 1100.0]) {
        tester.view.physicalSize = Size(width, 1200);
        await tester.pumpAndSettle();
        expectFullRow(tester, width);
      }
    });
  }

  testWidgets('theme preset cards distribute unused row width', (tester) async {
    useResizableView(tester);
    final controller = AppearanceController(store: MemoryAppearanceStore());
    await tester.pumpWidget(
      MaterialApp(
        theme: controller.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AppearanceSettings(controller: controller),
          ),
        ),
      ),
    );
    for (final width in [320.0, 480.0, 650.0, 900.0, 1280.0]) {
      tester.view.physicalSize = Size(width, 1200);
      await tester.pumpAndSettle();
      final rects = controller.themes
          .map(
            (theme) =>
                tester.getRect(find.byKey(ValueKey('theme-card-${theme.id}'))),
          )
          .toList();
      final row = rects
          .where((rect) => (rect.top - rects.first.top).abs() < 0.01)
          .toList();
      expect(row.first.left, 24);
      expect(row.last.right, closeTo(width - 24, 0.01));
      expect(tester.takeException(), isNull);
    }
  });
}

class _GridCatalog extends TestCatalog implements CatalogSearchRepository {
  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) async =>
      SearchResult(
        items: List.generate(
          18,
          (i) => switch (query.searchType) {
            SearchType.playlist => PlaylistItem(
              playlist(id: PlaylistId('ncm-playlist-$i'), name: '歌单$i').summary,
            ),
            SearchType.album => AlbumItem(
              AlbumSummary(
                id: AlbumId('ncm-album-$i'),
                title: '专辑$i',
                artistName: '歌手',
                trackCount: 1,
              ),
            ),
            SearchType.artist => ArtistItem(
              ArtistSummary(id: ArtistId('ncm-artist-$i'), name: '歌手$i'),
            ),
            _ => throw StateError('unexpected search type'),
          },
        ),
        hasMore: false,
      );
}
