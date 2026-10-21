import 'dart:convert';
import 'dart:io';

import 'package:fideflow_local_data/local_data_io.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late PlaybackCacheStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-playback-sqlite-');
    store = await PlaybackCacheStore.open('${directory.path}/cache.sqlite');
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });
  String key(String track, [String quality = 'high']) =>
      jsonEncode(['ncm', track, quality]);
  Map<String, dynamic> entry(
    String track, {
    String quality = 'high',
    int access = 1,
  }) => {
    'identity': ['ncm', track, quality],
    'kind': quality == 'lyrics' ? 'lyrics' : 'audio',
    'indexName': '$track.index.json',
    'fileName': '$track.$quality.data',
    'size': 4,
    'access': access,
    'revision': 1,
    'state': 'ready',
    'ranges': [
      [0, 4],
    ],
    'timeline': {
      'lines': ['must not reach SQLite'],
    },
  };

  test(
    'only light summaries persist; qualities share a document path',
    () async {
      final entries = {
        key('song'): entry('song'),
        key('song', 'lossless'): entry('song', quality: 'lossless'),
      };
      await store.applyDelta(PlaybackCacheDelta(entries: entries));
      expect((await store.load())['entries'], {
        for (final e in entries.entries)
          e.key: PlaybackCacheStore.summary(e.key, e.value),
      });
      final db = sqlite3.open('${directory.path}/cache.sqlite');
      try {
        final columns = db
            .select('PRAGMA table_info(cache_entries)')
            .map((r) => r['name'])
            .toSet();
        expect(columns, isNot(contains('document')));
        expect(columns, isNot(contains('fileName')));
        expect(columns, isNot(contains('ranges')));
        expect(columns, isNot(contains('timeline')));
        expect(
          db.select("SELECT name FROM sqlite_master WHERE name='entries'"),
          isEmpty,
        );
        expect(
          db
              .select('SELECT document_path FROM cache_entries')
              .map((r) => r['document_path']),
          everyElement('song.index.json'),
        );
      } finally {
        db.dispose();
      }
      expect(store.encodedDocuments, 0);
    },
  );

  test(
    'access updates and indexed LRU preserve totals through restart',
    () async {
      final entries = {
        for (var i = 0; i < 1000; i++) key('$i'): entry('$i', access: i),
      };
      await store.applyDelta(PlaybackCacheDelta(entries: entries));
      final latency = <int>[];
      for (var i = 0; i < 25; i++) {
        final timer = Stopwatch()..start();
        await store.applyDelta(
          PlaybackCacheDelta(access: {key('0'): 2000 + i}),
        );
        latency.add(timer.elapsedMicroseconds);
      }
      latency.sort();
      // ignore: avoid_print
      print(
        'Thin SQLite 1000 entries / 25 access commits P50=${latency[12]}us P95=${latency[23]}us',
      );
      expect((await store.lru(limit: 1)).single['key'], key('1'));
      expect((await store.lru(limit: 1, offset: 1)).single['key'], key('2'));
      await store.close();
      store = await PlaybackCacheStore.open('${directory.path}/cache.sqlite');
      final state = await store.load();
      expect(state['entries'][key('0')]['access'], 2024);
      expect(state['totals'], {'audio': 4000, 'lyrics': 0});
    },
  );

  test('all directory queries use the intended indexes', () {
    final db = sqlite3.open('${directory.path}/cache.sqlite');
    try {
      String plan(String sql) => db
          .select('EXPLAIN QUERY PLAN $sql')
          .map((r) => r['detail'])
          .join(' ');
      expect(
        plan("SELECT * FROM cache_entries WHERE resource_key='x'"),
        contains('sqlite_autoindex_cache_entries'),
      );
      expect(
        plan("SELECT * FROM cache_entries WHERE song_key='x'"),
        contains('ix_cache_entries_song'),
      );
      final lru = plan(
        "SELECT resource_key, last_access FROM cache_entries WHERE state='ready' ORDER BY last_access, resource_key LIMIT 128",
      );
      expect(lru, contains('ix_cache_entries_lru'));
      expect(lru, isNot(contains('TEMP B-TREE')));
    } finally {
      db.dispose();
    }
  });

  test('constraint failure rolls back every table and totals', () async {
    await store.applyDelta(
      PlaybackCacheDelta(
        entries: {key('one'): entry('one')},
        reservations: {
          'one.song': {'owner': 'one', 'stem': 'one'},
        },
        qualifications: {
          key('one'): {'account': 'A'},
        },
        limitBytes: 100,
      ),
    );
    await expectLater(
      store.applyDelta(
        PlaybackCacheDelta(
          entries: {
            key('bad'): {...entry('bad'), 'size': -1},
          },
          deletedQualifications: {key('one')},
          limitBytes: 200,
        ),
      ),
      throwsStateError,
    );
    final state = await store.load();
    expect(state['limitBytes'], 100);
    expect(state['qualifications'], contains(key('one')));
    expect(state['totals'], {'audio': 4, 'lyrics': 0});
    await store.applyDelta(
      PlaybackCacheDelta(
        deletedEntries: {key('one')},
        deletedQualifications: {key('one')},
        deletedReservations: {'one.song'},
      ),
    );
    expect((await store.load())['totals'], {'audio': 0, 'lyrics': 0});
  });

  test('reservation conflict rolls back associated entry', () async {
    await store.applyDelta(
      PlaybackCacheDelta(
        reservations: {
          'data': {'owner': 'one'},
        },
      ),
    );
    await expectLater(
      store.applyDelta(
        PlaybackCacheDelta(
          entries: {key('two'): entry('two')},
          reservations: {
            'data': {'owner': 'two'},
          },
        ),
      ),
      throwsStateError,
    );
    expect((await store.load())['entries'], isEmpty);
  });

  test(
    'deleting entries are excluded from LRU and still counted until removal',
    () async {
      await store.applyDelta(
        PlaybackCacheDelta(
          entries: {
            key('one'): {...entry('one'), 'state': 'deleting'},
          },
        ),
      );
      expect(await store.lru(), isEmpty);
      expect((await store.load())['totals']['audio'], 4);
    },
  );

  test(
    'empty delta sends no transaction; frozen delta remains immutable',
    () async {
      await store.applyDelta(PlaybackCacheDelta());
      expect(store.transactionCount, 0);
      final source = entry('one');
      final delta = PlaybackCacheDelta(entries: {key('one'): source});
      (source['ranges'] as List).single[1] = 2;
      expect(delta.entries[key('one')]!['ranges'], [
        [0, 4],
      ]);
      await store.applyDelta(delta);
      expect(
        (await store.load())['entries'][key('one')],
        isNot(contains('ranges')),
      );
    },
  );

  test('old schemas are rejected without migration or deletion', () async {
    final path = '${directory.path}/old.sqlite';
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE entries(document TEXT)');
    db.execute("INSERT INTO entries VALUES ('old')");
    db.execute('PRAGMA user_version=1');
    db.dispose();
    await expectLater(PlaybackCacheStore.open(path), throwsStateError);
    final check = sqlite3.open(path);
    expect(
      check.select('SELECT document FROM entries').single['document'],
      'old',
    );
    check.dispose();
  });

  test('corruption and inaccessible paths retain SQLite error codes', () async {
    final corrupt = File('${directory.path}/corrupt.sqlite');
    await corrupt.writeAsString('not SQLite');
    await expectLater(
      PlaybackCacheStore.open(corrupt.path),
      throwsA(
        isA<PlaybackCacheStoreException>()
            .having((e) => e.sqliteResultCode, 'code', SqlError.SQLITE_NOTADB)
            .having((e) => e.isCorrupt, 'corrupt', true),
      ),
    );
    await expectLater(
      PlaybackCacheStore.open('${directory.path}/missing/cache.sqlite'),
      throwsA(
        isA<PlaybackCacheStoreException>()
            .having((e) => e.sqliteResultCode, 'code', SqlError.SQLITE_CANTOPEN)
            .having((e) => e.isCorrupt, 'corrupt', false),
      ),
    );
  });
}
