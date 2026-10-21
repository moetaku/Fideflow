import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_host/media_host.dart'
    show
        AudioInputTransport,
        AudioInputReader,
        AudioInputWorkerProvider,
        AudioInputWorkerSource,
        AudioInputWorkerTransport;
import 'package:flutter/foundation.dart';

import '../presentation/playback/cache_view.dart';
export '../presentation/playback/cache_view.dart';

part 'audio_range_cache.dart';
part 'cached_audio_timeline.dart';
part 'cached_audio_worker.dart';

/// A single byte budget for compressed audio and parsed lyric sheets.
/// Audio indexes include durable byte ranges; lyrics remain atomic documents.
/// URLs and credentials never reach disk.
final class PlaybackCache extends ChangeNotifier
    implements CachedRangeReader, AudioCacheSettings {
  PlaybackCache(
    this.directory, {
    this.beforeAudioWrite,
    this.beforeDatabaseCommit,
    this.beforeIndexWrite,
    this.digest,
    this.provider = 'ncm',
    this.onDatabaseDelta,
  });

  final Map<String, ({Future<LyricTimeline> future, bool Function() valid})>
  _lyricsFetching = {};
  final Map<String, int> _lyricsSequences = {};
  final LinkedHashMap<
    String,
    ({int revision, int generation, LyricTimeline timeline})
  >
  _lyricsTimelines = LinkedHashMap();
  int _lyricsSequence = 0;
  final String provider;
  final String Function(String)? digest;
  static final Set<String> _openDirectories = {};
  String? _directoryIdentity;
  PlaybackCacheStore? _store;
  RandomAccessFile? _lock;
  final Map<String, Map<String, dynamic>> _reservations = {};
  final Map<String, Map<String, dynamic>> _qualifications = {};
  final Set<String> _dirtyDocuments = {};
  final Map<String, String> _retired = {};
  final Set<String> _blocked = {};
  Timer? _accessTimer;
  Timer? _notification;
  int indexWrites = 0;
  bool _databaseHealthy = true;
  bool _diskHealthy = true;
  @visibleForTesting
  final void Function(PlaybackCacheDelta)? onDatabaseDelta;
  final Map<String, int> _dirtyEntries = {};
  final Map<String, Map<String, dynamic>> _publishedEntries = {};
  final Map<String, int> _documentChanges = {};
  final Map<String, int> _audioChanges = {};
  void _markDocument(String key) {
    _dirtyDocuments.add(key);
    _documentChanges[key] = ++_changeSequence;
  }

  Map<String, dynamic> _freezeEntry(Map<String, dynamic> entry) =>
      PlaybackCacheDelta(entries: {'entry': entry}).entries['entry']!;

  // Used only during file validation/recovery, never for normal commits.
  bool _sameEntrySummary(Map? left, Map right) =>
      left != null &&
      const [
        'kind',
        'revision',
        'size',
      ].every((field) => left[field] == right[field]) &&
      _documentPath(left) == _documentPath(right);
  final Map<String, int> _dirtyReservations = {};
  final Map<String, int> _dirtyQualifications = {};
  final Map<String, int> _dirtyAccess = {};
  int? _nextAccessFlushAt;
  void _markAccess(String key, int time) {
    _dirtyAccess[key] = ++_changeSequence;
    final due = (_accessFlushTime[key] ?? time) + 60000;
    if (_nextAccessFlushAt == null || due < _nextAccessFlushAt!) {
      _nextAccessFlushAt = due;
    }
  }

  int _changeSequence = 0;
  int? _dirtyLimit;
  int _usedBytes = 0;
  int _reservedRangeBytes = 0;
  int _inputMailboxReservation = 0;
  @visibleForTesting
  int get databaseCommits => _store?.transactionCount ?? 0;
  @visibleForTesting
  int get databaseDocumentsEncoded => _store?.encodedDocuments ?? 0;

  final Map<String, int> _entryEpochs = {};
  bool _recovering = true;
  void _markEntry(String key) {
    _dirtyEntries[key] = ++_changeSequence;
    if (_recovering) _entryEpochs[key] = _changeSequence;
  }

  void _putEntry(
    String key,
    Map<String, dynamic> entry, {
    bool persist = true,
  }) {
    _usedBytes +=
        (entry['size'] as int) - ((_entries[key]?['size'] as int?) ?? 0);
    _entries[key] = entry;
    if (entry['fileName'] != null) _loaded.add(key);
    if (persist) {
      if (entry['kind'] == 'lyrics') _lyricsTimelines.remove(key);
      _publishedEntries[key] = _freezeEntry(entry);
      _markEntry(key);
    }
  }

  void _dropEntry(String key, {bool persist = true}) {
    _loaded.remove(key);
    _lyricsTimelines.remove(key);
    final old = _entries.remove(key);
    if (old != null) _usedBytes -= old['size'] as int;
    _publishedEntries.remove(key);
    _dirtyEntries.remove(key);
    _dirtyAudio.remove(key);
    _audioChanges.remove(key);
    _dirtyAccess.remove(key);
    if (_dirtyAccess.isEmpty) _nextAccessFlushAt = null;
    _persistedAccess.remove(key);
    _accessFlushTime.remove(key);
    if (persist) _markEntry(key);
  }

  void _putReservation(String name, Map<String, dynamic> reservation) {
    if (mapEquals(_reservations[name], reservation)) return;
    _reservations[name] = reservation;
    _dirtyReservations[name] = ++_changeSequence;
  }

  void _dropReservation(String name) {
    if (_reservations.remove(name) != null) {
      _dirtyReservations[name] = ++_changeSequence;
    }
  }

  String _qualificationKey(String account, String resource) =>
      jsonEncode([account, resource]);

  void _putQualification(String resource, Map<String, dynamic> qualification) {
    final key = _qualificationKey(qualification['account'] as String, resource);
    _qualifications[key] = {...qualification, 'resourceKey': resource};
    _dirtyQualifications[key] = ++_changeSequence;
  }

  void _dropQualificationRow(String key) {
    if (_qualifications.remove(key) != null) {
      _dirtyQualifications[key] = ++_changeSequence;
    }
  }

  void _dropQualification(String resource, {String? account}) {
    for (final item in _qualifications.entries.toList()) {
      if (item.value['resourceKey'] == resource &&
          (account == null || item.value['account'] == account)) {
        _dropQualificationRow(item.key);
      }
    }
  }

  bool _forceAccessFlush = false;
  final Map<String, int> _persistedAccess = {};
  final Map<String, int> _accessFlushTime = {};

  @visibleForTesting
  final Future<void> Function()? beforeAudioWrite;
  @visibleForTesting
  final Future<void> Function()? beforeDatabaseCommit;
  @visibleForTesting
  final Future<void> Function()? beforeIndexWrite;
  static const maxPendingAudioBytes = 4 * 1024 * 1024;
  int _pendingAudioBytes = 0;
  @visibleForTesting
  int get pendingAudioBytes => _pendingAudioBytes;
  final Directory directory;
  static const gb = 1000000000;
  @override
  int limitGb = 2;
  @override
  bool autoCacheEnabled = true;

  /// Zero means the entire queue; otherwise the next 1–20 entries.
  @override
  int autoCacheCount = 1;
  int clearEpoch = 0;

  @override
  Future<void> setAutoCache({bool? enabled, int? count}) async {
    if (count != null && (count < 0 || count > 20)) {
      throw ArgumentError.value(count, 'count');
    }
    await initialize();
    await _mutate(() async {
      final nextEnabled = enabled ?? autoCacheEnabled;
      final nextCount = count ?? autoCacheCount;
      final path = '${directory.path}/auto-cache.json';
      final temporary = '$path.tmp';
      for (final name in [path, temporary]) {
        final type = await FileSystemEntity.type(name, followLinks: false);
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file) {
          throw StateError('cache.settingsSymlink');
        }
      }
      await File(temporary).writeAsString(
        jsonEncode({'enabled': nextEnabled, 'count': nextCount}),
        flush: true,
      );
      await File(temporary).rename(path);
      autoCacheEnabled = nextEnabled;
      autoCacheCount = nextCount;
    });
    _notify(immediate: true);
  }

  final Map<String, Map<String, dynamic>> _entries = {};
  final Map<String, int> _pins = {};
  final Set<String> _writing = {};
  final Set<String> _pendingRemoval = {};
  bool _closed = false;
  bool _acceptAudioWrites = true;
  int _generation = 0;
  int get generation => _generation;
  Future<void> _tail = Future.value();
  final Map<String, Future<void>> _audioTails = {};
  final Map<int, int> _rangeReservations = {};
  int _nextReservation = 0;
  Future<void> _enqueueAudio(String key, Future<void> Function() operation) {
    final task = (_audioTails[key] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final settled = task.catchError((Object _) {});
    _audioTails[key] = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_audioTails[key], settled)) _audioTails.remove(key);
      }),
    );
    return task;
  }

  Timer? _timer;
  Timer? _rangeFlush;
  bool _rangeFlushInFlight = false;
  final Map<String, int> _audioRevisions = {};
  final Set<String> _dirtyAudio = {};
  @override
  int get usedBytes => _usedBytes;
  final _audioTimelines = <String, Future<_CachedAudioTimeline?>>{};

  /// Only report media intervals proven by a format index, never byte ratios.
  @override
  Future<List<CachedAudioRange>> cachedPlaybackRanges(
    TrackId track,
    AudioQuality? quality,
  ) async {
    if (quality == null || _closed) return const [];
    final resource = key('', track.value, quality.name);
    // The active in-memory ranges include newly persisted chunks. Reloading
    // the last published document here can replace them during a flush.
    if (!_loaded.contains(resource)) await validateEntry(resource);
    final entry = _entries[resource];
    if (entry == null || entry['state'] == 'deleting') return const [];
    if (completeAudio(entry)) return const [CachedAudioRange(0, 1)];
    final timeline = await _timelineFor(resource, entry);
    final current = _entries[resource];
    if (current == null || current['state'] == 'deleting') return const [];
    if (completeAudio(current)) return const [CachedAudioRange(0, 1)];
    return timeline?.project(audioRanges(current)) ?? const [];
  }

  Future<int?> cachedPlaybackByteOffset(
    TrackId track,
    AudioQuality quality,
    double fraction,
  ) async {
    final resource = key('', track.value, quality.name);
    if (!_loaded.contains(resource)) await validateEntry(resource);
    final entry = _entries[resource];
    if (entry == null || entry['state'] == 'deleting') return null;
    return (await _timelineFor(resource, entry))?.offsetAt(fraction);
  }

  Future<_CachedAudioTimeline?> _timelineFor(
    String resource,
    Map<String, dynamic> entry,
  ) async {
    final ranges = audioRanges(entry);
    final identity = '$_generation:${entry['fileName']}';
    // The header can become readable as a download progresses; don't memoize
    // absence while it still contains gaps.
    if (!_CachedAudioTimeline.covers(ranges, 0, 42)) return null;
    if (_audioTimelines.length >= 8 && !_audioTimelines.containsKey(identity)) {
      unawaited(_audioTimelines.remove(_audioTimelines.keys.first));
    }
    final timeline = await (_audioTimelines[identity] ??=
        _CachedAudioTimeline.read(
          file(resource),
          audioLength(entry),
          ranges,
        ).catchError((Object _) => null));
    if (timeline == null) unawaited(_audioTimelines.remove(identity));
    if (_closed ||
        _entries[resource]?['fileName'] != entry['fileName'] ||
        identity != '$_generation:${entry['fileName']}') {
      return null;
    }
    return timeline;
  }

  File file(String key) => File(
    '${directory.path}/${_entries[key]?['fileName'] ?? _candidate(key)}',
  );
  String key(String account, String track, String variant) => jsonEncode([
    provider,
    track,
    variant == 'lyrics-v1' ? 'lyrics' : variant,
  ]);
  String _hash(String identity) {
    final value =
        digest?.call(identity) ??
        sha256.convert(utf8.encode(identity)).toString();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw StateError('cache.invalidDigest');
    }
    return value;
  }

  String _candidate(String key) {
    final identity = jsonDecode(key) as List;
    if (identity.last == 'lyrics') {
      return 'l-${_hash(jsonEncode(identity.take(2).toList()))}.lyrics.json';
    }
    return 's-${_hash(jsonEncode(identity.take(2).toList()))}.q-${_hash(jsonEncode(identity[2]))}.g-1.audio.data';
  }

  bool _safeName(String name) => RegExp(
    r'^(s-[a-f0-9]{64}(?:-\d+)?(?:\.q-[a-f0-9]{64}(?:-\d+)?\.g-\d+\.audio\.data|\.index\.json)|l-[a-f0-9]{64}(?:-\d+)?\.lyrics\.json)$',
  ).hasMatch(name);
  Future<bool> _regular(String name) async =>
      _safeName(name) &&
      await FileSystemEntity.type(
            '${directory.path}/$name',
            followLinks: false,
          ) ==
          FileSystemEntityType.file;

  Future<String> _reserveStem(String base, String owner, String suffix) async {
    for (var n = 0; ; n++) {
      final stem = n == 0 ? base : '$base-$n';
      final name = '$stem$suffix';
      final reservation = _reservations[name];
      if (reservation?['owner'] == owner) {
        if (suffix == '.song' || suffix == '.quality') return stem;
        final type = await FileSystemEntity.type(
          '${directory.path}/$name',
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) return stem;
        if (type == FileSystemEntityType.file) {
          try {
            final doc =
                jsonDecode(await File('${directory.path}/$name').readAsString())
                    as Map;
            if (doc['schemaVersion'] == 2 &&
                jsonEncode(doc['identity']) == owner) {
              return stem;
            }
          } catch (_) {}
        }
        continue;
      }
      if ((suffix == '.song' &&
              await FileSystemEntity.type(
                    '${directory.path}/$stem.index.json',
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.notFound) ||
          reservation != null ||
          await FileSystemEntity.type(
                '${directory.path}/$name',
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
        continue;
      }
      _putReservation(name, {
        'owner': owner,
        'stem': stem,
        'generation': 0,
        'state': 'reserved',
      });
      return stem;
    }
  }

  Future<Map<String, dynamic>> _allocate(String key, String kind) async {
    final identity = jsonDecode(key) as List;
    if (kind == 'lyrics') {
      final stem = await _reserveStem(
        'l-${_hash(jsonEncode(identity.take(2).toList()))}',
        key,
        '.lyrics.json',
      );
      await _reserveTemporaryName(key, '$stem.lyrics.json', false);
      await _persistDatabase(reservationsOnly: true);
      return {
        'identity': identity,
        'lyricStem': stem,
        'fileName': '$stem.lyrics.json',
        'revision': 0,
      };
    }
    final songIdentity = jsonEncode(identity.take(2).toList());
    final songStem = await _reserveStem(
      's-${_hash(songIdentity)}',
      songIdentity,
      '.song',
    );
    final qualityStem = await _reserveStem(
      '$songStem.q-${_hash(jsonEncode(identity[2]))}',
      key,
      '.quality',
    );
    final indexName = '$songStem.index.json';
    final reservation = _reservations['$qualityStem.quality']!;
    _putReservation(indexName, {'owner': songIdentity, 'state': 'ready'});
    var generation = (reservation['generation'] as int) + 1;
    while (await FileSystemEntity.type(
              '${directory.path}/$qualityStem.g-$generation.audio.data',
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound ||
        _reservations.containsKey('$qualityStem.g-$generation.audio.data')) {
      generation++;
    }
    final name = '$qualityStem.g-$generation.audio.data';
    reservation['generation'] = generation;
    _dirtyReservations['$qualityStem.quality'] = ++_changeSequence;
    _putReservation(name, {
      'owner': key,
      'generation': generation,
      'state': 'reserved',
    });
    await _reserveTemporaryName(songIdentity, indexName, true);
    // Persist the name and generation before creating bytes.
    await _persistDatabase(reservationsOnly: true);
    await File('${directory.path}/$name').create(exclusive: true);
    return {
      'identity': identity,
      'songStem': songStem,
      'qualityStem': qualityStem,
      'indexName': indexName,
      'fileName': name,
      'generation': generation,
      'revision': 0,
    };
  }

  Future<String> _reserveTemporaryName(
    String key,
    String targetName,
    bool audio,
  ) async {
    final suffix = audio ? '.index.json' : '.lyrics.json';
    final ending = audio ? '.tmp' : '.part';
    final original = targetName.substring(0, targetName.length - suffix.length);
    final base = original.replaceFirst(RegExp(r'-\d+$'), '');
    for (var n = 0; ; n++) {
      final stem = n == 0 ? original : '$base-$n';
      final name = '$stem$suffix$ending';
      final reservation = _reservations[name];
      if (reservation != null && reservation['owner'] != key) continue;
      if (await FileSystemEntity.type(
            '${directory.path}/$name',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      if (reservation == null) {
        _putReservation(name, {
          'owner': key,
          'type': audio ? 'indexTemporary' : 'lyricsTemporary',
          'state': 'reserved',
        });
      }
      return name;
    }
  }

  Future<File> _temporaryFile(String key, String targetName, bool audio) async {
    for (;;) {
      final name = await _reserveTemporaryName(key, targetName, audio);
      await _persistDatabase(reservationsOnly: true);
      final file = File('${directory.path}/$name');
      try {
        await file.create(exclusive: true);
        return file;
      } on FileSystemException {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
  }

  final LinkedHashMap<String, Map<String, dynamic>> _songDocuments =
      LinkedHashMap();
  final LinkedHashMap<String, Map<String, dynamic>> _lyricDocuments =
      LinkedHashMap();
  final Set<String> _loaded = {};
  final Set<String> _documentLeases = {};
  final Set<String> _tombstoneDocuments = {};
  static const documentMemoryLimit = 128;

  @visibleForTesting
  int get loadedSongs => _songDocuments.length;
  @visibleForTesting
  int get loadedLyrics => _lyricDocuments.length;

  String _documentPath(Map e) =>
      (e['documentPath'] ??
              (e['kind'] == 'audio' ? e['indexName'] : e['fileName']))
          as String;

  void _boundDocuments() {
    void trim(
      LinkedHashMap<String, Map<String, dynamic>> documents,
      bool audio,
    ) {
      for (final name in documents.keys.toList()) {
        if (documents.length <= documentMemoryLimit) break;
        final keys = _loaded
            .where(
              (key) =>
                  _entries[key] != null &&
                  _documentPath(_entries[key]!) == name,
            )
            .toList();
        if (keys.any(
          (key) =>
              _pins.containsKey(key) ||
              _documentLeases.contains(key) ||
              _writing.contains(key) ||
              _dirtyDocuments.contains(key) ||
              _dirtyEntries.containsKey(key) ||
              _audioTails.containsKey(key),
        )) {
          continue;
        }
        documents.remove(name);
        for (final key in keys) {
          final e = _entries[key]!;
          _entries[key] = PlaybackCacheStore.summary(key, e);
          _publishedEntries.remove(key);
          _loaded.remove(key);
        }
      }
    }

    trim(_songDocuments, true);
    trim(_lyricDocuments, false);
  }

  Future<Map<String, dynamic>> _readDocument(String name, bool audio) async {
    final documents = audio ? _songDocuments : _lyricDocuments;
    final cached = documents.remove(name);
    if (cached != null) {
      documents[name] = cached;
      return cached;
    }
    final doc = Map<String, dynamic>.from(
      jsonDecode(await File('${directory.path}/$name').readAsString()) as Map,
    );
    if (doc['schemaVersion'] != 2) {
      throw StateError('cache.unsupportedDocument');
    }
    documents[name] = doc;
    return doc;
  }

  Map<String, dynamic> _audioFromSong(Map song, String key, String name) {
    final identity = jsonDecode(key) as List;
    if (identity.length != 3 ||
        identity.any((v) => v is! String) ||
        jsonEncode(song['songIdentity']) !=
            jsonEncode(identity.take(2).toList()) ||
        name != "${song['songStem']}.index.json") {
      throw StateError('cache.indexOwner');
    }
    final quality = (song['qualities'] as Map)[identity.last] as Map?;
    if (quality == null) throw StateError('cache.missingQuality');
    if (quality['identity'] != null && jsonEncode(quality['identity']) != key) {
      throw StateError('cache.qualityOwner');
    }
    final e = <String, dynamic>{
      ...quality.cast<String, dynamic>(),
      'version': quality['resourceVersion'],
      'total': quality['totalBytes'],
      'size': quality['effectiveBytes'],
      'identity': identity,
      'songStem': song['songStem'],
      'indexName': name,
      'kind': 'audio',
      'schemaVersion': 2,
    };
    if (e['fileName'] !=
            "${e['qualityStem']}.g-${e['generation']}.audio.data" ||
        !(e['qualityStem'] as String).startsWith("${song['songStem']}.q-")) {
      throw StateError('cache.invalidAudioName');
    }
    return e;
  }

  Future<Map<String, dynamic>?> _songForPublish(
    String name,
    String owner,
  ) async {
    final cached = _songDocuments[name];
    final remembered =
        cached != null &&
            cached['schemaVersion'] == 2 &&
            jsonEncode(cached['songIdentity']) == owner &&
            name == "${cached['songStem']}.index.json" &&
            cached['qualities'] is Map &&
            cached['tombstones'] is List &&
            cached['revision'] is int &&
            (cached['revision'] as int) >= 0
        ? cached
        : null;
    if (await FileSystemEntity.type(
          '${directory.path}/$name',
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      return remembered;
    }
    if (!await _regular(name)) throw StateError('cache.unsafeIndex');
    try {
      // A cached copy cannot hide damage to the authoritative file on publish.
      _songDocuments.remove(name);
      final song = await _readDocument(name, true);
      if (song['songIdentity'] is! List ||
          song['qualities'] is! Map ||
          song['tombstones'] is! List ||
          song['revision'] is! int ||
          (song['revision'] as int) < 0) {
        throw const FormatException('cache.invalidSongIndex');
      }
      if (jsonEncode(song['songIdentity']) != owner ||
          name != "${song['songStem']}.index.json") {
        throw StateError('cache.indexOwner');
      }
      return song;
    } catch (error) {
      // Unsupported versions, foreign identities and IO failures must not be
      // treated as corruption or overwrite someone else's document.
      if (error is! FormatException && error is! TypeError) rethrow;
      if (_reservations[name]?['owner'] != owner) rethrow;
      _songDocuments.remove(name);
      final qualities = <String, dynamic>{};
      final tombstones = <dynamic>[];
      var revision = 0;
      if (remembered != null &&
          jsonEncode(remembered['songIdentity']) == owner) {
        revision = remembered['revision'] as int;
        tombstones.addAll(remembered['tombstones'] as List);
        for (final quality in (remembered['qualities'] as Map).keys) {
          try {
            final entry = _audioFromSong(
              remembered,
              jsonEncode([...jsonDecode(owner) as List, quality]),
              name,
            );
            if (await _regular(entry['fileName'] as String) &&
                _validAudioIndex(
                  entry,
                  await File('${directory.path}/${entry['fileName']}').length(),
                )) {
              qualities[quality as String] =
                  (remembered['qualities'] as Map)[quality];
            }
          } on FileSystemException {
            // Unreadable bytes cannot be claimed by the reconstructed index.
          } on FormatException {
            // Only already validated, published qualities may be salvaged.
          } on TypeError {
            // A malformed sibling is unavailable, not an inferred cache hit.
          } on StateError {
            // Preserve independent valid qualities without adopting conflicts.
          }
        }
      }
      var suffix = 1;
      while (await FileSystemEntity.type(
            '${directory.path}/$name.corrupt-$suffix',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        suffix++;
      }
      await File(
        '${directory.path}/$name',
      ).rename('${directory.path}/$name.corrupt-$suffix');
      final rebuilt = <String, dynamic>{
        'schemaVersion': 2,
        'songIdentity': jsonDecode(owner),
        'songStem': name.substring(0, name.length - '.index.json'.length),
        'revision': revision,
        'qualities': qualities,
        'tombstones': tombstones,
      };
      // Retain the salvage seed if the replacement write itself has to retry.
      _songDocuments[name] = rebuilt;
      return rebuilt;
    }
  }

  Future<void> _writeDocument(String key, Map<String, dynamic> e) async {
    final audio = e['kind'] == 'audio';
    final name = _documentPath(e);
    final revision = (e['revision'] as int) + 1;
    final committed = {
      ..._freezeEntry(e),
      'revision': revision,
      'schemaVersion': 2,
    }..remove('documentPath');
    await beforeIndexWrite?.call();
    Map<String, dynamic> document;
    final owner = audio
        ? jsonEncode((e['identity'] as List).take(2).toList())
        : key;
    if (audio) {
      final old = await _songForPublish(name, owner);
      final qualities = <String, dynamic>{
        ...?old?['qualities'] as Map<String, dynamic>?,
      };
      final tombstones = <dynamic>[...?old?['tombstones'] as List?];
      final quality = (e['identity'] as List).last as String;
      if (e['state'] == 'deleting') {
        _tombstoneDocuments.add(name);
        qualities.remove(quality);
        tombstones.removeWhere((t) => t['resourceKey'] == key);
        tombstones.add({
          'resourceKey': key,
          'generation': e['generation'],
          'revision': revision,
          'fileName': e['fileName'],
        });
      } else {
        qualities[quality] =
            {
              ...committed,
              'state': committed['state'] ?? 'ready',
              'resourceVersion': committed['version'],
              'totalBytes': committed['total'],
              'effectiveBytes': committed['size'],
            }..removeWhere(
              (field, _) => const {
                'access',
                'identity',
                'songStem',
                'indexName',
                'schemaVersion',
                'kind',
                'version',
                'total',
                'size',
              }.contains(field),
            );
      }
      document = {
        'schemaVersion': 2,
        'songIdentity': jsonDecode(owner),
        'songStem': e['songStem'],
        'revision': ((old?['revision'] as int?) ?? 0) + 1,
        'qualities': qualities,
        'tombstones': tombstones,
      };
    } else {
      document = Map<String, dynamic>.from(committed)
        ..remove('access')
        ..remove('size');
    }
    final tmp = await _temporaryFile(owner, name, audio);
    await tmp.writeAsString(jsonEncode(document), flush: true);
    await tmp.rename('${directory.path}/$name');
    (audio ? _songDocuments : _lyricDocuments)[name] = document;
    e['revision'] = revision;
    e['schemaVersion'] = 2;
    _loaded.add(key);
    _publishedEntries[key] = committed;
    _markEntry(key);
    if (audio) indexWrites++;
  }

  Future<void> _cleanupRetired() async {
    if (_pins.isNotEmpty) return;
    for (final path in _retired.keys.toList()) {
      final owner = _retired[path]!;
      if (_dirtyDocuments.contains(owner) || _dirtyEntries.containsKey(owner)) {
        continue;
      }
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(path).delete();
      }
      _retired.remove(path);
      _dropReservation(File(path).uri.pathSegments.last);
    }
    for (final name in _tombstoneDocuments.toList()) {
      _songDocuments.remove(name);
      if (!await _regular(name)) {
        _tombstoneDocuments.remove(name);
        continue;
      }
      final song = await _readDocument(name, true);
      final retained = <dynamic>[];
      for (final tombstone in song['tombstones'] as List) {
        final key = tombstone['resourceKey'] as String;
        if (_audioTails.containsKey(key) ||
            _writing.contains(key) ||
            _dirtyDocuments.contains(key) ||
            _entries[key]?['state'] == 'deleting' ||
            await FileSystemEntity.type(
                  '${directory.path}/${tombstone['fileName']}',
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound) {
          retained.add(tombstone);
        } else if (!_entries.containsKey(key)) {
          final qualityStem = (tombstone['fileName'] as String).replaceFirst(
            RegExp(r'\.g-\d+\.audio\.data$'),
            '',
          );
          _dropReservation('$qualityStem.quality');
        }
      }
      if (retained.length == (song['tombstones'] as List).length) continue;
      final owner = jsonEncode(song['songIdentity']);
      if ((song['qualities'] as Map).isEmpty && retained.isEmpty) {
        await File('${directory.path}/$name').delete();
        _songDocuments.remove(name);
        _dropReservation(name);
        _dropReservation("${song['songStem']}.song");
      } else {
        final next = {
          ...song,
          'revision': (song['revision'] as int) + 1,
          'tombstones': retained,
        };
        final temporary = await _temporaryFile(owner, name, true);
        await temporary.writeAsString(jsonEncode(next), flush: true);
        await temporary.rename('${directory.path}/$name');
        _songDocuments[name] = next;
      }
      if (retained.isEmpty) _tombstoneDocuments.remove(name);
    }
  }

  Future<void> _persistDatabase({bool reservationsOnly = false}) async {
    final time = DateTime.now().millisecondsSinceEpoch;
    final entryVersions = reservationsOnly
        ? <String, int>{}
        : Map<String, int>.of(_dirtyEntries);
    final reservationVersions = Map<String, int>.of(_dirtyReservations);
    final qualificationVersions = reservationsOnly
        ? <String, int>{}
        : Map<String, int>.of(_dirtyQualifications);
    final collectAccess =
        !reservationsOnly &&
        (_forceAccessFlush ||
            (_nextAccessFlushAt != null && time >= _nextAccessFlushAt!));
    final accessVersions = !collectAccess
        ? <String, int>{}
        : {
            for (final e in _dirtyAccess.entries)
              if (_entries[e.key] != null &&
                  !_dirtyDocuments.contains(e.key) &&
                  (_forceAccessFlush ||
                      time - (_accessFlushTime[e.key] ?? 0) >= 60000))
                e.key: e.value,
          };
    final limitVersion = reservationsOnly ? null : _dirtyLimit;
    int accessFor(String key) => accessVersions.containsKey(key)
        ? _entries[key]!['access'] as int
        : _persistedAccess[key] ?? _entries[key]!['access'] as int;
    final delta = PlaybackCacheDelta(
      entries: {
        for (final key in entryVersions.keys)
          if (_entries[key] != null)
            key: PlaybackCacheStore.summary(key, {
              ...(_entries[key]!['state'] == 'deleting'
                  ? _entries[key]!
                  : _publishedEntries[key]!),
              'access': accessFor(key),
            }),
      },
      deletedEntries: {
        for (final key in entryVersions.keys)
          if (_entries[key] == null) key,
      },
      reservations: {
        for (final key in reservationVersions.keys)
          if (_reservations[key] != null) key: _reservations[key]!,
      },
      deletedReservations: {
        for (final key in reservationVersions.keys)
          if (_reservations[key] == null) key,
      },
      qualifications: {
        for (final key in qualificationVersions.keys)
          if (_qualifications[key] != null) key: _qualifications[key]!,
      },
      deletedQualifications: {
        for (final key in qualificationVersions.keys)
          if (_qualifications[key] == null) key,
      },
      access: {
        for (final key in accessVersions.keys)
          if (!entryVersions.containsKey(key))
            key: _entries[key]!['access'] as int,
      },
      limitBytes: limitVersion == null ? null : limitGb * gb,
    );
    if (delta.isEmpty) return;
    try {
      await beforeDatabaseCommit?.call();
      onDatabaseDelta?.call(delta);
      await _store?.applyDelta(delta);
      void acknowledge(Map<String, int> live, Map<String, int> sent) {
        for (final e in sent.entries) {
          if (live[e.key] == e.value) live.remove(e.key);
        }
      }

      acknowledge(_dirtyEntries, entryVersions);
      acknowledge(_dirtyReservations, reservationVersions);
      acknowledge(_dirtyQualifications, qualificationVersions);
      acknowledge(_dirtyAccess, accessVersions);
      if (_dirtyLimit == limitVersion) _dirtyLimit = null;
      for (final key in delta.deletedEntries) {
        _persistedAccess.remove(key);
        _accessFlushTime.remove(key);
      }
      for (final e in delta.entries.entries) {
        _persistedAccess[e.key] = e.value['access'] as int;
        if (_entries[e.key]?['access'] == e.value['access']) {
          _dirtyAccess.remove(e.key);
        }
        if (accessVersions.containsKey(e.key) ||
            !_accessFlushTime.containsKey(e.key)) {
          _accessFlushTime[e.key] = time;
        }
      }
      for (final e in delta.access.entries) {
        _persistedAccess[e.key] = e.value;
        _accessFlushTime[e.key] = time;
      }
      if (_dirtyAccess.isEmpty) {
        _nextAccessFlushAt = null;
      } else if (collectAccess) {
        // Only reconsider deferred access keys when their deadline is due,
        // rather than scanning them on every unrelated content commit.
        _nextAccessFlushAt = null;
        for (final key in _dirtyAccess.keys) {
          final due = (_accessFlushTime[key] ?? time) + 60000;
          if (_nextAccessFlushAt == null || due < _nextAccessFlushAt!) {
            _nextAccessFlushAt = due;
          }
        }
      }
      _databaseHealthy = true;
    } catch (_) {
      _databaseHealthy = false;
      rethrow;
    }
  }

  void _notify({bool immediate = false}) {
    if (_closed) return;
    if (immediate) {
      _notification?.cancel();
      _notification = null;
      notifyListeners();
      return;
    }
    _notification ??= Timer(const Duration(seconds: 1), () {
      _notification = null;
      if (!_closed) notifyListeners();
    });
  }

  bool _available = true;
  Future<void>? _ready;
  Future<void>? _recovery;
  Future<void> get recovery => _recovery ?? Future<void>.value();
  Future<void> validateEntry(String key) async {
    final e = _entries[key];
    if (e == null ||
        _dirtyDocuments.contains(key) ||
        e['state'] == 'deleting') {
      return;
    }
    try {
      final audio = e['kind'] == 'audio';
      final name = _documentPath(e);
      final doc = await _readDocument(name, audio);
      final content = audio
          ? _audioFromSong(doc, key, name)
          : Map<String, dynamic>.from(doc);
      if (jsonEncode(content['identity']) != key ||
          content['state'] == 'deleting' ||
          !await _regular(content['fileName'] as String) ||
          !_validAudioIndex(
            content,
            await File('${directory.path}/${content['fileName']}').length(),
          )) {
        throw StateError('cache.invalidDocument');
      }
      final validated = {
        ...content,
        'access': e['access'],
        if (!audio) 'size': await File('${directory.path}/$name').length(),
      };
      final changed =
          e['revision'] != validated['revision'] ||
          e['size'] != validated['size'];
      _putEntry(key, validated, persist: changed);
      _loaded.add(key);
      if (changed && audio) _dropQualification(key);
      _boundDocuments();
    } catch (_) {
      if (!_dirtyDocuments.contains(key)) {
        _dropEntry(key);
        _dropQualification(key);
      }
    }
  }

  Future<void> initialize() => _ready ??= _initialize().catchError((Object _) {
    _available = false;
    unawaited(_lock?.close());
    _lock = null;
    if (_directoryIdentity != null) _openDirectories.remove(_directoryIdentity);
    _directoryIdentity = null;
  });
  Future<void> _initialize() async {
    await directory.create(recursive: true);
    _directoryIdentity = await directory.resolveSymbolicLinks();
    if (!_openDirectories.add(_directoryIdentity!)) {
      _directoryIdentity = null;
      throw StateError('cache.directoryInUse');
    }
    final lockFile = File('${directory.path}/.lock');
    if (await FileSystemEntity.type(lockFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('cache.lockSymlink');
    }
    _lock = await lockFile.open(mode: FileMode.append);
    await _lock!.lock(FileLock.exclusive);
    for (final name in [
      'cache.sqlite',
      'cache.sqlite-wal',
      'cache.sqlite-shm',
    ]) {
      if (await FileSystemEntity.type(
            '${directory.path}/$name',
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        throw StateError('cache.databaseSymlink');
      }
    }
    Map<String, dynamic> snapshot;
    try {
      _store = await PlaybackCacheStore.open('${directory.path}/cache.sqlite');
      snapshot = await _store!.load();
    } catch (error) {
      if (error is! PlaybackCacheStoreException || !error.isCorrupt) {
        rethrow;
      }
      await _store?.close();
      _store = null;
      final database = File('${directory.path}/cache.sqlite');
      var suffix = 1;
      while (await FileSystemEntity.type(
            '${database.path}.corrupt-$suffix',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        suffix++;
      }
      await database.rename('${database.path}.corrupt-$suffix');
      for (final suffix in ['-wal', '-shm']) {
        final file = File('${database.path}$suffix');
        if (await file.exists()) await file.delete();
      }
      _store = await PlaybackCacheStore.open(database.path);
      snapshot = await _store!.load();
    }
    final settingsFile = File('${directory.path}/auto-cache.json');
    if (await FileSystemEntity.type(settingsFile.path, followLinks: false) ==
        FileSystemEntityType.file) {
      try {
        final settings = jsonDecode(await settingsFile.readAsString()) as Map;
        autoCacheEnabled = settings['enabled'] is bool
            ? settings['enabled'] as bool
            : true;
        final count = settings['count'];
        autoCacheCount = count is int && count >= 0 && count <= 20 ? count : 1;
      } catch (_) {
        /* Rebuildable settings use defaults when corrupt. */
      }
    }
    limitGb = ((snapshot['limitBytes'] as int) ~/ gb).clamp(1, 10);
    for (final item in (snapshot['reservations'] as Map).entries) {
      _reservations[item.key as String] = Map<String, dynamic>.from(
        item.value as Map,
      );
    }
    for (final item in (snapshot['qualifications'] as Map).entries) {
      _qualifications[item.key as String] = Map<String, dynamic>.from(
        item.value as Map,
      );
    }
    for (final item in (snapshot['entries'] as Map).entries) {
      final e = Map<String, dynamic>.from(item.value as Map);
      if (e['state'] != 'deleting' && _safeName(_documentPath(e))) {
        final key = item.key as String;
        _putEntry(key, e, persist: false);
        _persistedAccess[key] = e['access'] as int;
        _accessFlushTime[key] = DateTime.now().millisecondsSinceEpoch;
      }
    }
    _recovery = _recover(snapshot).catchError((Object _) {}).whenComplete(() {
      _recovering = false;
      _entryEpochs.clear();
    });
    if ((snapshot['entries'] as Map).isEmpty) await _recovery;
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_mutate(_trim).catchError((Object _) {}));
    });
    _accessTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_mutate(() async {}).catchError((Object _) {}));
    });
  }

  Future<void> _recover(Map<String, dynamic> snapshot) async {
    final startedGeneration = _generation;
    final startedEpochs = Map<String, int>.of(_entryEpochs);
    // Read independent authoritative documents. Unknown and old files are never adopted.
    final candidates = <String, Map<String, dynamic>>{};
    final files = <String, String>{};
    final songDocuments = <String, String>{};
    final conflictingSongs = <String>{};
    int scanned = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !_safeName(entity.uri.pathSegments.last) ||
          (!entity.path.endsWith('.index.json') &&
              !entity.path.endsWith('.lyrics.json'))) {
        continue;
      }
      try {
        final root = Map<String, dynamic>.from(
          jsonDecode(await entity.readAsString()) as Map,
        );
        if (root['schemaVersion'] != 2) continue;
        final actualName = entity.uri.pathSegments.last;
        final documents = <Map<String, dynamic>>[];
        if (entity.path.endsWith('.index.json')) {
          final song = root['songIdentity'] as List;
          final songKey = jsonEncode(song);
          final previous = songDocuments[songKey];
          if (previous != null && previous != actualName) {
            conflictingSongs.add(songKey);
            for (final item in candidates.entries) {
              if (item.value['songKey'] == songKey) _blocked.add(item.key);
            }
          }
          if (conflictingSongs.contains(songKey)) {
            for (final quality in (root['qualities'] as Map).keys) {
              _blocked.add(jsonEncode([...song, quality]));
            }
            continue;
          }
          songDocuments[songKey] = actualName;
          for (final quality in (root['qualities'] as Map).keys) {
            documents.add(
              _audioFromSong(root, jsonEncode([...song, quality]), actualName),
            );
          }
          // Durable deletion evidence survives losing the entire database.
          for (final tombstone in root['tombstones'] as List) {
            _tombstoneDocuments.add(actualName);
            final identity =
                jsonDecode(tombstone['resourceKey'] as String) as List;
            if (jsonEncode(identity.take(2).toList()) != jsonEncode(song)) {
              throw StateError('cache.tombstoneOwner');
            }
            final name = tombstone['fileName'];
            if ((root['qualities'] as Map).values.any(
              (quality) => quality['fileName'] == name,
            )) {
              throw StateError('cache.tombstoneReferencesLiveQuality');
            }
            if (name is String &&
                _safeName(name) &&
                name.startsWith("${root['songStem']}.q-") &&
                name.endsWith(".g-${tombstone['generation']}.audio.data")) {
              _retired['${directory.path}/$name'] =
                  tombstone['resourceKey'] as String;
            }
          }
        } else if (root['state'] != 'deleting') {
          documents.add(root);
        } else if (root['fileName'] == actualName &&
            (root['identity'] as List).length == 3 &&
            (root['identity'] as List).last == 'lyrics') {
          _retired[entity.path] = jsonEncode(root['identity']);
        }
        for (final document in documents) {
          final key = jsonEncode(document['identity']);
          final dbEntry = (snapshot['entries'] as Map)[key] as Map?;
          if (dbEntry?['state'] == 'deleting') continue;
          final filename = document['fileName'] as String;
          final registered = _reservations[actualName];
          if (registered != null &&
              registered['owner'] !=
                  (document['kind'] == 'audio'
                      ? jsonEncode(
                          (document['identity'] as List).take(2).toList(),
                        )
                      : key)) {
            _blocked.add(key);
            _blocked.add(registered['owner'] as String);
            continue;
          }
          if (document['kind'] == 'audio' &&
              (filename !=
                      '${document['qualityStem']}.g-${document['generation']}.audio.data' ||
                  document['indexName'] !=
                      '${document['songStem']}.index.json' ||
                  !(document['qualityStem'] as String).startsWith(
                    '${document['songStem']}.q-',
                  ))) {
            continue;
          }
          if (!await _regular(filename) ||
              (document['kind'] == 'audio'
                  ? document['indexName'] != actualName
                  : filename != actualName) ||
              !_validAudioIndex(
                document,
                await File('${directory.path}/$filename').length(),
              )) {
            continue;
          }
          if (candidates.containsKey(key) ||
              (files.containsKey(filename) && files[filename] != key)) {
            _blocked.add(key);
            if (files[filename] != null) _blocked.add(files[filename]!);
            continue;
          }
          files[filename] = key;
          document['access'] = dbEntry?['access'] ?? 0;
          if (document['kind'] == 'lyrics') {
            document['size'] = await entity.length();
          }
          candidates[key] = {
            ...PlaybackCacheStore.summary(key, document),
            for (final field in [
              'fileName',
              'indexName',
              'generation',
              'version',
              'songStem',
              'qualityStem',
              'lyricStem',
            ])
              if (document[field] != null) field: document[field],
          };
        }
      } catch (_) {
        /* Only this document is unavailable. */
      }
      if (++scanned % 64 == 0) await Future<void>.delayed(Duration.zero);
    }
    await _mutate(() async {
      if (startedGeneration != _generation || _closed) return;
      for (final key in (snapshot['entries'] as Map).keys.cast<String>()) {
        if (_entryEpochs[key] == startedEpochs[key] &&
            (!candidates.containsKey(key) || _blocked.contains(key)) &&
            !_dirtyDocuments.contains(key) &&
            !_pins.containsKey(key)) {
          _dropEntry(key);
          _dropQualification(key);
        }
      }
      for (final item in candidates.entries) {
        if (_blocked.contains(item.key) ||
            _entryEpochs[item.key] != startedEpochs[item.key]) {
          continue;
        }
        final live = _entries[item.key];
        final saved = (snapshot['entries'] as Map)[item.key] as Map?;
        if (_dirtyDocuments.contains(item.key)) continue;
        // NORMAL may also leave SQLite ahead of an older directory entry after
        // power failure. Repair either direction, but preserve this launch's
        // newer writes and access times.
        if (live != null) {
          item.value['access'] = max(
            live['access'] as int,
            item.value['access'] as int,
          );
        }
        final qualificationMismatch = _qualifications.values.any(
          (qualification) =>
              qualification['resourceKey'] == item.key &&
              (qualification['version'] != item.value['version'] ||
                  (qualification['generation'] != null &&
                      qualification['generation'] != item.value['generation'])),
        );
        if (item.value['kind'] == 'audio' &&
            (!_sameEntrySummary(saved, item.value) || qualificationMismatch)) {
          _dropQualification(item.key);
        }
        _putEntry(
          item.key,
          _loaded.contains(item.key) && _sameEntrySummary(live, item.value)
              ? {...live!, 'access': item.value['access']}
              : PlaybackCacheStore.summary(item.key, item.value),
          persist:
              saved == null ||
              saved['revision'] != item.value['revision'] ||
              saved['size'] != item.value['size'],
        );
        final e = item.value;
        _putReservation(e['fileName'] as String, {
          'owner': item.key,
          'generation': e['generation'] ?? 0,
          if (e['kind'] == 'lyrics') 'stem': e['lyricStem'],
          'state': 'ready',
        });
        if (e['kind'] == 'audio') {
          _putReservation(e['indexName'] as String, {
            'owner': jsonEncode((e['identity'] as List).take(2).toList()),
            'state': 'ready',
          });
          _putReservation('${e['qualityStem']}.quality', {
            'owner': item.key,
            'generation': e['generation'],
            'stem': e['qualityStem'],
            'state': 'ready',
          });
          final songIdentity = jsonEncode(
            (e['identity'] as List).take(2).toList(),
          );
          _putReservation('${e['songStem']}.song', {
            'owner': songIdentity,
            'generation': 0,
            'stem': e['songStem'],
            'state': 'ready',
          });
        }
      }
      // A database deletion marker may precede its authoritative tombstone.
      for (final item in (snapshot['entries'] as Map).entries) {
        if ((item.value as Map)['state'] != 'deleting') continue;
        final e = Map<String, dynamic>.from(item.value as Map);
        final name = _documentPath(e);
        try {
          final doc = await _readDocument(name, e['kind'] == 'audio');
          final content = e['kind'] == 'audio'
              ? _audioFromSong(doc, item.key as String, name)
              : doc;
          _putEntry(item.key as String, {
            ...content,
            'access': e['access'],
          }, persist: false);
          await _remove(item.key as String);
        } catch (_) {
          _dropEntry(item.key as String);
          _dropQualification(item.key as String);
        }
      }
      for (final name in _reservations.keys) {
        final owner = _reservations[name]!['owner'] as String;
        if (name.endsWith('.audio.data') &&
            !_blocked.contains(owner) &&
            candidates[owner]?['fileName'] != name &&
            !_dirtyDocuments.contains(owner) &&
            await _regular(name)) {
          _retired['${directory.path}/$name'] = owner;
        }
      }
      await _trim();
    });
    _notify(immediate: true);
  }

  Map<String, dynamic>? lookup(String key) {
    final e = _entries[key];
    if (_blocked.contains(key) || e?['state'] == 'deleting') return null;
    if (e != null) {
      final time = DateTime.now().millisecondsSinceEpoch;
      if (e['access'] != time) {
        e['access'] = time;
        _markAccess(key, time);
      }
    }
    return _loaded.contains(key) || _dirtyDocuments.contains(key) ? e : null;
  }

  void pin(String key) => _pins.update(key, (v) => v + 1, ifAbsent: () => 1);
  void unpin(String key) {
    final count = (_pins[key] ?? 1) - 1;
    if (count <= 0) {
      _pins.remove(key);
      _boundDocuments();
      if (_pendingRemoval.remove(key)) {
        unawaited(_mutate(() => _remove(key)));
      }
    } else {
      _pins[key] = count;
    }
  }

  Future<void> _mutate(
    Future<void> Function() operation, {
    bool persist = true,
  }) {
    final task = _tail.then((_) async {
      await operation();
      if (!persist) {
        return;
      }
      await _flushAudioFiles();
      for (final key in _dirtyDocuments.toList()) {
        if (_audioTails.containsKey(key) || _dirtyAudio.contains(key)) continue;
        final version = _documentChanges[key];
        final e = _entries[key];
        if (e != null && e['kind'] == 'audio') await _writeDocument(key, e);
        if (_documentChanges[key] == version) {
          _dirtyDocuments.remove(key);
          _documentChanges.remove(key);
        }
      }
      await _persistDatabase();
      await _cleanupRetired();
      await _persistDatabase();
      _boundDocuments();
      _notify();
    });
    _tail = task.catchError((Object _) {});
    return task;
  }

  @override
  Future<void> setLimit(int value) {
    if (value < 1 || value > 10) {
      throw RangeError.range(value, 1, 10);
    }
    return _mutate(() async {
      if (limitGb != value) {
        limitGb = value;
        _dirtyLimit = ++_changeSequence;
      }
      await _trim(reserved: _reservedRangeBytes);
    }).then((_) => _notify(immediate: true));
  }

  Future<void> clearAccount(String account) => _mutate(() async {
    for (final item in _qualifications.entries.toList()) {
      if (item.value['account'] == account) _dropQualificationRow(item.key);
    }
  });

  @override
  Future<void> clear({String? account}) {
    if (account != null) return clearAccount(account);
    clearEpoch++;
    // Invalidate queued network and disk publications immediately.
    _generation++;
    _lyricsTimelines.clear();
    _notify(immediate: true);
    return _mutate(() async {
      for (final key in _entries.keys.toList()) {
        await _remove(key);
      }
    }).then((_) => _notify(immediate: true));
  }

  Future<void> _remove(String key) async {
    // This is an internal document lease, not a reader pin: it protects the
    // validated metadata without deferring deletion of the target's bytes.
    _documentLeases.add(key);
    try {
      await _removeLeased(key);
    } finally {
      _documentLeases.remove(key);
      _boundDocuments();
    }
  }

  Future<void> _removeLeased(String key) async {
    if (!_loaded.contains(key)) await validateEntry(key);
    final entry = _entries[key];
    if (entry == null) return;
    entry['state'] = 'deleting';
    _markEntry(key);
    await _persistDatabase();
    await _writeDocument(key, entry);
    _dirtyDocuments.remove(key);
    if ((_pins[key] ?? 0) > 0) {
      _pendingRemoval.add(key);
      return;
    }
    try {
      if (await file(key).exists()) {
        await file(key).delete();
      }
    } catch (_) {
      return;
    }
    // Keep song tombstones until recovery has confirmed retired bytes are gone.
    // Other qualities still share this index and must remain discoverable.
    if (entry['kind'] == 'lyrics') _lyricDocuments.remove(_documentPath(entry));
    _dirtyDocuments.remove(key);
    _dropEntry(key);
    _dropQualification(key);
    _dropReservation(entry['fileName'] as String);
    if (!_audioTails.containsKey(key) &&
        !_writing.contains(key) &&
        !_retired.values.contains(key)) {
      for (final name in _reservations.keys.toList()) {
        if (!name.endsWith('.quality') &&
            _reservations[name]?['owner'] == key &&
            await FileSystemEntity.type(
                  '${directory.path}/$name',
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound) {
          _dropReservation(name);
        }
      }
    }
    _audioRevisions.update(key, (v) => v + 1, ifAbsent: () => 1);
  }

  Future<void> _trim({int reserved = 0}) async {
    if (usedBytes + reserved <= limitGb * gb) return;
    // Publish latest in-memory access before choosing indexed candidates. This
    // is only paid when over budget, not on normal playback or empty flushes.
    final forced = _forceAccessFlush;
    _forceAccessFlush = true;
    try {
      await _persistDatabase();
    } finally {
      _forceAccessFlush = forced;
    }
    var offset = 0;
    while (usedBytes + reserved > limitGb * gb) {
      final candidates = await _store?.lru(limit: 128, offset: offset) ?? [];
      if (candidates.isEmpty) break;
      var skipped = 0;
      for (final row in candidates) {
        if (usedBytes + reserved <= limitGb * gb) break;
        final key = row['key'] as String;
        final live = _entries[key];
        if (live == null ||
            _pins.containsKey(key) ||
            _audioTails.containsKey(key) ||
            _dirtyDocuments.contains(key) ||
            live['access'] != row['access']) {
          skipped++;
          continue;
        }
        await _remove(key);
        await _persistDatabase();
      }
      offset += skipped;
    }
  }

  static List<List<int>> audioRanges(Map<String, dynamic> entry) =>
      entry['ranges'] == null
      ? [
          [0, entry['size'] as int],
        ]
      : [
          for (final range in entry['ranges'] as List)
            List<int>.from(range as List),
        ];
  static int audioLength(Map<String, dynamic> entry) =>
      (entry['total'] ?? entry['size']) as int;
  static bool completeAudio(Map<String, dynamic> entry) =>
      entry['kind'] == 'audio' &&
      entry['size'] == audioLength(entry) &&
      audioRanges(entry).length == 1 &&
      audioRanges(entry).single[0] == 0 &&
      audioRanges(entry).single[1] == audioLength(entry);

  bool _validAudioIndex(Map<String, dynamic> entry, int length) {
    if (entry['kind'] != 'audio') return true;
    if (entry['ranges'] == null) {
      return length == entry['size'];
    }
    try {
      final total = audioLength(entry);
      final ranges = audioRanges(entry);
      int previous = 0, bytes = 0;
      for (final r in ranges) {
        if (r.length != 2 ||
            r[0] < previous ||
            r[1] <= r[0] ||
            r[1] > total ||
            r[1] > length) {
          return false;
        }
        bytes += r[1] - r[0];
        previous = r[1];
      }
      return total > 0 && bytes == entry['size'];
    } catch (_) {
      return false;
    }
  }

  int audioRevision(String key) => _audioRevisions[key] ?? 0;

  Future<void> _flushAudioFiles() async {
    for (final key in _dirtyAudio.toList()) {
      if (_audioTails.containsKey(key)) continue;
      final version = _audioChanges[key];
      final entry = _entries[key];
      if (entry != null && await _regular(entry['fileName'] as String)) {
        final handle = await file(key).open(mode: FileMode.append);
        try {
          await handle.flush();
        } finally {
          await handle.close();
        }
      }
      if (_audioChanges[key] == version) {
        _dirtyAudio.remove(key);
        _audioChanges.remove(key);
      }
    }
  }

  void _scheduleRangeFlush() {
    if (_closed || _rangeFlushInFlight) return;
    _rangeFlush ??= Timer(const Duration(milliseconds: 350), () {
      _rangeFlush = null;
      if (_closed) return;
      _rangeFlushInFlight = true;
      unawaited(
        flushAudioWrites().catchError((Object _) {}).whenComplete(() {
          _rangeFlushInFlight = false;
          if (_dirtyAudio.isNotEmpty || _dirtyDocuments.isNotEmpty) {
            _scheduleRangeFlush();
          }
        }),
      );
    });
  }

  Future<void> prepareAudio(
    String key,
    int total,
    String? version,
    Map<String, dynamic> metadata,
    int generation, {
    bool reset = false,
  }) async {
    if (!_loaded.contains(key)) await validateEntry(key);
    // Once prepared, subsequent fills must not wait behind pending disk writes.
    final existing = _entries[key];
    if (!reset &&
        generation == _generation &&
        existing != null &&
        audioLength(existing) == total &&
        existing['version'] == version) {
      return Future.value();
    }
    return _mutate(() async {
      if (!_available ||
          !_diskHealthy ||
          _closed ||
          generation != _generation) {
        return;
      }
      final old = _entries[key];
      if (reset ||
          (old != null &&
              (audioLength(old) != total || old['version'] != version))) {
        _audioRevisions.update(key, (v) => v + 1, ifAbsent: () => 1);
        if (old != null) _retired[file(key).path] = key;
        _dropEntry(key, persist: false);
      }
      if (!_entries.containsKey(key)) {
        final allocation = await _allocate(key, 'audio');
        _putEntry(key, {
          ...allocation,
          ...metadata,
          'kind': 'audio',
          'size': 0,
          'total': total,
          'version': version,
          'ranges': <List<int>>[],
          'access': DateTime.now().millisecondsSinceEpoch,
        }, persist: false);
        _markDocument(key);
      }
    }, persist: false);
  }

  // Best effort: bound retained bytes across all downloads, including the active
  // write. Dropped chunks remain holes in the durable range index.
  void _queueAudioRange(
    String key,
    int offset,
    List<int> bytes,
    int generation,
    int revision, {
    bool allowEviction = true,
  }) {
    if (!_acceptAudioWrites ||
        _closed ||
        !_available ||
        generation != _generation ||
        revision != audioRevision(key) ||
        _pendingAudioBytes + bytes.length >
            maxPendingAudioBytes - _inputMailboxReservation) {
      return;
    }
    final owned = Uint8List.fromList(bytes);
    _pendingAudioBytes += owned.length;
    // The HTTP reader may finish before these writes. Keep the entry protected
    // until its queued bytes have been handled, including capacity checks.
    pin(key);
    unawaited(
      writeAudioRange(
        key,
        offset,
        owned,
        generation,
        revision,
        allowEviction: allowEviction,
      ).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _pendingAudioBytes -= owned.length;
        unpin(key);
      }),
    );
  }

  /// Wait for queued writes and persist only successfully written ranges.
  Future<void> flushAudioWrites() async {
    await Future.wait(_audioTails.values.toList());
    if (!_diskHealthy) {
      for (var n = 0; ; n++) {
        final probe = File('${directory.path}/.write-probe-$n');
        if (await FileSystemEntity.type(probe.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        await probe.create(exclusive: true);
        try {
          await probe.writeAsBytes([0], flush: true);
          _diskHealthy = true;
        } finally {
          await probe.delete();
        }
        break;
      }
    }
    await _mutate(() async {});
  }

  Future<bool> writeAudioRange(
    String key,
    int offset,
    List<int> bytes,
    int generation,
    int revision, {
    bool allowEviction = true,
  }) async {
    final reservation = ++_nextReservation;
    bool saved = false;
    bool wroteBytes = false;
    try {
      await _enqueueAudio(key, () async {
        final entry = _entries[key];
        if (!_available ||
            _closed ||
            !_databaseHealthy ||
            !_diskHealthy ||
            generation != _generation ||
            revision != audioRevision(key) ||
            entry == null ||
            entry['state'] == 'deleting') {
          return;
        }
        final end = offset + bytes.length;
        if (offset < 0 || bytes.isEmpty || end > audioLength(entry)) {
          return;
        }
        // Writes are serialized per entry. Earlier overlapping fills may have
        // completed while this chunk was queued; only persist remaining holes
        // in the same representation, without rewriting cached audio/indexes.
        final existingRanges = audioRanges(entry);
        final missing = <List<int>>[];
        var position = offset;
        for (final range in existingRanges) {
          if (range[1] <= position) continue;
          if (range[0] >= end) break;
          if (range[0] > position) missing.add([position, range[0]]);
          position = max(position, range[1]);
          if (position >= end) break;
        }
        if (position < end) missing.add([position, end]);
        if (missing.isEmpty) {
          saved = true;
          return;
        }
        final merged = <List<int>>[];
        final ranges = [
          ...existingRanges,
          [offset, end],
        ]..sort((a, b) => a[0].compareTo(b[0]));
        for (final r in ranges) {
          if (merged.isNotEmpty && r[0] <= merged.last[1]) {
            merged.last[1] = max(merged.last[1], r[1]);
          } else {
            merged.add(List.of(r));
          }
        }
        final size = merged.fold<int>(0, (n, r) => n + r[1] - r[0]);
        final additional = size - (entry['size'] as int);
        _rangeReservations[reservation] = additional;
        _reservedRangeBytes += additional;
        if (allowEviction && usedBytes + _reservedRangeBytes > limitGb * gb) {
          await _mutate(
            () => _trim(reserved: _reservedRangeBytes),
            persist: false,
          );
        }
        if (usedBytes + _reservedRangeBytes > limitGb * gb) {
          return;
        }
        await beforeAudioWrite?.call();
        if (generation != _generation ||
            revision != audioRevision(key) ||
            entry['state'] == 'deleting' ||
            !await _regular(entry['fileName'] as String)) {
          return;
        }
        final handle = await file(key).open(mode: FileMode.append);
        try {
          for (final range in missing) {
            await handle.setPosition(range[0]);
            await handle.writeFrom(bytes, range[0] - offset, range[1] - offset);
          }
        } finally {
          await handle.close();
        }
        if (generation != _generation ||
            revision != audioRevision(key) ||
            entry['state'] == 'deleting') {
          return;
        }
        entry['ranges'] = merged;
        entry['size'] = size;
        _usedBytes += additional;
        final access = DateTime.now().millisecondsSinceEpoch;
        if (entry['access'] != access) {
          entry['access'] = access;
          _markAccess(key, access);
        }
        _dirtyAudio.add(key);
        _audioChanges[key] = ++_changeSequence;
        _markDocument(key);
        saved = true;
        wroteBytes = true;
      });
      if (wroteBytes) {
        if (completeAudio(_entries[key]!)) {
          unawaited(
            flushAudioWrites().then(
              (_) => _notify(immediate: true),
              onError: (Object _) {},
            ),
          );
        } else {
          _scheduleRangeFlush();
        }
      }
    } catch (_) {
      _diskHealthy = false;
      _scheduleRangeFlush();
      /* The range downloader also keeps a bounded fallback buffer. */
    }
    _reservedRangeBytes -= _rangeReservations.remove(reservation) ?? 0;
    return saved;
  }

  Stream<List<int>> recordAudioRange(
    String key,
    Stream<List<int>> input,
    int offset,
    int total,
    String? version,
    Map<String, dynamic> metadata,
    int generation, {
    bool reset = false,
  }) async* {
    try {
      await prepareAudio(
        key,
        total,
        version,
        metadata,
        generation,
        reset: reset,
      );
    } catch (_) {}
    final revision = audioRevision(key);
    int position = offset;
    try {
      await for (final bytes in input) {
        _queueAudioRange(key, position, bytes, generation, revision);
        position += bytes.length;
        yield bytes;
      }
    } finally {
      _scheduleRangeFlush();
    }
  }

  /// Atomic standalone document; the streaming audio path uses bounded range writes.
  Stream<List<int>> record(
    String key,
    Stream<List<int>> input,
    Map<String, dynamic> metadata, {
    int? expectedLength,
    int? expectedGeneration,
    bool Function()? commitAllowed,
  }) async* {
    if (!_available || !_writing.add(key)) {
      yield* input;
      return;
    }
    final generation = _generation;
    final bytes = BytesBuilder(copy: false);
    bool retain = true;
    try {
      await for (final chunk in input) {
        if (bytes.length + chunk.length > maxPendingAudioBytes) retain = false;
        if (retain) bytes.add(chunk);
        yield chunk;
      }
      if (commitAllowed?.call() == false ||
          !retain ||
          bytes.length == 0 ||
          (expectedLength != null && bytes.length != expectedLength) ||
          generation != _generation ||
          (expectedGeneration != null && expectedGeneration != _generation)) {
        return;
      }
      if (metadata['kind'] == 'audio') {
        await prepareAudio(
          key,
          bytes.length,
          metadata['version'] as String?,
          metadata,
          generation,
          reset: true,
        );
        await writeAudioRange(
          key,
          0,
          bytes.takeBytes(),
          generation,
          audioRevision(key),
        );
        await flushAudioWrites();
        return;
      }
      await _mutate(() async {
        if (commitAllowed?.call() == false ||
            generation != _generation ||
            (expectedGeneration != null && expectedGeneration != _generation)) {
          return;
        }
        if (!_loaded.contains(key)) await validateEntry(key);
        if (_entries[key]?['state'] == 'deleting') return;
        final allocation = _entries[key] ?? await _allocate(key, 'lyrics');
        final fetched = DateTime.now().millisecondsSinceEpoch;
        final document =
            {
                ...allocation,
                ...metadata,
                'schemaVersion': 2,
                'songIdentity': (allocation['identity'] as List)
                    .take(2)
                    .toList(),
                'formatVersion': 1,
                'revision': (allocation['revision'] as int) + 1,
                'fetchedAt': fetched,
                'timeline': jsonDecode(utf8.decode(bytes.takeBytes())),
              }
              ..remove('size')
              ..remove('access');
        final target = File('${directory.path}/${allocation['fileName']}');
        if (await target.exists() &&
            !await _regular(allocation['fileName'] as String)) {
          throw StateError('cache.unsafeLyrics');
        }
        final tmp = await _temporaryFile(
          key,
          allocation['fileName'] as String,
          false,
        );
        await tmp.writeAsString(jsonEncode(document), flush: true);
        if (commitAllowed?.call() == false || generation != _generation) {
          await tmp.delete();
          return;
        }
        await tmp.rename(target.path);
        _lyricDocuments[target.uri.pathSegments.last] = document;
        _putEntry(key, {
          ...document,
          'size': await target.length(),
          'access': fetched,
        });
        await _trim();
      });
    } finally {
      _writing.remove(key);
      _boundDocuments();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _acceptAudioWrites = false;
    _forceAccessFlush = true;
    await flushAudioWrites().catchError((Object _) {});
    _closed = true;
    _generation++;
    _timer?.cancel();
    _accessTimer?.cancel();
    _notification?.cancel();
    _rangeFlush?.cancel();
    await _ready;
    await _recovery;
    if (_available) {
      try {
        await _mutate(() async {});
      } catch (_) {}
    }
    await _tail;
    await _store?.close();
    await _lock?.unlock();
    await _lock?.close();
    if (_directoryIdentity != null) _openDirectories.remove(_directoryIdentity);
    dispose();
  }
}

/// Host-owned compressed input; FFmpeg sees only an opaque player-scoped ID.
final class CachedAudioResolver
    implements PlaybackSourceResolver, AudioInputWorkerProvider {
  CachedAudioResolver({
    required this.upstream,
    required this.cache,
    required this.account,
    required this.epoch,
    this.permissionEpoch,
    this.permissionExpires,
    this.permissionRefresh,
    this.onOfflineGap,
    this.now = DateTime.now,
    this.inputTrustedCertificates,
  }) : _client =
           HttpClient(
               context: inputTrustedCertificates == null
                   ? null
                   : (SecurityContext(withTrustedRoots: true)
                       ..setTrustedCertificatesBytes(inputTrustedCertificates)),
             )
             ..connectionTimeout = const Duration(seconds: 15)
             ..autoUncompress = false;
  final DateTime Function() now;

  /// Explicit test CA support for the independent input isolate. Production
  /// leaves this null and always uses the system trust store.
  final List<int>? inputTrustedCertificates;
  final PlaybackSourceResolver upstream;
  final PlaybackCache cache;
  final String Function() account;
  final int Function() epoch;
  final int Function()? permissionEpoch;
  final DateTime? Function(Set<String>)? permissionExpires;
  final Future<void> Function()? permissionRefresh;
  final Future<void> Function(TrackId)? onOfflineGap;
  AudioInputTransport? _inputTransport;
  final Map<String, List<dynamic>> _permits = {};
  final Set<_CachedInputReader> _inputReaders = {};
  final Set<Future<void> Function()> _workerClosers = {};
  final Map<Object, (String key, int position, bool busy)> _workerPlayback = {};

  @override
  Future<AudioInputWorkerSource> prepareAudioInputWorker(int sourceId) =>
      _prepareCachedAudioWorker(this, sourceId);
  @override
  void bindAudioInputTransport(AudioInputTransport transport) {
    if (identical(transport, _inputTransport)) return;
    if (_inputTransport != null) {
      throw StateError('audio.transportAlreadyBound');
    }
    _inputTransport = transport;
    if (transport is AudioInputWorkerTransport) {
      // Reserve worker messages inside the existing persistence budget. Split
      // the live range budget between precaching and the two native readers.
      cache._inputMailboxReservation = _inputWorkerMailboxBytes;
      _rangeMemoryLimit = 1024 * 1024;
    }
    for (final token in _sources.keys) {
      transport.registerAudioInput(int.parse(token));
    }
  }

  void _removeSource(String token) {
    _inputTransport?.revokeAudioInput(int.parse(token));
    _sources.remove(token);
    _permits.remove(token);
    for (final reader in _inputReaders.toList()) {
      if (reader.token == token) unawaited(reader.close());
    }
  }

  bool _validInput(String token) {
    final source = _sources[token];
    final data = _permits[token];
    if (_closing ||
        source == null ||
        data == null ||
        data[0] != account() ||
        data[1] != epoch() ||
        _permissionGenerations[token] != (permissionEpoch?.call() ?? 0) ||
        !now().isBefore(source.expiresAt)) {
      return false;
    }
    final expiry = permissionExpires?.call(source.requiredEntitlements);
    return expiry == null || now().isBefore(expiry);
  }

  @override
  Future<AudioInputReader> openAudioInput(int sourceId) async {
    final token = sourceId.toString();
    if (!_validInput(token)) throw StateError('playback.cancelled');
    final reader = _CachedInputReader(this, token);
    _inputReaders.add(reader);
    return reader;
  }

  // Raw upstream sources survive temporary precache permits. Each playback
  // still receives its own input token and passes the local rights checks.
  static const _sourceReuseWindow = Duration(minutes: 30);
  final _reusableSources =
      <
        (String, int, int, TrackId, AudioQuality),
        ({ResolvedMediaSource source, DateTime until})
      >{};

  final Set<String> _offlineTokens = {};
  final Map<String, int> _permissionGenerations = {};
  final HttpClient _client;
  final Map<String, ResolvedMediaSource> _sources = {};
  final Set<HttpClientRequest> _requests = {};
  final Map<String, _AudioRangeSession> _rangeSessions = {};
  _AudioSlots _audioSlots = _AudioSlots();
  final Set<Future<void>> _rangeTasks = {};
  final Set<String> _noRangeTokens = {};
  final Set<_RangeReader> _backgroundReaders = {};
  final Map<_RangeReader, (String, int, int)> _backgroundWindows = {};
  int _backgroundEpoch = 0;
  int get backgroundEpoch => _backgroundEpoch;
  int _foregroundSeekEpoch = 0;
  int get foregroundSeekEpoch => _foregroundSeekEpoch;
  int foregroundRequests = 0;
  int _liveAudioBytes = 0;
  int _rangeMemoryLimit = 2 * 1024 * 1024;

  /// Aggregate upstream response wait and slot wait, without URLs or credentials.
  int rangeFirstByteMicros = 0;
  int rangeSlotWaitMicros = 0;
  int rangeRequestCount = 0;
  void Function()? onAudioActivity;
  bool _closing = false;
  bool get foregroundBusy =>
      foregroundRequests > 0 ||
      _workerPlayback.values.any((reader) => reader.$3) ||
      _inputReaders.any(
        (reader) =>
            reader.valid &&
            reader._sequentialSlot &&
            (reader.totalBytes == null ||
                reader._position < reader.totalBytes!),
      ) ||
      _rangeSessions.values.any(
        (s) => s.fills.any(
          (f) =>
              !f.done &&
              !f.aborted &&
              f.users > 0 &&
              !_backgroundReaders.any((r) => r.fills.contains(f)),
        ),
      );

  void cancelPrecache() {
    _backgroundEpoch++;
    for (final reader in _backgroundReaders.toList()) {
      reader.close();
    }
  }

  /// Whether the running download still covers the first hole after playback.
  Future<bool> precacheMatchesPlayback(
    TrackId track,
    AudioQuality quality,
    double? fraction,
  ) async {
    final key = cache.key(account(), track.value, quality.name);
    final epoch = _backgroundEpoch;
    var offset = fraction == null
        ? null
        : await cache.cachedPlaybackByteOffset(track, quality, fraction);
    if (offset == null) {
      for (final input in _inputReaders) {
        if (input.valid && input.key == key) offset = input._position;
      }
      for (final input in _workerPlayback.values) {
        if (input.$1 == key) offset = input.$2;
      }
    }
    if (offset == null || epoch != _backgroundEpoch) return false;
    final entry = cache.lookup(key);
    if (entry == null) return false;
    for (final range in PlaybackCache.audioRanges(entry)) {
      if (range[1] <= offset!) continue;
      if (range[0] > offset) break;
      offset = range[1];
    }
    if (offset! >= PlaybackCache.audioLength(entry)) return false;
    return _backgroundReaders.any((reader) {
      if (!reader.active) return false;
      final window = _backgroundWindows[reader];
      // Retain the task while a completed chunk is being flushed, too.
      if (window != null &&
          window.$1 == key &&
          window.$2 <= offset! &&
          offset <= window.$3) {
        return true;
      }
      return reader.fills.any(
        (fill) =>
            fill.session.key == key &&
            !fill.done &&
            !fill.aborted &&
            fill.start <= offset! &&
            offset < fill.end,
      );
    });
  }

  /// Downloads authorized bytes through the same versioned range transport.
  /// With [prioritizePlayback], fill after the active decoder's read position
  /// first, without returning to earlier holes. Network reads and seek
  /// interrupt this work when they need another fill; cached seeks and readers
  /// joining the same pending fill can run concurrently.
  /// Returns false if interrupted or if the cache budget is exhausted.
  Future<bool> precache(
    TrackId id,
    AudioQuality quality, {
    required bool Function() valid,
    bool prioritizePlayback = false,
    double? playbackFraction,
  }) async {
    final backgroundEpoch = _backgroundEpoch;
    final owner = account();
    final authEpoch = epoch();
    final rightsEpoch = permissionEpoch?.call() ?? 0;
    final cacheEpoch = cache.generation;
    bool active() =>
        !_closing &&
        valid() &&
        backgroundEpoch == _backgroundEpoch &&
        owner == account() &&
        authEpoch == epoch() &&
        rightsEpoch == (permissionEpoch?.call() ?? 0) &&
        cacheEpoch == cache.generation;
    if (!active()) return false;
    final resolved = await _resolve(
      id,
      quality,
      NetworkPolicy.preferCache,
      background: true,
    );
    final token = resolved.uri.scheme == 'ffinput' ? resolved.uri.host : null;
    try {
      if (!active()) return false;
      if (resolved.uri.scheme == 'file') return true;
      if (resolved.actualQuality == null) return true;
      final data = _permits[token!]!;
      final key = cache.key(owner, id.value, resolved.actualQuality!.name);
      bool permitted() {
        final source = _sources[token];
        final expiry = permissionExpires?.call(resolved.requiredEntitlements);
        return source != null &&
            DateTime.now().isBefore(source.expiresAt) &&
            (expiry == null || DateTime.now().isBefore(expiry)) &&
            owner == account() &&
            authEpoch == epoch() &&
            rightsEpoch == (permissionEpoch?.call() ?? 0);
      }

      final session = _rangeSession(token, data, key, permitted, cacheEpoch);
      final reader = _RangeReader(
        () => active() && permitted(),
        background: true,
      );
      _backgroundReaders.add(reader);
      cache.pin(key);
      try {
        final existing = cache.lookup(key);
        final same =
            existing != null && existing['version'] == _sourceVersion(resolved);
        final present = same ? existing['size'] as int : 0;
        final estimate = resolved.fullContent == true
            ? resolved.totalBytes ?? _audioRangeBytes
            : resolved.allowedByteRanges.fold<int>(
                0,
                (n, r) => n + r.end - r.start,
              );
        if (cache.usedBytes + max(0, estimate - present) >
            cache.limitGb * PlaybackCache.gb) {
          return false;
        }
        // Preview initialization must start inside the authorized range.
        if (resolved.fullContent != true &&
            resolved.allowedByteRanges.first.start > 0) {
          final range = resolved.allowedByteRanges.first;
          final fill = session.ensureFill(
            range.start,
            min(range.end, range.start + _audioRangeBytes),
            reader,
          );
          await fill.ready.future;
          if (fill.error != null) throw fill.error!;
          session.initialized = true;
        } else {
          await session.initialize(reader);
        }
        if (!reader.active || session.total == null) return false;
        final permittedRanges = resolved.fullContent == true
            ? [MediaByteRange(0, session.total!)]
            : resolved.allowedByteRanges;
        var pivot = 0;
        if (prioritizePlayback) {
          // This is the decoder's next compressed byte, including read-ahead.
          // Do not estimate byte positions from media time for variable bitrate.
          for (final input in _inputReaders) {
            if (input.valid &&
                input.key == key &&
                _sourceVersion(_sources[input.token]!) ==
                    _sourceVersion(resolved)) {
              pivot = input._position;
            }
          }
          if (playbackFraction != null) {
            // Native AVIO may satisfy a seek from retained compressed blocks
            // without calling Dart. Its previous reader offset is then stale.
            pivot =
                await cache.cachedPlaybackByteOffset(
                  id,
                  resolved.actualQuality!,
                  playbackFraction,
                ) ??
                pivot;
          }
        }
        final ranges = [
          for (final range in permittedRanges)
            if (range.end > pivot)
              MediaByteRange(max(range.start, pivot), range.end),
          for (final range in permittedRanges)
            if (!prioritizePlayback && range.start < pivot)
              MediaByteRange(range.start, min(range.end, pivot)),
        ];
        for (final range in ranges) {
          for (
            var start = range.start;
            start < range.end;
            start += _audioRangeBytes
          ) {
            if (!reader.active) return false;
            final end = min(range.end, start + _audioRangeBytes);
            _backgroundWindows[reader] = (key, start, end);
            final entry = cache.lookup(key);
            final cached = entry == null
                ? 0
                : PlaybackCache.audioRanges(entry).fold<int>(
                    0,
                    (n, r) => n + max(0, min(end, r[1]) - max(start, r[0])),
                  );
            if (session.cacheReadable &&
                session.validated &&
                cached == end - start) {
              continue;
            }
            if (cache.usedBytes +
                    cache._reservedRangeBytes +
                    end -
                    start -
                    cached >
                cache.limitGb * PlaybackCache.gb) {
              return false;
            }
            await for (final _ in session.read(start, end, reader)) {
              if (!reader.active) return false;
            }
            await cache.flushAudioWrites();
            if (!reader.active || !session.cacheReadable) return false;
            final saved = cache.lookup(key);
            if (saved == null ||
                !PlaybackCache.audioRanges(
                  saved,
                ).any((r) => r[0] <= start && r[1] >= end)) {
              return false;
            }
          }
        }
        return reader.active;
      } catch (_) {
        if (!reader.active) return false;
        rethrow;
      } finally {
        reader.close();
        _backgroundReaders.remove(reader);
        _backgroundWindows.remove(reader);
        session.prune();
        cache.unpin(key);
      }
    } finally {
      // Background URLs are never handed to the player. Release their permits
      // on every exit, including cancellation and unknown-quality sources.
      if (token != null) {
        _removeSource(token);
        _permissionGenerations.remove(token);
        _offlineTokens.remove(token);
        _noRangeTokens.remove(token);
      }
    }
  }

  Future<void>? _ready;
  Future<void> initialize() => _ready ??= _initialize();
  Future<void> _initialize() async {
    await cache.initialize();
  }

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) => _resolve(id, preferredQuality, networkPolicy);

  Future<ResolvedMediaSource> _resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy, {
    bool background = false,
  }) async {
    await initialize();
    unawaited(cache.flushAudioWrites().catchError((Object _) {}));
    final owner = account();
    final generation = epoch();
    final permissions = permissionEpoch?.call() ?? 0;
    final reuseKey = (owner, generation, permissions, id, preferredQuality);
    final time = now();
    _reusableSources.removeWhere(
      (key, entry) =>
          key.$1 != owner ||
          key.$2 != generation ||
          key.$3 != permissions ||
          !time.isBefore(entry.until),
    );
    // onlineOnly is also the broker's recovery path after a failed source.
    // Drop every quality for this track so a later cache read cannot revive it.
    if (networkPolicy == NetworkPolicy.onlineOnly) {
      _reusableSources.removeWhere((key, _) => key.$4 == id);
    }
    var reusable = _reusableSources[reuseKey];
    ResolvedMediaSource? localSource;
    if (reusable != null) {
      final previous = reusable.source;
      final actual = previous.actualQuality;
      if (previous.fullContent == true && actual != null) {
        final key = cache.key(owner, id.value, actual.name);
        await cache.validateEntry(key);
        final hit = cache.lookup(key);
        if (hit != null &&
            PlaybackCache.completeAudio(hit) &&
            hit['version'] == _sourceVersion(previous)) {
          // The reuse window limits admission of new inputs, not playback of
          // an already admitted local file. It has no expiring CDN address;
          // account epochs, revocation and entitlement expiry still gate reads.
          // Missing bytes cannot fall through to the CDN.
          localSource = ResolvedMediaSource(
            trackId: id,
            uri: cache.file(key).uri,
            actualQuality: actual,
            expiresAt: DateTime.utc(9999),
            resourceId: previous.resourceId,
            access: previous.access,
            resourceFree: previous.resourceFree,
            fullContent: true,
            totalBytes: PlaybackCache.audioLength(hit),
            requiredEntitlements: previous.requiredEntitlements,
            normalizationGainDb: previous.normalizationGainDb,
            normalizationPeak: previous.normalizationPeak,
            codec: previous.codec,
            bitrateKbps: previous.bitrateKbps,
            sampleRateHz: previous.sampleRateHz,
          );
        }
      }
      if (localSource == null &&
          !time.add(const Duration(seconds: 30)).isBefore(previous.expiresAt)) {
        _reusableSources.removeWhere((key, _) => key == reuseKey);
        reusable = null;
      }
    }
    bool offline = localSource != null;
    ResolvedMediaSource source;
    try {
      source =
          localSource ??
          reusable?.source ??
          await upstream.resolve(
            id,
            preferredQuality,
            NetworkPolicy.onlineOnly,
          );
      if (source.uri.scheme == 'file' && localSource == null) return source;
      if (source.fullContent != true &&
          (source.totalBytes == null ||
              source.allowedByteRanges.isEmpty ||
              source.allowedByteRanges.any(
                (r) =>
                    r.start < 0 ||
                    r.end <= r.start ||
                    r.end > source.totalBytes!,
              ))) {
        throw StateError('playback.previewRangeUnknown');
      }
    } catch (error) {
      final networkFailure =
          error is SocketException ||
          error is TimeoutException ||
          (error is AppError && error.category == AppErrorCategory.network);
      final key = cache.key(owner, id.value, preferredQuality.name);
      await cache.validateEntry(key);
      if (networkPolicy != NetworkPolicy.preferCache || !networkFailure) {
        if (!networkFailure) {
          if (account() != owner ||
              epoch() != generation ||
              (permissionEpoch?.call() ?? 0) != permissions) {
            rethrow;
          }
          for (final candidate in cache._qualifications.values.toList()) {
            if (candidate['account'] != owner) continue;
            final resource = candidate['resourceKey'] as String;
            final identity = jsonDecode(resource) as List;
            if (identity[0] == cache.provider && identity[1] == id.value) {
              cache._dropQualification(resource, account: owner);
            }
          }
          await cache._mutate(() async {}).catchError((Object _) {});
        }
        rethrow;
      }
      final hit = cache.lookup(key);
      final eligibility =
          cache._qualifications[cache._qualificationKey(owner, key)];
      if (hit == null ||
          eligibility == null ||
          eligibility['account'] != owner ||
          eligibility['access'] != 'nonVip' ||
          eligibility['resourceFree'] != true ||
          eligibility['fullContent'] != true ||
          eligibility['version'] == null ||
          eligibility['version'] != hit['version']) {
        rethrow;
      }
      offline = true;
      source = ResolvedMediaSource(
        trackId: id,
        uri: cache.file(key).uri,
        access: SongAccess.nonVip,
        resourceFree: true,
        fullContent: true,
        totalBytes: PlaybackCache.audioLength(hit),
        actualQuality: preferredQuality,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        resourceId: hit['resourceId'] as String?,
        normalizationGainDb:
            eligibility['normalizationFormula'] == 'gain-minus-closedGain-v1'
            ? _normalizationNumber(eligibility['normalizationGainDb'])
            : null,
        normalizationPeak:
            eligibility['normalizationFormula'] == 'gain-minus-closedGain-v1'
            ? _normalizationNumber(
                eligibility['normalizationPeak'],
                positive: true,
              )
            : null,
        codec: hit['codec'] as String?,
        bitrateKbps: hit['bitrate'] as int?,
        sampleRateHz: hit['sampleRate'] as int?,
      );
    }
    if (account() != owner ||
        epoch() != generation ||
        (permissionEpoch?.call() ?? 0) != permissions) {
      throw StateError('playback.cancelled');
    }
    final actual = source.actualQuality;
    // Unknown quality can play but must never masquerade as the requested tier.
    final random = Random.secure();
    String token;
    do {
      token = ((random.nextInt(1 << 26) << 26) | random.nextInt(1 << 26))
          .toString();
    } while (token == '0' || _sources.containsKey(token));
    final permit = <dynamic>[
      owner,
      generation,
      id.value,
      actual?.name ?? 'unknown',
      preferredQuality.name,
      networkPolicy == NetworkPolicy.onlineOnly,
    ];
    // A speculative permit must not evict a URL still held by the player.
    // precache releases its temporary permit when the operation ends.
    if (!background && _sources.length >= 512) {
      final oldest = _sources.keys.first;
      _removeSource(oldest);
      _permissionGenerations.remove(oldest);
      _offlineTokens.remove(oldest);
    }
    if (source.requiredEntitlements.isNotEmpty) await permissionRefresh?.call();
    if (account() != owner ||
        epoch() != generation ||
        (permissionEpoch?.call() ?? 0) != permissions) {
      throw StateError('playback.cancelled');
    }
    final expires = permissionExpires?.call(source.requiredEntitlements);
    if (expires != null && !DateTime.now().isBefore(expires)) {
      throw StateError('playback.vipExpired');
    }
    if (!offline && reusable == null && now().isBefore(source.expiresAt)) {
      if (_reusableSources.length >= 64) {
        final oldest = _reusableSources.keys.first;
        _reusableSources.removeWhere((key, _) => key == oldest);
      }
      _reusableSources[reuseKey] = (
        source: source,
        until: now().add(_sourceReuseWindow),
      );
    }
    final reuseUntil = _reusableSources[reuseKey]?.until;
    _sources[token] = source;
    _permits[token] = permit;
    _permissionGenerations[token] = permissions;
    if (offline) _offlineTokens.add(token);
    _inputTransport?.registerAudioInput(int.parse(token));
    if (!offline && actual != null) {
      final key = cache.key(owner, id.value, actual.name);
      await cache.validateEntry(key);
      if (source.access != SongAccess.nonVip) {
        for (final candidate in cache._qualifications.values.toList()) {
          if (candidate['account'] != owner) continue;
          final resource = candidate['resourceKey'] as String;
          final identity = jsonDecode(resource) as List;
          if (identity[0] == cache.provider && identity[1] == id.value) {
            cache._dropQualification(resource, account: owner);
          }
        }
      }
      cache._putQualification(key, {
        'account': owner,
        'generation': cache.lookup(key)?['generation'],
        'access': source.access.name,
        'resourceFree': source.resourceFree,
        'fullContent': source.fullContent,
        'normalizationFormula': 'gain-minus-closedGain-v1',
        'normalizationGainDb': source.normalizationGainDb,
        'normalizationPeak': source.normalizationPeak,
        'version': _sourceVersion(source),
        'verifiedAt': DateTime.now().millisecondsSinceEpoch,
        'source': 'provider',
      });
      // Disk/SQLite persistence is optional for an already authorized source.
      await cache._mutate(() async {}).catchError((Object _) {});
    }
    // The broker and native queue use this deadline only when starting a
    // song. Keep the reader's source lifetime separate so an admitted local
    // input can finish playing after the authorization reuse window closes.
    var admissionExpiresAt = source.expiresAt;
    if (reuseUntil != null && reuseUntil.isBefore(admissionExpiresAt)) {
      admissionExpiresAt = reuseUntil;
    }
    if (expires != null && expires.isBefore(admissionExpiresAt)) {
      admissionExpiresAt = expires;
    }
    if (_inputTransport case final AudioInputWorkerTransport worker) {
      await worker.audioInputReady;
      if (!_validInput(token)) throw StateError('playback.cancelled');
    }
    return ResolvedMediaSource(
      trackId: id,
      uri: Uri.parse('ffinput://$token'),
      access: source.access,
      resourceFree: source.resourceFree,
      fullContent: source.fullContent,
      allowedByteRanges: source.allowedByteRanges,
      totalBytes: source.totalBytes,
      requiredEntitlements: source.requiredEntitlements,
      actualQuality: actual,
      expiresAt: admissionExpiresAt,
      codec: source.codec,
      bitrateKbps: source.bitrateKbps,
      sampleRateHz: source.sampleRateHz,
      resourceId: source.resourceId,
      normalizationGainDb: source.normalizationGainDb,
      normalizationPeak: source.normalizationPeak,
      headers: const {},
    );
  }

  Stream<List<int>> _sequentialInterval(
    Stream<List<int>> input,
    int start,
    int end, {
    bool allowEof = false,
  }) async* {
    var position = 0;
    await for (final chunk in input) {
      final next = position + chunk.length;
      if (next > start) {
        yield chunk.sublist(
          max(0, start - position),
          min(chunk.length, end - position),
        );
      }
      position = next;
      if (position >= end) return;
    }
    if (!allowEof) throw StateError('audio.shortRead');
  }

  void revokeTrack(TrackId id) {
    _reusableSources.removeWhere((key, _) => key.$4 == id);
    for (final token in _sources.keys.toList()) {
      if (_sources[token]!.trackId == id) {
        _removeSource(token);
        _permissionGenerations.remove(token);
        _offlineTokens.remove(token);
      }
    }
    for (final session in _rangeSessions.values) {
      if (!session.valid()) session.abort();
    }
  }

  bool requiresRights(TrackId? id, Set<String> rights) =>
      id != null &&
      _sources.values.any(
        (s) =>
            s.trackId == id &&
            s.requiredEntitlements.intersection(rights).isNotEmpty,
      );
  void revokeRights(Set<String> rights) {
    _reusableSources.removeWhere(
      (_, entry) =>
          entry.source.requiredEntitlements.intersection(rights).isNotEmpty,
    );
    for (final token in _sources.keys.toList()) {
      if (_sources[token]!.requiredEntitlements
          .intersection(rights)
          .isNotEmpty) {
        _removeSource(token);
        _permissionGenerations.remove(token);
      } else {
        _permissionGenerations[token] = permissionEpoch?.call() ?? 0;
      }
    }
    for (final session in _rangeSessions.values) {
      if (!session.valid()) session.abort();
    }
  }

  void revokePermissions() {
    _reusableSources.clear();
    cancelPrecache();
    for (final token in _sources.keys.toList()) {
      _removeSource(token);
    }
    _permissionGenerations.clear();
    _offlineTokens.clear();
    for (final request in _requests.toList()) {
      request.abort();
    }
    for (final session in _rangeSessions.values) {
      session.abort();
    }
  }

  Future<void> close() async {
    _closing = true;
    revokePermissions();
    cancelPrecache();
    for (final request in _requests.toList()) {
      request.abort();
    }
    for (final session in _rangeSessions.values) {
      session.abort();
    }
    _client.close(force: true);
    for (final reader in _inputReaders.toList()) {
      await reader.close();
    }
    for (final close in _workerClosers.toList()) {
      await close();
    }
    await Future.wait(_rangeTasks.toList());
    await cache.flushAudioWrites().catchError((Object _) {});
  }
}

final class CachedLyricsRepository implements LyricsRepository {
  CachedLyricsRepository({
    required this.upstream,
    required this.cache,
    required this.account,
    this.epoch,
  });
  final LyricsRepository upstream;
  final PlaybackCache cache;
  final String Function() account;
  final int Function()? epoch;
  final Map<String, Future<LyricTimeline>> _inflight = {};
  Map<String, int> get _sequences => cache._lyricsSequences;
  LinkedHashMap<
    String,
    ({int revision, int generation, LyricTimeline timeline})
  >
  get _timelines => cache._lyricsTimelines;
  String _requestKey(String key) =>
      jsonEncode([key, account(), epoch?.call() ?? 0, cache.generation]);

  @override
  Future<LyricTimeline> getLyrics(TrackId id) {
    final owner = account();
    final key = cache.key(owner, id.value, 'lyrics-v1');
    final requestKey = _requestKey(key);
    final requestedGeneration = cache.generation;
    final requestedEpoch = epoch?.call();
    return _inflight.putIfAbsent(
      requestKey,
      () => _read(id, owner, key, requestedGeneration, requestedEpoch)
          .whenComplete(() {
            _inflight.remove(requestKey);
          }),
    );
  }

  Future<LyricTimeline> _read(
    TrackId id,
    String owner,
    String key,
    int requestedGeneration,
    int? requestedEpoch,
  ) async {
    await cache.initialize();
    cache.pin(key);
    LyricTimeline? old;
    int? fetched;
    try {
      await cache.validateEntry(key);
      final hit = cache.lookup(key);
      if (hit != null) {
        final cached = _timelines.remove(key);
        old =
            cached?.revision == hit['revision'] &&
                cached?.generation == cache.generation
            ? cached!.timeline
            : null;
        if (old == null) {
          final document = await cache._readDocument(
            cache._documentPath(hit),
            false,
          );
          old = _decode(document['timeline'] as Map);
        }
        _timelines[key] = (
          revision: hit['revision'] as int,
          generation: cache.generation,
          timeline: old,
        );
        while (_timelines.length > PlaybackCache.documentMemoryLimit) {
          _timelines.remove(_timelines.keys.first);
        }
        fetched = (hit['fetchedAt'] ?? hit['fetched']) as int;
      } else {
        _timelines.remove(key);
      }
    } catch (_) {
      old = null;
      // Invalid documents are rebuildable; an upstream failure preserves valid old content.
    } finally {
      cache.unpin(key);
    }
    if (old != null) {
      if (DateTime.now().millisecondsSinceEpoch - fetched! >=
          const Duration(days: 7).inMilliseconds) {
        unawaited(_fetch(id, owner, key, requestedGeneration, requestedEpoch));
      }
      return old;
    }
    return _fetch(id, owner, key, requestedGeneration, requestedEpoch);
  }

  Future<LyricTimeline> _fetch(
    TrackId id,
    String owner,
    String key,
    int generation,
    int? accountEpoch,
  ) {
    bool currentAccount() =>
        owner == account() &&
        accountEpoch == epoch?.call() &&
        generation == cache.generation;
    if (!currentAccount()) {
      return Future.value(const LyricTimeline.unavailable());
    }
    final active = cache._lyricsFetching[key];
    if (active != null && active.valid()) return active.future;
    final sequence = ++cache._lyricsSequence;
    _sequences[key] = sequence;
    bool allowed() => currentAccount() && _sequences[key] == sequence;
    late final Future<LyricTimeline> result;
    result =
        (() async {
          try {
            final sheet = await upstream.getLyrics(id);
            if (allowed() && sheet.status != LyricsStatus.unavailable) {
              await cache
                  .record(
                    key,
                    Stream.value(utf8.encode(jsonEncode(_encode(sheet)))),
                    {'kind': 'lyrics'},
                    expectedGeneration: generation,
                    commitAllowed: allowed,
                  )
                  .drain<void>();
            }
            return sheet;
          } catch (_) {
            return const LyricTimeline.unavailable();
          } finally {
            if (_sequences[key] == sequence) _sequences.remove(key);
          }
        })().whenComplete(() {
          if (identical(cache._lyricsFetching[key]?.future, result)) {
            cache._lyricsFetching.remove(key);
          }
        });
    cache._lyricsFetching[key] = (future: result, valid: allowed);
    return result;
  }

  Map<String, dynamic> _encode(LyricTimeline t) => {
    'status': t.status.name,
    'offset': t.offset.inMicroseconds,
    'lines': [
      for (final l in t.lines)
        {
          'start': l.start.inMicroseconds,
          'end': l.end.inMicroseconds,
          'text': l.text,
          'translation': l.translation,
          'transliteration': l.transliteration,
          'words': [
            for (final w in l.words)
              {
                'start': w.start.inMicroseconds,
                'end': w.end.inMicroseconds,
                'text': w.text,
              },
          ],
        },
    ],
  };
  LyricTimeline _decode(Map t) => LyricTimeline(
    status: LyricsStatus.values.byName(t['status'] as String),
    offset: Duration(microseconds: t['offset'] as int),
    lines: [
      for (final l in t['lines'] as List)
        LyricLine(
          start: Duration(microseconds: l['start'] as int),
          end: Duration(microseconds: l['end'] as int),
          text: l['text'] as String,
          translation: l['translation'] as String?,
          transliteration: l['transliteration'] as String?,
          words: [
            for (final w in l['words'] as List)
              LyricWord(
                start: Duration(microseconds: w['start'] as int),
                end: Duration(microseconds: w['end'] as int),
                text: w['text'] as String,
              ),
          ],
        ),
    ],
  );
}

// Cache documents are rebuildable, so malformed optional gain must not block playback.
double? _normalizationNumber(Object? value, {bool positive = false}) {
  if (value is! num) return null;
  final number = value.toDouble();
  return number.isFinite && (!positive || number > 0) ? number : null;
}
