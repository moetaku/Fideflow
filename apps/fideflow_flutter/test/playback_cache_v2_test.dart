import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'playback_cache_authorization_test.dart' show Source;

// Legacy behavior tests explicitly open entries after restart. Dedicated thin
// cache tests assert that initialization itself does not load these documents.
Future<void> hydrate(PlaybackCache cache, Directory directory) async {
  final store = await PlaybackCacheStore.open('${directory.path}/cache.sqlite');
  final snapshot = await store.load();
  await store.close();
  for (final key in (snapshot['entries'] as Map).keys.cast<String>()) {
    await cache.validateEntry(key);
  }
}

final _songRoots = <String, Map<String, dynamic>>{};
Future<Map<String, dynamic>> readQuality(
  File file, [
  String quality = 'high',
]) async {
  final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  _songRoots[file.path] = root;
  final entry = (root['qualities'] as Map)[quality] as Map<String, dynamic>;
  entry.addAll({
    'version': entry['resourceVersion'],
    'total': entry['totalBytes'],
    'size': entry['effectiveBytes'],
  });
  return entry;
}

Future<void> writeQuality(File file, Map<String, dynamic> quality) async {
  final root = _songRoots[file.path]!;
  quality.addAll({
    'resourceVersion': quality.remove('version'),
    'totalBytes': quality.remove('total'),
    'effectiveBytes': quality.remove('size'),
  });
  root['revision'] = (root['revision'] as int) + 1;
  await file.writeAsString(jsonEncode(root));
}

