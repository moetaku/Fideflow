import 'dart:async';
import 'dart:io';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  late _Feed feed;
  late BrowseAndPlayController player;
  setUp(() async {
    feed = _Feed();
    player = BrowseAndPlayController(
      FakeCatalogRepository(),
      FakeMediaController(),
      homeFeed: feed,
    );
    await player.initialize(prefetchPlaylist: false);
  });
  tearDown(() => player.dispose());

  test(
    'parallel section refresh merges into latest feed and derives flat view',
    () async {
      final a = player.refreshSection(HomeSectionKind.recommended);
      final b = player.refreshSection(HomeSectionKind.toplists);
      feed.requests[0].complete(section(HomeSectionKind.recommended, 'new A'));
      await a;
      feed.requests[1].complete(section(HomeSectionKind.toplists, 'new B'));
      await b;
      expect(player.current.feed!.sections.map((s) => s.title), [
        'new A',
        'new B',
      ]);
      expect(player.current.feed!.playlists.map((p) => p.title), [
        'new A',
        'new B',
      ]);
    },
  );
  test(
    'older same-section request cannot overwrite the newer answer',
    () async {
      final old = player.refreshSection(HomeSectionKind.recommended);
      final next = player.refreshSection(HomeSectionKind.recommended);
      feed.requests[1].complete(section(HomeSectionKind.recommended, 'new'));
      await next;
      feed.requests[0].complete(section(HomeSectionKind.recommended, 'stale'));
      await old;
      expect(player.current.feed!.sections.first.title, 'new');
    },
  );
  test('full refresh invalidates pending section updates', () async {
    final old = player.refreshSection(HomeSectionKind.recommended);
    await player.refresh();
    feed.requests[0].complete(section(HomeSectionKind.recommended, 'stale'));
    await old;
    expect(player.current.feed!.sections.first.title, 'old A');
  });
  test('recommendation state can explicitly discard an old snapshot', () {
    final snapshot = DailySongsSnapshot(
      namespace: 'ncm',
      accountId: 'a',
      dateKey: '2026-10-12',
      songs: [],
      fetchedAt: DateTime(2026),
      staleUntil: DateTime(2026),
      retainUntil: DateTime(2026),
    );
    final state = RecommendState(
      dateKey: snapshot.dateKey,
      dailySnapshot: snapshot,
    );
    expect(state.copyWith().dailySnapshot, same(snapshot));
    expect(
      state
          .copyWith(dateKey: '2026-10-13', clearDailySnapshot: true)
          .dailySnapshot,
      isNull,
    );
  });

  test(
    'cleanup retains pre-fence ticket, rejects stale owners and confirms completion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ff-cleanup-test',
      );
      final store = SqliteMetadataCacheStore.open(
        path: '${directory.path}/cache.db',
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      const scope = CacheScope(namespace: 'ncm', accountId: 'a');
      const owner = CleanupOwner(
        namespace: 'ncm',
        accountId: 'a',
        authEpoch: 1,
        lifecycleSeq: 1,
      );
      final manager = AccountCleanupManager(
        maintenance: store,
        deleteArtworkFiles: (_) async {},
      );
      final old =
          (await store.readPartitionTicket(scope) as PartitionTicketAvailable)
              .ticket;
      await manager.prepareRevocation(owner);
      expect(
        await store.readPartitionTicket(scope),
        isA<PartitionTicketUnavailable>(),
      );
      expect(await manager.finishRevocation(owner), CleanupOutcome.stopped);
      final current =
          (await store.readPartitionTicket(scope) as PartitionTicketAvailable)
              .ticket;
      expect(current.partitionGeneration, old.partitionGeneration! + 1);
      store.fenceScope(old);
      expect(
        await store.readPartitionTicket(scope),
        isA<PartitionTicketAvailable>(),
      );
      expect(await manager.finishRevocation(owner), CleanupOutcome.stopped);
      const nextOwner = CleanupOwner(
        namespace: 'ncm',
        accountId: 'a',
        authEpoch: 2,
        lifecycleSeq: 2,
      );
      await manager.prepareRevocation(nextOwner);
      expect(
        await manager.finishRevocation(owner),
        CleanupOutcome.stopUnconfirmed,
      );
      expect(await manager.finishRevocation(nextOwner), CleanupOutcome.stopped);
    },
  );
  test(
    'unavailable storage cannot be reported as a successful cleanup',
    () async {
      final manager = AccountCleanupManager(
        maintenance: const DisabledMetadataCacheStore(),
        deleteArtworkFiles: (_) async {},
      );
      const owner = CleanupOwner(
        namespace: 'ncm',
        accountId: 'a',
        authEpoch: 1,
        lifecycleSeq: 1,
      );
      await manager.prepareRevocation(owner);
      expect(
        await manager.finishRevocation(owner),
        CleanupOutcome.stopUnconfirmed,
      );
    },
  );
}

HomeSection section(HomeSectionKind kind, String title) => HomeSection(
  kind: kind,
  title: title,
  playlists: [
    PlaylistSummary(
      id: PlaylistId(title),
      title: title,
      subtitle: '',
      trackCount: 0,
    ),
  ],
);

class _Feed implements HomeFeedRepository {
  final requests = <Completer<HomeSection>>[];
  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => HomeFeed(
    greeting: 'test',
    sections: [
      section(HomeSectionKind.recommended, 'old A'),
      section(HomeSectionKind.toplists, 'old B'),
    ],
  );
  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) {
    final request = Completer<HomeSection>();
    requests.add(request);
    return request.future;
  }
}
