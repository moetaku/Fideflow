import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';

/// Preserves SQLite error codes across the database worker boundary.
final class PlaybackCacheStoreException extends StateError {
  PlaybackCacheStoreException._fromError(Object error, {bool opening = false})
    : sqliteResultCode = error is SqliteException ? error.resultCode : null,
      super(
        opening ? 'playback.database.openFailed: $error' : error.toString(),
      );

  final int? sqliteResultCode;
  bool get isCorrupt =>
      sqliteResultCode == SqlError.SQLITE_CORRUPT ||
      sqliteResultCode == SqlError.SQLITE_NOTADB;
}

/// An immutable batch. Deletes apply before upserts in the same transaction.
/// Documents are copied without JSON encoding before crossing the isolate.
final class PlaybackCacheDelta {
  PlaybackCacheDelta({
    Map<String, Map<String, dynamic>> entries = const {},
    Set<String> deletedEntries = const {},
    Map<String, Map<String, dynamic>> reservations = const {},
    Set<String> deletedReservations = const {},
    Map<String, Map<String, dynamic>> qualifications = const {},
    Set<String> deletedQualifications = const {},
    Map<String, int> access = const {},
    this.limitBytes,
  }) : entries = _documents(entries),
       deletedEntries = Set.unmodifiable(deletedEntries),
       reservations = _documents(reservations),
       deletedReservations = Set.unmodifiable(deletedReservations),
       qualifications = _documents(qualifications),
       deletedQualifications = Set.unmodifiable(deletedQualifications),
       access = Map.unmodifiable(access);

  final Map<String, Map<String, dynamic>> entries, reservations, qualifications;
  final Set<String> deletedEntries, deletedReservations, deletedQualifications;
  final Map<String, int> access;
  final int? limitBytes;
  bool get isEmpty =>
      entries.isEmpty &&
      deletedEntries.isEmpty &&
      reservations.isEmpty &&
      deletedReservations.isEmpty &&
      qualifications.isEmpty &&
      deletedQualifications.isEmpty &&
      access.isEmpty &&
      limitBytes == null;
  int get documentCount =>
      entries.length + reservations.length + qualifications.length;
  Map<String, dynamic> toMessage() => {
    'entries': entries,
    'deletedEntries': deletedEntries.toList(),
    'reservations': reservations,
    'deletedReservations': deletedReservations.toList(),
    'qualifications': qualifications,
    'deletedQualifications': deletedQualifications.toList(),
    'access': access,
    'limitBytes': limitBytes,
  };
  static Map<String, Map<String, dynamic>> _documents(
    Map<String, Map<String, dynamic>> input,
  ) => Map.unmodifiable({
    for (final e in input.entries)
      e.key: _copy(e.value) as Map<String, dynamic>,
  });
  static dynamic _copy(dynamic value) => switch (value) {
    final Map value => Map<String, dynamic>.unmodifiable({
      for (final e in value.entries) e.key as String: _copy(e.value),
    }),
    final List value => List<dynamic>.unmodifiable(value.map(_copy)),
    _ => value,
  };
}

