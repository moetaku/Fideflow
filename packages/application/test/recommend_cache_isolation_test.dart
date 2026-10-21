import 'dart:async';
import 'dart:io';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:test/test.dart';

void main() {
  late MetadataCacheStore store;
  late CachedCatalogRepository cache;
  late _RecommendRepo remote;
  late CatalogCacheContext context;
  final now = DateTime.utc(2026, 9, 30, 12);
  const dateKey = '2026-09-30';
  final invalidated = throwsA(
    isA<AppError>().having((e) => e.code, 'code', 'cache.invalidated'),
  );

  DailySongsRead read({DateTime? staleUntil}) => DailySongsRead(
    snapshot: DailySongsSnapshot(
      namespace: 'provider',
      accountId: 'active',
      dateKey: dateKey,
      songs: const [],
      fetchedAt: now,
      staleUntil: staleUntil ?? now.add(const Duration(hours: 6)),
      retainUntil: now.add(const Duration(days: 7)),
    ),
    source: DailySongsSource.network,
    refreshedAt: now,
  );

  setUp(() {
    final directory = Directory.systemTemp.createTempSync('recommend-cache');
    store = SqliteMetadataCacheStore.open(
      path: '${directory.path}/cache.db',
      now: () => now,
    );
    addTearDown(() async {
      cache.dispose();
      await store.close();
      directory.deleteSync(recursive: true);
    });
    context = const CatalogCacheContext(
      namespace: 'ncm',
      accountId: 'A',
      accountEpoch: 1,
    );
    remote = _RecommendRepo();
    cache = CachedCatalogRepository(
      remote: remote,
      store: store,
      accountContext: () => context,
      now: () => now,
      backgroundRefresh: false,
    );
  });

  for (final policy in [RefreshPolicy.cacheFirst, RefreshPolicy.forceRefresh]) {
    test(
      'daily songs bind to the captured account for ${policy.name}',
      () async {
        remote.dailyResult = read();
        final result = await cache.getDailySongs(
          dateKey: dateKey,
          policy: policy,
        );
        expect(result.snapshot.accountId, 'A');
        expect(result.snapshot.namespace, 'ncm');
        final cached = await cache.getDailySongs(
          dateKey: dateKey,
          policy: RefreshPolicy.localOnly,
        );
        expect(cached.source, DailySongsSource.cache);
        await cache.getDailySongs(dateKey: dateKey);
        expect(remote.dailyCalls, 1);

        context = const CatalogCacheContext(
          namespace: 'ncm',
          accountId: 'B',
          accountEpoch: 2,
        );
        await expectLater(
          cache.getDailySongs(
            dateKey: dateKey,
            policy: RefreshPolicy.localOnly,
          ),
          throwsA(isA<AppError>().having((e) => e.code, 'code', 'cache.miss')),
        );
        await store.clearAccount('A');
        expect(
          await store.readDailySongs(
            const CacheScope(namespace: 'ncm', accountId: 'A'),
            dateKey,
          ),
          isNull,
        );
      },
    );
  }

  for (final policy in [
    RefreshPolicy.cacheFirst,
    RefreshPolicy.forceRefresh,
    RefreshPolicy.networkFirst,
  ]) {
    test(
      'daily songs reject a response after account switch for ${policy.name}',
      () async {
        if (policy == RefreshPolicy.networkFirst) {
          await store.putDailySongs(
            DailySongsSnapshot(
              namespace: 'ncm',
              accountId: 'A',
              dateKey: dateKey,
              songs: const [],
              fetchedAt: now.subtract(const Duration(days: 1)),
              staleUntil: now.subtract(const Duration(hours: 1)),
              retainUntil: now.add(const Duration(days: 6)),
            ),
          );
        }
        remote.dailyPending = Completer<DailySongsRead>();
        final pending = cache.getDailySongs(dateKey: dateKey, policy: policy);
        final assertion = expectLater(pending, invalidated);
        await remote.dailyStarted.future;
        context = const CatalogCacheContext(
          namespace: 'ncm',
          accountId: 'B',
          accountEpoch: 2,
        );
        remote.dailyPending!.complete(read());
        await assertion;
        expect(
          await store.readDailySongs(context.accountScope, dateKey),
          isNull,
        );
        if (policy != RefreshPolicy.networkFirst) {
          expect(
            await store.readDailySongs(
              const CacheScope(namespace: 'ncm', accountId: 'A'),
              dateKey,
            ),
            isNull,
          );
        }
      },
    );
  }

  for (final nextAccount in ['B', 'A']) {
    test(
      'late recent listening cannot overwrite account $nextAccount in a new epoch',
      () async {
        final outgoing = cache.getRecentListeningResources();
        final assertion = expectLater(outgoing, invalidated);
        context = CatalogCacheContext(
          namespace: 'ncm',
          accountId: nextAccount,
          accountEpoch: 2,
        );
        final incoming = cache.getRecentListeningResources();
        remote.recent[1].complete(const ListenResources(title: 'new session'));
        await incoming;
        remote.recent[0].complete(const ListenResources(title: 'old session'));
        await assertion;
        expect(
          (await cache.getRecentListeningResources()).title,
          'new session',
        );
        expect(remote.recent.length, 2);
      },
    );
  }
}

class _RecommendRepo implements CatalogRepository, RecommendRepository {
  DailySongsRead? dailyResult;
  Completer<DailySongsRead>? dailyPending;
  final dailyStarted = Completer<void>();
  int dailyCalls = 0;
  final recent = <Completer<ListenResources>>[];

  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    dailyCalls++;
    if (!dailyStarted.isCompleted) dailyStarted.complete();
    return dailyPending?.future ?? Future.value(dailyResult!);
  }

  @override
  Future<ListenResources> getRecentListeningResources({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    final pending = Completer<ListenResources>();
    recent.add(pending);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
