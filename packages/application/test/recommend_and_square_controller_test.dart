import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  Track track(String id, {String title = 'Song'}) {
    return Track(
      id: TrackId(id),
      title: title,
      artists: const [Artist(id: ArtistId('ar-1'), name: 'Artist')],
      album: const Album(id: AlbumId('al-1'), title: 'Album'),
      duration: const Duration(seconds: 180),
    );
  }

  group('PlaybackIntentCoordinator', () {
    test('replaceQueue updates queue and bumps incarnation', () async {
      final media = FakeMediaController();
      final player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      await player.initialize(prefetchPlaylist: false);

      final coordinator = PlaybackIntentCoordinator(player: player);

      final t1 = track('1');
      final t2 = track('2');

      final result = await coordinator.replaceQueue(
        tracks: [t1, t2],
        startIndex: 0,
      );

      expect(result.isAccepted, isTrue);
      expect(coordinator.queueIncarnation, equals(1));
      final snapshot = await media.getSnapshot();
      expect(snapshot.queue.map((t) => t.id.value).toList(), ['1', '2']);
      expect(snapshot.currentIndex, 0);

      await player.dispose();
    });

    test('appendTracks and playNextTracks serialize queue additions', () async {
      final media = FakeMediaController();
      final player = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      await player.initialize(prefetchPlaylist: false);

      final coordinator = PlaybackIntentCoordinator(player: player);

      final t1 = track('1');
      final t2 = track('2');
      final t3 = track('3');

      await coordinator.replaceQueue(tracks: [t1], startIndex: 0);
      await coordinator.appendTracks([t2]);
      await coordinator.playNextTracks([t3]);

      final snapshot = await media.getSnapshot();
      expect(
        snapshot.queue.map((t) => t.id.value).toList(),
        containsAllInOrder(['1', '3', '2']),
      );

      await player.dispose();
    });
  });

  group('RecommendController', () {
    test('account reset discards a delayed recommendation result', () async {
      final fake = FakeCatalogRepository(
        latency: const Duration(milliseconds: 20),
      );
      final media = FakeMediaController();
      final player = BrowseAndPlayController(fake, media);
      await player.initialize(prefetchPlaylist: false);
      final controller = RecommendController(
        repository: fake,
        playbackCoordinator: PlaybackIntentCoordinator(player: player),
      );
      final loading = controller.load();
      controller.resetAccount();
      await loading;
      expect(controller.state.status, LoadStatus.initial);
      expect(controller.state.dailySnapshot, isNull);
      expect(controller.state.recommendedPlaylists, isNull);
      controller.dispose();
      await player.dispose();
    });
    test(
      'account reset prevents an old daily hero request starting playback',
      () async {
        final fake = FakeCatalogRepository(
          latency: const Duration(milliseconds: 20),
        );
        final media = FakeMediaController();
        final player = BrowseAndPlayController(fake, media);
        await player.initialize(prefetchPlaylist: false);
        final controller = RecommendController(
          repository: fake,
          playbackCoordinator: PlaybackIntentCoordinator(player: player),
        );
        final playing = controller.playDailySongsHero();
        controller.resetAccount();
        expect(await playing, isNull);
        expect((await media.getSnapshot()).queue, isEmpty);
        controller.dispose();
        await player.dispose();
      },
    );
    test(
      'page refresh during daily hero playback allows later playback',
      () async {
        final fake = FakeCatalogRepository(
          latency: const Duration(milliseconds: 20),
        );
        final media = FakeMediaController();
        final player = BrowseAndPlayController(fake, media);
        await player.initialize(prefetchPlaylist: false);
        final controller = RecommendController(
          repository: fake,
          playbackCoordinator: PlaybackIntentCoordinator(player: player),
        );
        addTearDown(controller.dispose);
        addTearDown(player.dispose);
        await controller.load();

        final playing = controller.playDailySongsHero();
        final refreshing = controller.load();
        expect((await playing)?.isAccepted, isTrue);
        await refreshing;

        expect(controller.state.heroPlayLoading, isFalse);
        expect((await controller.playDailySongsHero())?.isAccepted, isTrue);
      },
    );
    test(
      'initial load fetches daily songs and recommended playlists',
      () async {
        final fakeGateway = FakeCatalogRepository(latency: Duration.zero);
        final media = FakeMediaController();
        final player = BrowseAndPlayController(fakeGateway, media);
        await player.initialize(prefetchPlaylist: false);
        final coordinator = PlaybackIntentCoordinator(player: player);

        final controller = RecommendController(
          repository: fakeGateway,
          playbackCoordinator: coordinator,
        );

        await controller.load();

        expect(controller.state.status, LoadStatus.ready);
        expect(controller.state.dailySnapshot, isNotNull);
        expect(controller.state.dailySnapshot!.tracks, isNotEmpty);
        expect(controller.state.recommendedPlaylists, isNotNull);
        expect(controller.state.recommendedPlaylists!.playlists, isNotEmpty);

        controller.dispose();
        await player.dispose();
      },
    );

    test(
      'playDailySongsHero uses forceRefresh and preserves queue on failure',
      () async {
        final media = FakeMediaController();
        final fakeGateway = FakeCatalogRepository(latency: Duration.zero);
        final player = BrowseAndPlayController(fakeGateway, media);
        await player.initialize(prefetchPlaylist: false);

        final existingTrack = track('existing');
        await player.playSingleTrack(existingTrack);

        final coordinator = PlaybackIntentCoordinator(player: player);
        final failingRepo = _FailingRecommendRepo();

        final controller = RecommendController(
          repository: failingRepo,
          playbackCoordinator: coordinator,
        );

        final result = await controller.playDailySongsHero();

        // Should fail and queue MUST remain unchanged
        expect(result?.isAccepted, isFalse);
        final snapshot = await media.getSnapshot();
        expect(snapshot.queue.map((t) => t.id.value).toList(), ['existing']);

        controller.dispose();
        await player.dispose();
      },
    );
  });

  group('DailySongsController', () {
    test('initialize loads daily songs and playAll plays them', () async {
      final fakeGateway = FakeCatalogRepository(latency: Duration.zero);
      final media = FakeMediaController();
      final player = BrowseAndPlayController(fakeGateway, media);
      await player.initialize(prefetchPlaylist: false);
      final coordinator = PlaybackIntentCoordinator(player: player);

      final controller = DailySongsController(
        dateKey: '2026-09-30',
        repository: fakeGateway,
        playbackCoordinator: coordinator,
      );

      await controller.load();

      expect(controller.state.status, LoadStatus.ready);
      expect(controller.state.read, isNotNull);
      expect(controller.state.playableTracks, isNotEmpty);

      await controller.playAll();

      final snapshot = await media.getSnapshot();
      expect(snapshot.queue, isNotEmpty);
      expect(snapshot.playWhenReady, isTrue);

      controller.dispose();
      await player.dispose();
    });
  });

  group('PlaylistSquareController', () {
    test('initialize loads tags and initial page, pagination works', () async {
      final fakeGateway = FakeCatalogRepository(latency: Duration.zero);

      final controller = PlaylistSquareController(repository: fakeGateway);

      await controller.loadInitial();

      expect(controller.state.status, LoadStatus.ready);
      expect(controller.state.playlists, isNotEmpty);
      expect(controller.state.hotTags, isNotEmpty);

      final initialCount = controller.state.playlists.length;
      await controller.loadMore();

      expect(
        controller.state.playlists.length,
        greaterThanOrEqualTo(initialCount),
      );
      controller.dispose();
    });
  });

  group('CatalogDetailController', () {
    for (final subscription in [
      SubscriptionEvidence.subscribed,
      SubscriptionEvidence.unsubscribed,
    ]) {
      test('cached content retains access evidence: $subscription', () async {
        final gateway = FakeCatalogRepository(latency: Duration.zero);
        final player = BrowseAndPlayController(gateway, FakeMediaController());
        await player.initialize(prefetchPlaylist: false);
        final controller = CatalogDetailController(
          playlistId: const PlaylistId('playlist-night-drive'),
          catalog: _CachedDetailWithEvidence(gateway, subscription),
          playbackCoordinator: PlaybackIntentCoordinator(player: player),
        );
        await controller.load();
        expect(controller.state.status, LoadStatus.ready);
        expect(
          controller.state.detail!.accountState!.subscription,
          subscription,
        );
        expect(controller.state.detail!.tracks, isNotEmpty);
        controller.dispose();
        await player.dispose();
      });
    }

    test('access check passes for public playlist', () async {
      final fakeGateway = FakeCatalogRepository(latency: Duration.zero);
      final media = FakeMediaController();
      final player = BrowseAndPlayController(fakeGateway, media);
      await player.initialize(prefetchPlaylist: false);
      final coordinator = PlaybackIntentCoordinator(player: player);

      final controller = CatalogDetailController(
        playlistId: const PlaylistId('playlist-night-drive'),
        catalog: fakeGateway,
        playbackCoordinator: coordinator,
      );

      await controller.load();

      expect(controller.state.status, LoadStatus.ready);
      expect(controller.state.detail, isNotNull);

      controller.dispose();
      await player.dispose();
    });
  });
}

final class _FailingRecommendRepo implements RecommendRepository {
  @override
  Future<DailySongsRead> getDailySongs({
    String? dateKey,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    throw const AppError(
      category: AppErrorCategory.network,
      code: 'network.timeout',
      retryable: true,
    );
  }

  @override
  Future<RecommendedPlaylists> getRecommendedPlaylists({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return const RecommendedPlaylists(playlists: []);
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

final class _CachedDetailWithEvidence implements CatalogRepository {
  _CachedDetailWithEvidence(this.delegate, this.subscription);
  final CatalogRepository delegate;
  final SubscriptionEvidence subscription;

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    final content = await delegate.getPlaylist(id, policy: policy);
    return PlaylistDetail(summary: content.summary, tracks: content.tracks);
  }

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => PlaylistAccessVerdict(
    namespace: 'ncm',
    target: id,
    state: PlaylistAccessState.accountConfirmed,
    evidenceMode: RequestAuthMode.establishedSession,
    evidenceKind: 'remoteDetailCheck',
    fetchedAt: DateTime.now(),
    freshUntil: DateTime(2099),
    accountState: PlaylistAccountState(
      accountId: 'test',
      subscription: subscription,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
