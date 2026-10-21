import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

void main() {
  late _Repo repo;
  late PlaylistSquareController controller;
  late DateTime now;

  setUp(() {
    repo = _Repo();
    now = DateTime(2026);
    controller = PlaylistSquareController(repository: repo, clock: () => now);
  });
  tearDown(() => controller.dispose());

  test(
    'cached category restores immediately without loading or requests',
    () async {
      await controller.loadInitial();
      await controller.selectCategory('ACG');
      final states = <PlaylistSquareState>[];
      final subscription = controller.states.listen(states.add);
      final switching = controller.selectCategory('全部');
      expect(controller.state.status, LoadStatus.ready);
      expect(controller.state.playlists.single.id.value, '全部-hot-0');
      expect(controller.state.highQuality, isNull);
      await switching;
      await Future<void>.delayed(Duration.zero);
      expect(states.map((s) => s.status), [LoadStatus.ready]);
      expect(repo.calls.length, 2);
      expect(repo.hqCalls, 0);
      await subscription.cancel();
    },
  );

  test('orders and empty results have separate caches', () async {
    await controller.loadInitial();
    repo.empty = true;
    await controller.setOrder(PlaylistOrder.newOrder);
    await controller.setOrder(PlaylistOrder.hot);
    expect(controller.state.playlists, isNotEmpty);
    await controller.setOrder(PlaylistOrder.newOrder);
    expect(controller.state.playlists, isEmpty);
    expect(controller.state.totalCount, isNull);
    expect(controller.state.highQuality, isNull);
    expect(repo.calls.length, 2);
  });

  test(
    'expiry at five minutes forces refresh and failed load can retry',
    () async {
      await controller.loadInitial();
      now = now.add(const Duration(minutes: 5));
      repo.fail = true;
      await controller.selectCategory('全部');
      expect(repo.calls.last.policy, RefreshPolicy.forceRefresh);
      expect(controller.state.status, LoadStatus.failure);
      repo.fail = false;
      await controller.selectCategory('全部');
      expect(controller.state.status, LoadStatus.ready);
      expect(repo.calls.length, 3);
      expect(repo.calls.last.policy, RefreshPolicy.forceRefresh);
    },
  );

  test('pagination restores offset and does not renew expiry', () async {
    await controller.loadInitial();
    now = now.add(const Duration(minutes: 4));
    await controller.loadMore();
    await controller.selectCategory('ACG');
    await controller.selectCategory('全部');
    expect(controller.state.playlists.length, 2);
    await controller.loadMore();
    expect(repo.calls.last.offset, 2);
    now = now.add(const Duration(minutes: 1));
    await controller.selectCategory('全部');
    expect(repo.calls.last.offset, 0);
    expect(repo.calls.last.policy, RefreshPolicy.forceRefresh);
    expect(controller.state.playlists.length, 1);
  });

  test('manual refresh bypasses cache and resets expiry', () async {
    await controller.loadInitial();
    now = now.add(const Duration(minutes: 4));
    await controller.refresh();
    expect(repo.calls.last.policy, RefreshPolicy.forceRefresh);
    now = now.add(const Duration(minutes: 2));
    await controller.selectCategory('ACG');
    await controller.selectCategory('全部');
    expect(repo.calls.length, 3);
  });

  test('no-progress pagination counter survives category switching', () async {
    await controller.loadInitial();
    repo.empty = true;
    await controller.loadMore();
    await controller.loadMore();
    await controller.selectCategory('ACG');
    await controller.selectCategory('全部');
    await controller.loadMore();
    expect(controller.state.hasMore, isFalse);
  });

  for (final pagination in [false, true]) {
    test(
      'cached switch rejects old ${pagination ? 'pagination' : 'category'} response',
      () async {
        await controller.loadInitial();
        final pending = Completer<SearchResult<PlaylistSummary>>();
        repo.pending = pending;
        final old = pagination
            ? controller.loadMore()
            : controller.selectCategory('ACG');
        await controller.selectCategory('全部');
        pending.complete(
          SearchResult(items: [_playlist('obsolete')], hasMore: false),
        );
        await old;
        expect(controller.state.playlists.single.id.value, '全部-hot-0');
        expect(controller.state.isLoadingMore, isFalse);
        await controller.selectCategory('ACG');
        expect(controller.state.playlists.single.id.value, 'ACG-hot-0');
      },
    );
  }

  test(
    'account reset fences cancelled loads and clears old cached pages',
    () async {
      await controller.loadInitial();
      await controller.selectCategory('ACG');
      final pending = Completer<SearchResult<PlaylistSummary>>();
      repo.pending = pending;
      final old = controller.refresh();
      controller.resetAccount();
      expect(controller.state.status, LoadStatus.initial);
      expect(controller.state.selectedCategory, 'ACG');
      expect(controller.state.playlists, isEmpty);
      expect(controller.state.error, isNull);
      await controller.loadInitial();
      pending.completeError(
        const AppError(
          category: AppErrorCategory.authentication,
          code: 'auth.epochMismatch',
          retryable: false,
        ),
      );
      await old;
      expect(controller.state.status, LoadStatus.ready);
      expect(controller.state.error, isNull);
      final before = repo.calls.length;
      await controller.selectCategory('全部');
      expect(
        repo.calls.length,
        before + 1,
        reason: 'old account cache must not survive',
      );
    },
  );

  test('account reset recovers a previously cancelled initial load', () async {
    repo.fail = true;
    await controller.loadInitial();
    expect(controller.state.status, LoadStatus.failure);
    controller.resetAccount();
    repo.fail = false;
    await controller.loadInitial();
    expect(controller.state.status, LoadStatus.ready);
    expect(controller.state.error, isNull);
  });

  test('custom cache duration is honored', () async {
    controller.dispose();
    controller = PlaylistSquareController(
      repository: repo,
      cacheDuration: const Duration(seconds: 10),
      clock: () => now,
    );
    await controller.loadInitial();
    now = now.add(const Duration(seconds: 10));
    await controller.selectCategory('全部');
    expect(repo.calls.length, 2);
    expect(repo.calls.last.policy, RefreshPolicy.forceRefresh);
  });
}

PlaylistSummary _playlist(String id) =>
    PlaylistSummary(id: PlaylistId(id), title: id, subtitle: '', trackCount: 0);

class _Repo implements PlaylistSquareRepository {
  final calls =
      <({String cat, PlaylistOrder order, int offset, RefreshPolicy policy})>[];
  int hqCalls = 0;
  bool empty = false;
  bool fail = false;
  Completer<SearchResult<PlaylistSummary>>? pending;

  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    calls.add((cat: cat, order: order, offset: offset, policy: policy));
    final wait = pending;
    pending = null;
    if (wait != null) return wait.future;
    if (fail) throw StateError('failed');
    return SearchResult(
      items: empty ? [] : [_playlist('$cat-${order.name}-$offset')],
      hasMore: true,
      totalCount: empty ? null : 100,
    );
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
  }) async {
    hqCalls++;
    return empty ? null : HighQualityPlaylist(summary: _playlist('hq-$cat'));
  }
}
