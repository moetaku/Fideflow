import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

void main() {
  for (final transition in ['category', 'order', 'refresh']) {
    for (final fails in [false, true]) {
      test(
        '$transition restores pagination while an old page ${fails ? 'fails' : 'succeeds'}',
        () async {
          final repo = _SquareRepo();
          final controller = PlaylistSquareController(repository: repo);
          addTearDown(controller.dispose);
          await controller.loadInitial();
          final more = controller.loadMore();
          expect(controller.state.isLoadingMore, isTrue);

          switch (transition) {
            case 'category':
              await controller.selectCategory('ACG');
            case 'order':
              await controller.setOrder(PlaylistOrder.newOrder);
            case 'refresh':
              await controller.refresh();
          }
          expect(controller.state.status, LoadStatus.ready);
          expect(controller.state.isLoadingMore, isFalse);
          expect(controller.state.hasMore, isTrue);
          if (fails) {
            repo.oldPage.completeError(StateError('old request failed'));
          } else {
            repo.oldPage.complete(
              SearchResult(items: [playlist('obsolete')], hasMore: true),
            );
          }
          await more;
          expect(
            controller.state.playlists.map((p) => p.id.value),
            isNot(contains('obsolete')),
          );

          await controller.loadMore();
          expect(repo.pageCalls, 2);
          expect(
            controller.state.playlists.map((p) => p.id.value),
            contains('next'),
          );
          expect(controller.state.isLoadingMore, isFalse);
        },
      );
    }
  }
}

PlaylistSummary playlist(String id) =>
    PlaylistSummary(id: PlaylistId(id), title: id, subtitle: '', trackCount: 0);

class _SquareRepo implements PlaylistSquareRepository {
  final oldPage = Completer<SearchResult<PlaylistSummary>>();
  int pageCalls = 0;

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (offset == 0) {
      return SearchResult(
        items: [playlist('$cat-${order.name}')],
        hasMore: true,
      );
    }
    if (++pageCalls == 1) return oldPage.future;
    return SearchResult(items: [playlist('next')], hasMore: false);
  }

  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const PlaylistCategoryTree();
  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => [];
  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => null;
}
