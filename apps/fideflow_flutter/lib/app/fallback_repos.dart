import 'package:fideflow_domain/domain.dart';

final class FallbackRecommendRepo implements RecommendRepository {
  FallbackRecommendRepo(this._catalog);
  final CatalogRepository _catalog;

  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return DailySongsRead(
      snapshot: DailySongsSnapshot(
        namespace: 'fallback',
        accountId: 'anon',
        dateKey: dateKey ?? '2026-09-30',
        songs: const [],
        fetchedAt: DateTime.now(),
        staleUntil: DateTime.now().add(const Duration(hours: 1)),
        retainUntil: DateTime.now().add(const Duration(days: 7)),
      ),
      source: DailySongsSource.network,
      refreshedAt: DateTime.now(),
    );
  }

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final feed = await _catalog.getHomeFeed(policy: policy);
    return RecommendedPlaylists(playlists: feed.playlists);
  }

  @override
  Future<List<Track>> getNewSongs({
    int limit = 10,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const [];
  }

  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const ListenResources(resources: []);
  }
}

final class FallbackSquareRepo implements PlaylistSquareRepository {
  FallbackSquareRepo(this._catalog);
  final CatalogRepository _catalog;

  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const PlaylistCategoryTree(categories: {}, sub: []);
  }

  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const [];
  }

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    String cat = NcmPlaylistCategory.all,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final feed = await _catalog.getHomeFeed(policy: policy);
    return SearchResult(
      items: feed.playlists.skip(offset).take(limit).toList(),
      totalCount: feed.playlists.length,
      hasMore: offset + limit < feed.playlists.length,
    );
  }

  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return null;
  }
}
