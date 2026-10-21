import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:sqlite3/sqlite3.dart';

import 'cache_models.dart';
import 'cache_store.dart';

/// The SQLite-backed metadata cache (design §3, §4, §10).
///
/// One file holds the normalized entities, the playlist snapshots, the paged
/// lists, the negative cache and the artwork index. Rows are committed in
/// transactions, so a snapshot never becomes visible half-written, and the file
/// is disposable: an unreadable database degrades to a store that misses rather
/// than failing a launch.
///
/// It performs no I/O beyond its own database — the artwork files a dropped row
/// named are handed back to the caller to delete. sqlite3 is a synchronous FFI
/// binding, so a caller keeps this off the first frame and off the playback
/// path; the port is asynchronous so the work can move to a background isolate
/// without changing its shape.
final class SqliteMetadataCacheStore
    implements MetadataCacheStore, PlaylistCacheInvalidator {
  SqliteMetadataCacheStore._(this._db, this._now, this._onDiagnostic);

  /// The schema this build reads and writes. A file written by a newer build is
  /// disposable, so it is rebuilt rather than guessed at (design §4).
  static const int schemaVersion = 9;

  static const String _tracks = 'cache_tracks';
  static const String _trackGroups = 'cache_track_groups';
  static const String _absentTracks = 'cache_absent_tracks';
  static const String _playlists = 'cache_playlists';
  static const String _playlistEntries = 'cache_playlist_entries';
  static const String _idPages = 'cache_id_pages';
  static const String _artwork = 'cache_artwork';
  static const String _catalogEntities = 'cache_catalog_entities';
  static const String _homeSections = 'cache_home_sections';
  static const String _dailySongs = 'cache_daily_songs';
  static const String _partitions = 'cache_partitions';
  static const String _meta = 'cache_meta';

  static const String _userPlaylistKind = 'user_playlist';
  static const String _searchKind = 'search';

  /// Reads are written back in batches rather than per row per frame
  /// (design §10).
  static const int _accessFlushThreshold = 64;

  /// The tables that hold rebuildable cache data, in the order they can be
  /// dropped.
  static const List<String> _dataTables = [
    _tracks,
    _trackGroups,
    _absentTracks,
    _playlists,
    _playlistEntries,
    _idPages,
    _artwork,
    _catalogEntities,
    _homeSections,
    _dailySongs,
    _partitions,
  ];

  /// Opens the store at [path], returning a [DisabledMetadataCacheStore] when
  /// the file cannot be used.
  ///
  /// [onDiagnostic] receives stable codes only — never a record's contents, a
  /// search term or a URL.
  static MetadataCacheStore open({
    required String path,
    DateTime Function()? now,
    void Function(String diagnostic)? onDiagnostic,
  }) {
    final clock = now ?? DateTime.now;
    try {
      File(path).parent.createSync(recursive: true);
      final db = sqlite3.open(path);
      final store = SqliteMetadataCacheStore._(db, clock, onDiagnostic);
      store._prepareSchema();
      return store;
    } on SqliteException catch (error) {
      onDiagnostic?.call('cache.store.openFailed.${error.resultCode}');
      return const DisabledMetadataCacheStore();
    } on FileSystemException {
      onDiagnostic?.call('cache.store.unwritable');
      return const DisabledMetadataCacheStore();
    }
  }

  final Database _db;
  final DateTime Function() _now;
  final void Function(String diagnostic)? _onDiagnostic;
  final Map<String, _PendingAccess> _pendingAccess = {};

  String _storeInstanceId = '';
  int _cacheGeneration = 0;
  int _nextWriteSequence = 1;

  /// Set once the file has proven unusable, so later calls do not keep hitting
  /// a corrupt database.
  bool _degraded = false;
  bool _closed = false;

  @override
  int get cacheGeneration => _cacheGeneration;

  // -------------------------------------------------------------------------
  // Schema
  // -------------------------------------------------------------------------

  void _prepareSchema() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');

    if (_db.userVersion == 3) {
      _db.execute('ALTER TABLE $_playlists ADD COLUMN creator_id TEXT');
      _db.execute('ALTER TABLE $_playlists ADD COLUMN privacy INTEGER');
      _db.userVersion = 4;
    }
    if (_db.userVersion == 4) {
      _db.execute('ALTER TABLE $_playlists ADD COLUMN metadata_json TEXT');
      _db.userVersion = 5;
    }
    if (_db.userVersion == 5) {
      _db.execute('ALTER TABLE $_tracks ADD COLUMN audio_specs_json TEXT');
      _db.userVersion = 6;
    }
    if (_db.userVersion == 6) {
      _db.execute(
        'ALTER TABLE $_tracks ADD COLUMN translation_names_json TEXT',
      );
      _db.userVersion = 7;
    }
    if (_db.userVersion == 7) {
      // Legacy origin also labels album/artist responses as detail, so it
      // cannot safely establish that song/detail was fetched.
      _db.execute(
        'ALTER TABLE $_tracks ADD COLUMN is_detail INTEGER NOT NULL DEFAULT 0',
      );
      _db.userVersion = 8;
    }
    if (_db.userVersion == 8) {
      _db.execute('ALTER TABLE $_tracks DROP COLUMN origin');
      _db.userVersion = 9;
    }
    if (_db.userVersion != schemaVersion && _db.userVersion != 0) {
      // Written by a different build. Nothing here is authoritative, so it is
      // rebuilt instead of being read with the wrong shape (design §4).
      _onDiagnostic?.call('cache.store.unknownSchema');
      for (final table in _dataTables) {
        _db.execute('DROP TABLE IF EXISTS $table');
      }
      _db.userVersion = 0;
    }

    for (final statement in _schemaStatements) {
      _db.execute(statement);
    }
    _db.userVersion = schemaVersion;
    _cacheGeneration = int.tryParse(_readMeta('cache_generation') ?? '') ?? 0;
    _nextWriteSequence =
        int.tryParse(_readMeta('next_write_sequence') ?? '') ?? 1;
    _storeInstanceId = _readMeta('store_instance_id') ?? '';
    if (_storeInstanceId.isEmpty) {
      _storeInstanceId = 'store_${_now().microsecondsSinceEpoch}';
      _writeMeta('store_instance_id', _storeInstanceId);
    }
  }

  static const List<String> _schemaStatements = [
    '''
CREATE TABLE IF NOT EXISTS $_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''',
    '''
CREATE TABLE IF NOT EXISTS $_tracks (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  track_id TEXT NOT NULL,
  title TEXT,
  artists_json TEXT,
  album_id TEXT,
  album_title TEXT,
  artwork_uri TEXT,
  duration_ms INTEGER,
  is_detail INTEGER NOT NULL DEFAULT 0,
  availability TEXT,
  max_potential_quality TEXT,
  fee TEXT,
  alias_json TEXT,
  translation_names_json TEXT,
  objective_quality TEXT,
  audio_specs_json TEXT,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  etag TEXT,
  last_modified INTEGER,
  request_generation INTEGER NOT NULL,
  PRIMARY KEY (namespace, account_key, track_id)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_trackGroups (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  track_id TEXT NOT NULL,
  field_group TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  PRIMARY KEY (namespace, account_key, track_id, field_group)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_absentTracks (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  track_id TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  PRIMARY KEY (namespace, account_key, track_id)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_playlists (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  playlist_id TEXT NOT NULL,
  title TEXT,
  subtitle TEXT,
  track_count INTEGER,
  artwork_uri TEXT,
  description TEXT,
  special_type INTEGER,
  creator_id TEXT,
  privacy INTEGER,
  metadata_json TEXT,
  total_count INTEGER,
  is_complete INTEGER NOT NULL,
  generation INTEGER NOT NULL,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  etag TEXT,
  last_modified INTEGER,
  PRIMARY KEY (namespace, account_key, playlist_id)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_playlistEntries (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  playlist_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  track_id TEXT NOT NULL,
  PRIMARY KEY (namespace, account_key, playlist_id, ordinal)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_idPages (
  kind TEXT NOT NULL,
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  query_key TEXT NOT NULL,
  page_offset INTEGER NOT NULL,
  ids_json TEXT NOT NULL,
  page_limit INTEGER NOT NULL,
  has_more INTEGER NOT NULL,
  is_complete INTEGER NOT NULL,
  generation INTEGER NOT NULL,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  PRIMARY KEY (kind, namespace, account_key, query_key, page_offset)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_artwork (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  asset_key TEXT NOT NULL,
  file_path TEXT NOT NULL,
  sha256 TEXT,
  mime_type TEXT,
  byte_size INTEGER NOT NULL,
  pixel_width INTEGER,
  pixel_height INTEGER,
  size_bucket INTEGER,
  resource_version TEXT,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  etag TEXT,
  last_modified INTEGER,
  PRIMARY KEY (namespace, account_key, asset_key)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_catalogEntities (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  summary_json TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  PRIMARY KEY (namespace, account_key, entity_type, entity_id)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_homeSections (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  section_id TEXT NOT NULL,
  section_kind TEXT NOT NULL,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  items_json TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  last_access_at INTEGER,
  PRIMARY KEY (namespace, account_key, section_id)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_dailySongs (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  date_key TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  fresh_until INTEGER NOT NULL,
  stale_until INTEGER NOT NULL,
  retain_until INTEGER NOT NULL,
  last_access_at INTEGER,
  PRIMARY KEY (namespace, account_key, date_key)
)''',
    '''
CREATE TABLE IF NOT EXISTS $_partitions (
  namespace TEXT NOT NULL,
  account_key TEXT NOT NULL,
  generation INTEGER NOT NULL,
  fenced INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (namespace, account_key)
)''',
    'CREATE INDEX IF NOT EXISTS ix_tracks_access ON $_tracks (last_access_at, fetched_at)',
    'CREATE INDEX IF NOT EXISTS ix_tracks_expiry ON $_tracks (stale_until)',
    'CREATE INDEX IF NOT EXISTS ix_playlists_access ON $_playlists (last_access_at, fetched_at)',
    'CREATE INDEX IF NOT EXISTS ix_id_pages_access ON $_idPages (last_access_at, fetched_at)',
    'CREATE INDEX IF NOT EXISTS ix_artwork_access ON $_artwork (last_access_at, fetched_at)',
    'CREATE INDEX IF NOT EXISTS ix_catalog_entities_access ON $_catalogEntities (last_access_at, fetched_at)',
    'CREATE INDEX IF NOT EXISTS ix_home_sections_access ON $_homeSections (last_access_at, fetched_at)',
    'CREATE INDEX IF NOT EXISTS ix_daily_songs_access ON $_dailySongs (last_access_at, fetched_at)',
  ];

  // -------------------------------------------------------------------------
  // Error handling
  // -------------------------------------------------------------------------

  /// Runs [body], turning a database failure into a miss.
  ///
  /// Corruption and "not a database" mark the store degraded: the file is
  /// disposable, and every later call short-circuits instead of failing a page
  /// (design §4, §10).
  T? _guard<T>(T? Function() body) {
    if (_closed || _degraded) return null;
    try {
      return body();
    } on SqliteException catch (error) {
      _onDiagnostic?.call('cache.store.sqliteError.${error.resultCode}');
      if (error.resultCode == SqlError.SQLITE_CORRUPT ||
          error.resultCode == SqlError.SQLITE_NOTADB) {
        _degraded = true;
      }
      return null;
    }
  }

  void _transaction(void Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      try {
        _db.execute('ROLLBACK');
      } on SqliteException {
        // The rollback failed; the original failure is the one worth reporting.
      }
      rethrow;
    }
  }

  String? _readMeta(String key) {
    final rows = _db.select('SELECT value FROM $_meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void _writeMeta(String key, String value) {
    _db.execute(
      'INSERT INTO $_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  static int _ms(DateTime time) => time.toUtc().millisecondsSinceEpoch;

  static DateTime _time(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(value! as int, isUtc: true);

  static DateTime? _timeOrNull(Object? value) =>
      value == null ? null : _time(value);

  static int _bool(bool value) => value ? 1 : 0;

  static String _placeholders(int count) =>
      List<String>.filled(count, '?').join(', ');

  static ArtworkSizeBucket? _bucketFromPixels(Object? pixels) {
    if (pixels is! int) return null;
    for (final bucket in ArtworkSizeBucket.values) {
      if (bucket.pixels == pixels) return bucket;
    }
    return null;
  }

  static List<String> _decodeIdList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final value in decoded)
        if (value is String) value,
    ];
  }

  // -------------------------------------------------------------------------
  // Access coalescing
  // -------------------------------------------------------------------------

  void _noteAccess(
    String table,
    List<String> columns,
    List<Object?> keyValues,
    DateTime at,
  ) {
    final key = '$table|${keyValues.join('|')}';
    final existing = _pendingAccess[key];
    if (existing == null || at.isAfter(existing.at)) {
      _pendingAccess[key] = _PendingAccess(table, columns, keyValues, at);
    }
    if (_pendingAccess.length >= _accessFlushThreshold) {
      _guard(() {
        _flushAccess();
        return true;
      });
    }
  }

  void _flushAccess() {
    if (_pendingAccess.isEmpty) return;
    final pending = List<_PendingAccess>.of(_pendingAccess.values);
    _pendingAccess.clear();
    _transaction(() {
      for (final entry in pending) {
        final where = entry.columns
            .map((column) => '$column = ?')
            .join(' AND ');
        _db.execute(
          'UPDATE ${entry.table} SET last_access_at = ? WHERE $where',
          [_ms(entry.at), ...entry.values],
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Tracks
  // -------------------------------------------------------------------------

  @override
  Future<Map<TrackId, CachedTrack>> readTracks(
    CacheScope scope,
    Iterable<TrackId> ids, {
    bool includeExpired = false,
  }) async {
    final wanted = <String>{for (final id in ids) id.value}.toList();
    if (wanted.isEmpty) return const {};
    return _guard(() {
          final now = _now();
          final namespace = scope.namespace;
          final accountKey = accountKeyOf(scope);
          final placeholders = _placeholders(wanted.length);
          final rows = _db.select(
            'SELECT * FROM $_tracks WHERE namespace = ? AND account_key = ? '
            'AND track_id IN ($placeholders)',
            [namespace, accountKey, ...wanted],
          );
          if (rows.isEmpty) return const <TrackId, CachedTrack>{};

          final groupsByTrack = _groupsFor(namespace, accountKey, wanted);
          final result = <TrackId, CachedTrack>{};
          for (final row in rows) {
            final id = row['track_id']! as String;
            final track = _trackFromRow(row, id);
            if (track == null) {
              // A row that cannot produce a displayable entity is treated as
              // absent rather than half-shown. It stays in place so a later
              // response can complete it (design §4).
              continue;
            }
            final cached = CachedTrack(
              track: track,
              groups: groupsByTrack[id] ?? const {},
              envelope: _trackEnvelope(row, namespace, accountKey),

              isDetail: row['is_detail'] == 1,
            );
            if (!includeExpired &&
                cached.freshnessAt(now) == CacheFreshness.miss) {
              continue;
            }
            result[TrackId(id)] = cached;
            _noteAccess(
              _tracks,
              ['namespace', 'account_key', 'track_id'],
              [namespace, accountKey, id],
              now,
            );
          }
          return result;
        }) ??
        const {};
  }

  Map<String, Map<TrackFieldGroup, CacheEnvelope>> _groupsFor(
    String namespace,
    String accountKey,
    List<String> ids,
  ) {
    if (ids.isEmpty) return const {};
    final rows = _db.select(
      'SELECT * FROM $_trackGroups WHERE namespace = ? AND account_key = ? '
      'AND track_id IN (${_placeholders(ids.length)})',
      [namespace, accountKey, ...ids],
    );
    final result = <String, Map<TrackFieldGroup, CacheEnvelope>>{};
    for (final row in rows) {
      final group = decodeFieldGroup(row['field_group']);
      if (group == null) continue;
      (result[row['track_id']! as String] ??= {})[group] = CacheEnvelope(
        scope: scopeOf(namespace, accountKey),
        fetchedAt: _time(row['fetched_at']),
        freshUntil: _time(row['fresh_until']),
        staleUntil: _time(row['stale_until']),
      );
    }
    return result;
  }

  CacheEnvelope _trackEnvelope(Row row, String namespace, String accountKey) =>
      CacheEnvelope(
        scope: scopeOf(namespace, accountKey),
        fetchedAt: _time(row['fetched_at']),
        freshUntil: _time(row['fresh_until']),
        staleUntil: _time(row['stale_until']),
        lastAccessAt: _timeOrNull(row['last_access_at']),
        etag: row['etag'] as String?,
        lastModified: _timeOrNull(row['last_modified']),
        requestGeneration: (row['request_generation'] as int?) ?? 0,
      );

  Track? _trackFromRow(Row row, String id) {
    final title = row['title'] as String?;
    final albumId = row['album_id'] as String?;
    final albumTitle = row['album_title'] as String?;
    final durationMs = row['duration_ms'] as int?;
    final artists = decodeArtists(row['artists_json']);
    if (title == null || title.isEmpty) return null;
    if (artists.isEmpty) return null;
    if (albumId == null || albumId.isEmpty) return null;
    if (albumTitle == null || albumTitle.isEmpty) return null;
    // Zero is "the service did not say", which the UI shows as unknown; it is
    // still displayable, and the duration group stays unnamed so a later
    // response with a real length can fill it in (design §5).
    if (durationMs == null || durationMs < 0) return null;
    final artwork = row['artwork_uri'] as String?;
    final availabilityStr = row['availability'] as String?;
    final qualityStr = row['max_potential_quality'] as String?;
    final feeStr = row['fee'] as String?;
    final aliasJson = row['alias_json'] as String?;
    final objectiveQualityStr = row['objective_quality'] as String?;

    final availability = availabilityStr != null
        ? (TrackAvailability.values
                  .where((a) => a.name == availabilityStr)
                  .firstOrNull ??
              TrackAvailability.unknown)
        : TrackAvailability.unknown;
    final maxPotentialQuality = qualityStr != null
        ? (TrackQuality.values.where((q) => q.name == qualityStr).firstOrNull ??
              TrackQuality.unknown)
        : TrackQuality.unknown;
    final fee = feeStr != null
        ? (TrackFee.values.where((f) => f.name == feeStr).firstOrNull ??
              TrackFee.unknown)
        : TrackFee.unknown;
    final alias = _decodeIdList(aliasJson);
    final objectiveQuality = objectiveQualityStr != null
        ? (TrackQuality.values
              .where((q) => q.name == objectiveQualityStr)
              .firstOrNull)
        : null;

    return Track(
      id: TrackId(id),
      title: title,
      artists: artists,
      album: Album(
        id: AlbumId(albumId),
        title: albumTitle,
        artworkUri: (artwork == null || artwork.isEmpty)
            ? null
            : Uri.tryParse(artwork),
      ),
      duration: Duration(milliseconds: durationMs),
      availability: availability,
      maxPotentialQuality: maxPotentialQuality,
      fee: fee,
      alias: alias,
      translationNames: _decodeIdList(row['translation_names_json'] as String?),
      objectiveQuality: objectiveQuality,
      audioSpecs: decodeTrackAudioSpecs(row['audio_specs_json'] as String?),
    );
  }

  @override
  Future<void> putTracks(Iterable<CachedTrack> tracks) async {
    _guard(() {
      final byScope = <String, Map<String, CachedTrack>>{};
      for (final incoming in tracks) {
        final scope = incoming.envelope.scope;
        final id = incoming.track.id.value;
        final scopeKey = '${scope.namespace}\u0000${accountKeyOf(scope)}';
        final bucket = byScope[scopeKey] ??= {};
        bucket[id] = mergeCachedTrack(bucket[id], incoming);
      }
      if (byScope.isEmpty) return true;

      _transaction(() {
        for (final entry in byScope.entries) {
          final separator = entry.key.indexOf('\u0000');
          _upsertTracks(
            entry.key.substring(0, separator),
            entry.key.substring(separator + 1),
            entry.value,
          );
        }
      });
      return true;
    });
  }

  void _upsertTracks(
    String namespace,
    String accountKey,
    Map<String, CachedTrack> incoming,
  ) {
    final ids = incoming.keys.toList();
    final existing = _readTracksForMerge(namespace, accountKey, ids);

    for (final entry in incoming.entries) {
      final merged = mergeCachedTrack(existing[entry.key], entry.value);
      final envelope = merged.envelope;
      final track = merged.track;
      _db.execute(
        'INSERT INTO $_tracks (namespace, account_key, track_id, title, '
        'artists_json, album_id, album_title, artwork_uri, duration_ms, '
        'availability, max_potential_quality, fee, alias_json, translation_names_json, objective_quality, audio_specs_json, '
        'size_bytes, fetched_at, fresh_until, stale_until, last_access_at, etag, '
        'last_modified, request_generation, is_detail) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(namespace, account_key, track_id) DO UPDATE SET '
        'title = excluded.title, artists_json = excluded.artists_json, '
        'album_id = excluded.album_id, album_title = excluded.album_title, '
        'artwork_uri = excluded.artwork_uri, duration_ms = excluded.duration_ms, '
        'is_detail = excluded.is_detail, '
        'availability = excluded.availability, '
        'max_potential_quality = excluded.max_potential_quality, '
        'fee = excluded.fee, alias_json = excluded.alias_json, '
        'translation_names_json = excluded.translation_names_json, '
        'objective_quality = excluded.objective_quality, '
        'audio_specs_json = excluded.audio_specs_json, '
        'size_bytes = excluded.size_bytes, '
        'fetched_at = excluded.fetched_at, fresh_until = excluded.fresh_until, '
        'stale_until = excluded.stale_until, '
        'last_access_at = excluded.last_access_at, etag = excluded.etag, '
        'last_modified = excluded.last_modified, '
        'request_generation = excluded.request_generation',
        [
          namespace,
          accountKey,
          entry.key,
          track.title,
          encodeArtists(track.artists),
          track.album.id.value,
          track.album.title,
          track.album.artworkUri?.toString(),
          track.duration.inMilliseconds,
          track.availability.name,
          track.maxPotentialQuality.name,
          track.fee.name,
          jsonEncode(track.alias),
          jsonEncode(track.translationNames),
          track.objectiveQuality?.name,
          encodeTrackAudioSpecs(track.audioSpecs),
          _trackSize(merged),
          _ms(envelope.fetchedAt),
          _ms(envelope.freshUntil),
          _ms(envelope.staleUntil),
          envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
          envelope.etag,
          envelope.lastModified == null ? null : _ms(envelope.lastModified!),
          envelope.requestGeneration,
          merged.isDetail ? 1 : 0,
        ],
      );

      for (final group in merged.groups.entries) {
        final groupEnvelope = group.value;
        _db.execute(
          'INSERT INTO $_trackGroups (namespace, account_key, track_id, '
          'field_group, fetched_at, fresh_until, stale_until) '
          'VALUES (?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(namespace, account_key, track_id, field_group) DO UPDATE '
          'SET fetched_at = excluded.fetched_at, '
          'fresh_until = excluded.fresh_until, '
          'stale_until = excluded.stale_until',
          [
            namespace,
            accountKey,
            entry.key,
            encodeFieldGroup(group.key),
            _ms(groupEnvelope.fetchedAt),
            _ms(groupEnvelope.freshUntil),
            _ms(groupEnvelope.staleUntil),
          ],
        );
      }
    }
  }

  Map<String, CachedTrack> _readTracksForMerge(
    String namespace,
    String accountKey,
    List<String> ids,
  ) {
    if (ids.isEmpty) return const {};
    final rows = _db.select(
      'SELECT * FROM $_tracks WHERE namespace = ? AND account_key = ? '
      'AND track_id IN (${_placeholders(ids.length)})',
      [namespace, accountKey, ...ids],
    );
    if (rows.isEmpty) return const {};
    final groupsByTrack = _groupsFor(namespace, accountKey, ids);
    final result = <String, CachedTrack>{};
    for (final row in rows) {
      final id = row['track_id']! as String;
      final track = _trackFromRow(row, id);
      if (track == null) continue;
      result[id] = CachedTrack(
        track: track,
        groups: groupsByTrack[id] ?? const {},
        envelope: _trackEnvelope(row, namespace, accountKey),

        isDetail: row['is_detail'] == 1,
      );
    }
    return result;
  }

  int _trackSize(CachedTrack cached) {
    var size = 48;
    size += utf8LengthOf(cached.track.title);
    size += utf8LengthOf(encodeArtists(cached.track.artists));
    size += utf8LengthOf(cached.track.album.id.value);
    size += utf8LengthOf(cached.track.album.title);
    size += utf8LengthOf(cached.track.album.artworkUri?.toString());
    size += utf8LengthOf(cached.envelope.etag);
    size += cached.groups.length * 32;
    size += cached.track.availability.name.length;
    size += cached.track.maxPotentialQuality.name.length;
    size += cached.track.fee.name.length;
    size += jsonEncode(cached.track.alias).length;
    size += jsonEncode(cached.track.translationNames).length;
    size += encodeTrackAudioSpecs(cached.track.audioSpecs).length;
    if (cached.track.objectiveQuality != null) {
      size += cached.track.objectiveQuality!.name.length;
    }
    return size;
  }

  // -------------------------------------------------------------------------
  // Negative cache
  // -------------------------------------------------------------------------

  @override
  Future<Map<TrackId, AbsentTrackRecord>> readAbsentTracks(
    CacheScope scope,
    Iterable<TrackId> ids,
  ) async {
    final wanted = <String>{for (final id in ids) id.value}.toList();
    if (wanted.isEmpty) return const {};
    return _guard(() {
          final now = _now();
          final namespace = scope.namespace;
          final accountKey = accountKeyOf(scope);
          final rows = _db.select(
            'SELECT * FROM $_absentTracks WHERE namespace = ? AND account_key = ? '
            'AND track_id IN (${_placeholders(wanted.length)})',
            [namespace, accountKey, ...wanted],
          );
          final result = <TrackId, AbsentTrackRecord>{};
          for (final row in rows) {
            final id = row['track_id']! as String;
            result[TrackId(id)] = AbsentTrackRecord(
              trackId: TrackId(id),
              envelope: CacheEnvelope(
                scope: scopeOf(namespace, accountKey),
                fetchedAt: _time(row['fetched_at']),
                freshUntil: _time(row['fresh_until']),
                staleUntil: _time(row['stale_until']),
                lastAccessAt: _timeOrNull(row['last_access_at']),
              ),
            );
            _noteAccess(
              _absentTracks,
              ['namespace', 'account_key', 'track_id'],
              [namespace, accountKey, id],
              now,
            );
          }
          return result;
        }) ??
        const {};
  }

  void _upsertSingleAbsentTrack(CacheScope scope, AbsentTrackRecord record) {
    final envelope = record.envelope;
    _db.execute(
      'INSERT INTO $_absentTracks (namespace, account_key, track_id, '
      'size_bytes, fetched_at, fresh_until, stale_until, last_access_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, account_key, track_id) DO UPDATE SET '
      'size_bytes = excluded.size_bytes, '
      'fetched_at = excluded.fetched_at, '
      'fresh_until = excluded.fresh_until, '
      'stale_until = excluded.stale_until, '
      'last_access_at = excluded.last_access_at',
      [
        scope.namespace,
        accountKeyOf(scope),
        record.trackId.value,
        32,
        _ms(envelope.fetchedAt),
        _ms(envelope.freshUntil),
        _ms(envelope.staleUntil),
        envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
      ],
    );
  }

  @override
  Future<void> putAbsentTracks(Iterable<AbsentTrackRecord> records) async {
    _guard(() {
      _transaction(() {
        for (final record in records) {
          _upsertSingleAbsentTrack(record.envelope.scope, record);
        }
      });
      return true;
    });
  }

  // -------------------------------------------------------------------------
  // Playlists
  // -------------------------------------------------------------------------

  @override
  Future<PlaylistSnapshot?> readPlaylistSnapshot(
    CacheScope scope,
    PlaylistId id, {
    bool includeExpired = false,
  }) async => _guard(() {
    final now = _now();
    final namespace = scope.namespace;
    final accountKey = accountKeyOf(scope);
    final rows = _db.select(
      'SELECT * FROM $_playlists WHERE namespace = ? AND account_key = ? '
      'AND playlist_id = ?',
      [namespace, accountKey, id.value],
    );
    if (rows.isEmpty) return null;
    final envelope = _playlistEnvelope(rows.first);
    if (!includeExpired && envelope.freshnessAt(now) == CacheFreshness.miss) {
      return null;
    }
    final entryRows = _db.select(
      'SELECT track_id FROM $_playlistEntries WHERE namespace = ? '
      'AND account_key = ? AND playlist_id = ? ORDER BY ordinal ASC',
      [namespace, accountKey, id.value],
    );
    _noteAccess(
      _playlists,
      ['namespace', 'account_key', 'playlist_id'],
      [namespace, accountKey, id.value],
      now,
    );
    return PlaylistSnapshot(
      summary: _summaryFromRow(rows.first),
      header: _headerFromRow(rows.first),
      entryTrackIds: [
        for (final row in entryRows) TrackId(row['track_id']! as String),
      ],
      isComplete: (rows.first['is_complete'] as int?) == 1,
      envelope: envelope,
      totalCount: rows.first['total_count'] as int?,
      generation: (rows.first['generation'] as int?) ?? 0,
    );
  });

  CacheEnvelope _playlistEnvelope(Row row) => CacheEnvelope(
    scope: scopeOf(row['namespace']! as String, row['account_key']! as String),
    fetchedAt: _time(row['fetched_at']),
    freshUntil: _time(row['fresh_until']),
    staleUntil: _time(row['stale_until']),
    lastAccessAt: _timeOrNull(row['last_access_at']),
    etag: row['etag'] as String?,
    lastModified: _timeOrNull(row['last_modified']),
  );

  PlaylistHeaderMetadata _headerFromRow(Row row) {
    final raw = row['metadata_json'];
    if (raw is! String) {
      final summary = _summaryFromRow(row);
      return PlaylistHeaderMetadata(
        description: summary.description,
        playCount: summary.playCount,
        declaredTrackCount: summary.trackCount,
      );
    }
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? decodePlaylistHeader(decoded['header'])
        : const PlaylistHeaderMetadata();
  }

  PlaylistSummary _summaryFromRow(Row row) {
    final metadata = row['metadata_json'];
    if (metadata is String) {
      final decoded = jsonDecode(metadata);
      if (decoded is Map && decoded['summary'] is String) {
        final summaries = decodePlaylistSummaries(decoded['summary'] as String);
        if (summaries.isNotEmpty) return summaries.single;
      }
    }
    final artwork = row['artwork_uri'] as String?;
    return PlaylistSummary(
      id: PlaylistId(row['playlist_id']! as String),
      title: (row['title'] as String?) ?? '',
      subtitle: (row['subtitle'] as String?) ?? '',
      trackCount: (row['track_count'] as int?) ?? 0,
      artworkUri: (artwork == null || artwork.isEmpty)
          ? null
          : Uri.tryParse(artwork),
      description: row['description'] as String?,
      specialType: row['special_type'] as int?,
      creatorId: row['creator_id'] is String
          ? UserId(row['creator_id'] as String)
          : null,
      privacy: row['privacy'] as int?,
    );
  }

  @override
  Future<void> invalidatePlaylistSnapshot(
    CacheScope scope,
    PlaylistId id,
  ) async {
    final values = [scope.namespace, accountKeyOf(scope), id.value];
    _transaction(() {
      _db.execute(
        'DELETE FROM $_playlistEntries WHERE namespace = ? AND account_key = ? AND playlist_id = ?',
        values,
      );
      _db.execute(
        'DELETE FROM $_playlists WHERE namespace = ? AND account_key = ? AND playlist_id = ?',
        values,
      );
    });
  }

  void _commitPlaylistSnapshotInternal(PlaylistSnapshot snapshot) {
    final namespace = snapshot.envelope.scope.namespace;
    final accountKey = accountKeyOf(snapshot.envelope.scope);
    final playlistId = snapshot.summary.id.value;
    final envelope = snapshot.envelope;
    final summary = snapshot.summary;

    _db.execute(
      'DELETE FROM $_playlistEntries WHERE namespace = ? AND '
      'account_key = ? AND playlist_id = ?',
      [namespace, accountKey, playlistId],
    );
    _db.execute(
      'INSERT INTO $_playlists (namespace, account_key, playlist_id, title, '
      'subtitle, track_count, artwork_uri, description, special_type, '
      'total_count, is_complete, generation, size_bytes, fetched_at, '
      'fresh_until, stale_until, last_access_at, etag, last_modified) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, account_key, playlist_id) DO UPDATE SET '
      'title = excluded.title, subtitle = excluded.subtitle, '
      'track_count = excluded.track_count, '
      'artwork_uri = excluded.artwork_uri, '
      'description = excluded.description, '
      'special_type = excluded.special_type, '
      'total_count = excluded.total_count, '
      'is_complete = excluded.is_complete, '
      'generation = excluded.generation, '
      'size_bytes = excluded.size_bytes, '
      'fetched_at = excluded.fetched_at, '
      'fresh_until = excluded.fresh_until, '
      'stale_until = excluded.stale_until, '
      'last_access_at = excluded.last_access_at, etag = excluded.etag, '
      'last_modified = excluded.last_modified',
      [
        namespace,
        accountKey,
        playlistId,
        summary.title,
        summary.subtitle,
        summary.trackCount,
        summary.artworkUri?.toString(),
        summary.description,
        summary.specialType,
        snapshot.totalCount,
        _bool(snapshot.isComplete),
        snapshot.generation,
        _playlistSize(snapshot),
        _ms(envelope.fetchedAt),
        _ms(envelope.freshUntil),
        _ms(envelope.staleUntil),
        envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
        envelope.etag,
        envelope.lastModified == null ? null : _ms(envelope.lastModified!),
      ],
    );
    _db.execute(
      'UPDATE $_playlists SET creator_id = ?, privacy = ?, metadata_json = ? WHERE namespace = ? AND account_key = ? AND playlist_id = ?',
      [
        summary.creatorId?.value,
        summary.privacy,
        jsonEncode({
          'summary': encodePlaylistSummaries([summary]),
          'header': encodePlaylistHeader(snapshot.header),
        }),
        namespace,
        accountKey,
        playlistId,
      ],
    );

    for (var ordinal = 0; ordinal < snapshot.entryTrackIds.length; ordinal++) {
      _db.execute(
        'INSERT INTO $_playlistEntries (namespace, account_key, '
        'playlist_id, ordinal, track_id) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(namespace, account_key, playlist_id, ordinal) '
        'DO UPDATE SET track_id = excluded.track_id',
        [
          namespace,
          accountKey,
          playlistId,
          ordinal,
          snapshot.entryTrackIds[ordinal].value,
        ],
      );
    }
  }

  @override
  Future<void> commitPlaylistSnapshot(PlaylistSnapshot snapshot) async {
    _guard(() {
      // The header and the entries land together, so a reader never sees a
      // refreshed header against the previous membership (design §4, §7).
      _transaction(() {
        _commitPlaylistSnapshotInternal(snapshot);
      });
      return true;
    });
  }

  int _playlistSize(PlaylistSnapshot snapshot) {
    var size = 64;
    size += utf8LengthOf(jsonEncode(encodePlaylistHeader(snapshot.header)));
    size += utf8LengthOf(encodePlaylistSummaries([snapshot.summary]));
    size += utf8LengthOf(snapshot.summary.title);
    size += utf8LengthOf(snapshot.summary.subtitle);
    size += utf8LengthOf(snapshot.summary.description);
    size += utf8LengthOf(snapshot.summary.artworkUri?.toString());
    size += utf8LengthOf(snapshot.envelope.etag);
    for (final id in snapshot.entryTrackIds) {
      size += id.value.length + 12;
    }
    return size;
  }

  // -------------------------------------------------------------------------
  // Paged lists
  // -------------------------------------------------------------------------

  @override
  Future<CachedIdPage<String>?> readIdPage({
    required CacheScope scope,
    required String kind,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  }) async => _guard(() {
    final row = _readPageRow(kind, scope, queryKey, offset, includeExpired);
    if (row == null) return null;
    return CachedIdPage<String>(
      ids: _decodeIdList(row['ids_json']),
      offset: offset,
      limit: (row['page_limit'] as int?) ?? 0,
      hasMore: (row['has_more'] as int?) == 1,
      isComplete: (row['is_complete'] as int?) == 1,
      generation: (row['generation'] as int?) ?? 0,
      envelope: _pageEnvelope(row),
    );
  });

  @override
  Future<CachedIdPage<PlaylistId>?> readUserPlaylistPage({
    required CacheScope scope,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  }) async {
    final page = await readIdPage(
      scope: scope,
      kind: _userPlaylistKind,
      queryKey: queryKey,
      offset: offset,
      includeExpired: includeExpired,
    );
    if (page == null) return null;
    return CachedIdPage<PlaylistId>(
      ids: [for (final id in page.ids) PlaylistId(id)],
      offset: page.offset,
      limit: page.limit,
      hasMore: page.hasMore,
      isComplete: page.isComplete,
      generation: page.generation,
      envelope: page.envelope,
    );
  }

  @override
  Future<CachedIdPage<TrackId>?> readSearchPage({
    required CacheScope scope,
    required String queryKey,
    required int offset,
    bool includeExpired = false,
  }) async {
    final page = await readIdPage(
      scope: scope,
      kind: _searchKind,
      queryKey: queryKey,
      offset: offset,
      includeExpired: includeExpired,
    );
    if (page == null) return null;
    return CachedIdPage<TrackId>(
      ids: [for (final id in page.ids) TrackId(id)],
      offset: page.offset,
      limit: page.limit,
      hasMore: page.hasMore,
      isComplete: page.isComplete,
      generation: page.generation,
      envelope: page.envelope,
    );
  }

  Row? _readPageRow(
    String kind,
    CacheScope scope,
    String queryKey,
    int offset,
    bool includeExpired,
  ) {
    final namespace = scope.namespace;
    final accountKey = accountKeyOf(scope);
    final rows = _db.select(
      'SELECT * FROM $_idPages WHERE kind = ? AND namespace = ? AND '
      'account_key = ? AND query_key = ? AND page_offset = ?',
      [kind, namespace, accountKey, queryKey, offset],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final now = _now();
    if (!includeExpired &&
        _pageEnvelope(row).freshnessAt(now) == CacheFreshness.miss) {
      return null;
    }
    _noteAccess(
      _idPages,
      ['kind', 'namespace', 'account_key', 'query_key', 'page_offset'],
      [kind, namespace, accountKey, queryKey, offset],
      now,
    );
    return row;
  }

  CacheEnvelope _pageEnvelope(Row row) => CacheEnvelope(
    scope: scopeOf(row['namespace']! as String, row['account_key']! as String),
    fetchedAt: _time(row['fetched_at']),
    freshUntil: _time(row['fresh_until']),
    staleUntil: _time(row['stale_until']),
    lastAccessAt: _timeOrNull(row['last_access_at']),
  );

  void _writePage({
    required String kind,
    required String queryKey,
    required CacheEnvelope envelope,
    required List<String> ids,
    required int offset,
    required int limit,
    required bool hasMore,
    required bool isComplete,
    required int generation,
  }) {
    _guard(() {
      final namespace = envelope.scope.namespace;
      final accountKey = accountKeyOf(envelope.scope);
      final encoded = jsonEncode(ids);
      _db.execute(
        'INSERT INTO $_idPages (kind, namespace, account_key, query_key, '
        'page_offset, ids_json, page_limit, has_more, is_complete, '
        'generation, size_bytes, fetched_at, fresh_until, stale_until, '
        'last_access_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(kind, namespace, account_key, query_key, page_offset) '
        'DO UPDATE SET ids_json = excluded.ids_json, '
        'page_limit = excluded.page_limit, has_more = excluded.has_more, '
        'is_complete = excluded.is_complete, '
        'generation = excluded.generation, size_bytes = excluded.size_bytes, '
        'fetched_at = excluded.fetched_at, '
        'fresh_until = excluded.fresh_until, '
        'stale_until = excluded.stale_until, '
        'last_access_at = excluded.last_access_at',
        [
          kind,
          namespace,
          accountKey,
          queryKey,
          offset,
          encoded,
          limit,
          _bool(hasMore),
          _bool(isComplete),
          generation,
          utf8LengthOf(encoded) + 48,
          _ms(envelope.fetchedAt),
          _ms(envelope.freshUntil),
          _ms(envelope.staleUntil),
          envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
        ],
      );
      return true;
    });
  }

  @override
  Future<void> putIdPage({
    required String kind,
    required String queryKey,
    required CachedIdPage<String> page,
  }) async {
    _writePage(
      kind: kind,
      queryKey: queryKey,
      envelope: page.envelope,
      ids: page.ids,
      offset: page.offset,
      limit: page.limit,
      hasMore: page.hasMore,
      isComplete: page.isComplete,
      generation: page.generation,
    );
  }

  @override
  Future<void> putUserPlaylistPage({
    required String queryKey,
    required CachedIdPage<PlaylistId> page,
  }) => putIdPage(
    kind: _userPlaylistKind,
    queryKey: queryKey,
    page: CachedIdPage<String>(
      ids: [for (final id in page.ids) id.value],
      offset: page.offset,
      limit: page.limit,
      hasMore: page.hasMore,
      isComplete: page.isComplete,
      generation: page.generation,
      envelope: page.envelope,
    ),
  );

  @override
  Future<void> putSearchPage({
    required String queryKey,
    required CachedIdPage<TrackId> page,
  }) => putIdPage(
    kind: _searchKind,
    queryKey: queryKey,
    page: CachedIdPage<String>(
      ids: [for (final id in page.ids) id.value],
      offset: page.offset,
      limit: page.limit,
      hasMore: page.hasMore,
      isComplete: page.isComplete,
      generation: page.generation,
      envelope: page.envelope,
    ),
  );

  @override
  Future<void> pruneIdPages({
    required CacheScope scope,
    required String kind,
    required String queryKey,
    required int generation,
  }) async {
    _guard(() {
      _db.execute(
        'DELETE FROM $_idPages WHERE kind = ? AND namespace = ? AND '
        'account_key = ? AND query_key = ? AND generation <> ?',
        [kind, scope.namespace, accountKeyOf(scope), queryKey, generation],
      );
      return true;
    });
  }

  // -------------------------------------------------------------------------
  // Catalog entities
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, CatalogEntitySummary>> readCatalogEntities(
    CacheScope scope,
    String entityType,
    Iterable<String> ids, {
    bool includeExpired = false,
  }) async {
    final wanted = ids.toList();
    if (wanted.isEmpty) return const {};
    return _guard(() {
          final now = _now();
          final namespace = scope.namespace;
          final accountKey = accountKeyOf(scope);
          final rows = _db.select(
            'SELECT * FROM $_catalogEntities WHERE namespace = ? AND account_key = ? '
            'AND entity_type = ? AND entity_id IN (${_placeholders(wanted.length)})',
            [namespace, accountKey, entityType, ...wanted],
          );
          final result = <String, CatalogEntitySummary>{};
          for (final row in rows) {
            final id = row['entity_id']! as String;
            final envelope = _entityEnvelope(row, namespace, accountKey);
            if (!includeExpired &&
                envelope.freshnessAt(now) == CacheFreshness.miss) {
              continue;
            }
            result[id] = CatalogEntitySummary(
              scope: scopeOf(namespace, accountKey),
              kind: entityType,
              entityId: id,
              summaryJson: row['summary_json']! as String,
              envelope: envelope,
            );
            _noteAccess(
              _catalogEntities,
              ['namespace', 'account_key', 'entity_type', 'entity_id'],
              [namespace, accountKey, entityType, id],
              now,
            );
          }
          return result;
        }) ??
        const {};
  }

  CacheEnvelope _entityEnvelope(Row row, String namespace, String accountKey) =>
      CacheEnvelope(
        scope: scopeOf(namespace, accountKey),
        fetchedAt: _time(row['fetched_at']),
        freshUntil: _time(row['fresh_until']),
        staleUntil: _time(row['stale_until']),
        lastAccessAt: _timeOrNull(row['last_access_at']),
      );

  void _upsertSingleEntity(CacheScope scope, CatalogEntitySummary entity) {
    final envelope = entity.envelope;
    final json = entity.summaryJson;
    _db.execute(
      'INSERT INTO $_catalogEntities (namespace, account_key, entity_type, '
      'entity_id, summary_json, size_bytes, fetched_at, fresh_until, '
      'stale_until, last_access_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, account_key, entity_type, entity_id) DO UPDATE SET '
      'summary_json = excluded.summary_json, '
      'size_bytes = excluded.size_bytes, '
      'fetched_at = excluded.fetched_at, '
      'fresh_until = excluded.fresh_until, '
      'stale_until = excluded.stale_until, '
      'last_access_at = excluded.last_access_at',
      [
        scope.namespace,
        accountKeyOf(scope),
        entity.kind,
        entity.entityId,
        json,
        utf8LengthOf(json) + 32,
        _ms(envelope.fetchedAt),
        _ms(envelope.freshUntil),
        _ms(envelope.staleUntil),
        envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
      ],
    );
  }

  @override
  Future<void> putCatalogEntities(
    Iterable<CatalogEntitySummary> entities,
  ) async {
    _guard(() {
      _transaction(() {
        for (final entity in entities) {
          _upsertSingleEntity(entity.scope, entity);
        }
      });
      return true;
    });
  }

  // -------------------------------------------------------------------------
  // Home sections
  // -------------------------------------------------------------------------

  @override
  Future<Map<HomeSectionKind, HomeSection>> readHomeSections(
    CacheScope scope, {
    bool includeExpired = false,
  }) async =>
      _guard(() {
        final now = _now();
        final namespace = scope.namespace;
        final accountKey = accountKeyOf(scope);
        final rows = _db.select(
          'SELECT * FROM $_homeSections WHERE namespace = ? AND account_key = ?',
          [namespace, accountKey],
        );
        if (rows.isEmpty) return const {};

        final sections = <HomeSectionKind, HomeSection>{};
        for (final row in rows) {
          final envelope = _entityEnvelope(row, namespace, accountKey);
          if (!includeExpired &&
              envelope.freshnessAt(now) == CacheFreshness.miss) {
            continue;
          }
          final sectionId = row['section_id']! as String;
          final kindStr = row['section_kind']! as String;
          final title = (row['title'] as String?) ?? '';
          final statusStr = (row['status'] as String?) ?? '';
          final itemsJson = (row['items_json'] as String?) ?? '[]';

          final kind = HomeSectionKind.values
              .where((k) => k.name == kindStr)
              .firstOrNull;
          if (kind == null) continue;

          final status =
              HomeSectionStatus.values
                  .where((s) => s.name == statusStr)
                  .firstOrNull ??
              HomeSectionStatus.ready;

          final playlists = decodePlaylistSummaries(itemsJson);

          sections[kind] = HomeSection(
            kind: kind,
            title: title,
            playlists: playlists,
            status: status,
          );

          _noteAccess(
            _homeSections,
            ['namespace', 'account_key', 'section_id'],
            [namespace, accountKey, sectionId],
            now,
          );
        }

        return sections;
      }) ??
      const {};

  void _commitHomeSectionInternal(
    CacheScope scope,
    HomeSectionKind kind,
    HomeSection section,
  ) {
    final now = _now();
    final envelope = CacheEnvelope.fresh(
      scope: scope,
      at: now,
      window: CacheContentKind.home.window,
    );
    final namespace = scope.namespace;
    final accountKey = accountKeyOf(scope);
    final json = encodePlaylistSummaries(section.playlists);
    _db.execute(
      'INSERT INTO $_homeSections (namespace, account_key, section_id, '
      'section_kind, title, status, items_json, size_bytes, fetched_at, '
      'fresh_until, stale_until, last_access_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, account_key, section_id) DO UPDATE SET '
      'section_kind = excluded.section_kind, '
      'title = excluded.title, '
      'status = excluded.status, '
      'items_json = excluded.items_json, '
      'size_bytes = excluded.size_bytes, '
      'fetched_at = excluded.fetched_at, '
      'fresh_until = excluded.fresh_until, '
      'stale_until = excluded.stale_until, '
      'last_access_at = excluded.last_access_at',
      [
        namespace,
        accountKey,
        kind.name,
        kind.name,
        section.title,
        section.status.name,
        json,
        utf8LengthOf(json) + utf8LengthOf(section.title) + 48,
        _ms(envelope.fetchedAt),
        _ms(envelope.freshUntil),
        _ms(envelope.staleUntil),
        envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
      ],
    );
  }

  @override
  Future<void> commitHomeSection(
    CacheScope scope,
    HomeSectionKind kind,
    HomeSection section,
  ) async {
    _guard(() {
      _commitHomeSectionInternal(scope, kind, section);
      return true;
    });
  }

  // -------------------------------------------------------------------------
  // Artwork index
  // -------------------------------------------------------------------------

  @override
  Future<ArtworkIndexEntry?> readArtworkIndex(
    CacheScope scope,
    String assetKey,
  ) async => _guard(() {
    final namespace = scope.namespace;
    final accountKey = accountKeyOf(scope);
    final rows = _db.select(
      'SELECT * FROM $_artwork WHERE namespace = ? AND account_key = ? '
      'AND asset_key = ?',
      [namespace, accountKey, assetKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    _noteAccess(
      _artwork,
      ['namespace', 'account_key', 'asset_key'],
      [namespace, accountKey, assetKey],
      _now(),
    );
    return ArtworkIndexEntry(
      assetKey: assetKey,
      filePath: row['file_path']! as String,
      byteSize: (row['byte_size'] as int?) ?? 0,
      sha256: row['sha256'] as String?,
      mimeType: row['mime_type'] as String?,
      pixelWidth: row['pixel_width'] as int?,
      pixelHeight: row['pixel_height'] as int?,
      sizeBucket: _bucketFromPixels(row['size_bucket']),
      resourceVersion: row['resource_version'] as String?,
      envelope: CacheEnvelope(
        scope: scopeOf(namespace, accountKey),
        fetchedAt: _time(row['fetched_at']),
        freshUntil: _time(row['fresh_until']),
        staleUntil: _time(row['stale_until']),
        lastAccessAt: _timeOrNull(row['last_access_at']),
        etag: row['etag'] as String?,
        lastModified: _timeOrNull(row['last_modified']),
      ),
    );
  });

  @override
  Future<void> putArtworkIndex(ArtworkIndexEntry entry) async {
    _guard(() {
      final scope = entry.scope;
      final envelope = entry.envelope;
      _db.execute(
        'INSERT INTO $_artwork (namespace, account_key, asset_key, file_path, '
        'sha256, mime_type, byte_size, pixel_width, pixel_height, size_bucket, '
        'resource_version, fetched_at, fresh_until, stale_until, last_access_at, '
        'etag, last_modified) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(namespace, account_key, asset_key) DO UPDATE SET '
        'file_path = excluded.file_path, sha256 = excluded.sha256, '
        'mime_type = excluded.mime_type, byte_size = excluded.byte_size, '
        'pixel_width = excluded.pixel_width, '
        'pixel_height = excluded.pixel_height, '
        'size_bucket = excluded.size_bucket, '
        'resource_version = excluded.resource_version, '
        'fetched_at = excluded.fetched_at, '
        'fresh_until = excluded.fresh_until, '
        'stale_until = excluded.stale_until, '
        'last_access_at = excluded.last_access_at, etag = excluded.etag, '
        'last_modified = excluded.last_modified',
        [
          scope.namespace,
          accountKeyOf(scope),
          entry.assetKey,
          entry.filePath,
          entry.sha256,
          entry.mimeType,
          entry.byteSize,
          entry.pixelWidth,
          entry.pixelHeight,
          entry.sizeBucket?.pixels,
          entry.resourceVersion,
          _ms(envelope.fetchedAt),
          _ms(envelope.freshUntil),
          _ms(envelope.staleUntil),
          envelope.lastAccessAt == null ? null : _ms(envelope.lastAccessAt!),
          envelope.etag,
          envelope.lastModified == null ? null : _ms(envelope.lastModified!),
        ],
      );
      return true;
    });
  }

  @override
  Future<void> deleteArtworkIndex(CacheScope scope, String assetKey) async {
    _guard(() {
      _db.execute(
        'DELETE FROM $_artwork WHERE namespace = ? AND account_key = ? '
        'AND asset_key = ?',
        [scope.namespace, accountKeyOf(scope), assetKey],
      );
      return true;
    });
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  Future<List<String>> clearAccount(String accountId) async =>
      _guard(() {
        final files = _collectArtworkFiles(accountId);
        _transaction(() {
          for (final table in _dataTables) {
            _db.execute('DELETE FROM $table WHERE account_key = ?', [
              accountId,
            ]);
          }
          // The account epoch moves on sign-out too; bumping this as well makes
          // sure a result already in flight is dropped rather than written back
          // (design §9).
          _cacheGeneration++;
          _writeMeta('cache_generation', '$_cacheGeneration');
        });
        _pendingAccess.removeWhere((key, _) => key.contains('|$accountId|'));
        return files;
      }) ??
      const [];

  @override
  Future<List<String>> clearAll() async =>
      _guard(() {
        final files = _collectArtworkFiles(null);
        _transaction(() {
          for (final table in _dataTables) {
            _db.execute('DELETE FROM $table');
          }
          _cacheGeneration++;
          _writeMeta('cache_generation', '$_cacheGeneration');
        });
        _pendingAccess.clear();
        return files;
      }) ??
      const [];

  @override
  Future<List<String>> clearArtwork() async =>
      _guard(() {
        final files = _collectArtworkFiles(null);
        _transaction(() {
          _db.execute('DELETE FROM $_artwork');
        });
        return files;
      }) ??
      const [];

  List<String> _collectArtworkFiles(String? accountId) {
    final rows = accountId == null
        ? _db.select('SELECT file_path FROM $_artwork')
        : _db.select('SELECT file_path FROM $_artwork WHERE account_key = ?', [
            accountId,
          ]);
    return [
      for (final row in rows)
        if (row['file_path'] is String) row['file_path']! as String,
    ];
  }

  @override
  Future<CacheStoreStats> stats() async =>
      _guard(() {
        var metadataBytes = 0;
        var trackCount = 0;
        for (final table in [
          _tracks,
          _absentTracks,
          _playlists,
          _idPages,
          _catalogEntities,
          _homeSections,
          _dailySongs,
        ]) {
          final rows = _db.select(
            'SELECT COUNT(*) AS rows, COALESCE(SUM(size_bytes), 0) AS bytes '
            'FROM $table',
          );
          metadataBytes += (rows.first['bytes'] as int?) ?? 0;
          if (table == _tracks) {
            trackCount = (rows.first['rows'] as int?) ?? 0;
          }
        }
        final artwork = _db.select(
          'SELECT COUNT(*) AS rows, COALESCE(SUM(byte_size), 0) AS bytes '
          'FROM $_artwork',
        );
        return CacheStoreStats(
          trackCount: trackCount,
          metadataBytes: metadataBytes,
          artworkIndexCount: (artwork.first['rows'] as int?) ?? 0,
          artworkBytes: (artwork.first['bytes'] as int?) ?? 0,
        );
      }) ??
      const CacheStoreStats.empty();

  @override
  Future<List<String>> enforceBudget({
    int budgetBytes = CacheBudget.metadataDiskBytes,
    Set<TrackId> pinnedTrackIds = const {},
    Set<String> pinnedArtworkKeys = const {},
  }) async =>
      _guard(() {
        _flushAccess();
        final now = _now();
        final pinnedTracks = {for (final id in pinnedTrackIds) id.value};
        final orphaned = <String>[];
        _transaction(() {
          _deleteExpired(now, pinnedTracks);
          _evictMetadata(budgetBytes, pinnedTracks);
          orphaned.addAll(_evictArtwork(pinnedArtworkKeys));
        });
        return orphaned;
      }) ??
      const [];

  void _deleteExpired(DateTime now, Set<String> pinnedTracks) {
    final cutoff = _ms(now);
    final pinnedClause = pinnedTracks.isEmpty
        ? ''
        : ' AND track_id NOT IN (${_placeholders(pinnedTracks.length)})';
    _db.execute('DELETE FROM $_tracks WHERE stale_until < ?$pinnedClause', [
      cutoff,
      ...pinnedTracks,
    ]);
    _db.execute('DELETE FROM $_absentTracks WHERE stale_until < ?', [cutoff]);
    _db.execute('DELETE FROM $_playlists WHERE stale_until < ?', [cutoff]);
    _db.execute('DELETE FROM $_idPages WHERE stale_until < ?', [cutoff]);
    _db.execute('DELETE FROM $_catalogEntities WHERE stale_until < ?', [
      cutoff,
    ]);
    _db.execute('DELETE FROM $_homeSections WHERE stale_until < ?', [cutoff]);
    _db.execute('DELETE FROM $_dailySongs WHERE retain_until < ?', [cutoff]);

    // Children of a deleted parent are unreachable; drop them rather than
    // leaving them to be re-counted (design §10).
    _db.execute(
      'DELETE FROM $_trackGroups WHERE NOT EXISTS (SELECT 1 FROM $_tracks t '
      'WHERE t.namespace = $_trackGroups.namespace '
      'AND t.account_key = $_trackGroups.account_key '
      'AND t.track_id = $_trackGroups.track_id)',
    );
    _db.execute(
      'DELETE FROM $_playlistEntries WHERE NOT EXISTS (SELECT 1 FROM '
      '$_playlists p WHERE p.namespace = $_playlistEntries.namespace '
      'AND p.account_key = $_playlistEntries.account_key '
      'AND p.playlist_id = $_playlistEntries.playlist_id)',
    );
  }

  /// Evicts least-recently-used metadata rows until the store is back to the
  /// target fraction of [budgetBytes] (design §10).
  void _evictMetadata(int budgetBytes, Set<String> pinnedTracks) {
    var total = _metadataBytes();
    if (total <= budgetBytes) return;
    final target = (budgetBytes * CacheBudget.evictionTargetFraction).floor();

    final candidates = _lruCandidates();
    // Pinned labels are protected only up to their own cap; past it they are
    // ordinary candidates, so an endless queue cannot pin the whole cache.
    var protectedBytes = 0;
    for (final candidate in candidates) {
      if (!candidate.isTrack || !pinnedTracks.contains(candidate.key1)) {
        continue;
      }
      if (protectedBytes + candidate.bytes <=
          CacheBudget.protectedTrackLabelBytes) {
        protectedBytes += candidate.bytes;
        candidate.protected = true;
      }
    }

    for (final candidate in candidates) {
      if (total <= target) break;
      if (candidate.protected) continue;
      _deleteCandidate(candidate);
      total -= candidate.bytes;
    }
  }

  int _metadataBytes() {
    var total = 0;
    for (final table in [
      _tracks,
      _absentTracks,
      _playlists,
      _idPages,
      _catalogEntities,
      _homeSections,
      _dailySongs,
    ]) {
      final rows = _db.select(
        'SELECT COALESCE(SUM(size_bytes), 0) AS bytes FROM $table',
      );
      total += (rows.first['bytes'] as int?) ?? 0;
    }
    return total;
  }

  List<_EvictionCandidate> _lruCandidates() {
    final rows = _db.select('''
SELECT 'track' AS tag, namespace AS ns, account_key AS acct, track_id AS k1,
       '' AS k2, '' AS k3, size_bytes AS bytes,
       COALESCE(last_access_at, fetched_at) AS access
  FROM $_tracks
UNION ALL
SELECT 'absent', namespace, account_key, track_id, '', '', size_bytes,
       COALESCE(last_access_at, fetched_at)
  FROM $_absentTracks
UNION ALL
SELECT 'playlist', namespace, account_key, playlist_id, '', '', size_bytes,
       COALESCE(last_access_at, fetched_at)
  FROM $_playlists
UNION ALL
SELECT 'page', namespace, account_key, query_key, CAST(page_offset AS TEXT),
       kind, size_bytes, COALESCE(last_access_at, fetched_at)
  FROM $_idPages
UNION ALL
SELECT 'entity', namespace, account_key, entity_type, entity_id, '', size_bytes,
       COALESCE(last_access_at, fetched_at)
  FROM $_catalogEntities
UNION ALL
SELECT 'home', namespace, account_key, section_id, '', '', size_bytes,
       COALESCE(last_access_at, fetched_at)
  FROM $_homeSections
UNION ALL
SELECT 'daily_songs', namespace, account_key, date_key, '', '', size_bytes,
       COALESCE(last_access_at, fetched_at)
  FROM $_dailySongs
ORDER BY access ASC''');
    return [
      for (final row in rows)
        _EvictionCandidate(
          tag: row['tag']! as String,
          namespace: row['ns']! as String,
          accountKey: row['acct']! as String,
          key1: row['k1']! as String,
          key2: row['k2']! as String,
          key3: row['k3']! as String,
          bytes: (row['bytes'] as int?) ?? 0,
        ),
    ];
  }

  void _deleteCandidate(_EvictionCandidate candidate) {
    switch (candidate.tag) {
      case 'track':
        _db.execute(
          'DELETE FROM $_tracks WHERE namespace = ? AND account_key = ? '
          'AND track_id = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
        _db.execute(
          'DELETE FROM $_trackGroups WHERE namespace = ? AND account_key = ? '
          'AND track_id = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
      case 'daily_songs':
        _db.execute(
          'DELETE FROM $_dailySongs WHERE namespace = ? AND account_key = ? '
          'AND date_key = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
      case 'absent':
        _db.execute(
          'DELETE FROM $_absentTracks WHERE namespace = ? AND account_key = ? '
          'AND track_id = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
      case 'playlist':
        _db.execute(
          'DELETE FROM $_playlists WHERE namespace = ? AND account_key = ? '
          'AND playlist_id = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
        _db.execute(
          'DELETE FROM $_playlistEntries WHERE namespace = ? AND '
          'account_key = ? AND playlist_id = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
      case 'page':
        _db.execute(
          'DELETE FROM $_idPages WHERE kind = ? AND namespace = ? AND '
          'account_key = ? AND query_key = ? AND page_offset = ?',
          [
            candidate.key3,
            candidate.namespace,
            candidate.accountKey,
            candidate.key1,
            int.tryParse(candidate.key2) ?? 0,
          ],
        );
      case 'entity':
        _db.execute(
          'DELETE FROM $_catalogEntities WHERE namespace = ? AND account_key = ? '
          'AND entity_type = ? AND entity_id = ?',
          [
            candidate.namespace,
            candidate.accountKey,
            candidate.key1,
            candidate.key2,
          ],
        );
      case 'home':
        _db.execute(
          'DELETE FROM $_homeSections WHERE namespace = ? AND account_key = ? '
          'AND section_id = ?',
          [candidate.namespace, candidate.accountKey, candidate.key1],
        );
    }
  }

  List<String> _evictArtwork(Set<String> pinnedKeys) {
    final rows = _db.select('''
SELECT namespace, account_key, asset_key, file_path, byte_size,
       COALESCE(last_access_at, fetched_at) AS access
  FROM $_artwork ORDER BY access ASC''');

    var total = 0;
    for (final row in rows) {
      total += (row['byte_size'] as int?) ?? 0;
    }
    if (total <= CacheBudget.artworkDiskBytes) return const [];
    final target =
        (CacheBudget.artworkDiskBytes * CacheBudget.evictionTargetFraction)
            .floor();

    final protected = <String>{};
    var protectedBytes = 0;
    for (final row in rows) {
      final key = row['asset_key']! as String;
      if (!pinnedKeys.contains(key)) continue;
      final bytes = (row['byte_size'] as int?) ?? 0;
      if (protectedBytes + bytes <= CacheBudget.protectedArtworkBytes) {
        protectedBytes += bytes;
        protected.add(key);
      }
    }

    final orphaned = <String>[];
    for (final row in rows) {
      if (total <= target) break;
      final key = row['asset_key']! as String;
      if (protected.contains(key)) continue;
      orphaned.add(row['file_path']! as String);
      _db.execute(
        'DELETE FROM $_artwork WHERE namespace = ? AND account_key = ? '
        'AND asset_key = ?',
        [row['namespace'], row['account_key'], key],
      );
      total -= (row['byte_size'] as int?) ?? 0;
    }
    return orphaned;
  }

  void _updateTrackProjection(
    CacheScope scope,
    TrackProjectionRecord projection,
  ) {
    _db.execute(
      'UPDATE $_tracks SET '
      'fee = CASE WHEN ? <> \'unknown\' THEN ? ELSE fee END, '
      'availability = CASE WHEN ? <> \'unknown\' THEN ? ELSE availability END, '
      'max_potential_quality = CASE WHEN ? <> \'unknown\' THEN ? ELSE max_potential_quality END '
      'WHERE namespace = ? AND account_key = ? AND track_id = ?',
      [
        projection.fee.name,
        projection.fee.name,
        projection.availability.name,
        projection.availability.name,
        projection.maxPotentialQuality.name,
        projection.maxPotentialQuality.name,
        scope.namespace,
        accountKeyOf(scope),
        projection.trackId.value,
      ],
    );
  }

  @override
  Future<DailySongsSnapshot?> readDailySongs(
    CacheScope scope,
    String dateKey, {
    bool includeExpired = false,
  }) async => _guard(() {
    final now = _now();
    final namespace = scope.namespace;
    final accountKey = accountKeyOf(scope);
    final rows = _db.select(
      'SELECT * FROM $_dailySongs WHERE namespace = ? AND account_key = ? AND date_key = ?',
      [namespace, accountKey, dateKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final staleUntil = _time(row['stale_until']);
    final retainUntil = _time(row['retain_until']);
    if (!includeExpired) {
      if (now.isAfter(staleUntil) && now.isAfter(retainUntil)) {
        return null;
      }
    }
    final snapshotJson = row['snapshot_json'] as String;
    final snapshot = decodeDailySongsSnapshot(snapshotJson);
    if (snapshot == null) return null;
    _noteAccess(
      _dailySongs,
      ['namespace', 'account_key', 'date_key'],
      [namespace, accountKey, dateKey],
      now,
    );
    return snapshot;
  });

  @override
  Future<void> putDailySongs(DailySongsSnapshot snapshot) async {
    _guard(() {
      _transaction(() {
        _upsertDailySongsInternal(snapshot);
      });
      return true;
    });
  }

  void _upsertDailySongsInternal(DailySongsSnapshot snapshot) {
    final scope = scopeOf(snapshot.namespace, snapshot.accountId);
    final json = encodeDailySongsSnapshot(snapshot);
    _db.execute(
      'INSERT INTO $_dailySongs (namespace, account_key, date_key, snapshot_json, '
      'size_bytes, fetched_at, fresh_until, stale_until, retain_until, last_access_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, account_key, date_key) DO UPDATE SET '
      'snapshot_json = excluded.snapshot_json, '
      'size_bytes = excluded.size_bytes, '
      'fetched_at = excluded.fetched_at, '
      'fresh_until = excluded.fresh_until, '
      'stale_until = excluded.stale_until, '
      'retain_until = excluded.retain_until, '
      'last_access_at = excluded.last_access_at',
      [
        snapshot.namespace,
        accountKeyOf(scope),
        snapshot.dateKey,
        json,
        utf8LengthOf(json) + 32,
        _ms(snapshot.fetchedAt),
        _ms(snapshot.staleUntil),
        _ms(snapshot.staleUntil),
        _ms(snapshot.retainUntil),
        _ms(_now()),
      ],
    );
  }

  @override
  Future<PartitionTicketResult> readPartitionTicket(CacheScope scope) async =>
      _guard(() {
        final namespace = scope.namespace;
        final accountKey = accountKeyOf(scope);
        final rows = _db.select(
          'SELECT generation, fenced FROM $_partitions WHERE namespace = ? AND account_key = ?',
          [namespace, accountKey],
        );
        final int gen;
        final int fenced;
        if (rows.isEmpty) {
          gen = 0;
          fenced = 0;
          _db.execute(
            'INSERT INTO $_partitions (namespace, account_key, generation, fenced) VALUES (?, ?, ?, ?)',
            [namespace, accountKey, 0, 0],
          );
        } else {
          gen = (rows.first['generation'] as int?) ?? 0;
          fenced = (rows.first['fenced'] as int?) ?? 0;
        }
        if (fenced != 0) {
          return const PartitionTicketResult.unavailable();
        }
        return PartitionTicketResult.available(
          CacheWriteTicket(
            storeInstanceId: _storeInstanceId,
            cacheGeneration: _cacheGeneration,
            scope: scope,
            partitionGeneration: gen,
          ),
        );
      }) ??
      const PartitionTicketResult.unavailable();

  @override
  void fenceScope(CacheWriteTicket ticket) {
    _guard(() {
      if (ticket.storeInstanceId != _storeInstanceId ||
          ticket.cacheGeneration != _cacheGeneration) {
        return false;
      }
      final namespace = ticket.scope.namespace;
      final accountKey = accountKeyOf(ticket.scope);
      _db.execute(
        'UPDATE $_partitions SET fenced = 1 WHERE namespace = ? AND account_key = ? AND generation = ?',
        [namespace, accountKey, ticket.partitionGeneration],
      );
      return true;
    });
  }

  @override
  Future<InvalidationResult> invalidatePartition(
    CacheWriteTicket ticket,
  ) async =>
      _guard(() {
        if (ticket.storeInstanceId != _storeInstanceId ||
            ticket.cacheGeneration != _cacheGeneration) {
          return const InvalidationResult.superseded();
        }
        final namespace = ticket.scope.namespace;
        final accountKey = accountKeyOf(ticket.scope);
        final rows = _db.select(
          'SELECT generation FROM $_partitions WHERE namespace = ? AND account_key = ?',
          [namespace, accountKey],
        );
        final currentGen = rows.isEmpty
            ? 0
            : ((rows.first['generation'] as int?) ?? 0);
        if (ticket.partitionGeneration != null &&
            ticket.partitionGeneration != currentGen) {
          return const InvalidationResult.superseded();
        }
        final orphanedFiles = _collectArtworkFiles(accountKey);
        final nextGen = currentGen + 1;
        _transaction(() {
          for (final table in _dataTables) {
            if (table == _partitions) continue;
            _db.execute(
              'DELETE FROM $table WHERE namespace = ? AND account_key = ?',
              [namespace, accountKey],
            );
          }
          _db.execute(
            'INSERT INTO $_partitions (namespace, account_key, generation, fenced) '
            'VALUES (?, ?, ?, 0) '
            'ON CONFLICT(namespace, account_key) DO UPDATE SET '
            'generation = excluded.generation, fenced = 0',
            [namespace, accountKey, nextGen],
          );
        });
        _pendingAccess.removeWhere(
          (key, _) => key.contains('$namespace|$accountKey'),
        );
        return InvalidationResult.invalidated(
          generation: nextGen,
          orphanedArtworkFiles: orphanedFiles,
        );
      }) ??
      const InvalidationResult.unavailable();

  @override
  Future<ResourceWriteStamp?> reserveWriteStamp(
    CacheWriteTicket ticket,
    String resourceKey,
  ) async => _guard(() {
    if (ticket.storeInstanceId != _storeInstanceId ||
        ticket.cacheGeneration != _cacheGeneration) {
      return null;
    }
    final namespace = ticket.scope.namespace;
    final accountKey = accountKeyOf(ticket.scope);
    final rows = _db.select(
      'SELECT generation, fenced FROM $_partitions WHERE namespace = ? AND account_key = ?',
      [namespace, accountKey],
    );
    final currentGen = rows.isEmpty
        ? 0
        : ((rows.first['generation'] as int?) ?? 0);
    final fenced = rows.isEmpty ? 0 : ((rows.first['fenced'] as int?) ?? 0);
    if (fenced != 0) return null;
    if (ticket.partitionGeneration != null &&
        ticket.partitionGeneration != currentGen) {
      return null;
    }
    _nextWriteSequence++;
    _writeMeta('next_write_sequence', '$_nextWriteSequence');
    return ResourceWriteStamp(
      storeInstanceId: _storeInstanceId,
      writeSequence: _nextWriteSequence,
      resourceKey: resourceKey,
      expectedActiveGeneration: currentGen,
    );
  });

  @override
  Future<CacheCommitResult> commitBatch(CacheBatch batch) async =>
      _guard(() {
        for (final ticket in batch.tickets) {
          if (ticket.storeInstanceId != _storeInstanceId ||
              ticket.cacheGeneration != _cacheGeneration) {
            return CacheCommitResult.superseded;
          }
          final namespace = ticket.scope.namespace;
          final accountKey = accountKeyOf(ticket.scope);
          final rows = _db.select(
            'SELECT generation, fenced FROM $_partitions WHERE namespace = ? AND account_key = ?',
            [namespace, accountKey],
          );
          final currentGen = rows.isEmpty
              ? 0
              : ((rows.first['generation'] as int?) ?? 0);
          final fenced = rows.isEmpty
              ? 0
              : ((rows.first['fenced'] as int?) ?? 0);
          if (fenced != 0) return CacheCommitResult.superseded;
          if (ticket.partitionGeneration != null &&
              ticket.partitionGeneration != currentGen) {
            return CacheCommitResult.superseded;
          }
        }

        for (final page in batch.pages) {
          if (page.stamp != null &&
              page.stamp!.storeInstanceId != _storeInstanceId) {
            return CacheCommitResult.superseded;
          }
        }
        for (final update in batch.pointerUpdates) {
          if (update.stamp != null &&
              update.stamp!.storeInstanceId != _storeInstanceId) {
            return CacheCommitResult.superseded;
          }
        }

        _transaction(() {
          if (batch.tracks.isNotEmpty) {
            final byScope = <String, Map<String, CachedTrack>>{};
            for (final sw in batch.tracks) {
              final track = sw.value;
              final scope = sw.scope;
              final id = track.track.id.value;
              final scopeKey = '${scope.namespace}\u0000${accountKeyOf(scope)}';
              final bucket = byScope[scopeKey] ??= {};
              bucket[id] = mergeCachedTrack(bucket[id], track);
            }
            for (final entry in byScope.entries) {
              final sep = entry.key.indexOf('\u0000');
              _upsertTracks(
                entry.key.substring(0, sep),
                entry.key.substring(sep + 1),
                entry.value,
              );
            }
          }
          if (batch.absentTracks.isNotEmpty) {
            for (final sw in batch.absentTracks) {
              _upsertSingleAbsentTrack(sw.scope, sw.value);
            }
          }
          if (batch.entities.isNotEmpty) {
            for (final sw in batch.entities) {
              _upsertSingleEntity(sw.scope, sw.value);
            }
          }
          if (batch.playlistSnapshots.isNotEmpty) {
            for (final sw in batch.playlistSnapshots) {
              _commitPlaylistSnapshotInternal(sw.value);
            }
          }
          if (batch.projections.isNotEmpty) {
            for (final sw in batch.projections) {
              _updateTrackProjection(sw.scope, sw.value);
            }
          }
          if (batch.pages.isNotEmpty) {
            for (final p in batch.pages) {
              _writePage(
                kind: p.kind,
                queryKey: p.queryKey,
                envelope: p.page.envelope,
                ids: [for (final id in p.page.ids) id.toString()],
                offset: p.page.offset,
                limit: p.page.limit,
                hasMore: p.page.hasMore,
                isComplete: p.page.isComplete,
                generation: p.page.generation,
              );
            }
          }
          if (batch.homeSections.isNotEmpty) {
            for (final hs in batch.homeSections) {
              _commitHomeSectionInternal(hs.scope, hs.kind, hs.section);
            }
          }
          if (batch.dailySnapshots.isNotEmpty) {
            for (final ds in batch.dailySnapshots) {
              _upsertDailySongsInternal(ds.value);
            }
          }
          if (batch.pointerUpdates.isNotEmpty) {
            for (final pu in batch.pointerUpdates) {
              _db.execute(
                'DELETE FROM $_idPages WHERE kind = ? AND namespace = ? AND '
                'account_key = ? AND query_key = ? AND generation <> ?',
                [
                  pu.kind,
                  pu.scope.namespace,
                  accountKeyOf(pu.scope),
                  pu.queryKey,
                  pu.targetGeneration,
                ],
              );
            }
          }
        });
        return CacheCommitResult.committed;
      }) ??
      CacheCommitResult.unavailable;

  @override
  Future<void> close() async {
    if (_closed) return;
    _guard(() {
      _flushAccess();
      return true;
    });
    _closed = true;
    _cacheGeneration++;
    _pendingAccess.clear();
    _db.dispose();
  }
}

final class _PendingAccess {
  _PendingAccess(this.table, this.columns, this.values, this.at);

  final String table;
  final List<String> columns;
  final List<Object?> values;
  final DateTime at;
}

final class _EvictionCandidate {
  _EvictionCandidate({
    required this.tag,
    required this.namespace,
    required this.accountKey,
    required this.key1,
    required this.key2,
    required this.key3,
    required this.bytes,
  });

  final String tag;
  final String namespace;
  final String accountKey;
  final String key1;
  final String key2;
  final String key3;
  final int bytes;

  /// Set while the candidate is inside its protection cap (design §10).
  bool protected = false;

  bool get isTrack => tag == 'track';
}
