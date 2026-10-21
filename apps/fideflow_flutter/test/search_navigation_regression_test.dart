import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/search/search_page.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

void main() {
  for (final detail in ['album', 'artist', 'playlist']) {
    testWidgets(
      'returning from $detail preserves search pages, filters and scroll',
      (tester) async {
        await setTestViewport(tester, const Size(390, 844));
        addTearDown(() => setTestViewport(tester, null));
        final repository = _PagedSearchCatalog();
        final search = CatalogSearchController(repository);
        if (detail == 'artist') await search.switchType(SearchType.album);
        final catalog = FakeCatalogRepository(latency: Duration.zero);
        final player = BrowseAndPlayController(catalog, FakeMediaController());
        addTearDown(search.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: HomeScreen(
              controller: player,
              searchController: search,
              detailRepository: catalog,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '  paged query  ');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        await search.loadMore();
        search.setOnlyPlayable(true);
        await tester.pumpAndSettle();
        final saved = search.current;
        expect(saved.items.length, 60);
        final page = tester.element(find.byType(SearchPage));
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SearchPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(320);
        await tester.pump();
        final offset = scroll.position.pixels;
        final requests = repository.queries.length;
        final view = tester.widget<SearchPage>(find.byType(SearchPage));
        switch (detail) {
          case 'album':
            view.onOpenAlbum!(_album(1));
          case 'artist':
            view.onOpenArtist!(
              const ArtistSummary(id: ArtistId('ncm-artist-1'), name: 'Artist'),
            );
          case 'playlist':
            view.onOpenPlaylist(player.current.feed!.playlists.first);
        }
        await tester.pumpAndSettle();
        if (detail == 'artist') {
          await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(
          repository.queries.length,
          requests,
          reason:
              'Returning to the same query must not request page one again.',
        );
        expect(search.current, same(saved));
        expect(tester.element(find.byType(SearchPage)), same(page));
        expect(scroll.position.pixels, closeTo(offset, 0.1));
        await search.loadMore();
        await tester.pumpAndSettle();
        expect(repository.queries.last.offset, 60);
        expect(search.current.items.length, 90);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final replacement in ['cleared', 'different query']) {
    testWidgets(
      'returning restores search when the controller was $replacement',
      (tester) async {
        await setTestViewport(tester, const Size(390, 844));
        addTearDown(() => setTestViewport(tester, null));
        final repository = _PagedSearchCatalog();
        final search = CatalogSearchController(repository);
        final catalog = FakeCatalogRepository(latency: Duration.zero);
        final player = BrowseAndPlayController(catalog, FakeMediaController());
        addTearDown(search.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: HomeScreen(
              controller: player,
              searchController: search,
              detailRepository: catalog,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'original query');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        tester.widget<SearchPage>(find.byType(SearchPage)).onOpenAlbum!(
          _album(1),
        );
        await tester.pumpAndSettle();
        if (replacement == 'cleared') {
          search.clear();
        } else {
          await search.search('another query');
        }
        final requests = repository.queries.length;
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(repository.queries.length, requests + 1);
        expect(repository.queries.last.keywords, 'original query');
        expect(search.current.query, 'original query');
        expect(search.current.status, SearchStatus.success);
        expect(search.current.items.length, 30);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

AlbumSummary _album(int index) => AlbumSummary(
  id: AlbumId('ncm-album-$index'),
  title: 'Album $index',
  artistName: 'Artist',
  trackCount: 0,
);

final class _PagedSearchCatalog
    implements CatalogRepository, CatalogSearchRepository {
  final queries = <SearchQuery>[];

  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) async {
    queries.add(query);
    final end = (query.offset + query.limit).clamp(0, 90);
    return SearchResult(
      items: [
        for (var index = query.offset; index < end; index++)
          if (query.searchType == SearchType.album)
            AlbumItem(_album(index + 1))
          else
            TrackItem(
              Track(
                id: TrackId('result-$index'),
                title: 'Result $index',
                artists: const [],
                album: const Album(id: AlbumId('ncm-album-1'), title: 'Album'),
                duration: const Duration(minutes: 3),
                availability: TrackAvailability.full,
              ),
            ),
      ],
      hasMore: end < 90,
      totalCount: 90,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