void main() {
  late Directory dir;
  late PlaybackCache cache;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ff-playback-cache-v2-');
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
  });
  tearDown(() async {
    await cache.close();
    await dir.delete(recursive: true);
  });
  Future<void> audio(String key, String version) async {
    await cache.prepareAudio(key, 4, version, {}, cache.generation);
    await cache.writeAudioRange(
      key,
      0,
      [1, 2, 3, 4],
      cache.generation,
      cache.audioRevision(key),
    );
    await cache.flushAudioWrites();
  }

  Future<Map<String, dynamic>> database() async {
    final store = await PlaybackCacheStore.open('${dir.path}/cache.sqlite');
    try {
      return await store.load();
    } finally {
      await store.close();
    }
  }

  test(
    'first allocation combines reservations and defers the empty index',
    () async {
      final key = cache.key('A', 'song', 'high');
      final commits = cache.databaseCommits;
      await cache.prepareAudio(key, 4, 'v1', {}, cache.generation);
      expect(cache.databaseCommits - commits, 1);
      expect(cache.indexWrites, 0);
      expect((await database())['entries'], isEmpty);
      expect((await database())['reservations'], hasLength(5));
      await audio(key, 'v1');
      expect(cache.databaseCommits - commits, 2);
      expect(cache.databaseDocumentsEncoded, 5);
      expect(cache.indexWrites, 1);
      final settled = cache.databaseCommits;
      for (var i = 0; i < 20; i++) {
        await cache.flushAudioWrites();
      }
      expect(cache.databaseCommits, settled);
      expect(cache.indexWrites, 1);
    },
  );

  test(
    'first lyric creation reserves target and temporary name together',
    () async {
      final key = cache.key('A', 'song', 'lyrics-v1');
      await cache.record(
        key,
        Stream.value(utf8.encode(jsonEncode({'text': 'lyric'}))),
        {'kind': 'lyrics'},
      ).drain<void>();
      expect(cache.databaseCommits, 2);
      expect(cache.databaseDocumentsEncoded, 2);
      expect(cache.indexWrites, 0);
      final state = await database();
      expect(state['reservations'], hasLength(2));
      expect(state['entries'], hasLength(1));
      expect(cache.usedBytes, await cache.file(key).length());
      expect(state['totals'], {'audio': 0, 'lyrics': cache.usedBytes});
    },
  );

  test(
    'single entry update never sends unrelated entries or reservations',
    () async {
      await cache.close();
      final deltas = <PlaybackCacheDelta>[];
      cache = PlaybackCache(dir, onDatabaseDelta: deltas.add);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      for (var i = 0; i < 20; i++) {
        await audio(cache.key('A', '$i', 'high'), 'v1');
      }
      for (var i = 0; i < 20; i++) {
        cache.lookup(cache.key('A', '$i', 'high'));
      }
      final key = cache.key('A', 'new', 'high');
      await cache.prepareAudio(key, 8, 'v1', {}, cache.generation);
      await cache.writeAudioRange(
        key,
        0,
        [1, 2],
        cache.generation,
        cache.audioRevision(key),
      );
      deltas.clear();
      await cache.flushAudioWrites();
      expect(deltas, hasLength(1));
      expect(deltas.single.entries.keys, [key]);
      expect(deltas.single.reservations, isEmpty);
      expect(deltas.single.documentCount, 1);
    },
  );

  test(
    'bytes written during a database commit remain dirty and snapshots stay consistent',
    () async {
      await cache.close();
      final entered = Completer<void>(), release = Completer<void>();
      var hold = false;
      cache = PlaybackCache(
        dir,
        beforeDatabaseCommit: () async {
          if (hold) {
            hold = false;
            entered.complete();
            await release.future;
          }
        },
      );
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(key, 8, 'v1', {}, cache.generation);
      await cache.writeAudioRange(
        key,
        0,
        [1, 2],
        cache.generation,
        cache.audioRevision(key),
      );
      hold = true;
      final pending = cache.flushAudioWrites();
      await entered.future;
      await cache.writeAudioRange(
        key,
        2,
        [3, 4],
        cache.generation,
        cache.audioRevision(key),
      );
      release.complete();
      await pending;
      final first = (await database())['entries'][key] as Map;
      final doc =
          jsonDecode(
                await File(
                  '${dir.path}/${first['documentPath']}',
                ).readAsString(),
              )
              as Map;
      expect(first, isNot(contains('ranges')));
      expect((doc['qualities'] as Map)['high']['ranges'], [
        [0, 2],
      ]);
      expect(first['size'], 2);
      await cache.flushAudioWrites();
      expect((await database())['entries'][key]['size'], 4);
      expect(cache.usedBytes, 4);
    },
  );

  test(
    'bytes written during index IO are excluded until a later synchronized publish',
    () async {
      await cache.close();
      final entered = Completer<void>(), release = Completer<void>();
      var hold = false;
      cache = PlaybackCache(
        dir,
        beforeIndexWrite: () async {
          if (hold) {
            hold = false;
            entered.complete();
            await release.future;
          }
        },
      );
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(key, 8, 'v1', {}, cache.generation);
      await cache.writeAudioRange(
        key,
        0,
        [1, 2],
        cache.generation,
        cache.audioRevision(key),
      );
      hold = true;
      final pending = cache.flushAudioWrites();
      await entered.future;
      await cache.writeAudioRange(
        key,
        2,
        [3, 4],
        cache.generation,
        cache.audioRevision(key),
      );
      release.complete();
      await pending;
      final first = (await database())['entries'][key] as Map;
      final doc =
          jsonDecode(
                await File(
                  '${dir.path}/${first['documentPath']}',
                ).readAsString(),
              )
              as Map;
      expect(first, isNot(contains('ranges')));
      expect((doc['qualities'] as Map)['high']['ranges'], [
        [0, 2],
      ]);
      expect(first['size'], 2);
      await cache.flushAudioWrites();
      expect((await database())['entries'][key]['size'], 4);
      expect(cache.usedBytes, 4);
    },
  );

  test(
    'access changed while committing is retained through normal close',
    () async {
      await cache.close();
      final entered = Completer<void>(), release = Completer<void>();
      var hold = false;
      cache = PlaybackCache(
        dir,
        beforeDatabaseCommit: () async {
          if (hold) {
            hold = false;
            entered.complete();
            await release.future;
          }
        },
      );
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      cache.lookup(key);
      hold = true;
      final closing = cache.close();
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final latest = cache.lookup(key)!['access'];
      release.complete();
      await closing;
      expect((await database())['entries'][key]['access'], latest);
    },
  );

  test(
    'restart after reservation-only creation ignores the unpublished data file',
    () async {
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(key, 4, 'v1', {}, cache.generation);
      final snapshot = await database();
      final generation = cache.lookup(key)!['generation'] as int;
      final crashDir = await Directory.systemTemp.createTemp(
        'ff-reservation-crash-',
      );
      final crashStore = await PlaybackCacheStore.open(
        '${crashDir.path}/cache.sqlite',
      );
      await crashStore.applyDelta(
        PlaybackCacheDelta(
          reservations: {
            for (final e in (snapshot['reservations'] as Map).entries)
              e.key as String: Map<String, dynamic>.from(e.value as Map),
          },
        ),
      );
      await crashStore.close();
      await cache
          .file(key)
          .copy('${crashDir.path}/${cache.lookup(key)!['fileName']}');
      final restarted = PlaybackCache(crashDir);
      try {
        await restarted.initialize();
        await restarted.recovery;
        expect(restarted.lookup(key), isNull);
        await restarted.prepareAudio(key, 4, 'v2', {}, restarted.generation);
        expect(restarted.lookup(key)!['generation'], greaterThan(generation));
      } finally {
        await restarted.close();
        await crashDir.delete(recursive: true);
      }
    },
  );

  for (final mismatch in ['revision', 'generation', 'version']) {
    test(
      'recovery clears offline eligibility after $mismatch mismatch',
      () async {
        final key = cache.key('A', 'song', 'high');
        await audio(key, 'provider:v1');
        final source = Source();
        final resolver = CachedAudioResolver(
          upstream: source,
          cache: cache,
          account: () => 'A',
          epoch: () => 1,
        );
        await resolver.resolve(
          const TrackId('song'),
          AudioQuality.high,
          NetworkPolicy.preferCache,
        );
        await resolver.close();
        final path = File('${dir.path}/${cache.lookup(key)!['indexName']}');
        final original = cache.file(key);
        await cache.close();
        final doc = await readQuality(path);
        if (mismatch == 'version') {
          doc['version'] = doc['resourceVersion'] = 'provider:v2';
        } else {
          doc[mismatch] = (doc[mismatch] as int) + 1;
          if (mismatch == 'generation') {
            doc['fileName'] =
                "${doc['qualityStem']}.g-${doc['generation']}.audio.data";
            await original.copy('${dir.path}/${doc['fileName']}');
          }
        }
        await writeQuality(path, doc);
        cache = PlaybackCache(dir);
        await cache.initialize();
        await cache.recovery;
        await hydrate(cache, dir);
        expect(cache.usedBytes, 4);
        source.error = const SocketException('offline');
        final offline = CachedAudioResolver(
          upstream: source,
          cache: cache,
          account: () => 'A',
          epoch: () => 1,
        );
        try {
          await expectLater(
            offline.resolve(
              const TrackId('song'),
              AudioQuality.high,
              NetworkPolicy.preferCache,
            ),
            throwsA(isA<SocketException>()),
          );
        } finally {
          await offline.close();
        }
      },
    );
  }

  test(
    'database ahead of index repairs metadata and clears offline qualification',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'provider:v1');
      final resolver = CachedAudioResolver(
        upstream: Source(),
        cache: cache,
        account: () => 'A',
        epoch: () => 1,
      );
      await resolver.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      await resolver.close();
      await cache.close();
      final store = await PlaybackCacheStore.open('${dir.path}/cache.sqlite');
      final state = await store.load();
      final doc = Map<String, dynamic>.from(state['entries'][key] as Map);
      final originalRevision = doc['revision'] as int;
      doc['revision'] = originalRevision + 1;
      await store.applyDelta(PlaybackCacheDelta(entries: {key: doc}));
      await store.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final repaired = await database();
      expect(repaired['entries'][key]['revision'], originalRevision);
      expect(repaired['qualifications'], isEmpty);
      expect(cache.usedBytes, 4);
    },
  );

  test('duplicate audio ranges do not rewrite bytes or the index', () async {
    await cache.close();
    var writes = 0;
    cache = PlaybackCache(dir, beforeAudioWrite: () async => writes++);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
    final key = cache.key('A', 'song', 'high');
    await audio(key, 'v1');
    final indexWrites = cache.indexWrites;
    final index = File(
      '${dir.path}/${cache.lookup(key)!['songStem']}.index.json',
    );
    final original = await index.readAsString();
    writes = 0;
    await Future.wait([
      for (var i = 0; i < 8; i++)
        cache.writeAudioRange(
          key,
          0,
          [9, 9, 9, 9],
          cache.generation,
          cache.audioRevision(key),
        ),
    ]);
    await cache.flushAudioWrites();
    expect(writes, 0);
    expect(cache.indexWrites, indexWrites);
    expect(await index.readAsString(), original);
    expect(await cache.file(key).readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'overlapping audio ranges write only holes in the same version',
    () async {
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(key, 10, 'v1', {}, cache.generation);
      for (final start in [0, 4, 8]) {
        await cache.writeAudioRange(
          key,
          start,
          [start + 1, start + 2],
          cache.generation,
          cache.audioRevision(key),
        );
      }
      await cache.flushAudioWrites();
      await cache.writeAudioRange(
        key,
        1,
        [99, 3, 4, 99, 99, 7, 8, 99],
        cache.generation,
        cache.audioRevision(key),
      );
      await cache.flushAudioWrites();
      expect(await cache.file(key).readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
      ]);
      expect(cache.usedBytes, 10);
      expect(PlaybackCache.completeAudio(cache.lookup(key)!), isTrue);
      // A different representation still replaces every byte.
      await cache.prepareAudio(key, 10, 'v2', {}, cache.generation);
      await cache.writeAudioRange(
        key,
        0,
        List.filled(10, 42),
        cache.generation,
        cache.audioRevision(key),
      );
      await cache.flushAudioWrites();
      expect(await cache.file(key).readAsBytes(), List.filled(10, 42));
    },
  );

  test(
    'failed disk write publishes no range and retries after a writable probe',
    () async {
      await cache.close();
      var fail = true;
      cache = PlaybackCache(
        dir,
        beforeAudioWrite: () async {
          if (fail) throw const FileSystemException('injected disk full');
        },
      );
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(key, 8, 'v1', {}, cache.generation);
      expect(
        await cache.writeAudioRange(
          key,
          0,
          [1, 2],
          cache.generation,
          cache.audioRevision(key),
        ),
        isFalse,
      );
      expect(cache.usedBytes, 0);
      fail = false;
      expect(
        await cache.writeAudioRange(
          key,
          0,
          [1, 2],
          cache.generation,
          cache.audioRevision(key),
        ),
        isFalse,
      );
      await cache.flushAudioWrites();
      expect(
        await cache.writeAudioRange(
          key,
          0,
          [1, 2],
          cache.generation,
          cache.audioRevision(key),
        ),
        isTrue,
      );
      await cache.flushAudioWrites();
      expect(cache.usedBytes, 2);
    },
  );
  test(
    'database commit failure pauses persistence and retries the authoritative index',
    () async {
      await cache.close();
      var fail = false;
      cache = PlaybackCache(
        dir,
        beforeDatabaseCommit: () async {
          if (fail) throw StateError('injected database failure');
        },
      );
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(key, 8, 'v1', {}, cache.generation);
      await cache.writeAudioRange(
        key,
        0,
        [1, 2],
        cache.generation,
        cache.audioRevision(key),
      );
      fail = true;
      await expectLater(cache.flushAudioWrites(), throwsStateError);
      expect(
        await cache.writeAudioRange(
          key,
          2,
          [3, 4],
          cache.generation,
          cache.audioRevision(key),
        ),
        isFalse,
      );
      fail = false;
      await cache.flushAudioWrites();
      expect(
        await cache.writeAudioRange(
          key,
          2,
          [3, 4],
          cache.generation,
          cache.audioRevision(key),
        ),
        isTrue,
      );
      await cache.flushAudioWrites();
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      expect(cache.lookup(key)?['size'], 4);
    },
  );

  test('newer index repairs an older database summary', () async {
    final key = cache.key('A', 'song', 'high');
    await audio(key, 'v1');
    final document = File('${dir.path}/${cache.lookup(key)!['indexName']}');
    await cache.close();
    final doc = await readQuality(document);
    doc['revision'] = (doc['revision'] as int) + 1;
    doc['size'] = 2;
    doc['effectiveBytes'] = 2;
    doc['ranges'] = [
      [0, 2],
    ];
    await writeQuality(document, doc);
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
    expect(cache.usedBytes, 2);
    expect(cache.lookup(key)?['revision'], doc['revision']);
  });

  test(
    'LRU evicts individual qualities and protects an active quality',
    () async {
      final documents = <File>[];
      for (final quality in ['standard', 'high', 'lossless']) {
        final key = cache.key('A', 'song', quality);
        await cache.prepareAudio(key, 600000000, 'v1', {}, cache.generation);
        final handle = await cache.file(key).open(mode: FileMode.append);
        await handle.truncate(600000000);
        await handle.close();
        documents.add(File('${dir.path}/${cache.lookup(key)!['indexName']}'));
      }
      await cache.close();
      for (var i = 0; i < documents.length; i++) {
        final doc = await readQuality(
          documents[i],
          ['standard', 'high', 'lossless'][i],
        );
        doc['size'] = 600000000;
        doc['effectiveBytes'] = 600000000;
        doc['ranges'] = [
          [0, 600000000],
        ];
        doc['revision'] = (doc['revision'] as int) + 1;
        await writeQuality(documents[i], doc);
      }
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final high = cache.key('B', 'song', 'high');
      cache.pin(high);
      cache.lookup(high);
      await cache.setLimit(1);
      expect(cache.lookup(high)?['size'], 600000000);
      expect(cache.lookup(cache.key('A', 'song', 'standard')), isNull);
      expect(cache.lookup(cache.key('A', 'song', 'lossless')), isNull);
      expect(cache.usedBytes, 600000000);
      cache.unpin(high);
    },
  );

  File index(String key) =>
      File('${dir.path}/${cache.lookup(key)!['indexName']}');
  test(
    'shared audio and lyrics, flat safe names and exact Unicode identity',
    () async {
      for (final id in ['a/b\\c..', 'A', 'a', 'é', 'e\u0301', 'x' * 10000]) {
        await audio(cache.key('one', id, 'high'), 'v1');
      }
      expect(cache.key('one', 'A', 'high'), cache.key('two', 'A', 'high'));
      expect(
        cache.key('one', 'A', 'lyrics-v1'),
        cache.key('two', 'A', 'lyrics-v1'),
      );
      expect(cache.usedBytes, 24);
      final entities = await dir.list().toList();
      expect(entities.whereType<Directory>(), isEmpty);
      expect(
        entities.where((e) => e.path.endsWith('.index.json')),
        hasLength(6),
      );
      expect(
        entities.where((e) => e.path.endsWith('.audio.data')),
        hasLength(6),
      );
    },
  );
  test(
    'reads do not rewrite; another quality merges the shared index',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      final content = await index(key).readAsString(),
          writes = cache.indexWrites;
      for (var i = 0; i < 10; i++) {
        cache.lookup(key);
        await cache.file(key).openRead(1, 3).drain<void>();
      }
      await cache.flushAudioWrites();
      expect(cache.indexWrites, writes);
      await audio(cache.key('A', 'song', 'lossless'), 'v2');
      expect(
        (jsonDecode(await index(key).readAsString())
            as Map)['qualities']['high'],
        (jsonDecode(content) as Map)['qualities']['high'],
      );
      expect(
        cache.lookup(key)!['indexName'],
        cache.lookup(cache.key('A', 'song', 'lossless'))!['indexName'],
      );
    },
  );
  test(
    'generation replacement preserves old readers and increments after restart',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      final old = cache.file(key);
      cache.pin(key);
      await audio(key, 'v2');
      expect(cache.file(key).path, isNot(old.path));
      expect(await old.readAsBytes(), [1, 2, 3, 4]);
      cache.unpin(key);
      await cache.flushAudioWrites();
      expect(await old.exists(), isFalse);
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final generation = cache.lookup(key)!['generation'];
      await audio(key, 'v3');
      expect(
        cache.lookup(key)!['generation'] as int,
        greaterThan(generation as int),
      );
    },
  );
  test('database loss rejects all qualities in a damaged song index', () async {
    final high = cache.key('A', 'song', 'high'),
        lossless = cache.key('A', 'song', 'lossless');
    await audio(high, 'v1');
    await audio(lossless, 'v2');
    final bad = index(high);
    await cache.close();
    await bad.writeAsString('{broken');
    await File('${dir.path}/cache.sqlite').delete();
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
    expect(cache.lookup(high), isNull);
    expect(cache.lookup(lossless), isNull);
    expect(cache.usedBytes, 0);
  });
  test(
    'digest collisions preserve names across restart and unknown files',
    () async {
      await cache.close();
      final digest = '0' * 64;
      final occupied = File('${dir.path}/s-$digest.index.json');
      await occupied.writeAsString('unknown');
      cache = PlaybackCache(dir, digest: (_) => digest);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final first = cache.key('A', 'first', 'high'),
          second = cache.key('A', 'second', 'high');
      await audio(first, 'v1');
      await audio(second, 'v1');
      final firstFile = cache.file(first).path,
          secondFile = cache.file(second).path;
      expect(firstFile, isNot(secondFile));
      expect(await occupied.readAsString(), 'unknown');
      await cache.close();
      cache = PlaybackCache(dir, digest: (_) => digest);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      expect(cache.file(first).path, firstFile);
      expect(cache.file(second).path, secondFile);
    },
  );
  test('audio symlink is rejected on recovery', () async {
    final key = cache.key('A', 'song', 'high');
    await audio(key, 'v1');
    final path = cache.file(key).path;
    await cache.close();
    final outside = File('${dir.path}/outside');
    await outside.writeAsString('safe');
    await File(path).delete();
    try {
      await Link(path).create(outside.path);
    } on FileSystemException catch (error) {
      if (!Platform.isWindows || error.osError?.errorCode != 1314) rethrow;
      markTestSkipped('Windows account lacks symbolic-link creation privilege');
      return;
    }
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
    expect(cache.lookup(key), isNull);
    expect(await outside.readAsString(), 'safe');
  });
  test(
    'index contains public identity and no credentials or access timestamp',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      final doc = jsonDecode(await index(key).readAsString()) as Map;
      expect(doc['songIdentity'], ['ncm', 'song']);
      expect((doc['qualities'] as Map).keys, ['high']);
      expect(doc.containsKey('access'), isFalse);
      expect(doc.containsKey('url'), isFalse);
      expect(doc.containsKey('headers'), isFalse);
    },
  );
  test('a second manager cannot write into the locked directory', () async {
    final second = PlaybackCache(dir);
    await second.initialize();
    final key = second.key('B', 'new', 'high');
    await second.record(key, Stream.value([1]), {
      'kind': 'audio',
    }).drain<void>();
    expect(second.lookup(key), isNull);
    expect(cache.lookup(key), isNull);
    await second.close();
    await audio(cache.key('A', 'song', 'high'), 'v1');
    expect(cache.usedBytes, 4);
  });
  test(
    'unknown temporary files remain occupied and do not block commits',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      final temporary = File('${index(key).path}.tmp');
      await temporary.writeAsString('unowned');
      await audio(key, 'v2');
      expect(await temporary.readAsString(), 'unowned');
      expect(cache.lookup(key)?['version'], 'v2');
    },
  );
  test(
    'pinned deletion is tombstoned and cannot resurrect after restart',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      cache.pin(key);
      final data = cache.file(key);
      await cache.clear();
      expect(cache.lookup(key), isNull);
      expect(await data.exists(), isTrue);
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      expect(cache.lookup(key), isNull);
      expect(await data.exists(), isFalse);
    },
  );
  test(
    'provider identity separates audio inside the same flat directory',
    () async {
      final first = cache.key('A', 'song', 'high');
      await audio(first, 'v1');
      await cache.close();
      cache = PlaybackCache(dir, provider: 'another');
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final second = cache.key('A', 'song', 'high');
      await audio(second, 'v1');
      expect(first, isNot(second));
      expect(cache.file(first).path, isNot(cache.file(second).path));
      expect(cache.usedBytes, 8);
    },
  );
  test(
    'a corrupt database is rebuilt from documents without trusting its summaries',
    () async {
      final key = cache.key('A', 'song', 'high');
      await audio(key, 'v1');
      await cache.close();
      await File('${dir.path}/cache.sqlite').writeAsString('not SQLite');
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      expect(cache.lookup(key)?['size'], 4);
    },
  );
}
