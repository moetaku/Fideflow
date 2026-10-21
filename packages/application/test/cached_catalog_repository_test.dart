import 'dart:async';
import 'dart:io';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  late Directory directory;
  late MetadataCacheStore store;
  late _FakeCatalog fake;
  late CachedCatalogRepository repository;
  late CatalogCacheContext context;
  late DateTime now;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ff-cached-catalog');
    now = DateTime.utc(2026, 9, 28, 12);
    context = const CatalogCacheContext(
      namespace: 'ncm-test',
      accountId: 'guest',
      accountEpoch: 1,
    );
    store = SqliteMetadataCacheStore.open(
      path: '${directory.path}/cache.db',
      now: () => now,
    );
    fake = _FakeCatalog();
    repository = CachedCatalogRepository(
      remote: fake,
      store: store,
      accountContext: () => context,
      now: () => now,
    );
  });

  tearDown(() async {
    repository.dispose();
    await store.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Lets queued asynchronous work (a refresh behind the caller) finish.
  Future<void> pump([int turns = 24]) async {
    for (var turn = 0; turn < turns; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Track track(String id, {String title = '标题', String? artwork}) => Track(
    id: TrackId(id),
    title: title,
    artists: const [Artist(id: ArtistId('a'), name: '艺人')],
    album: Album(
      id: const AlbumId('al'),
      title: '专辑',
      artworkUri: artwork == null ? null : Uri.parse(artwork),
    ),
    duration: const Duration(minutes: 3),
  );

  test(
    'summary cache loads details once, including known empty translations',
    () async {
      final old = track('ncm-1');
      final envelope = CacheEnvelope.fresh(
        scope: context.publicScope,
        at: now,
        window: CacheContentKind.trackDetail.window,
      );
      await store.putTracks([
        CachedTrack(
          track: old,
          groups: {TrackFieldGroup.title: envelope},
          envelope: envelope,
        ),
      ]);
      fake.tracks['ncm-1'] = old;
      expect(
        (await repository.getTrack(old.id, requireDetail: true)).title,
        localizedTestValue(old.title),
      );
      await pump();
      expect(fake.getTrackCalls, 1);
      final refreshed = (await store.readTracks(context.publicScope, [
        old.id,
      ])).values.single;
      expect(refreshed.knows(TrackFieldGroup.translationNames), isTrue);
      expect(refreshed.track.translationNames, isEmpty);
      await repository.getTrack(old.id);
      await pump();
      expect(fake.getTrackCalls, 1);
    },
  );

  test(
    'shared titles never carry another account playback availability',
    () async {
      const id = TrackId('ncm-1');
      Track entitled(TrackAvailability availability) => Track(
        id: id,
        title: 'Shared title',
        artists: const [Artist(id: ArtistId('artist'), name: 'Artist')],
        album: const Album(id: AlbumId('album'), title: 'Shared album'),
        duration: const Duration(minutes: 3),
        availability: availability,
      );
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'A',
        accountEpoch: 1,
      );
      fake.tracks[id.value] = entitled(TrackAvailability.preview);
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'B',
        accountEpoch: 2,
      );
      final shared = await repository.getTrack(
        id,
        policy: RefreshPolicy.localOnly,
      );
      expect(shared.title, 'Shared title');
      expect(shared.availability, TrackAvailability.unknown);
      fake.tracks[id.value] = entitled(TrackAvailability.none);
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'A',
        accountEpoch: 3,
      );
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).availability,
        TrackAvailability.preview,
      );
      await store.clearAccount('A');
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).availability,
        TrackAvailability.unknown,
      );
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'B',
        accountEpoch: 4,
      );
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).availability,
        TrackAvailability.none,
      );
      expect(
        (await store.readTracks(context.publicScope, [id]))[id]!.track.title,
        'Shared title',
      );
    },
  );

  test(
    'VIP quality ceiling survives a non-VIP account reading the same track',
    () async {
      const id = TrackId('ncm-1');
      Track rendition(TrackQuality maximum, {TrackQuality? objective}) => Track(
        id: id,
        title: 'Song',
        artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
        album: const Album(id: AlbumId('al'), title: 'Album'),
        duration: const Duration(minutes: 3),
        availability: TrackAvailability.full,
        maxPotentialQuality: maximum,
        objectiveQuality: objective,
      );
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'VIP',
        accountEpoch: 1,
      );
      fake.tracks[id.value] = rendition(TrackQuality.hiRes);
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'free',
        accountEpoch: 2,
      );
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.unknown,
      );
      fake.tracks[id.value] = rendition(TrackQuality.standard);
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'VIP',
        accountEpoch: 3,
      );
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.hiRes,
      );
      expect(
        (await repository.getTracks([
          id,
        ], policy: RefreshPolicy.localOnly))[id]!.maxPotentialQuality,
        TrackQuality.hiRes,
      );
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'free',
        accountEpoch: 4,
      );
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.standard,
      );
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'guest',
        accountEpoch: 5,
      );
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.unknown,
      );
      expect(
        (await store.readTracks(context.publicScope, [
          id,
        ]))[id]!.track.maxPotentialQuality,
        TrackQuality.unknown,
      );
    },
  );

  test(
    'shared objective masters take precedence over private permission ceilings',
    () async {
      const id = TrackId('ncm-1');
      fake.tracks[id.value] = Track(
        id: id,
        title: 'Song',
        artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
        album: const Album(id: AlbumId('al'), title: 'Album'),
        duration: const Duration(minutes: 3),
        maxPotentialQuality: TrackQuality.hiRes,
        objectiveQuality: TrackQuality.hiRes,
        audioSpecs: const [
          TrackAudioSpecs(quality: TrackQuality.hiRes, sampleRateHz: 96000),
        ],
      );
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'other',
        accountEpoch: 2,
      );
      fake.tracks[id.value] = Track(
        id: id,
        title: 'Song',
        artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
        album: const Album(id: AlbumId('al'), title: 'Album'),
        duration: const Duration(minutes: 3),
        maxPotentialQuality: TrackQuality.standard,
      );
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      final cached = await repository.getTrack(
        id,
        policy: RefreshPolicy.localOnly,
      );
      expect(cached.maxPotentialQuality, TrackQuality.hiRes);
      expect(cached.objectiveQuality, TrackQuality.hiRes);
      expect(cached.audioSpecs.single.sampleRateHz, 96000);
    },
  );

  test(
    'sparse permission responses preserve independent quality expiry',
    () async {
      const id = TrackId('ncm-1');
      fake.tracks[id.value] = Track(
        id: id,
        title: 'Song',
        artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
        album: const Album(id: AlbumId('al'), title: 'Album'),
        duration: const Duration(minutes: 3),
        availability: TrackAvailability.full,
        maxPotentialQuality: TrackQuality.hiRes,
      );
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      now = now.add(const Duration(minutes: 4));
      fake.tracks[id.value] = Track(
        id: id,
        title: 'Song',
        artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
        album: const Album(id: AlbumId('al'), title: 'Album'),
        duration: const Duration(minutes: 3),
        availability: TrackAvailability.full,
      );
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.hiRes,
      );
      now = now.add(const Duration(minutes: 2));
      final expired = await repository.getTrack(
        id,
        policy: RefreshPolicy.localOnly,
      );
      expect(expired.maxPotentialQuality, TrackQuality.unknown);
      expect(expired.availability, TrackAvailability.full);
    },
  );

  test(
    'legacy shared permission ceilings are scrubbed before refresh',
    () async {
      const id = TrackId('ncm-1');
      final envelope = CacheEnvelope.fresh(
        scope: context.publicScope,
        at: now,
        window: CacheContentKind.trackDetail.window,
      );
      await store.putTracks([
        CachedTrack(
          track: Track(
            id: id,
            title: 'Legacy',
            artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
            album: const Album(id: AlbumId('al'), title: 'Album'),
            duration: const Duration(minutes: 3),
            maxPotentialQuality: TrackQuality.standard,
          ),
          groups: {
            TrackFieldGroup.title: envelope,
            TrackFieldGroup.maxPotentialQuality: envelope,
          },
          envelope: envelope,
        ),
      ]);
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.unknown,
      );
      fake.tracks[id.value] = Track(
        id: id,
        title: 'Legacy',
        artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
        album: const Album(id: AlbumId('al'), title: 'Album'),
        duration: const Duration(minutes: 3),
        maxPotentialQuality: TrackQuality.hiRes,
      );
      await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
      expect(
        (await repository.getTrack(
          id,
          policy: RefreshPolicy.localOnly,
        )).maxPotentialQuality,
        TrackQuality.hiRes,
      );
    },
  );

  for (final availability in [
    TrackAvailability.none,
    TrackAvailability.preview,
  ]) {
    test(
      'sparse search preserves $availability without extending its expiry',
      () async {
        const id = TrackId('ncm-1');
        fake.tracks[id.value] = Track(
          id: id,
          title: 'Song',
          artists: const [Artist(id: ArtistId('a'), name: 'Artist')],
          album: const Album(id: AlbumId('al'), title: 'Album'),
          duration: const Duration(minutes: 3),
          availability: availability,
        );
        await repository.getTrack(id, policy: RefreshPolicy.forceRefresh);
        now = now.add(const Duration(minutes: 4));
        fake.searchResult = SearchResult(
          items: [track(id.value)],
          hasMore: false,
        );
        await repository.searchTracks(
          const SearchQuery(keywords: 'Song'),
          policy: RefreshPolicy.forceRefresh,
        );

        expect(
          (await repository.getTrack(
            id,
            policy: RefreshPolicy.localOnly,
          )).availability,
          availability,
        );
        now = now.add(const Duration(minutes: 2));
        expect(
          (await repository.getTrack(
            id,
            policy: RefreshPolicy.localOnly,
          )).availability,
          TrackAvailability.unknown,
        );
      },
    );
  }

  group('getTrack', () {
    test(
      'a miss reads the provider once and the next read is cached',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');

        expect(
          localizedTestValue(
            (await repository.getTrack(const TrackId('ncm-1'))).title,
          ),
          '标题',
        );
        expect(fake.getTrackCalls, 1);

        expect(
          localizedTestValue(
            (await repository.getTrack(const TrackId('ncm-1'))).title,
          ),
          '标题',
        );
        expect(fake.getTrackCalls, 1);
      },
    );

    test('localOnly never touches the network', () async {
      await expectLater(
        repository.getTrack(
          const TrackId('ncm-1'),
          policy: RefreshPolicy.localOnly,
        ),
        throwsA(
          isA<AppError>().having((error) => error.code, 'code', 'cache.miss'),
        ),
      );
      expect(fake.getTrackCalls, 0);

      fake.tracks['ncm-1'] = track('ncm-1');
      await repository.getTrack(const TrackId('ncm-1'));

      expect(
        localizedTestValue(
          (await repository.getTrack(
            const TrackId('ncm-1'),
            policy: RefreshPolicy.localOnly,
          )).title,
        ),
        '标题',
      );
      expect(fake.getTrackCalls, 1);
    });

    test('a differently spelled id hits the same record', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      await repository.getTrack(const TrackId('ncm-1'));

      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('1'))).title,
        ),
        '标题',
      );
      expect(fake.getTrackCalls, 1);
    });

    test('forceRefresh fetches again and a failure moves nothing', () async {
      fake.tracks['ncm-1'] = track('ncm-1', title: '旧');
      await repository.getTrack(const TrackId('ncm-1'));

      fake.tracks['ncm-1'] = track('ncm-1', title: '新');
      expect(
        localizedTestValue(
          (await repository.getTrack(
            const TrackId('ncm-1'),
            policy: RefreshPolicy.forceRefresh,
          )).title,
        ),
        '新',
      );
      expect(fake.getTrackCalls, 2);

      fake.trackFailure = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );
      await expectLater(
        repository.getTrack(
          const TrackId('ncm-1'),
          policy: RefreshPolicy.forceRefresh,
        ),
        throwsA(isA<AppError>()),
      );

      fake.trackFailure = null;
      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('ncm-1'))).title,
        ),
        '新',
      );
      expect(fake.getTrackCalls, 3);
    });

    test(
      'networkFirst falls back to a stale value when the network fails',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');
        await repository.getTrack(const TrackId('ncm-1'));

        now = now.add(const Duration(days: 10));
        fake.failure = const AppError(
          category: AppErrorCategory.network,
          code: 'network.unreachable',
          retryable: true,
        );

        final fallback = await repository.getTrack(
          const TrackId('ncm-1'),
          policy: RefreshPolicy.networkFirst,
        );
        expect(localizedTestValue(fallback.title), '标题');
      },
    );

    test('a stale value is returned while a refresh runs behind it', () async {
      fake.tracks['ncm-1'] = track('ncm-1', title: '旧');
      await repository.getTrack(const TrackId('ncm-1'));

      now = now.add(const Duration(days: 10));
      final updates = <CatalogInvalidation>[];
      final subscription = repository.invalidations.listen(updates.add);
      fake.tracks['ncm-1'] = track('ncm-1', title: '新');

      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('ncm-1'))).title,
        ),
        '旧',
      );
      await pump();

      expect(updates, hasLength(1));
      expect(updates.single.resource, CatalogResource.track);
      expect(updates.single.error, isNull);
      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('ncm-1'))).title,
        ),
        '新',
      );
      await subscription.cancel();
    });

    test('two concurrent reads of one track make one request', () async {
      fake.tracks['ncm-1'] = track('ncm-1');

      final results = await Future.wait([
        repository.getTrack(const TrackId('ncm-1')),
        repository.getTrack(const TrackId('ncm-1')),
      ]);

      expect(
        localizedTestValue(results.map((track) => track.title)),
        everyElement('标题'),
      );
      expect(fake.getTrackCalls, 1);
    });
  });

  test(
    'queue labels keep cached metadata and load missing identities immediately',
    () async {
      fake.tracks['ncm-1'] = track('ncm-1', title: 'Cached');
      await repository.getTrack(const TrackId('ncm-1'));
      fake.tracks['ncm-1'] = track('ncm-1', title: 'Remote');
      fake.tracks['ncm-2'] = track('ncm-2');
      now = now.add(const Duration(days: 2));
      final cached = await repository.getTrack(
        const TrackId('ncm-1'),
        refreshCached: false,
      );
      expect(cached.title, 'Cached');
      final queue = await repository.getTracks([
        const TrackId('ncm-1'),
        const TrackId('ncm-2'),
      ], refreshCached: false);
      expect(queue[const TrackId('ncm-1')]!.title, 'Cached');
      expect(queue[const TrackId('ncm-2')], isNotNull);
      await pump();
      expect(fake.getTrackCalls, 1);
      expect(fake.getTracksCalls, 1);
      expect(fake.calls.last, 'batch:ncm-2');
      await repository.getTrack(
        const TrackId('ncm-1'),
        policy: RefreshPolicy.forceRefresh,
        refreshCached: false,
      );
      expect(fake.getTrackCalls, 2);
    },
  );

  test('queue cache miss loads a single track immediately', () async {
    fake.tracks['ncm-1'] = track('ncm-1');
    final loaded = await repository.getTrack(
      const TrackId('ncm-1'),
      refreshCached: false,
    );
    expect(loaded.id, const TrackId('ncm-1'));
    expect(fake.getTrackCalls, 1);
  });

  group('detail cache marker', () {
    Future<void> seed(Track value, {bool isDetail = false}) async {
      final envelope = CacheEnvelope.fresh(
        scope: context.publicScope,
        at: now,
        window: CacheContentKind.trackDetail.window,
      );
      await store.putTracks([
        CachedTrack(
          track: value,
          groups: {TrackFieldGroup.title: envelope},
          envelope: envelope,

          isDetail: isDetail,
        ),
      ]);
    }

    for (final batch in [false, true]) {
      Future<Track?> read({bool requireDetail = true}) async => batch
          ? (await repository.getTracks(
              [const TrackId('ncm-1')],
              refreshCached: false,
              requireDetail: requireDetail,
            ))[const TrackId('ncm-1')]
          : await repository.getTrack(
              const TrackId('ncm-1'),
              refreshCached: false,
              requireDetail: requireDetail,
            );

      test(
        '${batch ? 'batch' : 'single'} queue accepts summary cache',
        () async {
          await seed(track('ncm-1', title: 'Summary'));
          expect((await read(requireDetail: false))!.title, 'Summary');
          expect(fake.getTrackCalls + fake.getTracksCalls, 0);
        },
      );

      test(
        '${batch ? 'batch' : 'single'} detail loads once despite empty optional fields',
        () async {
          await seed(track('ncm-1', title: 'Summary'));
          fake.tracks['ncm-1'] = track('ncm-1', title: 'Detail');
          expect((await read())!.title, 'Detail');
          final cached = (await store.readTracks(context.publicScope, [
            const TrackId('ncm-1'),
          ])).values.single;
          expect(cached.isDetail, isTrue);
          expect(cached.track.alias, isEmpty);
          expect(cached.track.translationNames, isEmpty);
          expect(cached.track.audioSpecs, isEmpty);
          expect(cached.track.objectiveQuality, isNull);
          expect(cached.track.album.artworkUri, isNull);
          repository.dispose();
          await store.close();
          store = SqliteMetadataCacheStore.open(
            path: '${directory.path}/cache.db',
            now: () => now,
          );
          repository = CachedCatalogRepository(
            remote: fake,
            store: store,
            accountContext: () => context,
            now: () => now,
          );
          expect((await read())!.title, 'Detail');
          expect(fake.getTrackCalls + fake.getTracksCalls, 1);
        },
      );

      test(
        '${batch ? 'batch' : 'single'} failed detail remains a summary and retries',
        () async {
          await seed(track('ncm-1', title: 'Summary'));
          fake.failure = const AppError(
            category: AppErrorCategory.network,
            code: 'offline',
            retryable: true,
          );
          await expectLater(read(), throwsA(isA<AppError>()));
          final cached = (await store.readTracks(context.publicScope, [
            const TrackId('ncm-1'),
          ])).values.single;
          expect(cached.isDetail, isFalse);
          fake.failure = null;
          fake.tracks['ncm-1'] = track('ncm-1', title: 'Detail');
          expect((await read())!.title, 'Detail');
          expect(fake.getTrackCalls + fake.getTracksCalls, 2);
        },
      );
    }

    test('localOnly never enriches a summary', () async {
      const id = TrackId('ncm-1');
      await seed(track(id.value));
      await repository.getTrack(
        id,
        policy: RefreshPolicy.localOnly,
        requireDetail: true,
      );
      await repository.getTracks(
        [id],
        policy: RefreshPolicy.localOnly,
        requireDetail: true,
      );
      expect(fake.getTrackCalls + fake.getTracksCalls, 0);
    });

    test('batch fetches only summaries', () async {
      const complete = TrackId('ncm-1');
      const summary = TrackId('ncm-2');
      await seed(track(complete.value), isDetail: true);
      await seed(track(summary.value));
      fake.tracks[summary.value] = track(summary.value);
      final loaded = await repository.getTracks(
        [complete, summary],
        refreshCached: false,
        requireDetail: true,
      );
      expect(loaded, hasLength(2));
      expect(fake.calls, ['batch:ncm-2']);
    });

    test('search summary merge preserves detail marker and metadata', () async {
      const id = TrackId('ncm-1');
      fake.tracks[id.value] = track(
        id.value,
        artwork: 'https://example.com/cover.jpg',
      );
      await repository.getTrack(id, requireDetail: true);
      fake.searchResult = SearchResult(
        items: [track(id.value)],
        hasMore: false,
      );
      await repository.searchTracks(const SearchQuery(keywords: 'song'));
      final loaded = await repository.getTrack(
        id,
        refreshCached: false,
        requireDetail: true,
      );
      expect(loaded.album.artworkUri, isNotNull);
      expect(fake.getTrackCalls, 1);
      expect(
        (await store.readTracks(context.publicScope, [
          id,
        ])).values.single.isDetail,
        isTrue,
      );
    });
  });

  group('getTracks', () {
    test('asks only for what is missing and then serves from cache', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.tracks['ncm-2'] = track('ncm-2');

      final first = await repository.getTracks([
        const TrackId('ncm-1'),
        const TrackId('ncm-2'),
      ]);
      expect(first, hasLength(2));
      expect(fake.getTracksCalls, 1);
      expect(fake.getTrackCalls, 0, reason: 'the batch reader was used');

      final second = await repository.getTracks([
        const TrackId('ncm-1'),
        const TrackId('ncm-2'),
      ]);
      expect(second, hasLength(2));
      expect(fake.getTracksCalls, 1);
    });

    test(
      'an id a batch omitted is asked again rather than remembered',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');
        fake.tracks['ncm-2'] = track('ncm-2');
        fake.batchAnswers = {const TrackId('ncm-1')};

        final first = await repository.getTracks([
          const TrackId('ncm-1'),
          const TrackId('ncm-2'),
        ]);
        expect(first.keys, [const TrackId('ncm-1')]);

        fake.batchAnswers = null;
        final second = await repository.getTracks([const TrackId('ncm-2')]);
        expect(second.keys, [const TrackId('ncm-2')]);
        expect(fake.getTracksCalls, 2);
      },
    );

    test('an explicit not-found is remembered for minutes', () async {
      fake.trackFailure = const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.trackNotFound',
        retryable: false,
      );
      await expectLater(
        repository.getTrack(const TrackId('ncm-9')),
        throwsA(isA<AppError>()),
      );
      expect(fake.getTrackCalls, 1);

      expect(await repository.getTracks([const TrackId('ncm-9')]), isEmpty);
      expect(fake.getTrackCalls, 1);
      expect(fake.getTracksCalls, 0);
    });

    test('localOnly returns what is cached and nothing else', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      await repository.getTracks([const TrackId('ncm-1')]);

      final cached = await repository.getTracks([
        const TrackId('ncm-1'),
        const TrackId('ncm-2'),
      ], policy: RefreshPolicy.localOnly);
      expect(cached.keys, [const TrackId('ncm-1')]);
      expect(fake.getTracksCalls, 1);
    });
  });

  group('playlists', () {
    test(
      'cached playlist retains full header and refresh updates it',
      () async {
        const id = PlaylistId('ncm-playlist-5');
        const summary = PlaylistSummary(
          id: id,
          title: '歌单',
          subtitle: '作者',
          trackCount: 1,
          playCount: 123,
          creatorNickname: '作者',
        );
        final header = PlaylistHeaderMetadata(
          description: '简介',
          subscribedCount: 42,
          playCount: 123,
          createTime: DateTime.utc(2026, 1, 1),
          tags: const ['摇滚'],
          creator: PlaylistCreator(
            userId: const UserId('7'),
            nickname: '作者',
            avatarUri: Uri.parse('https://example.com/avatar'),
          ),
        );
        fake.tracks['ncm-1'] = track('ncm-1');
        fake.playlist = PlaylistDetail(
          summary: summary,
          header: header,
          tracks: [fake.tracks['ncm-1']!],
        );
        await repository.getPlaylist(id);
        final cached = await repository.getPlaylist(
          id,
          policy: RefreshPolicy.localOnly,
        );
        expect(cached.header.description, '简介');
        expect(cached.header.subscribedCount, 42);
        expect(cached.header.creator!.avatarUri, header.creator!.avatarUri);
        expect(cached.header.createTime, header.createTime);
        expect(cached.header.tags, ['摇滚']);
        expect(cached.summary.playCount, 123);
        fake.playlist = PlaylistDetail(
          summary: summary,
          header: const PlaylistHeaderMetadata(
            description: '',
            subscribedCount: 43,
          ),
          tracks: [fake.tracks['ncm-1']!],
        );
        await repository.getPlaylist(id, policy: RefreshPolicy.networkFirst);
        final updated = await repository.getPlaylist(
          id,
          policy: RefreshPolicy.localOnly,
        );
        expect(updated.header.description, '');
        expect(updated.header.subscribedCount, 43);
      },
    );

    PlaylistDetail detail(List<Track> tracks) => PlaylistDetail(
      summary: const PlaylistSummary(
        id: PlaylistId('ncm-playlist-5'),
        title: '歌单',
        subtitle: '创建者',
        trackCount: 2,
      ),
      tracks: tracks,
    );

    test(
      'mutation invalidation rejects old flight and starts a new resource read',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');
        fake.playlist = detail([fake.tracks['ncm-1']!]);
        const id = PlaylistId('ncm-playlist-5');
        final gate = Completer<void>();
        fake.delay = gate.future;
        final old = repository.getPlaylist(
          id,
          policy: RefreshPolicy.forceRefresh,
        );
        await pump();
        final refused = expectLater(
          old,
          throwsA(
            isA<AppError>().having((e) => e.code, 'code', 'cache.invalidated'),
          ),
        );
        await repository.invalidatePlaylist(id);
        fake.delay = null;
        final fresh = await repository.getPlaylist(id);
        expect(fresh.tracks.single.id, const TrackId('ncm-1'));
        expect(fake.getPlaylistCalls, 2);
        gate.complete();
        await refused;
        expect(
          (await store.readPlaylistSnapshot(
            context.accountScope,
            id,
          ))!.entryTrackIds,
          [const TrackId('ncm-1')],
        );
      },
    );

    test(
      'invalidated local-only reads never issue a network request',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');
        fake.playlist = detail([fake.tracks['ncm-1']!]);
        const id = PlaylistId('ncm-playlist-5');
        await repository.getPlaylist(id);
        await repository.invalidatePlaylist(id);
        await expectLater(
          repository.getPlaylist(id, policy: RefreshPolicy.localOnly),
          throwsA(isA<AppError>()),
        );
        await expectLater(
          repository.getPlaylistTracks(id, policy: RefreshPolicy.localOnly),
          throwsA(isA<AppError>()),
        );
        expect(fake.getPlaylistCalls, 1);
        expect(fake.playlistTracksCalls, 0);
      },
    );
    test('removed persistent snapshot stays absent after reopening', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.playlist = detail([fake.tracks['ncm-1']!]);
      const id = PlaylistId('ncm-playlist-5');
      await repository.getPlaylist(id);
      await repository.invalidatePlaylist(id);
      final reopened = SqliteMetadataCacheStore.open(
        path: '${directory.path}/cache.db',
        now: () => now,
      );
      expect(
        await reopened.readPlaylistSnapshot(context.accountScope, id),
        isNull,
      );
      await reopened.close();
    });

    test(
      'a playlist is fetched once and then served from its snapshot',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');
        fake.tracks['ncm-2'] = track('ncm-2');
        fake.playlist = detail([fake.tracks['ncm-1']!, fake.tracks['ncm-2']!]);

        final first = await repository.getPlaylist(
          const PlaylistId('ncm-playlist-5'),
        );
        expect(first.tracks, hasLength(2));
        expect(first.isPartial, isFalse);
        expect(fake.getPlaylistCalls, 1);

        // Nothing left to serve from the network: a cache read must not need it.
        fake.playlist = null;
        final second = await repository.getPlaylist(
          const PlaylistId('ncm-playlist-5'),
        );
        expect(second.tracks, hasLength(2));
        expect(localizedTestValue(second.summary.title), '歌单');
        expect(fake.getPlaylistCalls, 1);
      },
    );

    test('a playlist response backfills the track cache', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.playlist = detail([fake.tracks['ncm-1']!]);
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));

      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('ncm-1'))).title,
        ),
        '标题',
      );
      expect(fake.getTrackCalls, 0);
    });

    test('localOnly reads the snapshot without the network', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.playlist = detail([fake.tracks['ncm-1']!]);
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));

      await expectLater(
        repository.getPlaylist(
          const PlaylistId('ncm-playlist-9'),
          policy: RefreshPolicy.localOnly,
        ),
        throwsA(
          isA<AppError>().having((error) => error.code, 'code', 'cache.miss'),
        ),
      );

      final cached = await repository.getPlaylist(
        const PlaylistId('ncm-playlist-5'),
        policy: RefreshPolicy.localOnly,
      );
      expect(cached.tracks, hasLength(1));
      expect(fake.getPlaylistCalls, 1);
    });

    test('a playlist one account cached is not readable by another', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.playlist = detail([fake.tracks['ncm-1']!]);

      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'a',
        accountEpoch: 1,
      );
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));

      // A signs out; what it cached is dropped and nothing of it is left for
      // whoever asks next.
      await store.clearAccount('a');

      for (final account in const ['b', 'guest']) {
        context = CatalogCacheContext(
          namespace: 'ncm-test',
          accountId: account,
          accountEpoch: 2,
        );
        await expectLater(
          repository.getPlaylist(
            const PlaylistId('ncm-playlist-5'),
            policy: RefreshPolicy.localOnly,
          ),
          throwsA(
            isA<AppError>().having((error) => error.code, 'code', 'cache.miss'),
          ),
          reason: '$account 不得读到 a 的歌单',
        );
      }
    });

    test('a partial refresh does not shorten a complete snapshot', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.tracks['ncm-2'] = track('ncm-2');
      fake.playlist = detail([fake.tracks['ncm-1']!, fake.tracks['ncm-2']!]);
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));

      now = now.add(const Duration(minutes: 20));
      // The next refresh could only complete one of the two songs.
      fake.playlist = PlaylistDetail(
        summary: detail(const []).summary,
        tracks: [fake.tracks['ncm-1']!],
        isPartial: true,
      );

      await expectLater(
        repository.getPlaylist(
          const PlaylistId('ncm-playlist-5'),
          policy: RefreshPolicy.forceRefresh,
        ),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'cache.playlistRefreshIncomplete',
          ),
        ),
      );

      final cached = await repository.getPlaylist(
        const PlaylistId('ncm-playlist-5'),
        policy: RefreshPolicy.localOnly,
      );
      expect(cached.tracks, hasLength(2), reason: '完整快照必须保留');
      expect(cached.isPartial, isFalse);
    });

    test('a partial refresh is reported on the update stream', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.tracks['ncm-2'] = track('ncm-2');
      fake.playlist = detail([fake.tracks['ncm-1']!, fake.tracks['ncm-2']!]);
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));

      now = now.add(const Duration(minutes: 20));
      fake.playlist = PlaylistDetail(
        summary: detail(const []).summary,
        tracks: [fake.tracks['ncm-1']!],
        isPartial: true,
      );
      final updates = <CatalogInvalidation>[];
      final subscription = repository.invalidations.listen(updates.add);

      // The stale snapshot is what the page keeps; the failure is what the
      // refresh reports.
      final shown = await repository.getPlaylist(
        const PlaylistId('ncm-playlist-5'),
      );
      expect(shown.tracks, hasLength(2));
      await pump();

      expect(updates, hasLength(1));
      expect(updates.single.error?.code, 'cache.playlistRefreshIncomplete');
      await subscription.cancel();
    });

    test('a partial first read is marked incomplete', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.playlist = PlaylistDetail(
        summary: detail(const []).summary,
        tracks: [fake.tracks['ncm-1']!],
        isPartial: true,
      );

      final first = await repository.getPlaylist(
        const PlaylistId('ncm-playlist-5'),
        policy: RefreshPolicy.forceRefresh,
      );
      expect(first.isPartial, isTrue);

      final cached = await repository.getPlaylist(
        const PlaylistId('ncm-playlist-5'),
        policy: RefreshPolicy.localOnly,
      );
      expect(cached.isPartial, isTrue, reason: '没有完整快照可守时，部分结果要明确标记');
      expect(cached.tracks.single.id, const TrackId('ncm-1'));
      expect(fake.playlistTracksCalls, 0);
    });

    test('a page is served from a complete snapshot', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.tracks['ncm-2'] = track('ncm-2');
      fake.playlist = detail([fake.tracks['ncm-1']!, fake.tracks['ncm-2']!]);
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));

      final page = await repository.getPlaylistTracks(
        const PlaylistId('ncm-playlist-5'),
        limit: 1,
        offset: 1,
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.id, const TrackId('ncm-2'));
      expect(fake.playlistTracksCalls, 0);
    });
  });

  group('search', () {
    test(
      'a page is cached and only meaningless whitespace is normalized',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1');
        fake.searchResult = SearchResult(
          items: [fake.tracks['ncm-1']!],
          hasMore: true,
          totalCount: 10,
        );

        final first = await repository.searchTracks(
          const SearchQuery(keywords: ' 海阔天空 '),
        );
        expect(first.items, hasLength(1));
        expect(first.hasMore, isTrue);
        expect(fake.searchCalls, 1);

        final second = await repository.searchTracks(
          const SearchQuery(keywords: '海阔天空'),
        );
        expect(second.items, hasLength(1));
        expect(fake.searchCalls, 1);

        await repository.searchTracks(const SearchQuery(keywords: '别的'));
        expect(fake.searchCalls, 2);
      },
    );

    test('localOnly answers a cached page and misses an unknown one', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.searchResult = SearchResult(
        items: [fake.tracks['ncm-1']!],
        hasMore: false,
      );
      await repository.searchTracks(const SearchQuery(keywords: '歌'));

      final cached = await repository.searchTracks(
        const SearchQuery(keywords: '歌'),
        policy: RefreshPolicy.localOnly,
      );
      expect(cached.items, hasLength(1));

      await expectLater(
        repository.searchTracks(
          const SearchQuery(keywords: '没有缓存'),
          policy: RefreshPolicy.localOnly,
        ),
        throwsA(
          isA<AppError>().having((error) => error.code, 'code', 'cache.miss'),
        ),
      );
    });
  });

  group('in-flight partitions', () {
    SearchResult<Track> oneTrack() =>
        SearchResult(items: [fake.tracks['ncm-1']!], hasMore: false);

    test('a search started by one account is not handed to the next', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.searchResult = oneTrack();
      final gate = Completer<void>();
      fake.delay = gate.future;

      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'b',
        accountEpoch: 1,
      );
      final b = repository.searchTracks(const SearchQuery(keywords: '歌'));
      await pump();

      context = const CatalogCacheContext(
        namespace: 'ncm-test',
        accountId: 'c',
        accountEpoch: 2,
      );
      final c = repository.searchTracks(const SearchQuery(keywords: '歌'));
      gate.complete();

      await expectLater(
        b,
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'cache.invalidated',
          ),
        ),
        reason: '另一个账号的结果不得交给新的调用者',
      );
      final result = await c;
      expect(result.items, hasLength(1));
      expect(fake.searchCalls, 2, reason: '不同账号的同名搜索不得合并成一个请求');
    });

    test(
      'a cached search is not re-published to the account that follows',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1', title: 'A 的歌');
        fake.searchResult = oneTrack();

        // A caches its search page.
        context = const CatalogCacheContext(
          namespace: 'ncm-test',
          accountId: 'a',
          accountEpoch: 1,
        );
        await repository.searchTracks(const SearchQuery(keywords: '歌'));

        // Its refresh is still in flight when the account is switched, and the
        // app drops the outgoing account on the way out.
        now = now.add(const Duration(minutes: 10));
        final gate = Completer<void>();
        fake.delay = gate.future;
        final pending = repository.searchTracks(
          const SearchQuery(keywords: '歌'),
          policy: RefreshPolicy.networkFirst,
        );
        await pump();

        await store.clearAccount('a');
        context = const CatalogCacheContext(
          namespace: 'ncm-test',
          accountId: 'b',
          accountEpoch: 2,
        );
        gate.complete();

        await expectLater(
          pending,
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'cache.invalidated',
            ),
          ),
          reason: '回退不得把上一个账号的搜索结果重新发布',
        );
      },
    );

    test(
      'a cached label is not re-published to the account that follows',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1', title: 'A 的歌');

        context = const CatalogCacheContext(
          namespace: 'ncm-test',
          accountId: 'a',
          accountEpoch: 1,
        );
        await repository.getTrack(const TrackId('ncm-1'));

        now = now.add(const Duration(days: 10));
        final gate = Completer<void>();
        fake.delay = gate.future;
        final pending = repository.getTrack(
          const TrackId('ncm-1'),
          policy: RefreshPolicy.networkFirst,
        );
        await pump();

        context = const CatalogCacheContext(
          namespace: 'ncm-test',
          accountId: 'b',
          accountEpoch: 2,
        );
        gate.complete();

        await expectLater(
          pending,
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'cache.invalidated',
            ),
          ),
        );
      },
    );

    test('a cached search still answers an ordinary network failure', () async {
      fake.tracks['ncm-1'] = track('ncm-1', title: 'A 的歌');
      fake.searchResult = oneTrack();
      await repository.searchTracks(const SearchQuery(keywords: '歌'));

      now = now.add(const Duration(minutes: 10));
      fake.failure = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );

      final fallback = await repository.searchTracks(
        const SearchQuery(keywords: '歌'),
        policy: RefreshPolicy.networkFirst,
      );

      expect(
        localizedTestValue(fallback.items.single.title),
        'A 的歌',
        reason: '真正的网络失败仍要回退到缓存，收紧不能过头',
      );
    });

    test('a search started before a clear is not reused after it', () async {
      fake.tracks['ncm-1'] = track('ncm-1');
      fake.searchResult = oneTrack();
      final gate = Completer<void>();
      fake.delay = gate.future;

      final before = repository.searchTracks(const SearchQuery(keywords: '歌'));
      await pump();

      await store.clearAll();
      final after = repository.searchTracks(const SearchQuery(keywords: '歌'));
      gate.complete();

      await expectLater(
        before,
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'cache.invalidated',
          ),
        ),
      );
      final result = await after;
      expect(result.items, hasLength(1));
      expect(fake.searchCalls, 2, reason: '清理后的新读必须与清理前的请求分离');
    });
  });

  group('controller wiring', () {
    test('a visible search page follows a background refresh', () async {
      final controller = CatalogSearchController(
        repository,
        updates: repository,
      );
      addTearDown(controller.dispose);

      fake.tracks['ncm-1'] = track('ncm-1', title: '旧');
      fake.searchResult = SearchResult(
        items: [fake.tracks['ncm-1']!],
        hasMore: false,
      );
      await controller.search('歌');
      expect(localizedTestValue(controller.current.tracks.single.title), '旧');

      // Past the five-minute fresh window: the page shows and refreshes behind.
      now = now.add(const Duration(days: 1));
      fake.tracks['ncm-1'] = track('ncm-1', title: '新');
      fake.searchResult = SearchResult(
        items: [fake.tracks['ncm-1']!],
        hasMore: false,
      );

      await controller.search('歌');
      expect(localizedTestValue(controller.current.tracks.single.title), '旧');
      await pump();

      expect(localizedTestValue(controller.current.tracks.single.title), '新');
      expect(controller.current.status, SearchStatus.success);
    });

    test('the browsed playlist follows a background refresh', () async {
      final media = FakeMediaController();
      final controller = BrowseAndPlayController(
        repository,
        media,
        updates: repository,
      );
      addTearDown(controller.dispose);

      fake.tracks['ncm-1'] = track('ncm-1');
      fake.playlist = PlaylistDetail(
        summary: const PlaylistSummary(
          id: PlaylistId('ncm-playlist-5'),
          title: '歌单',
          subtitle: '创建者',
          trackCount: 1,
        ),
        tracks: [fake.tracks['ncm-1']!],
      );
      await controller.selectPlaylist(const PlaylistId('ncm-playlist-5'));
      expect(
        localizedTestValue(
          controller.current.selectedPlaylist!.tracks.single.title,
        ),
        '标题',
      );

      now = now.add(const Duration(days: 1));
      fake.tracks['ncm-1'] = track('ncm-1', title: '新');
      fake.playlist = PlaylistDetail(
        summary: const PlaylistSummary(
          id: PlaylistId('ncm-playlist-5'),
          title: '歌单',
          subtitle: '创建者',
          trackCount: 1,
        ),
        tracks: [fake.tracks['ncm-1']!],
      );

      // Any cached read of the now-stale snapshot schedules the refresh.
      await repository.getPlaylist(const PlaylistId('ncm-playlist-5'));
      await pump();

      expect(
        localizedTestValue(
          controller.current.selectedPlaylist!.tracks.single.title,
        ),
        '新',
      );
      expect(controller.current.status, LoadStatus.ready);
    });
  });

  group('generations', () {
    test(
      'a result that lands after the cache was cleared is not written',
      () async {
        fake.tracks['ncm-1'] = track('ncm-1', title: '旧');
        await repository.getTrack(const TrackId('ncm-1'));

        now = now.add(const Duration(days: 10));
        final gate = Completer<void>();
        fake.delay = gate.future;
        fake.tracks['ncm-1'] = track('ncm-1', title: '新');

        expect(
          localizedTestValue(
            (await repository.getTrack(const TrackId('ncm-1'))).title,
          ),
          '旧',
        );

        await store.clearAll();
        gate.complete();
        await pump();

        expect(
          await store.readTracks(context.publicScope, [const TrackId('ncm-1')]),
          isEmpty,
          reason: 'a late answer must not refill a cleared cache',
        );
      },
    );

    test('a failed refresh is reported without moving the value', () async {
      fake.tracks['ncm-1'] = track('ncm-1', title: '旧');
      await repository.getTrack(const TrackId('ncm-1'));

      now = now.add(const Duration(days: 10));
      final updates = <CatalogInvalidation>[];
      final subscription = repository.invalidations.listen(updates.add);
      fake.failure = const AppError(
        category: AppErrorCategory.network,
        code: 'network.timeout',
        retryable: true,
      );

      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('ncm-1'))).title,
        ),
        '旧',
      );
      await pump();

      expect(updates, hasLength(1));
      expect(updates.single.error?.code, 'network.timeout');
      expect(
        localizedTestValue(
          (await repository.getTrack(const TrackId('ncm-1'))).title,
        ),
        '旧',
      );
      await subscription.cancel();
    });

    group('new capabilities and caching', () {
      test(
        'search delegates to searchTracks when searchType is track and remote lacks CatalogSearchRepository',
        () async {
          fake.tracks['ncm-1'] = track('ncm-1', title: 'Song 1');
          fake.searchResult = SearchResult(
            items: [fake.tracks['ncm-1']!],
            hasMore: false,
          );

          final res = await repository.search(
            const SearchQuery(keywords: 'Song', type: 1),
          );
          expect(res.items, hasLength(1));
          expect(res.items.first, isA<TrackItem>());
          expect((res.items.first as TrackItem).track.title, 'Song 1');
        },
      );

      test(
        'search throws provider.unsupported when searchType is non-track and remote lacks CatalogSearchRepository',
        () async {
          await expectLater(
            repository.search(const SearchQuery(keywords: 'Album', type: 10)),
            throwsA(
              isA<AppError>().having(
                (e) => e.code,
                'code',
                'provider.unsupported',
              ),
            ),
          );
        },
      );

      test(
        'getAlbum and getArtist throw provider.unsupported when remote lacks CatalogDetailRepository',
        () async {
          await expectLater(
            repository.getAlbum(const AlbumId('al-1')),
            throwsA(
              isA<AppError>().having(
                (e) => e.code,
                'code',
                'provider.unsupported',
              ),
            ),
          );
          await expectLater(
            repository.getArtist(const ArtistId('ar-1')),
            throwsA(
              isA<AppError>().having(
                (e) => e.code,
                'code',
                'provider.unsupported',
              ),
            ),
          );
        },
      );

      test(
        'guest home recommendations require login without caching',
        () async {
          final fullRepo = CachedCatalogRepository(
            remote: _FullFakeCatalog(),
            store: store,
            accountContext: () => context,
            now: () => now,
          );
          addTearDown(fullRepo.dispose);
          final section = await fullRepo.getHomeSection(
            HomeSectionKind.recommended,
          );
          expect(section.status, HomeSectionStatus.requiresAuth);
          expect(section.playlists, isEmpty);
          expect(await store.readHomeSections(context.accountScope), isEmpty);
        },
      );

      test(
        'full remote caches album, artist, and home sections in SQLite store',
        () async {
          context = const CatalogCacheContext(
            namespace: 'ncm-test',
            accountId: 'signed-in-user',
            accountEpoch: 1,
          );
          final fullFake = _FullFakeCatalog();
          final fullRepo = CachedCatalogRepository(
            remote: fullFake,
            store: store,
            accountContext: () => context,
            now: () => now,
          );
          addTearDown(fullRepo.dispose);

          // 1. getAlbum caches summary into catalog entities and tracks into tracks
          final albumDetail = await fullRepo.getAlbum(
            const AlbumId('ncm-album-100'),
          );
          expect(albumDetail.summary.title, 'Test Album');
          expect(albumDetail.tracks, hasLength(1));

          final cachedAlbum = await store.readCatalogEntities(
            context.publicScope,
            'album',
            ['ncm-album-100'],
          );
          expect(cachedAlbum, contains('ncm-album-100'));

          // 2. getArtist caches summary into catalog entities
          final artistDetail = await fullRepo.getArtist(
            const ArtistId('ncm-artist-200'),
          );
          expect(artistDetail.summary.name, 'Test Artist');
          expect(artistDetail.tracks, hasLength(1));
          final summaries = await store.readTracks(context.publicScope, [
            ...albumDetail.tracks.map((track) => canonicalTrackId(track.id)),
            ...artistDetail.tracks.map((track) => canonicalTrackId(track.id)),
          ]);
          expect(summaries, hasLength(2));
          expect(summaries.values.every((record) => !record.isDetail), isTrue);

          final cachedArtist = await store.readCatalogEntities(
            context.publicScope,
            'artist',
            ['ncm-artist-200'],
          );
          expect(cachedArtist, contains('ncm-artist-200'));

          // 3. getHomeSection caches section in SQLite store
          final section = await fullRepo.getHomeSection(
            HomeSectionKind.recommended,
          );
          expect(section.status, HomeSectionStatus.ready);
          expect(section.playlists, hasLength(1));

          final cachedSections = await store.readHomeSections(
            context.accountScope,
          );
          expect(cachedSections, contains(HomeSectionKind.recommended));
        },
      );
    });
  });
}

