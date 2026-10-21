import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late DateTime now;

  const publicScope = CacheScope.public(namespace: 'ncm-test');
  const accountA = CacheScope(namespace: 'ncm-test', accountId: 'a');
  const accountB = CacheScope(namespace: 'ncm-test', accountId: 'b');

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ff-cache-store');
    databasePath = '${directory.path}/cache.db';
    now = DateTime.utc(2026, 9, 28, 12);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  MetadataCacheStore openStore({DateTime Function()? clock}) =>
      SqliteMetadataCacheStore.open(
        path: databasePath,
        now: clock ?? () => now,
      );

  test('closed stores reject late work and close is idempotent', () async {
    final store = openStore();
    final generation = store.cacheGeneration;
    await store.close();
    expect(store.cacheGeneration, greaterThan(generation));
    expect(await store.readArtworkIndex(publicScope, 'late-cover'), isNull);
    await store.deleteArtworkIndex(publicScope, 'late-cover');
    await store.close();
  });

  CachedTrack trackRecord(
    String id, {
    CacheScope scope = publicScope,
    DateTime? at,
    String title = '标题',
    String? artworkUri,
    Set<TrackFieldGroup>? groups,
  }) {
    final fetchedAt = at ?? now;
    // A response names a group only when it actually carried it; artwork is
    // named when the URI is present, and a caller may override the set to model
    // an explicit clear or a partial row.
    final effectiveGroups =
        groups ??
        {
          TrackFieldGroup.title,
          TrackFieldGroup.artists,
          TrackFieldGroup.album,
          TrackFieldGroup.duration,
          if (artworkUri != null) TrackFieldGroup.artwork,
        };
    final envelope = CacheEnvelope.fresh(
      scope: scope,
      at: fetchedAt,
      window: CacheContentKind.trackDetail.window,
    );
    return CachedTrack(
      track: Track(
        id: TrackId(id),
        title: title,
        artists: const [Artist(id: ArtistId('artist-1'), name: '艺人')],
        album: Album(
          id: const AlbumId('album-1'),
          title: '专辑',
          artworkUri: artworkUri == null ? null : Uri.parse(artworkUri),
        ),
        duration: const Duration(minutes: 3),
      ),
      groups: {
        for (final group in effectiveGroups)
          group: group == TrackFieldGroup.artwork
              ? CacheEnvelope.fresh(
                  scope: scope,
                  at: fetchedAt,
                  window: CacheContentKind.artwork.window,
                )
              : envelope,
      },
      envelope: envelope,
    );
  }

  PlaylistSnapshot snapshot({
    List<String> entries = const ['t1', 't2', 't1'],
    int generation = 1,
    bool isComplete = true,
    CacheScope scope = publicScope,
    DateTime? at,
  }) => PlaylistSnapshot(
    summary: const PlaylistSummary(
      id: PlaylistId('ncm-playlist-1'),
      title: '歌单',
      subtitle: '创建者',
      trackCount: 3,
    ),
    entryTrackIds: [for (final id in entries) TrackId(id)],
    isComplete: isComplete,
    totalCount: 3,
    generation: generation,
    envelope: CacheEnvelope.fresh(
      scope: scope,
      at: at ?? now,
      window: CacheContentKind.playlistEntries.window,
    ),
  );

  test(
    'playlist ownership and privacy round-trip and resource removal is account scoped',
    () async {
      final store = openStore();
      final at = now;
      PlaylistSnapshot owned(CacheScope scope) => PlaylistSnapshot(
        summary: const PlaylistSummary(
          id: PlaylistId('ncm-playlist-1'),
          title: '私密',
          subtitle: '',
          trackCount: 0,
          creatorId: UserId('42'),
          privacy: 10,
        ),
        entryTrackIds: [],
        isComplete: true,
        totalCount: 0,
        generation: 1,
        envelope: CacheEnvelope.fresh(
          scope: scope,
          at: at,
          window: CacheContentKind.playlistEntries.window,
        ),
      );
      await store.commitPlaylistSnapshot(owned(accountA));
      await store.commitPlaylistSnapshot(owned(accountB));
      final p = await store.readPlaylistSnapshot(
        accountA,
        const PlaylistId('ncm-playlist-1'),
      );
      expect(p!.summary.creatorId, const UserId('42'));
      expect(p.summary.privacy, 10);
      await (store as PlaylistCacheInvalidator).invalidatePlaylistSnapshot(
        accountA,
        const PlaylistId('ncm-playlist-1'),
      );
      expect(
        await store.readPlaylistSnapshot(
          accountA,
          const PlaylistId('ncm-playlist-1'),
        ),
        isNull,
      );
      expect(
        await store.readPlaylistSnapshot(
          accountB,
          const PlaylistId('ncm-playlist-1'),
        ),
        isNotNull,
      );
      await store.close();
    },
  );

  test(
    'v3 migration preserves display tracks and treats missing ownership as unknown',
    () async {
      final store = openStore();
      await store.putTracks([trackRecord('t1')]);
      await store.commitPlaylistSnapshot(snapshot(scope: accountA));
      await store.close();
      final raw = sqlite3.open(databasePath);
      final table =
          raw
                  .select(
                    "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%special_type%'",
                  )
                  .single['name']
              as String;
      raw.execute('ALTER TABLE $table DROP COLUMN creator_id');
      raw.execute('ALTER TABLE $table DROP COLUMN privacy');
      raw.execute('ALTER TABLE $table DROP COLUMN metadata_json');
      final trackTable =
          raw
                  .select(
                    "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%audio_specs_json%'",
                  )
                  .single['name']
              as String;
      raw.execute('ALTER TABLE $trackTable DROP COLUMN audio_specs_json');
      raw.execute('ALTER TABLE $trackTable DROP COLUMN translation_names_json');
      raw.execute('ALTER TABLE $trackTable DROP COLUMN is_detail');
      raw.execute('ALTER TABLE $trackTable ADD COLUMN origin TEXT');
      raw.userVersion = 3;
      raw.dispose();
      final migrated = openStore();
      expect(
        await migrated.readTracks(publicScope, [const TrackId('t1')]),
        isNotEmpty,
      );
      final old = await migrated.readPlaylistSnapshot(
        accountA,
        const PlaylistId('ncm-playlist-1'),
      );
      expect(old, isNotNull);
      expect(old!.summary.creatorId, isNull);
      expect(old.summary.privacy, isNull);
      await migrated.close();
    },
  );

  test('v8 migration removes origin and preserves detail markers', () async {
    final store = openStore();
    final record = trackRecord('t1');
    await store.putTracks([
      CachedTrack(
        track: record.track,
        groups: record.groups,
        envelope: record.envelope,
        isDetail: true,
      ),
    ]);
    await store.close();
    final raw = sqlite3.open(databasePath);
    raw.execute('ALTER TABLE cache_tracks ADD COLUMN origin TEXT');
    raw.execute("UPDATE cache_tracks SET origin = 'searchResult'");
    raw.userVersion = 8;
    raw.dispose();
    final migrated = openStore();
    final cached = (await migrated.readTracks(publicScope, [
      const TrackId('t1'),
    ])).values.single;
    expect(cached.isDetail, isTrue);
    expect(cached.track.title, '标题');
    await migrated.close();
    final check = sqlite3.open(databasePath);
    expect(
      check
          .select('PRAGMA table_info(cache_tracks)')
          .any((row) => row['name'] == 'origin'),
      isFalse,
    );
    expect(check.userVersion, SqliteMetadataCacheStore.schemaVersion);
    check.dispose();
  });

  test(
    'v7 migration preserves summaries without guessing detail provenance',
    () async {
      final store = openStore();
      await store.putTracks([trackRecord('t1')]);
      await store.close();
      final raw = sqlite3.open(databasePath);
      raw.execute('ALTER TABLE cache_tracks DROP COLUMN is_detail');
      raw.execute('ALTER TABLE cache_tracks ADD COLUMN origin TEXT');
      raw.execute("UPDATE cache_tracks SET origin = 'detail'");
      raw.userVersion = 7;
      raw.dispose();
      final migrated = openStore();
      final cached = (await migrated.readTracks(publicScope, [
        const TrackId('t1'),
      ])).values.single;
      expect(cached.track.title, '标题');
      expect(cached.isDetail, isFalse);
      await migrated.close();
    },
  );

  test(
    'detail marker persists across reopen and survives summary merges',
    () async {
      var store = openStore();
      final record = trackRecord(
        't1',
        artworkUri: 'https://example.com/cover.jpg',
      );
      await store.putTracks([
        CachedTrack(
          track: record.track,
          groups: record.groups,
          envelope: record.envelope,
          isDetail: true,
        ),
      ]);
      await store.putTracks([trackRecord('t1', title: 'Summary')]);
      await store.close();
      store = openStore();
      final cached = (await store.readTracks(publicScope, [
        const TrackId('t1'),
      ])).values.single;
      expect(cached.isDetail, isTrue);
      expect(cached.track.album.artworkUri, record.track.album.artworkUri);
      await store.close();
    },
  );

  test(
    'v6 migration keeps tracks and allows translation names to be filled',
    () async {
      final store = openStore();
      await store.putTracks([trackRecord('t1')]);
      await store.close();
      final raw = sqlite3.open(databasePath);
      final table =
          raw
                  .select(
                    "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%translation_names_json%'",
                  )
                  .single['name']
              as String;
      raw.execute('ALTER TABLE $table DROP COLUMN translation_names_json');
      raw.execute('ALTER TABLE $table DROP COLUMN is_detail');
      raw.execute('ALTER TABLE $table ADD COLUMN origin TEXT');
      raw.userVersion = 6;
      raw.dispose();
      final migrated = openStore();
      final old = (await migrated.readTracks(publicScope, [
        const TrackId('t1'),
      ])).values.single;
      expect(old.track.title, '标题');
      expect(old.track.translationNames, isEmpty);
      final source = old.track;
      final envelope = old.envelope;
      await migrated.putTracks([
        CachedTrack(
          track: Track(
            id: source.id,
            title: source.title,
            artists: source.artists,
            album: source.album,
            duration: source.duration,
            translationNames: ['译名'],
          ),
          groups: {TrackFieldGroup.translationNames: envelope},
          envelope: envelope,
        ),
      ]);
      final filled = (await migrated.readTracks(publicScope, [
        source.id,
      ])).values.single;
      expect(filled.track.title, '标题');
      expect(filled.track.translationNames, ['译名']);
      expect(filled.knows(TrackFieldGroup.translationNames), isTrue);
      await migrated.close();
    },
  );

  group('tracks', () {
    test('a record round-trips with its field groups', () async {
      final store = openStore();
      await store.putTracks([
        trackRecord('t1', artworkUri: 'https://cdn/1.jpg'),
      ]);

      final read = await store.readTracks(publicScope, [const TrackId('t1')]);

      final cached = read[const TrackId('t1')]!;
      expect(cached.track.title, '标题');
      expect(cached.track.artistLabel, '艺人');
      expect(cached.track.album.id.value, 'album-1');
      expect(cached.track.duration, const Duration(minutes: 3));
      expect(cached.knows(TrackFieldGroup.duration), isTrue);
      await store.close();
    });

    test('survives a restart on disk', () async {
      final first = openStore();
      await first.putTracks([trackRecord('t1')]);
      await first.close();

      final second = openStore();
      final read = await second.readTracks(publicScope, [const TrackId('t1')]);
      expect(read.keys, [const TrackId('t1')]);
      await second.close();
    });

    test('a row that omitted artwork neither loses nor refreshes it', () async {
      final store = openStore();
      await store.putTracks([
        trackRecord('t1', artworkUri: 'https://cdn/1.jpg'),
      ]);

      final later = now.add(const Duration(hours: 2));
      await store.putTracks([trackRecord('t1', at: later, title: '新标题')]);

      final cached = (await store.readTracks(publicScope, [
        const TrackId('t1'),
      ]))[const TrackId('t1')]!;
      expect(cached.track.title, '新标题');
      expect(cached.track.album.artworkUri.toString(), 'https://cdn/1.jpg');
      // The artwork group keeps the time it was actually told.
      expect(
        cached.groups[TrackFieldGroup.artwork]!.fetchedAt,
        DateTime.utc(2026, 9, 28, 12),
      );
      expect(cached.groups[TrackFieldGroup.title]!.fetchedAt, later);
      await store.close();
    });

    test(
      'a row that carried only artwork keeps the labels it omitted',
      () async {
        final store = openStore();
        await store.putTracks([
          trackRecord('t1', artworkUri: 'https://cdn/1.jpg'),
        ]);

        final later = now.add(const Duration(hours: 2));
        // A response that knew the cover and nothing else: it names the artwork
        // group, so that group is refreshed — and no other group may be touched
        // by values this response never carried.
        await store.putTracks([
          trackRecord(
            't1',
            at: later,
            title: '',
            artworkUri: 'https://cdn/2.jpg',
            groups: const {TrackFieldGroup.artwork},
          ),
        ]);

        final cached = (await store.readTracks(publicScope, [
          const TrackId('t1'),
        ]))[const TrackId('t1')];

        expect(cached, isNotNull, reason: '局部更新不得让歌曲变得不可读');
        expect(cached!.track.title, '标题');
        expect(cached.track.artistLabel, '艺人');
        expect(cached.track.album.id.value, 'album-1');
        expect(cached.track.album.title, '专辑');
        expect(cached.track.duration, const Duration(minutes: 3));
        expect(cached.track.album.artworkUri.toString(), 'https://cdn/2.jpg');
        expect(cached.groups[TrackFieldGroup.artwork]!.fetchedAt, later);
        expect(
          cached.groups[TrackFieldGroup.title]!.fetchedAt,
          DateTime.utc(2026, 9, 28, 12),
          reason: '未被声明的组连新鲜度也不能动',
        );
        await store.close();
      },
    );

    test(
      'a row that carried only a title keeps the cover and the length',
      () async {
        final store = openStore();
        await store.putTracks([
          trackRecord('t1', artworkUri: 'https://cdn/1.jpg'),
        ]);

        final later = now.add(const Duration(hours: 2));
        await store.putTracks([
          trackRecord(
            't1',
            at: later,
            title: '新标题',
            groups: const {TrackFieldGroup.title},
          ),
        ]);

        final cached = (await store.readTracks(publicScope, [
          const TrackId('t1'),
        ]))[const TrackId('t1')]!;

        expect(cached.track.title, '新标题');
        expect(cached.track.album.artworkUri.toString(), 'https://cdn/1.jpg');
        expect(cached.track.duration, const Duration(minutes: 3));
        expect(cached.groups[TrackFieldGroup.title]!.fetchedAt, later);
        expect(
          cached.groups[TrackFieldGroup.duration]!.fetchedAt,
          DateTime.utc(2026, 9, 28, 12),
        );
        await store.close();
      },
    );

    test('an explicitly empty artwork group clears the stored one', () async {
      final store = openStore();
      await store.putTracks([
        trackRecord('t1', artworkUri: 'https://cdn/1.jpg'),
      ]);
      await store.putTracks([
        trackRecord('t1', groups: const {TrackFieldGroup.artwork}),
      ]);

      final cached = (await store.readTracks(publicScope, [
        const TrackId('t1'),
      ]))[const TrackId('t1')]!;
      expect(cached.track.album.artworkUri, isNull);
      await store.close();
    });

    test(
      'a row past its maximum display age is a miss unless asked for',
      () async {
        final store = openStore();
        final old = now.subtract(const Duration(days: 120));
        await store.putTracks([trackRecord('t1', at: old)]);

        expect(
          await store.readTracks(publicScope, [const TrackId('t1')]),
          isEmpty,
        );
        final history = await store.readTracks(publicScope, [
          const TrackId('t1'),
        ], includeExpired: true);
        expect(history[const TrackId('t1')]!.track.title, '标题');
        await store.close();
      },
    );

    test('account scopes never read each other', () async {
      final store = openStore();
      await store.putTracks([trackRecord('a1', scope: accountA)]);

      expect(await store.readTracks(accountB, [const TrackId('a1')]), isEmpty);
      expect(
        await store.readTracks(publicScope, [const TrackId('a1')]),
        isEmpty,
      );
      expect(
        (await store.readTracks(accountA, [const TrackId('a1')])).length,
        1,
      );
      await store.close();
    });
  });

  group('negative cache', () {
    test(
      'a written absence is returned and only believed while fresh',
      () async {
        final store = openStore();
        final record = AbsentTrackRecord(
          trackId: const TrackId('gone'),
          envelope: CacheEnvelope.fresh(
            scope: publicScope,
            at: now,
            window: CacheContentKind.absentTrack.window,
          ),
        );
        await store.putAbsentTracks([record]);

        final read = await store.readAbsentTracks(publicScope, [
          const TrackId('gone'),
        ]);
        expect(read[const TrackId('gone')]!.isBelievableAt(now), isTrue);
        expect(
          read[const TrackId('gone')]!.isBelievableAt(
            now.add(const Duration(minutes: 6)),
          ),
          isFalse,
        );
        await store.close();
      },
    );
  });

  group('playlists', () {
    test('a commit replaces the membership and keeps duplicates', () async {
      final store = openStore();
      await store.commitPlaylistSnapshot(snapshot(entries: ['t1', 't2', 't1']));

      final first = await store.readPlaylistSnapshot(
        publicScope,
        const PlaylistId('ncm-playlist-1'),
      );
      expect(first!.entryTrackIds.map((id) => id.value), ['t1', 't2', 't1']);

      await store.commitPlaylistSnapshot(
        snapshot(entries: ['t9'], generation: 2),
      );
      final second = await store.readPlaylistSnapshot(
        publicScope,
        const PlaylistId('ncm-playlist-1'),
      );
      expect(second!.entryTrackIds.map((id) => id.value), ['t9']);
      expect(second.generation, 2);
      await store.close();
    });

    test('an old snapshot stops being readable past its maximum age', () async {
      final store = openStore();
      final old = now.subtract(const Duration(days: 8));
      await store.commitPlaylistSnapshot(snapshot(at: old));

      expect(
        await store.readPlaylistSnapshot(
          publicScope,
          const PlaylistId('ncm-playlist-1'),
        ),
        isNull,
      );
      expect(
        await store.readPlaylistSnapshot(
          publicScope,
          const PlaylistId('ncm-playlist-1'),
          includeExpired: true,
        ),
        isNotNull,
      );
      await store.close();
    });

    test('a sign-out keeps a public snapshot', () async {
      final store = openStore();
      await store.commitPlaylistSnapshot(snapshot());
      await store.commitPlaylistSnapshot(
        snapshot(scope: accountA, generation: 5),
      );

      await store.clearAccount('a');

      expect(
        await store.readPlaylistSnapshot(
          publicScope,
          const PlaylistId('ncm-playlist-1'),
        ),
        isNotNull,
      );
      expect(
        await store.readPlaylistSnapshot(
          accountA,
          const PlaylistId('ncm-playlist-1'),
        ),
        isNull,
      );
      await store.close();
    });
  });

  group('paged lists', () {
    test('a user playlist page round-trips in order', () async {
      final store = openStore();
      await store.putUserPlaylistPage(
        queryKey: 'all',
        page: CachedIdPage<PlaylistId>(
          ids: const [PlaylistId('p1'), PlaylistId('p2')],
          offset: 0,
          limit: 30,
          hasMore: true,
          isComplete: true,
          generation: 3,
          envelope: CacheEnvelope.fresh(
            scope: accountA,
            at: now,
            window: CacheContentKind.userPlaylists.window,
          ),
        ),
      );

      final page = await store.readUserPlaylistPage(
        scope: accountA,
        queryKey: 'all',
        offset: 0,
      );
      expect(page!.ids.map((id) => id.value), ['p1', 'p2']);
      expect(page.hasMore, isTrue);
      expect(page.generation, 3);
      await store.close();
    });

    test('pruning keeps only the active generation', () async {
      final store = openStore();
      for (final generation in [1, 2]) {
        await store.putSearchPage(
          queryKey: 'q',
          page: CachedIdPage<TrackId>(
            ids: [TrackId('t$generation')],
            offset: 0,
            limit: 30,
            hasMore: false,
            isComplete: true,
            generation: generation,
            envelope: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.searchResults.window,
            ),
          ),
        );
      }
      // Only generation 2 remains after the newer page is written.
      await store.pruneIdPages(
        scope: publicScope,
        queryKey: 'q',
        generation: 2,
        kind: 'search',
      );

      final page = await store.readSearchPage(
        scope: publicScope,
        queryKey: 'q',
        offset: 0,
      );
      expect(page!.generation, 2);
      expect(page.ids.map((id) => id.value), ['t2']);
      await store.close();
    });
  });

  group('artwork index', () {
    test('an index row round-trips and clearAll hands back its file', () async {
      final store = openStore();
      await store.putArtworkIndex(
        ArtworkIndexEntry(
          assetKey: 'asset-1|v1|256',
          filePath: 'assets/aa/bb.jpg',
          byteSize: 2048,
          sha256: 'deadbeef',
          mimeType: 'image/jpeg',
          pixelWidth: 256,
          pixelHeight: 256,
          sizeBucket: ArtworkSizeBucket.px256,
          envelope: CacheEnvelope.fresh(
            scope: publicScope,
            at: now,
            window: CacheContentKind.artwork.window,
          ),
        ),
      );

      final entry = await store.readArtworkIndex(publicScope, 'asset-1|v1|256');
      expect(entry!.filePath, 'assets/aa/bb.jpg');
      expect(entry.sizeBucket, ArtworkSizeBucket.px256);
      expect((await store.stats()).artworkBytes, 2048);

      final orphaned = await store.clearAll();
      expect(orphaned, ['assets/aa/bb.jpg']);
      expect((await store.stats()).artworkIndexCount, 0);
      await store.close();
    });
  });

  group('lifecycle', () {
    test('clearAll advances the generation and drops every record', () async {
      final store = openStore();
      final before = store.cacheGeneration;
      await store.putTracks([trackRecord('t1')]);

      await store.clearAll();

      expect(store.cacheGeneration, before + 1);
      expect(
        await store.readTracks(publicScope, [const TrackId('t1')]),
        isEmpty,
      );
      expect((await store.stats()).trackCount, 0);
      await store.close();
    });

    test('enforceBudget evicts the least recently fetched rows', () async {
      final store = openStore();
      await store.putTracks([
        trackRecord('oldest', at: now.subtract(const Duration(hours: 3))),
        trackRecord('middle', at: now.subtract(const Duration(hours: 2))),
        trackRecord('newest', at: now.subtract(const Duration(hours: 1))),
      ]);
      final before = await store.stats();
      expect(before.trackCount, 3);

      await store.enforceBudget(
        budgetBytes: (before.metadataBytes / 2).floor(),
      );

      final after = await store.stats();
      expect(after.trackCount, lessThan(3));
      final remaining = await store.readTracks(publicScope, [
        const TrackId('oldest'),
        const TrackId('middle'),
        const TrackId('newest'),
      ]);
      expect(remaining.containsKey(const TrackId('oldest')), isFalse);
      await store.close();
    });

    test(
      'enforceBudget keeps pinned labels inside their protection cap',
      () async {
        final store = openStore();
        await store.putTracks([
          trackRecord('oldest', at: now.subtract(const Duration(hours: 3))),
          trackRecord('middle', at: now.subtract(const Duration(hours: 2))),
          trackRecord('newest', at: now.subtract(const Duration(hours: 1))),
        ]);

        await store.enforceBudget(
          budgetBytes: 1,
          pinnedTrackIds: {const TrackId('oldest')},
        );

        // The pinned row outlives its unpinned neighbours within the cap.
        expect(
          await store.readTracks(publicScope, [const TrackId('oldest')]),
          isNotEmpty,
        );
        await store.close();
      },
    );
  });

  group('integrity', () {
    test('a database from a newer schema is rebuilt, not guessed at', () async {
      final first = openStore();
      await first.putTracks([trackRecord('t1')]);
      await first.close();

      final raw = sqlite3.open(databasePath);
      raw.userVersion = 99;
      raw.dispose();

      final rebuilt = openStore();
      expect(
        await rebuilt.readTracks(publicScope, [const TrackId('t1')]),
        isEmpty,
        reason: 'an unknown schema is disposable',
      );
      await rebuilt.putTracks([trackRecord('t1')]);
      expect(
        await rebuilt.readTracks(publicScope, [const TrackId('t1')]),
        isNotEmpty,
      );
      await rebuilt.close();
    });

    test('a malformed page row reads as an empty page', () async {
      final store = openStore();
      await store.putUserPlaylistPage(
        queryKey: 'all',
        page: CachedIdPage<PlaylistId>(
          ids: const [PlaylistId('p1')],
          offset: 0,
          limit: 30,
          hasMore: false,
          isComplete: true,
          envelope: CacheEnvelope.fresh(
            scope: accountA,
            at: now,
            window: CacheContentKind.userPlaylists.window,
          ),
        ),
      );
      await store.close();

      final raw = sqlite3.open(databasePath);
      raw.execute("UPDATE cache_id_pages SET ids_json = '{'");
      raw.dispose();

      final reopened = openStore();
      final page = await reopened.readUserPlaylistPage(
        scope: accountA,
        queryKey: 'all',
        offset: 0,
      );
      expect(page!.ids, isEmpty);
      await reopened.close();
    });

    test('an unusable path degrades to a store that misses', () async {
      // A directory where the database file should be.
      final blocked = Directory('${directory.path}/blocked.db')..createSync();

      final store = SqliteMetadataCacheStore.open(path: blocked.path);

      expect(store.cacheGeneration, 0);
      expect(
        await store.readTracks(publicScope, [const TrackId('t1')]),
        isEmpty,
      );
      await store.putTracks([trackRecord('t1')]);
      expect(
        await store.readTracks(publicScope, [const TrackId('t1')]),
        isEmpty,
      );
      expect(await store.stats(), isA<CacheStoreStats>());
      await store.close();
    });
  });

  group('v2 schema additions', () {
    test('track availability and maxPotentialQuality round-trip', () async {
      final store = openStore();
      final track = Track(
        id: const TrackId('t-qual'),
        title: 'Title',
        artists: const [Artist(id: ArtistId('a1'), name: 'Artist 1')],
        album: const Album(id: AlbumId('alb1'), title: 'Album 1'),
        duration: const Duration(seconds: 180),
        availability: TrackAvailability.full,
        maxPotentialQuality: TrackQuality.lossless,
      );
      await store.putTracks([
        CachedTrack(
          track: track,
          groups: {
            TrackFieldGroup.title: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
            TrackFieldGroup.availability: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
            TrackFieldGroup.maxPotentialQuality: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
          },
          envelope: CacheEnvelope.fresh(
            scope: publicScope,
            at: now,
            window: CacheContentKind.trackDetail.window,
          ),
        ),
      ]);

      final read = await store.readTracks(publicScope, [
        const TrackId('t-qual'),
      ]);
      expect(read[const TrackId('t-qual')], isNotNull);
      expect(
        read[const TrackId('t-qual')]!.track.availability,
        TrackAvailability.full,
      );
      expect(
        read[const TrackId('t-qual')]!.track.maxPotentialQuality,
        TrackQuality.lossless,
      );
      await store.close();
    });

    test('catalog entities round-trip through store', () async {
      final store = openStore();
      final album = AlbumSummary(
        id: const AlbumId('alb123'),
        title: 'Test Album',
        artistName: 'Test Artist',
        trackCount: 10,
        artworkUri: Uri.parse('https://example.com/cover.jpg'),
      );
      final entity = CatalogEntitySummary(
        scope: publicScope,
        kind: 'album',
        entityId: 'alb123',
        summaryJson: encodeAlbumSummary(album),
        envelope: CacheEnvelope.fresh(
          scope: publicScope,
          at: now,
          window: CacheContentKind.albumSummary.window,
        ),
      );
      await store.putCatalogEntities([entity]);

      final read = await store.readCatalogEntities(publicScope, 'album', [
        'alb123',
      ]);
      expect(read['alb123'], isNotNull);
      final decoded = decodeAlbumSummary(read['alb123']!.summaryJson);
      expect(decoded?.title, 'Test Album');
      expect(decoded?.artistName, 'Test Artist');
      await store.close();
    });

    test('home sections round-trip through store', () async {
      final store = openStore();
      final section = HomeSection(
        kind: HomeSectionKind.recommended,
        title: 'Recommended Playlists',
        playlists: [
          PlaylistSummary(
            id: const PlaylistId('p1'),
            title: 'Playlist 1',
            subtitle: 'Sub 1',
            trackCount: 20,
          ),
        ],
      );
      await store.commitHomeSection(
        publicScope,
        HomeSectionKind.recommended,
        section,
      );

      final read = await store.readHomeSections(publicScope);
      expect(read.length, 1);
      expect(read[HomeSectionKind.recommended], isNotNull);
      expect(read[HomeSectionKind.recommended]!.title, 'Recommended Playlists');
      expect(
        read[HomeSectionKind.recommended]!.playlists.first.title,
        'Playlist 1',
      );
      await store.close();
    });

    test('generic readIdPage and putIdPage round-trip', () async {
      final store = openStore();
      await store.putIdPage(
        kind: 'album_search',
        queryKey: 'rock',
        page: CachedIdPage<String>(
          ids: ['alb1', 'alb2'],
          offset: 0,
          limit: 20,
          hasMore: false,
          isComplete: true,
          generation: 1,
          envelope: CacheEnvelope.fresh(
            scope: publicScope,
            at: now,
            window: CacheContentKind.searchResults.window,
          ),
        ),
      );

      final page = await store.readIdPage(
        scope: publicScope,
        kind: 'album_search',
        queryKey: 'rock',
        offset: 0,
      );
      expect(page, isNotNull);
      expect(page!.ids, ['alb1', 'alb2']);
      expect(page.generation, 1);
      await store.close();
    });
  });

  group('v3 schema additions', () {
    test('track fee, alias, and objectiveQuality round-trip', () async {
      final store = openStore();
      final track = Track(
        id: const TrackId('t-v3'),
        title: 'Song V3',
        audioSpecs: const [
          TrackAudioSpecs(
            quality: TrackQuality.lossless,
            bitrateKbps: 948,
            sampleRateHz: 44100,
          ),
        ],
        artists: [Artist(id: const ArtistId('a1'), name: 'Artist 1')],
        album: const Album(id: AlbumId('alb1'), title: 'Album 1'),
        duration: const Duration(seconds: 180),
        availability: TrackAvailability.full,
        maxPotentialQuality: TrackQuality.lossless,
        fee: TrackFee.vip,
        alias: ['Alias One', 'Alias Two'],
        translationNames: ['译名'],
        objectiveQuality: TrackQuality.lossless,
      );

      await store.putTracks([
        CachedTrack(
          track: track,
          groups: {
            TrackFieldGroup.title: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
            TrackFieldGroup.fee: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
            TrackFieldGroup.alias: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
            TrackFieldGroup.objectiveQuality: CacheEnvelope.fresh(
              scope: publicScope,
              at: now,
              window: CacheContentKind.trackDetail.window,
            ),
          },
          envelope: CacheEnvelope.fresh(
            scope: publicScope,
            at: now,
            window: CacheContentKind.trackDetail.window,
          ),
        ),
      ]);

      final read = await store.readTracks(publicScope, [const TrackId('t-v3')]);
      expect(read[const TrackId('t-v3')], isNotNull);
      final loaded = read[const TrackId('t-v3')]!.track;
      expect(loaded.fee, TrackFee.vip);
      expect(loaded.alias, ['Alias One', 'Alias Two']);
      expect(loaded.translationNames, ['译名']);
      expect(loaded.objectiveQuality, TrackQuality.lossless);
      expect(loaded.audioSpecs.single.bitrateKbps, 948);
      expect(loaded.audioSpecs.single.sampleRateHz, 44100);
      await store.close();
    });

    test('daily songs snapshot round-trips', () async {
      final store = openStore();
      final track = Track(
        id: const TrackId('t-daily'),
        title: 'Daily Song',
        translationNames: ['Daily translation'],
        artists: [Artist(id: const ArtistId('a1'), name: 'Artist 1')],
        album: const Album(id: AlbumId('alb1'), title: 'Album 1'),
        duration: const Duration(seconds: 200),
      );

      final snapshot = DailySongsSnapshot(
        namespace: publicScope.namespace,
        accountId: accountKeyOf(publicScope),
        dateKey: '2026-09-30',
        songs: [
          DailySongEntry(
            ordinal: 0,
            track: track,
            reason: 'Because you listened',
          ),
        ],
        fetchedAt: now,
        staleUntil: now.add(const Duration(hours: 1)),
        retainUntil: now.add(const Duration(days: 30)),
      );

      await store.putDailySongs(snapshot);

      final read = await store.readDailySongs(publicScope, '2026-09-30');
      expect(read, isNotNull);
      expect(read!.dateKey, '2026-09-30');
      expect(read.songs.length, 1);
      expect(read.songs.first.track.title, 'Daily Song');
      expect(read.songs.first.track.translationNames, ['Daily translation']);
      expect(read.songs.first.reason, 'Because you listened');
      await store.close();
    });

    test(
      'partition tickets, fenceScope, invalidatePartition, and commitBatch',
      () async {
        final store = openStore();
        final accountScope = CacheScope(namespace: 'ncm', accountId: 'user123');

        // 1. Read partition ticket
        final ticketResult = await store.readPartitionTicket(accountScope);
        expect(ticketResult, isA<PartitionTicketAvailable>());
        final ticket = (ticketResult as PartitionTicketAvailable).ticket;
        expect(ticket.scope, accountScope);
        expect(ticket.partitionGeneration, 0);

        // 2. Commit batch with valid ticket
        final track = Track(
          id: const TrackId('t-batch'),
          title: 'Batch Song',
          artists: [Artist(id: const ArtistId('a1'), name: 'Batch Artist')],
          album: const Album(id: AlbumId('alb1'), title: 'Batch Album'),
          duration: const Duration(seconds: 120),
        );
        final batch = CacheBatch(
          tickets: [ticket],
          tracks: [
            ScopedWrite(
              scope: accountScope,
              value: CachedTrack(
                track: track,
                groups: {
                  TrackFieldGroup.title: CacheEnvelope.fresh(
                    scope: accountScope,
                    at: now,
                    window: CacheContentKind.trackDetail.window,
                  ),
                },
                envelope: CacheEnvelope.fresh(
                  scope: accountScope,
                  at: now,
                  window: CacheContentKind.trackDetail.window,
                ),
              ),
            ),
          ],
        );

        final commitResult = await store.commitBatch(batch);
        expect(commitResult, CacheCommitResult.committed);

        var read = await store.readTracks(accountScope, [
          const TrackId('t-batch'),
        ]);
        expect(read[const TrackId('t-batch')], isNotNull);

        // 3. Invalidate partition
        final invalidation = await store.invalidatePartition(ticket);
        expect(invalidation, isA<InvalidationSuccess>());
        expect((invalidation as InvalidationSuccess).generation, 1);

        // Verify partition data deleted
        read = await store.readTracks(accountScope, [const TrackId('t-batch')]);
        expect(read, isEmpty);

        // 4. Old ticket is now superseded
        final oldTicketCommit = await store.commitBatch(batch);
        expect(oldTicketCommit, CacheCommitResult.superseded);

        // 5. New ticket can be read
        final newTicketResult = await store.readPartitionTicket(accountScope);
        expect(newTicketResult, isA<PartitionTicketAvailable>());
        final newTicket = (newTicketResult as PartitionTicketAvailable).ticket;
        expect(newTicket.partitionGeneration, 1);

        // 6. Fencing scope blocks ticket and commits
        store.fenceScope(newTicket);
        final fencedTicketResult = await store.readPartitionTicket(
          accountScope,
        );
        expect(fencedTicketResult, isA<PartitionTicketUnavailable>());

        final fencedCommit = await store.commitBatch(
          CacheBatch(tickets: [newTicket]),
        );
        expect(fencedCommit, CacheCommitResult.superseded);

        await store.close();
      },
    );
  });
}
