import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

final class _ControlledCatalog implements CatalogRepository {
  _ControlledCatalog({this.onSearch});

  Future<SearchResult<Track>> Function(SearchQuery query)? onSearch;

  /// Every offset the controller asked the service for, in order: the pagination
  /// contract is about which ranges are consumed, so a test asserts on this
  /// rather than on how many rows happen to be visible.
  final List<int> offsets = [];

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    offsets.add(query.offset);
    if (onSearch != null) return onSearch!(query);
    return const SearchResult(items: [], hasMore: false, totalCount: 0);
  }

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();

  @override
  Future<Track> getTrack(TrackId id) => throw UnimplementedError();

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();
}

void main() {
  final testTrack1 = Track(
    id: const TrackId('t1'),
    title: 'Song 1',
    artists: const [Artist(id: ArtistId('a1'), name: 'Artist 1')],
    album: const Album(id: AlbumId('al1'), title: 'Album 1'),
    duration: const Duration(seconds: 180),
  );
  final testTrack2 = Track(
    id: const TrackId('t2'),
    title: 'Song 2',
    artists: const [Artist(id: ArtistId('a2'), name: 'Artist 2')],
    album: const Album(id: AlbumId('al2'), title: 'Album 2'),
    duration: const Duration(seconds: 210),
  );

  group('CatalogSearchController', () {
    test('initial state has empty query and initial status', () {
      final controller = CatalogSearchController(_ControlledCatalog());
      addTearDown(controller.dispose);

      expect(controller.current.status, SearchStatus.initial);
      expect(controller.current.query, isEmpty);
      expect(controller.current.tracks, isEmpty);
      expect(controller.current.hasMore, isFalse);
    });

    test('search updates state to success with tracks', () async {
      final catalog = _ControlledCatalog(
        onSearch: (q) async =>
            SearchResult(items: [testTrack1], hasMore: true, totalCount: 50),
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Beyond');

      expect(controller.current.status, SearchStatus.success);
      expect(controller.current.query, 'Beyond');
      expect(controller.current.tracks, [testTrack1]);
      expect(controller.current.hasMore, isTrue);
      expect(controller.current.totalCount, 50);
    });

    test('empty search resets to initial state without network call', () async {
      var searched = false;
      final catalog = _ControlledCatalog(
        onSearch: (q) async {
          searched = true;
          return const SearchResult(items: [], hasMore: false);
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('   ');

      expect(controller.current.status, SearchStatus.initial);
      expect(searched, isFalse);
    });

    test('slow older search does not overwrite newer search', () async {
      final completerA = Completer<SearchResult<Track>>();
      final completerB = Completer<SearchResult<Track>>();

      final catalog = _ControlledCatalog(
        onSearch: (q) {
          if (q.keywords == 'A') return completerA.future;
          if (q.keywords == 'B') return completerB.future;
          return Future.value(const SearchResult(items: [], hasMore: false));
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      // Start search A
      final futureA = controller.search('A');
      // Start search B immediately after
      final futureB = controller.search('B');

      // B finishes first with track 2
      completerB.complete(
        SearchResult(items: [testTrack2], hasMore: false, totalCount: 1),
      );
      await futureB;

      expect(controller.current.query, 'B');
      expect(controller.current.tracks, [testTrack2]);

      // A finishes late with track 1
      completerA.complete(
        SearchResult(items: [testTrack1], hasMore: false, totalCount: 1),
      );
      await futureA;

      // Current state MUST still be B!
      expect(controller.current.query, 'B');
      expect(controller.current.tracks, [testTrack2]);
    });

    test('search failure updates state to failure', () async {
      final catalog = _ControlledCatalog(
        onSearch: (q) async => throw const AppError(
          category: AppErrorCategory.network,
          code: 'network.offline',
          retryable: true,
        ),
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Fail');

      expect(controller.current.status, SearchStatus.failure);
      expect(controller.current.errorCode, 'network.offline');
    });

    test('loadMore appends results to current tracks', () async {
      var callCount = 0;
      final catalog = _ControlledCatalog(
        onSearch: (q) async {
          callCount++;
          if (q.offset == 0) {
            return SearchResult(
              items: [testTrack1],
              hasMore: true,
              totalCount: 2,
            );
          }
          return SearchResult(
            items: [testTrack2],
            hasMore: false,
            totalCount: 2,
          );
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');
      expect(controller.current.tracks, [testTrack1]);
      expect(controller.current.hasMore, isTrue);

      await controller.loadMore();
      expect(controller.current.tracks, [testTrack1, testTrack2]);
      expect(controller.current.hasMore, isFalse);
      expect(callCount, 2);
    });

    test(
      'an overlapping page adds only what is new, and the offset moves on',
      () async {
        final testTrack3 = Track(
          id: const TrackId('t3'),
          title: 'Song 3',
          artists: const [Artist(id: ArtistId('a3'), name: 'Artist 3')],
          album: const Album(id: AlbumId('al3'), title: 'Album 3'),
          duration: const Duration(seconds: 150),
        );
        // The second page repeats a row the first one already had. That is normal
        // for a service whose result set shifted between requests.
        final catalog = _ControlledCatalog(
          onSearch: (q) async => switch (q.offset) {
            0 => SearchResult(items: [testTrack1, testTrack2], hasMore: true),
            2 => SearchResult(items: [testTrack2, testTrack3], hasMore: true),
            _ => const SearchResult(items: [], hasMore: false),
          },
        );
        final controller = CatalogSearchController(catalog);
        addTearDown(controller.dispose);

        await controller.search('Test');
        await controller.loadMore();

        expect(controller.current.tracks, [
          testTrack1,
          testTrack2,
          testTrack3,
        ], reason: 'the repeated row appears once');
        expect(
          catalog.offsets,
          [0, 2],
          reason:
              'the offset is what the service consumed, not what the page shows',
        );
        expect(controller.current.hasMore, isTrue);

        // The next request continues past the range that was consumed, instead of
        // asking for the two rows already on screen.
        await controller.loadMore();
        expect(catalog.offsets, [0, 2, 4]);
      },
    );

    test('a page of rows already known ends the search', () async {
      final catalog = _ControlledCatalog(
        onSearch: (q) async => switch (q.offset) {
          0 => SearchResult(items: [testTrack1], hasMore: true),
          _ => SearchResult(items: [testTrack1], hasMore: true),
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');
      await controller.loadMore();

      expect(controller.current.tracks, [testTrack1]);
      expect(
        controller.current.hasMore,
        isFalse,
        reason: 'the service says more, but it is not sending anything new',
      );

      // A further request cannot produce anything, so none is made.
      final requests = catalog.offsets.length;
      await controller.loadMore();
      expect(catalog.offsets.length, requests);
    });

    test('an empty page ends the search', () async {
      final catalog = _ControlledCatalog(
        onSearch: (q) async => switch (q.offset) {
          0 => SearchResult(items: [testTrack1], hasMore: true, totalCount: 40),
          _ => const SearchResult(items: [], hasMore: true, totalCount: 40),
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');
      await controller.loadMore();

      expect(controller.current.tracks, [testTrack1]);
      expect(controller.current.hasMore, isFalse);
      final requests = catalog.offsets.length;
      await controller.loadMore();
      expect(catalog.offsets.length, requests);
    });

    test('the first page is de-duplicated as well', () async {
      // One track listed twice, which a catalog can do when a song is filed under
      // two entries: the page renders one row either way.
      final catalog = _ControlledCatalog(
        onSearch: (q) async => SearchResult(
          items: [testTrack1, testTrack1, testTrack2],
          hasMore: true,
        ),
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');

      expect(controller.current.tracks, [testTrack1, testTrack2]);
      expect(
        controller.current.hasMore,
        isFalse,
        reason: 'the same page cannot be asked for again',
      );
    });

    test('a second loadMore while one is in flight is ignored', () async {
      final held = Completer<SearchResult<Track>>();
      final catalog = _ControlledCatalog(
        onSearch: (q) async {
          if (q.offset == 0) {
            return SearchResult(items: [testTrack1], hasMore: true);
          }
          return held.future;
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');
      final first = controller.loadMore();
      final second = controller.loadMore();
      expect(catalog.offsets, [
        0,
        1,
      ], reason: 'the second tap asks for nothing');

      held.complete(SearchResult(items: [testTrack2], hasMore: false));
      await first;
      await second;
      expect(controller.current.tracks, [testTrack1, testTrack2]);
    });

    test('a new search starts its own offset', () async {
      final catalog = _ControlledCatalog(
        onSearch: (q) async => SearchResult(items: [testTrack1], hasMore: true),
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');
      await controller.loadMore();
      await controller.search('Other');
      await controller.loadMore();

      expect(
        catalog.offsets.last,
        1,
        reason: 'the new search re-consumes the result set from its own start',
      );
    });

    test('clear resets state to initial', () async {
      final catalog = _ControlledCatalog(
        onSearch: (q) async =>
            SearchResult(items: [testTrack1], hasMore: false),
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Test');
      expect(controller.current.status, SearchStatus.success);

      controller.clear();
      expect(controller.current.status, SearchStatus.initial);
      expect(controller.current.query, isEmpty);
      expect(controller.current.tracks, isEmpty);
    });

    test('multi-type search handles album, artist, playlist results', () async {
      final albumItem = AlbumItem(
        const AlbumSummary(
          id: AlbumId('ncm-album-1'),
          title: 'Great Album',
          artistName: 'Artist 1',
          trackCount: 10,
        ),
      );
      final artistItem = ArtistItem(
        const ArtistSummary(id: ArtistId('ncm-artist-1'), name: 'Great Artist'),
      );

      final catalog = _MultiTypeCatalog(
        onMultiSearch: (q) async {
          if (q.searchType == SearchType.album) {
            return SearchResult(
              items: [albumItem],
              hasMore: false,
              totalCount: 1,
            );
          }
          if (q.searchType == SearchType.artist) {
            return SearchResult(
              items: [artistItem],
              hasMore: false,
              totalCount: 1,
            );
          }
          return const SearchResult(items: [], hasMore: false, totalCount: 0);
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Jay', type: SearchType.album);
      expect(controller.current.status, SearchStatus.success);
      expect(controller.current.searchType, SearchType.album);
      expect(controller.current.items, [albumItem]);
      expect(controller.current.tracks, isEmpty);

      await controller.switchType(SearchType.artist);
      expect(controller.current.status, SearchStatus.success);
      expect(controller.current.searchType, SearchType.artist);
      expect(controller.current.items, [artistItem]);
    });

    test(
      'switching category drops the previous category total count',
      () async {
        final catalog = _MultiTypeCatalog(
          onMultiSearch: (q) async {
            if (q.searchType == SearchType.album) {
              return SearchResult(
                items: [
                  AlbumItem(
                    const AlbumSummary(
                      id: AlbumId('ncm-album-9'),
                      title: 'Album',
                      artistName: 'Artist',
                      trackCount: 7,
                    ),
                  ),
                ],
                hasMore: false,
                totalCount: 7,
              );
            }
            throw const AppError(
              category: AppErrorCategory.network,
              code: 'network.timeout',
              retryable: true,
            );
          },
        );
        final controller = CatalogSearchController(catalog);
        addTearDown(controller.dispose);

        await controller.search('Jay', type: SearchType.album);
        expect(controller.current.totalCount, 7);

        // The artist search fails, so nothing replaces the count: a count that
        // outlives its result set would describe the wrong category.
        await controller.switchType(SearchType.artist);
        expect(controller.current.status, SearchStatus.failure);
        expect(controller.current.totalCount, isNull);
      },
    );

    test(
      'degradation fallback: non-track searches fail if provider lacks capability',
      () async {
        // _ControlledCatalog only implements CatalogRepository (no CatalogSearchRepository)
        final catalog = _ControlledCatalog(
          onSearch: (q) async =>
              SearchResult(items: [testTrack1], hasMore: false),
        );
        final controller = CatalogSearchController(catalog);
        addTearDown(controller.dispose);

        // Track search succeeds via fallback to searchTracks
        await controller.search('Song', type: SearchType.track);
        expect(controller.current.status, SearchStatus.success);
        expect(controller.current.tracks, [testTrack1]);

        // Album search fails because catalog lacks capability
        await controller.search('Album', type: SearchType.album);
        expect(controller.current.status, SearchStatus.failure);
        expect(controller.current.errorCode, 'provider.unsupported');
      },
    );

    test(
      'onlyPlayable filter strictly retains full availability and excludes others',
      () async {
        final fullTrack = Track(
          id: const TrackId('t-full'),
          title: 'Full Track',
          artists: const [Artist(id: ArtistId('a1'), name: 'Artist 1')],
          album: const Album(id: AlbumId('al1'), title: 'Album 1'),
          duration: const Duration(seconds: 180),
          availability: TrackAvailability.full,
        );
        final previewTrack = Track(
          id: const TrackId('t-preview'),
          title: 'Preview Track',
          artists: const [Artist(id: ArtistId('a1'), name: 'Artist 1')],
          album: const Album(id: AlbumId('al1'), title: 'Album 1'),
          duration: const Duration(seconds: 180),
          availability: TrackAvailability.preview,
        );
        final noneTrack = Track(
          id: const TrackId('t-none'),
          title: 'None Track',
          artists: const [Artist(id: ArtistId('a1'), name: 'Artist 1')],
          album: const Album(id: AlbumId('al1'), title: 'Album 1'),
          duration: const Duration(seconds: 180),
          availability: TrackAvailability.none,
        );
        final unknownTrack = Track(
          id: const TrackId('t-unknown'),
          title: 'Unknown Track',
          artists: const [Artist(id: ArtistId('a1'), name: 'Artist 1')],
          album: const Album(id: AlbumId('al1'), title: 'Album 1'),
          duration: const Duration(seconds: 180),
          availability: TrackAvailability.unknown,
        );

        final catalog = _ControlledCatalog(
          onSearch: (q) async => SearchResult(
            items: [fullTrack, previewTrack, noneTrack, unknownTrack],
            hasMore: false,
          ),
        );
        final controller = CatalogSearchController(catalog);
        addTearDown(controller.dispose);

        await controller.search('Mixed');
        expect(controller.current.tracks, hasLength(4));
        expect(controller.current.visibleTracks, hasLength(4));

        // Enable onlyPlayable
        controller.setOnlyPlayable(true);
        expect(controller.current.onlyPlayable, isTrue);
        // Strictly retains ONLY full
        expect(controller.current.visibleTracks, [fullTrack]);
        expect(
          (controller.current.visibleItems.single as TrackItem).track,
          fullTrack,
        );

        // Disable onlyPlayable
        controller.setOnlyPlayable(false);
        expect(controller.current.visibleTracks, hasLength(4));
      },
    );

    test('retryLoadMore invokes loadMore', () async {
      var callCount = 0;
      final catalog = _ControlledCatalog(
        onSearch: (q) async {
          callCount++;
          if (callCount == 1) {
            return SearchResult(items: [testTrack1], hasMore: true);
          }
          if (callCount == 2) {
            throw const AppError(
              category: AppErrorCategory.network,
              code: 'network.timeout',
              retryable: true,
            );
          }
          return SearchResult(items: [testTrack2], hasMore: false);
        },
      );
      final controller = CatalogSearchController(catalog);
      addTearDown(controller.dispose);

      await controller.search('Query');
      expect(controller.current.tracks, [testTrack1]);
      expect(controller.current.hasMore, isTrue);

      // Attempt 1 fails
      await controller.loadMore();
      expect(controller.current.errorCode, 'network.timeout');

      // Attempt 2 succeeds via retryLoadMore
      await controller.retryLoadMore();
      expect(controller.current.tracks, [testTrack1, testTrack2]);
      expect(controller.current.errorCode, isNull);
    });
  });
}

final class _MultiTypeCatalog
    implements CatalogRepository, CatalogSearchRepository {
  _MultiTypeCatalog({this.onMultiSearch});

  Future<SearchResult<CatalogItem>> Function(SearchQuery query)? onMultiSearch;

  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) async {
    if (onMultiSearch != null) return onMultiSearch!(query);
    return const SearchResult(items: [], hasMore: false, totalCount: 0);
  }

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async =>
      const SearchResult(items: [], hasMore: false, totalCount: 0);

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();

  @override
  Future<Track> getTrack(TrackId id) => throw UnimplementedError();

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => throw UnimplementedError();
}