final class _FakeCatalog implements CatalogRepository, TrackBatchReader {
  final Map<String, Track> tracks = {};
  final List<String> calls = [];

  int getTrackCalls = 0;
  int getTracksCalls = 0;
  int getPlaylistCalls = 0;
  int searchCalls = 0;
  int playlistTracksCalls = 0;

  /// When set, every call fails with it.
  AppError? failure;

  /// When set, only `getTrack` fails with it.
  AppError? trackFailure;

  /// When set, `getTracks` answers only these ids.
  Set<TrackId>? batchAnswers;

  /// When set, every call waits for it first.
  Future<void>? delay;

  PlaylistDetail? playlist;
  SearchResult<Track> searchResult = const SearchResult(
    items: [],
    hasMore: false,
  );

  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const HomeFeed(greeting: '', playlists: []);

  @override
  Future<Track> getTrack(TrackId id) async {
    getTrackCalls++;
    calls.add('track:${id.value}');
    if (delay != null) await delay;
    final error = trackFailure ?? failure;
    if (error != null) throw error;
    final found = tracks[id.value];
    if (found == null) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.trackNotFound',
        retryable: false,
      );
    }
    return found;
  }

  @override
  Future<Map<TrackId, Track>> getTracks(Iterable<TrackId> ids) async {
    getTracksCalls++;
    calls.add('batch:${ids.map((id) => id.value).join(',')}');
    if (delay != null) await delay;
    final error = failure;
    if (error != null) throw error;
    final answer = batchAnswers;
    return {
      for (final id in ids)
        if (tracks[id.value] != null && (answer == null || answer.contains(id)))
          id: tracks[id.value]!,
    };
  }

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    getPlaylistCalls++;
    calls.add('playlist:${id.value}');
    if (delay != null) await delay;
    final error = failure;
    if (error != null) throw error;
    final found = playlist;
    if (found == null) {
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.playlistNotFound',
        retryable: false,
      );
    }
    return found;
  }

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async {
    searchCalls++;
    calls.add('search:${query.keywords.trim()}');
    if (delay != null) await delay;
    final error = failure;
    if (error != null) throw error;
    return searchResult;
  }

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    playlistTracksCalls++;
    calls.add('playlistTracks:${id.value}:$limit:$offset');
    if (delay != null) await delay;
    final error = failure;
    if (error != null) throw error;
    return const SearchResult(items: [], hasMore: false);
  }

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return PlaylistAccessVerdict(
      namespace: 'ncm',
      target: id,
      state: PlaylistAccessState.publicConfirmed,
      evidenceMode: RequestAuthMode.establishedSession,
      evidenceKind: 'test',
      fetchedAt: DateTime(2026),
      freshUntil: DateTime(2099),
    );
  }
}

