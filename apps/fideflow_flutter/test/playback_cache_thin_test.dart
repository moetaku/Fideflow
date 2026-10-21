import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:flutter_test/flutter_test.dart';

final class DeferredLyrics implements LyricsRepository {
  final requests = <Completer<LyricTimeline>>[];
  @override
  Future<LyricTimeline> getLyrics(TrackId id) {
    final request = Completer<LyricTimeline>();
    requests.add(request);
    return request.future;
  }
}

LyricTimeline sheet(String text) => LyricTimeline(
  status: LyricsStatus.unsynchronized,
  offset: Duration.zero,
  lines: [
    LyricLine(
      start: Duration.zero,
      end: const Duration(seconds: 1),
      text: text,
    ),
  ],
);

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('condition timed out');
}

void main() {
  late Directory dir;
  late PlaybackCache cache;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ff-thin-cache-');
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
  });
  tearDown(() async {
    await cache.close();
    await dir.delete(recursive: true);
  });
  Future<void> audio(String track, String quality) async {
    await cache.record(
      cache.key('A', track, quality),
      Stream.value([1, 2, 3, 4]),
      {'kind': 'audio', 'version': 'v1'},
    ).drain<void>();
  }

  Future<void> dropDatabase() async {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${dir.path}/cache.sqlite$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  test(
    'startup retains summaries and opens song and lyrics documents on demand',
    () async {
      await audio('song', 'high');
      final remote = DeferredLyrics();
      final repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'A',
      );
      final request = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.isNotEmpty);
      remote.requests.single.complete(sheet('shared'));
      await request;
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      expect(cache.loadedSongs, 0);
      expect(cache.loadedLyrics, 0);
      expect(cache.lookup(cache.key('A', 'song', 'high')), isNull);
      await cache.validateEntry(cache.key('A', 'song', 'high'));
      expect(cache.loadedSongs, 1);
      final hit = await CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'B',
      ).getLyrics(const TrackId('song'));
      expect(hit.lines.single.text, 'shared');
      expect(remote.requests, hasLength(1));
      expect(cache.loadedLyrics, 1);
    },
  );

  test(
    'song LRU is bounded and protects pinned documents until release',
    () async {
      for (var i = 0; i < 130; i++) {
        await audio('$i', 'high');
      }
      expect(cache.loadedSongs, lessThanOrEqualTo(128));
      final first = cache.key('A', '0', 'high');
      cache.pin(first);
      await cache.validateEntry(first);
      for (var i = 1; i < 130; i++) {
        await cache.validateEntry(cache.key('A', '$i', 'high'));
      }
      expect(cache.lookup(first), isNotNull);
      expect(cache.loadedSongs, lessThanOrEqualTo(128));
      cache.unpin(first);
      expect(cache.loadedSongs, lessThanOrEqualTo(128));
    },
  );

  test(
    'parallel qualities publish one song index without losing ranges',
    () async {
      await Future.wait([audio('song', 'high'), audio('song', 'lossless')]);
      final indexes = await dir
          .list()
          .where((e) => e.path.endsWith('.index.json'))
          .toList();
      expect(indexes, hasLength(1));
      final document =
          jsonDecode(await File(indexes.single.path).readAsString()) as Map;
      expect((document['qualities'] as Map).keys.toSet(), {'high', 'lossless'});
      final store = await PlaybackCacheStore.open('${dir.path}/cache.sqlite');
      final snapshot = await store.load();
      await store.close();
      for (final quality in ['high', 'lossless']) {
        final entry =
            snapshot['entries'][cache.key('A', 'song', quality)] as Map;
        expect(entry['revision'], document['qualities'][quality]['revision']);
        expect(entry, isNot(contains('ranges')));
      }
    },
  );

  test('public refresh is deduplicated across repository instances', () async {
    final remote = DeferredLyrics();
    final first = CachedLyricsRepository(
      upstream: remote,
      cache: cache,
      account: () => 'A',
    );
    final second = CachedLyricsRepository(
      upstream: remote,
      cache: cache,
      account: () => 'B',
    );
    final a = first.getLyrics(const TrackId('song'));
    final b = second.getLyrics(const TrackId('song'));
    await until(() => remote.requests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(remote.requests, hasLength(1));
    remote.requests.single.complete(sheet('one'));
    await Future.wait([a, b]);
    await cache.clearAccount('A');
    expect(
      await dir.list().where((e) => e.path.endsWith('.lyrics.json')).length,
      1,
    );
    expect(
      cache.key('A', 'song', 'lyrics-v1'),
      cache.key('B', 'song', 'lyrics-v1'),
    );
  });

  test(
    'revoked account result cannot overwrite the new account refresh',
    () async {
      final remote = DeferredLyrics();
      var account = 'A';
      var epoch = 0;
      final repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => account,
        epoch: () => epoch,
      );
      final old = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.length == 1);
      account = 'B';
      epoch++;
      final current = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.length == 2);
      remote.requests[1].complete(sheet('new'));
      await current;
      remote.requests[0].complete(sheet('old'));
      await old;
      expect(
        (await repo.getLyrics(const TrackId('song'))).lines.single.text,
        'new',
      );
      expect(remote.requests, hasLength(2));
      final text = await cache
          .file(cache.key('B', 'song', 'lyrics-v1'))
          .readAsString();
      expect(text, isNot(contains('account')));
      expect(text, isNot(contains('Cookie')));
    },
  );

  test(
    'clear fences old requests and invalidates decoded timeline revisions',
    () async {
      final remote = DeferredLyrics();
      final repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'A',
      );
      final old = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.length == 1);
      await cache.clear();
      remote.requests[0].complete(sheet('old'));
      await old;
      expect(cache.lookup(cache.key('A', 'song', 'lyrics-v1')), isNull);
      final fresh = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.length == 2);
      remote.requests[1].complete(sheet('new'));
      await fresh;
      expect(
        (await repo.getLyrics(const TrackId('song'))).lines.single.text,
        'new',
      );
      await cache.clear();
      final next = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.length == 3);
      remote.requests[2].complete(sheet('next'));
      await next;
      expect(
        (await repo.getLyrics(const TrackId('song'))).lines.single.text,
        'next',
      );
    },
  );

  test(
    'stale lyrics return immediately; failed refresh preserves fetchedAt',
    () async {
      final remote = DeferredLyrics();
      var repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'A',
      );
      final initial = repo.getLyrics(const TrackId('song'));
      await until(() => remote.requests.isNotEmpty);
      remote.requests.single.complete(sheet('keep'));
      await initial;
      final file = cache.file(cache.key('A', 'song', 'lyrics-v1'));
      await cache.close();
      final doc = jsonDecode(await file.readAsString()) as Map;
      final fetched = DateTime.now()
          .subtract(const Duration(days: 8))
          .millisecondsSinceEpoch;
      doc['fetchedAt'] = doc['fetched'] = fetched;
      await file.writeAsString(jsonEncode(doc));
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'B',
      );
      expect(
        (await repo.getLyrics(const TrackId('song'))).lines.single.text,
        'keep',
      );
      await until(() => remote.requests.length == 2);
      remote.requests[1].completeError(StateError('network failure'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        (jsonDecode(await file.readAsString()) as Map)['fetchedAt'],
        fetched,
      );
    },
  );

  test(
    'database loss cannot revive pinned audio or lyrics deleted before crash',
    () async {
      await audio('song', 'high');
      final lyrics = cache.key('A', 'song', 'lyrics-v1');
      await cache.record(
        lyrics,
        Stream.value(
          utf8.encode(
            jsonEncode({'status': 'instrumental', 'offset': 0, 'lines': []}),
          ),
        ),
        {'kind': 'lyrics'},
      ).drain<void>();
      final high = cache.key('A', 'song', 'high');
      cache.pin(high);
      cache.pin(lyrics);
      await cache.clear();
      final file = cache.file(high);
      expect(await file.exists(), true);
      await cache.close();
      await dropDatabase();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await cache.validateEntry(high);
      await cache.validateEntry(lyrics);
      expect(cache.lookup(high), isNull);
      expect(cache.lookup(lyrics), isNull);
      expect(cache.usedBytes, 0);
      expect(await file.exists(), false);
      expect(
        await dir.list().where((e) => e.path.endsWith('.lyrics.json')).length,
        0,
      );
    },
  );

  test('all v1 documents are ignored without migration', () async {
    await cache.close();
    await dropDatabase();
    final old = File('${dir.path}/l-${'0' * 64}.lyrics.json');
    await old.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'identity': ['A', 'ncm', 'song', 'lyrics-v1'],
        'kind': 'lyrics',
        'fileName': old.uri.pathSegments.last,
      }),
    );
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    expect(cache.usedBytes, 0);
    expect(await old.exists(), true);
  });
  test(
    'clear fences a lyric request before its first asynchronous read',
    () async {
      final remote = DeferredLyrics();
      final repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'A',
      );
      final request = repo.getLyrics(const TrackId('song'));
      await cache.clear();
      expect((await request).status, LyricsStatus.unavailable);
      expect(remote.requests, isEmpty);
    },
  );

  test(
    'lyrics document LRU stays bounded with many lyrics and no audio',
    () async {
      for (var i = 0; i < 130; i++) {
        final key = cache.key('A', '$i', 'lyrics-v1');
        await cache.record(
          key,
          Stream.value(
            utf8.encode(
              jsonEncode({'status': 'instrumental', 'offset': 0, 'lines': []}),
            ),
          ),
          {'kind': 'lyrics'},
        ).drain<void>();
      }
      expect(cache.loadedLyrics, lessThanOrEqualTo(128));
      final remote = DeferredLyrics();
      final repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'B',
      );
      for (var i = 0; i < 130; i++) {
        expect(
          (await repo.getLyrics(TrackId('$i'))).status,
          LyricsStatus.instrumental,
        );
      }
      expect(cache.loadedLyrics, lessThanOrEqualTo(128));
      expect(remote.requests, isEmpty);
      expect(cache.loadedSongs, 0);
    },
  );

  test('LRU continues past a full page of pinned candidates', () async {
    const size = 16 * 1024 * 1024;
    await cache.setLimit(10);
    final indexes = <File>[];
    for (var i = 0; i < 130; i++) {
      final key = cache.key('A', '$i', 'high');
      await cache.prepareAudio(key, size, 'v1', {}, cache.generation);
      final handle = await cache.file(key).open(mode: FileMode.append);
      await handle.truncate(size);
      await handle.close();
      await cache.flushAudioWrites();
      indexes.add(File('${dir.path}/${cache.lookup(key)!['indexName']}'));
    }
    await cache.close();
    for (final file in indexes) {
      final root = jsonDecode(await file.readAsString()) as Map;
      final quality = root['qualities']['high'] as Map;
      quality['effectiveBytes'] = size;
      quality['ranges'] = [
        [0, size],
      ];
      quality['revision'] = (quality['revision'] as int) + 1;
      root['revision'] = (root['revision'] as int) + 1;
      await file.writeAsString(jsonEncode(root));
    }
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    for (var i = 0; i < 128; i++) {
      cache.pin(cache.key('A', '$i', 'high'));
    }
    await cache.setLimit(1);
    expect(cache.usedBytes, 128 * size);
    await cache.validateEntry(cache.key('A', '128', 'high'));
    await cache.validateEntry(cache.key('A', '129', 'high'));
    expect(cache.lookup(cache.key('A', '128', 'high')), isNull);
    expect(cache.lookup(cache.key('A', '129', 'high')), isNull);
    for (var i = 0; i < 128; i++) {
      cache.unpin(cache.key('A', '$i', 'high'));
    }
  });
  test('duplicate song indexes with disjoint qualities are isolated', () async {
    await audio('song', 'high');
    await audio('song', 'lossless');
    final original = File(
      '${dir.path}/${cache.lookup(cache.key('A', 'song', 'high'))!['indexName']}',
    );
    final lossless = cache.file(cache.key('A', 'song', 'lossless'));
    await cache.close();
    final root = jsonDecode(await original.readAsString()) as Map;
    final duplicate = jsonDecode(jsonEncode(root)) as Map;
    final stem = "${root['songStem']}-1";
    duplicate['songStem'] = stem;
    (duplicate['qualities'] as Map).remove('high');
    final quality = duplicate['qualities']['lossless'] as Map;
    quality['qualityStem'] = (quality['qualityStem'] as String).replaceFirst(
      root['songStem'] as String,
      stem,
    );
    quality['fileName'] =
        "${quality['qualityStem']}.g-${quality['generation']}.audio.data";
    await lossless.copy('${dir.path}/${quality['fileName']}');
    (root['qualities'] as Map).remove('lossless');
    await original.writeAsString(jsonEncode(root));
    await File(
      '${dir.path}/$stem.index.json',
    ).writeAsString(jsonEncode(duplicate));
    await dropDatabase();
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    expect(cache.usedBytes, 0);
    await cache.validateEntry(cache.key('A', 'song', 'high'));
    await cache.validateEntry(cache.key('A', 'song', 'lossless'));
    expect(cache.lookup(cache.key('A', 'song', 'high')), isNull);
    expect(cache.lookup(cache.key('A', 'song', 'lossless')), isNull);
  });
  test('a corrupt song index can be cached again after restart', () async {
    await audio('song', 'high');
    final key = cache.key('A', 'song', 'high');
    final index = File('${dir.path}/${cache.lookup(key)!['indexName']}');
    await cache.close();
    await index.writeAsString('{broken');
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    expect(cache.usedBytes, 0);
    await audio('song', 'high');
    expect(await cache.file(key).readAsBytes(), [1, 2, 3, 4]);
    final root = jsonDecode(await index.readAsString()) as Map;
    expect(root['qualities']['high']['effectiveBytes'], 4);
    final quarantined = await dir
        .list()
        .where((file) => file.uri.path.startsWith('${index.uri.path}.corrupt-'))
        .toList();
    expect(quarantined, hasLength(1));
    expect(await File(quarantined.single.path).readAsString(), '{broken');
    await cache.close();
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await cache.validateEntry(key);
    expect(cache.lookup(key)?['size'], 4);
  });

  test('repairing a corrupt index retains other published qualities', () async {
    await audio('song', 'high');
    final high = cache.key('A', 'song', 'high');
    final original = cache.file(high);
    final index = File('${dir.path}/${cache.lookup(high)!['indexName']}');
    await index.writeAsString('{broken');
    await audio('song', 'lossless');
    final root = jsonDecode(await index.readAsString()) as Map;
    expect((root['qualities'] as Map).keys.toSet(), {'high', 'lossless'});
    expect(root['qualities']['high']['effectiveBytes'], 4);
    expect(cache.file(high).path, original.path);
    expect(await original.readAsBytes(), [1, 2, 3, 4]);
    await cache.close();
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await cache.validateEntry(high);
    await cache.validateEntry(cache.key('A', 'song', 'lossless'));
    expect(cache.usedBytes, 8);
    expect(cache.lookup(high)?['size'], 4);
    expect(cache.lookup(cache.key('A', 'song', 'lossless'))?['size'], 4);
  });

  test(
    'clear safely deletes a cold entry while 128 documents are pinned',
    () async {
      for (var i = 0; i < 129; i++) {
        await audio('$i', 'high');
      }
      for (var i = 0; i < 128; i++) {
        final key = cache.key('A', '$i', 'high');
        cache.pin(key);
        await cache.validateEntry(key);
      }
      expect(cache.loadedSongs, 128);
      final cold = cache.key('A', '128', 'high');
      expect(cache.lookup(cold), isNull);
      await cache.clear();
      expect(cache.usedBytes, 128 * 4);
      final store = await PlaybackCacheStore.open('${dir.path}/cache.sqlite');
      final snapshot = await store.load();
      await store.close();
      expect(snapshot['entries'], isNot(contains(cold)));
      expect(
        (snapshot['entries'] as Map).values,
        everyElement(containsPair('state', 'deleting')),
      );
      for (var i = 0; i < 128; i++) {
        cache.unpin(cache.key('A', '$i', 'high'));
      }
      await cache.flushAudioWrites();
      expect(cache.usedBytes, 0);
      expect(cache.loadedSongs, lessThanOrEqualTo(128));
      expect(
        await dir
            .list()
            .where((file) => file.path.endsWith('.audio.data'))
            .length,
        0,
      );
      expect(
        await dir
            .list()
            .where((file) => file.path.endsWith('.index.json'))
            .length,
        0,
      );
    },
  );
  test('a malformed cached v2 index is quarantined before rebuilding', () async {
    await audio('song', 'high');
    final key = cache.key('A', 'song', 'high');
    final index = File('${dir.path}/${cache.lookup(key)!['indexName']}');
    await cache.close();
    final root = jsonDecode(await index.readAsString()) as Map;
    root['qualities'] = 'broken';
    await index.writeAsString(jsonEncode(root));
    // Keep SQLite summaries for validateEntry to encounter and cache the bad root.
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.validateEntry(key);
    await cache.recovery;
    await audio('song', 'high');
    expect(cache.lookup(key)?['size'], 4);
    expect(
      (jsonDecode(await index.readAsString()) as Map)['qualities'],
      isA<Map>(),
    );
  });

  test('repair never overwrites an unsupported future index', () async {
    await audio('song', 'high');
    final key = cache.key('A', 'song', 'high');
    final index = File('${dir.path}/${cache.lookup(key)!['indexName']}');
    final root = jsonDecode(await index.readAsString()) as Map;
    root['schemaVersion'] = 999;
    final unsupported = jsonEncode(root);
    await index.writeAsString(unsupported);
    await expectLater(audio('song', 'lossless'), throwsStateError);
    expect(await index.readAsString(), unsupported);
    expect(
      await dir
          .list()
          .where(
            (file) => file.uri.path.startsWith('${index.uri.path}.corrupt-'),
          )
          .length,
      0,
    );
  });
}