/// Dedicated database worker. No SQLite work runs on the audio/UI isolate.
final class PlaybackCacheStore {
  PlaybackCacheStore._(this._port, this._isolate);
  final SendPort _port;
  final Isolate _isolate;
  int _transactionCount = 0;
  int _encodedDocuments = 0;
  int get transactionCount => _transactionCount;
  int get encodedDocuments => _encodedDocuments;
  static Future<PlaybackCacheStore> open(String path) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_worker, [path, ready.sendPort]);
    final result = await ready.first;
    ready.close();
    if (result is! SendPort) {
      isolate.kill();
      if (result is PlaybackCacheStoreException) throw result;
      throw StateError('playback.database.openFailed: $result');
    }
    return PlaybackCacheStore._(result, isolate);
  }

  Future<dynamic> _request(String operation, [dynamic value]) async {
    final reply = ReceivePort();
    try {
      _port.send([operation, value, reply.sendPort]);
      final response = await reply.first as List;
      if (response[0] != true) throw response[1] as PlaybackCacheStoreException;
      return response[1];
    } finally {
      reply.close();
    }
  }

  Future<Map<String, dynamic>> load() async =>
      Map<String, dynamic>.from(await _request('load') as Map);
  Future<void> applyDelta(PlaybackCacheDelta delta) async {
    if (delta.isEmpty) return;
    await _request('delta', {
      ...delta.toMessage(),
      'entries': {
        for (final e in delta.entries.entries) e.key: summary(e.key, e.value),
      },
    });
    _transactionCount++;
    _encodedDocuments +=
        delta.reservations.length + delta.qualifications.length;
  }

  Future<List<Map<String, dynamic>>> lru({
    int limit = 128,
    int offset = 0,
  }) async => [
    for (final row in await _request('lru', [limit, offset]) as List)
      Map<String, dynamic>.from(row as Map),
  ];

  /// The only entry representation crossing the database boundary.
  static Map<String, dynamic> summary(String key, Map entry) {
    final identity = entry['identity'] as List? ?? jsonDecode(key) as List;
    final audio = entry['kind'] == 'audio';
    return {
      'identity': identity,
      'songKey': jsonEncode(identity.take(2).toList()),
      'kind': entry['kind'],
      'qualityKey': audio ? identity.last : null,
      'documentPath':
          entry['documentPath'] ??
          (audio ? entry['indexName'] : entry['fileName']),
      'size': entry['size'],
      'access': entry['access'],
      'revision': entry['revision'],
      'state': entry['state'] ?? 'ready',
    };
  }

  Future<void> close() async {
    await _request('close');
    _isolate.kill();
  }

  static void _worker(List<dynamic> args) {
    final ready = args[1] as SendPort;
    Database? opened;
    try {
      final db = opened = sqlite3.open(args[0] as String);
      final version =
          db.select('PRAGMA user_version').single.values.single as int;
      if ((version != 0 && version != 2) ||
          db
              .select(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='entries'",
              )
              .isNotEmpty) {
        throw StateError(
          'cache.unsupportedSchema: clear the old playback cache',
        );
      }
      db.execute('PRAGMA journal_mode=WAL');
      // Cache summaries may lose recent transactions on power failure. Files
      // remain independently validated; process crashes still retain WAL commits.
      db.execute('PRAGMA synchronous=NORMAL');
      db.execute(
        'CREATE TABLE IF NOT EXISTS config (id INTEGER PRIMARY KEY CHECK(id=1), limitBytes INTEGER NOT NULL)',
      );
      db.execute(
        "CREATE TABLE IF NOT EXISTS cache_entries (resource_key TEXT PRIMARY KEY NOT NULL, song_key TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('audio','lyrics')), quality_key TEXT, document_path TEXT NOT NULL, effective_bytes INTEGER NOT NULL CHECK(effective_bytes>=0), last_access INTEGER NOT NULL, revision INTEGER NOT NULL CHECK(revision>=0), state TEXT NOT NULL CHECK(state IN ('ready','deleting')), CHECK((kind='audio' AND quality_key IS NOT NULL) OR (kind='lyrics' AND quality_key IS NULL)))",
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS reservations (name TEXT PRIMARY KEY, owner TEXT NOT NULL, document TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS offline_qualification (key TEXT PRIMARY KEY, document TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS totals (id INTEGER PRIMARY KEY CHECK(id=1), audio INTEGER NOT NULL, lyrics INTEGER NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS identity_mappings (identity TEXT PRIMARY KEY, stem TEXT UNIQUE NOT NULL)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS ix_cache_entries_song ON cache_entries(song_key)',
      );
      db.execute(
        "CREATE INDEX IF NOT EXISTS ix_cache_entries_lru ON cache_entries(last_access, resource_key) WHERE state='ready'",
      );
      db.execute('PRAGMA user_version=2');
      final statements = <String, PreparedStatement>{
        'old': db.prepare(
          'SELECT effective_bytes, kind FROM cache_entries WHERE resource_key=?',
        ),
        'deleteEntry': db.prepare(
          'DELETE FROM cache_entries WHERE resource_key=?',
        ),
        'entry': db.prepare(
          'INSERT INTO cache_entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(resource_key) DO UPDATE SET song_key=excluded.song_key, kind=excluded.kind, quality_key=excluded.quality_key, document_path=excluded.document_path, effective_bytes=excluded.effective_bytes, last_access=excluded.last_access, revision=excluded.revision, state=excluded.state',
        ),
        'access': db.prepare(
          'UPDATE cache_entries SET last_access=? WHERE resource_key=?',
        ),
        'reservation': db.prepare(
          'INSERT OR REPLACE INTO reservations VALUES (?, ?, ?)',
        ),
        'deleteReservation': db.prepare(
          'DELETE FROM reservations WHERE name=?',
        ),
        'mapping': db.prepare(
          'INSERT INTO identity_mappings VALUES (?, ?) ON CONFLICT(identity) DO UPDATE SET stem=excluded.stem',
        ),
        'deleteMapping': db.prepare(
          'DELETE FROM identity_mappings WHERE identity=? AND stem=?',
        ),
        'oldReservation': db.prepare(
          'SELECT owner, document FROM reservations WHERE name=?',
        ),
        'qualification': db.prepare(
          'INSERT OR REPLACE INTO offline_qualification VALUES (?, ?)',
        ),
        'deleteQualification': db.prepare(
          'DELETE FROM offline_qualification WHERE key=?',
        ),
        'config': db.prepare('INSERT OR REPLACE INTO config VALUES (1, ?)'),
        'totals': db.prepare(
          'INSERT INTO totals VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET audio=audio+excluded.audio, lyrics=lyrics+excluded.lyrics',
        ),
      };
      // One-time repair for databases predating incremental totals.
      if (db.select('SELECT id FROM totals WHERE id=1').isEmpty) {
        var audio = 0, lyrics = 0;
        for (final row in db.select(
          'SELECT effective_bytes, kind FROM cache_entries',
        )) {
          if (row['kind'] == 'audio') {
            audio += row['effective_bytes'] as int;
          } else {
            lyrics += row['effective_bytes'] as int;
          }
        }
        db.execute('INSERT INTO totals VALUES (1, ?, ?)', [audio, lyrics]);
      }
      final requests = ReceivePort();
      ready.send(requests.sendPort);
      String mappingIdentity(String name, Map r) =>
          '${r['owner']}:${name.endsWith('.song')
              ? 'song'
              : name.endsWith('.quality')
              ? 'quality'
              : 'document'}';
      requests.listen((message) {
        final m = message as List;
        final reply = m[2] as SendPort;
        try {
          switch (m[0]) {
            case 'load':
              reply.send([
                true,
                {
                  'limitBytes':
                      db
                          .select('SELECT limitBytes FROM config')
                          .firstOrNull?['limitBytes'] ??
                      2000000000,
                  'entries': {
                    for (final r in db.select('SELECT * FROM cache_entries'))
                      r['resource_key']: {
                        'identity': jsonDecode(r['resource_key'] as String),
                        'songKey': r['song_key'],
                        'kind': r['kind'],
                        'qualityKey': r['quality_key'],
                        'documentPath': r['document_path'],
                        'size': r['effective_bytes'],
                        'access': r['last_access'],
                        'revision': r['revision'],
                        'state': r['state'],
                      },
                  },
                  'reservations': {
                    for (final r in db.select(
                      'SELECT name, document FROM reservations',
                    ))
                      r['name']: jsonDecode(r['document'] as String),
                  },
                  'qualifications': {
                    for (final r in db.select(
                      'SELECT key, document FROM offline_qualification',
                    ))
                      r['key']: jsonDecode(r['document'] as String),
                  },
                  'totals': {
                    ...db
                        .select('SELECT audio, lyrics FROM totals WHERE id=1')
                        .single,
                  },
                },
              ]);
            case 'delta':
              final s = m[1] as Map;
              db.execute('BEGIN IMMEDIATE');
              try {
                var audio = 0, lyrics = 0;
                void subtract(String key) {
                  final old = statements['old']!.select([key]).firstOrNull;
                  if (old == null) return;
                  if (old['kind'] == 'audio') {
                    audio -= old['effective_bytes'] as int;
                  } else {
                    lyrics -= old['effective_bytes'] as int;
                  }
                }

                for (final key in s['deletedEntries'] as List) {
                  subtract(key as String);
                  statements['deleteEntry']!.execute([key]);
                }
                for (final item in (s['entries'] as Map).entries) {
                  final e = item.value as Map;
                  subtract(item.key as String);
                  statements['entry']!.execute([
                    item.key,
                    e['songKey'],
                    e['kind'],
                    e['qualityKey'],
                    e['documentPath'],
                    e['size'],
                    e['access'],
                    e['revision'],
                    e['state'] ?? 'ready',
                  ]);
                  if (e['kind'] == 'audio') {
                    audio += e['size'] as int;
                  } else {
                    lyrics += e['size'] as int;
                  }
                }
                for (final item in (s['access'] as Map).entries) {
                  statements['access']!.execute([item.value, item.key]);
                }
                for (final name in s['deletedReservations'] as List) {
                  final old = statements['oldReservation']!.select([
                    name,
                  ]).firstOrNull;
                  if (old != null) {
                    final r = jsonDecode(old['document'] as String) as Map;
                    if (r['stem'] is String) {
                      statements['deleteMapping']!.execute([
                        mappingIdentity(name as String, r),
                        r['stem'],
                      ]);
                    }
                  }
                  statements['deleteReservation']!.execute([name]);
                }
                for (final item in (s['reservations'] as Map).entries) {
                  final r = item.value as Map;
                  final existing = statements['oldReservation']!.select([
                    item.key,
                  ]).firstOrNull;
                  if (existing != null && existing['owner'] != r['owner']) {
                    throw StateError('cache.reservationOwner');
                  }
                  final encoded = jsonEncode(r);
                  if (r['stem'] is String) {
                    statements['mapping']!.execute([
                      mappingIdentity(item.key as String, r),
                      r['stem'],
                    ]);
                  }
                  statements['reservation']!.execute([
                    item.key,
                    r['owner'],
                    encoded,
                  ]);
                }
                for (final key in s['deletedQualifications'] as List) {
                  statements['deleteQualification']!.execute([key]);
                }
                for (final item in (s['qualifications'] as Map).entries) {
                  statements['qualification']!.execute([
                    item.key,
                    jsonEncode(item.value),
                  ]);
                }
                if (s['limitBytes'] != null) {
                  statements['config']!.execute([s['limitBytes']]);
                }
                if (audio != 0 || lyrics != 0) {
                  statements['totals']!.execute([audio, lyrics]);
                }
                db.execute('COMMIT');
              } catch (_) {
                db.execute('ROLLBACK');
                rethrow;
              }
              reply.send([true, null]);
            case 'lru':
              final args = m[1] as List;
              reply.send([
                true,
                [
                  for (final row in db.select(
                    "SELECT resource_key, last_access FROM cache_entries WHERE state='ready' ORDER BY last_access, resource_key LIMIT ? OFFSET ?",
                    args,
                  ))
                    {'key': row['resource_key'], 'access': row['last_access']},
                ],
              ]);
            case 'close':
              for (final statement in statements.values) {
                statement.dispose();
              }
              db.dispose();
              requests.close();
              reply.send([true, null]);
          }
        } catch (error) {
          reply.send([false, PlaybackCacheStoreException._fromError(error)]);
        }
      });
    } catch (error) {
      opened?.dispose();
      ready.send(PlaybackCacheStoreException._fromError(error, opening: true));
    }
  }
}