final class _FullFakeCatalog extends _FakeCatalog
    implements
        CatalogSearchRepository,
        HomeFeedRepository,
        CatalogDetailRepository {
  @override
  Future<SearchResult<CatalogItem>> search(SearchQuery query) async {
    return const SearchResult(items: [], hasMore: false);
  }

  @override
  Future<HomeSection> getHomeSection(
    HomeSectionKind kind, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    return HomeSection(
      kind: kind,
      title: kind.name,
      status: HomeSectionStatus.ready,
      playlists: const [
        PlaylistSummary(
          id: PlaylistId('ncm-playlist-1'),
          title: 'Section Playlist',
          subtitle: 'Sub',
          trackCount: 5,
        ),
      ],
    );
  }

  @override
  Future<AlbumDetail> getAlbum(AlbumId id) async {
    return AlbumDetail(
      summary: AlbumSummary(
        id: id,
        title: 'Test Album',
        artistName: 'Artist',
        trackCount: 1,
      ),
      tracks: [
        Track(
          id: const TrackId('ncm-track-1'),
          title: 'Album Song',
          artists: const [Artist(id: ArtistId('ar-1'), name: 'Artist')],
          album: Album(id: id, title: 'Test Album'),
          duration: const Duration(seconds: 200),
        ),
      ],
    );
  }

  @override
  Future<ArtistDetail> getArtist(ArtistId id) async {
    return ArtistDetail(
      summary: ArtistSummary(id: id, name: 'Test Artist', trackCount: 1),
      tracks: [
        Track(
          id: const TrackId('ncm-track-2'),
          title: 'Hot Song',
          artists: [Artist(id: id, name: 'Test Artist')],
          album: const Album(id: AlbumId('al-2'), title: 'Album 2'),
          duration: const Duration(seconds: 200),
        ),
      ],
    );
  }
}
