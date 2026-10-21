import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';
import 'recent_playback_store.dart';

/// Durable history, independent of disposable metadata/audio caches.
final class SqliteRecentPlaybackStore implements RecentPlaybackStore {
  SqliteRecentPlaybackStore._(this._port, this._isolate);
  final SendPort _port;
  final Isolate _isolate;
  bool _closed = false;
  static Future<SqliteRecentPlaybackStore> open(String path) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_worker, [path, ready.sendPort]);
    final result = await ready.first;
    ready.close();
    if (result is! SendPort) {
      isolate.kill();
      throw StateError('recent.openFailed: $result');
    }
    return SqliteRecentPlaybackStore._(result, isolate);
  }

  Future<dynamic> _request(String op, dynamic value) async {
    if (_closed) throw StateError('recent.closed');
    final reply = ReceivePort();
    try {
      _port.send([op, value, reply.sendPort]);
      final result = await reply.first as List;
      if (result[0] != true) throw StateError(result[1] as String);
      return result[1];
    } finally {
      reply.close();
    }
  }

  @override
  Future<void> record(List<RecentPlaybackEntry> entries) async =>
      await _request('record', entries.map((e) => e.toMap()).toList());
  @override
  Future<List<RecentPlaybackEntry>> read(
    RecentKind kind, {
    int limit = 1000,
    int offset = 0,
  }) async {
    final rows =
        await _request('read', [kind.storageCode, limit, offset]) as List;
    return [
      for (final row in rows)
        if (RecentPlaybackEntry.tryFromMap(row) case final entry?
            when entry.kind == kind)
          entry,
    ];
  }

  @override
  Future<void> delete(RecentKind kind, List<String> ids) async =>
      await _request('delete', [
        kind.storageCode,
        ids.map((id) => recentPlaybackId(kind, id)).toList(),
      ]);
  @override
  Future<void> clear(RecentKind kind) async =>
      await _request('clear', kind.storageCode);
  @override
  Future<void> close() async {
    if (_closed) return;
    await _request('close', null);
    _closed = true;
    _isolate.kill();
  }

  static void _worker(List<dynamic> args) {
    Database? db;
    try {
      final path = args[0] as String;
      File(path).parent.createSync(recursive: true);
      final database = db = sqlite3.open(path);
      database.execute('PRAGMA journal_mode=WAL');
      database.execute('PRAGMA synchronous=FULL');
      final version =
          database.select('PRAGMA user_version').first.values.first as int;
      if (version > 1) throw StateError('recent.unsupportedVersion');
      database.execute(
        'CREATE TABLE IF NOT EXISTS recent_playback (kind INTEGER NOT NULL, id TEXT NOT NULL, played_at INTEGER NOT NULL, document TEXT NOT NULL, PRIMARY KEY(kind,id))',
      );
      database.execute(
        'CREATE INDEX IF NOT EXISTS recent_order ON recent_playback(kind,played_at DESC,id)',
      );
      database.execute('PRAGMA user_version=1');
      final requests = ReceivePort();
      (args[1] as SendPort).send(requests.sendPort);
      requests.listen((dynamic message) {
        final m = message as List;
        final reply = m[2] as SendPort;
        try {
          dynamic result;
          switch (m[0]) {
            case 'record':
              database.execute('BEGIN IMMEDIATE');
              try {
                for (final e in m[1] as List) {
                  database.execute(
                    'INSERT INTO recent_playback VALUES (?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET played_at=excluded.played_at,document=excluded.document',
                    [e['kind'], e['id'], e['at'], jsonEncode(e)],
                  );
                }
                for (final kind in RecentKind.values) {
                  database.execute(
                    'DELETE FROM recent_playback WHERE kind=? AND id IN (SELECT id FROM recent_playback WHERE kind=? ORDER BY played_at DESC,id LIMIT -1 OFFSET 1000)',
                    [kind.storageCode, kind.storageCode],
                  );
                }
                database.execute('COMMIT');
              } catch (_) {
                database.execute('ROLLBACK');
                rethrow;
              }
            case 'read':
              final v = m[1] as List;
              result = database
                  .select(
                    'SELECT document FROM recent_playback WHERE kind=? ORDER BY played_at DESC,id LIMIT ? OFFSET ?',
                    v,
                  )
                  .map((r) {
                    try {
                      return jsonDecode(r['document'] as String);
                    } on FormatException {
                      return null;
                    }
                  })
                  .toList();
            case 'delete':
              final v = m[1] as List;
              database.execute('BEGIN IMMEDIATE');
              try {
                for (final id in v[1] as List) {
                  database.execute(
                    'DELETE FROM recent_playback WHERE kind=? AND id=?',
                    [v[0], id],
                  );
                }
                database.execute('COMMIT');
              } catch (_) {
                database.execute('ROLLBACK');
                rethrow;
              }
            case 'clear':
              database.execute('DELETE FROM recent_playback WHERE kind=?', [
                m[1],
              ]);
            case 'close':
              database.dispose();
              requests.close();
            default:
              throw StateError('recent.unknownOperation');
          }
          reply.send([true, result]);
        } catch (e) {
          reply.send([false, e.toString()]);
        }
      });
    } catch (e) {
      db?.dispose();
      (args[1] as SendPort).send(e.toString());
    }
  }
}

/// Opens on first use; failure remains retryable and never blocks app startup.
final class LazyRecentPlaybackStore implements RecentPlaybackStore {
  LazyRecentPlaybackStore(
    this.path, {
    Future<RecentPlaybackStore> Function(String)? openStore,
  }) : _openStore = openStore ?? SqliteRecentPlaybackStore.open;
  final String path;
  final Future<RecentPlaybackStore> Function(String) _openStore;
  Future<RecentPlaybackStore>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  Future<RecentPlaybackStore> _open() {
    if (_closed) return Future.error(StateError('recent.closed'));
    return _opening ??= _initialize();
  }

  Future<RecentPlaybackStore> _initialize() async {
    try {
      return await Future.sync(() => _openStore(path));
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  @override
  Future<void> record(List<RecentPlaybackEntry> entries) async =>
      (await _open()).record(entries);
  @override
  Future<List<RecentPlaybackEntry>> read(
    RecentKind kind, {
    int limit = 1000,
    int offset = 0,
  }) async => (await _open()).read(kind, limit: limit, offset: offset);
  @override
  Future<void> delete(RecentKind kind, List<String> ids) async =>
      (await _open()).delete(kind, ids);
  @override
  Future<void> clear(RecentKind kind) async => (await _open()).clear(kind);
  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    final pending = _opening;
    if (pending == null) return;
    final RecentPlaybackStore store;
    try {
      store = await pending;
    } catch (_) {
      return;
    }
    await store.close();
  }
}
