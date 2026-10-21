part of 'playback_cache.dart';

const _inputWorkerMailboxBytes = 1024 * 1024;

/// Snapshot only admitted metadata. The worker never opens the cache database
/// or writes files: the existing owner continues to serialize every mutation.
Future<AudioInputWorkerSource> _prepareCachedAudioWorker(
  CachedAudioResolver host,
  int id,
) async {
  final token = id.toString();
  if (!host._validInput(token)) throw StateError('playback.cancelled');
  final source = host._sources[token]!;
  final permit = host._permits[token]!;
  final generation = host.cache.generation;
  final key = host.cache.key(
    permit[0] as String,
    permit[2] as String,
    permit[3] as String,
  );
  await host.cache.validateEntry(key);
  if (!host._validInput(token) || generation != host.cache.generation) {
    throw StateError('playback.cancelled');
  }
  final snapshot = host.cache.lookup(key);
  final entry = snapshot == null ? null : Map<String, dynamic>.from(snapshot);
  final ownerRevision = host.cache.audioRevision(key);
  final expiry = host.permissionExpires?.call(source.requiredEntitlements);
  var publishedExpiry = expiry;
  host.cache.pin(key);
  final identity = Object();
  SendPort? control;
  var released = false;
  var expectedRevision = ownerRevision;
  var workerRevision = ownerRevision;
  var seekEpoch = 0;
  var requests = 0;
  var firstByteMicros = 0;
  var slotWaitMicros = 0;
  Future<void> tail = Future.value();
  bool valid() =>
      !released &&
      host._validInput(token) &&
      generation == host.cache.generation;
  void check() {
    if (!valid() || expectedRevision != host.cache.audioRevision(key)) {
      control?.send('revoke');
    } else {
      final currentExpiry = host.permissionExpires?.call(
        source.requiredEntitlements,
      );
      if (publishedExpiry != currentExpiry) {
        publishedExpiry = currentExpiry;
        control?.send(['expiry', currentExpiry]);
      }
    }
  }

  final watchdog = Timer.periodic(
    const Duration(milliseconds: 250),
    (_) => check(),
  );
  host.cache.addListener(check);
  Future<void>? closing;
  late Future<void> Function() close;
  close = () => closing ??= () async {
    released = true;
    control?.send('revoke');
    watchdog.cancel();
    host.cache.removeListener(check);
    host._workerPlayback.remove(identity);
    host._workerClosers.remove(close);
    await tail;
    host.cache.unpin(key);
    host.onAudioActivity?.call();
  }();
  host._workerClosers.add(close);
  return AudioInputWorkerSource(
    configuration: <String, Object?>{
      'source': source,
      'permit': List<dynamic>.from(permit),
      'token': token,
      'directory': host.cache.directory.path,
      'provider': host.cache.provider,
      'key': key,
      'entry': entry,
      'generation': generation,
      'revision': ownerRevision,
      'offline': host._offlineTokens.contains(token),
      'expiry': expiry,
      'available': host.cache._available,
      'userAgent': host._client.userAgent,
      'certificates': host.inputTrustedCertificates,
    },
    createReader: _createCachedAudioWorkerReader,
    onEvent: (event) {
      final data = event as List;
      if (data[0] == 'control') {
        control = data[1] as SendPort;
        check();
      } else if (data[0] == 'activity') {
        if (!valid()) return;
        host._workerPlayback[identity] = (key, data[1] as int, data[2] as bool);
        if (data[3] == true) host.cancelPrecache();
        host._foregroundSeekEpoch += (data[4] as int) - seekEpoch;
        host.rangeRequestCount += (data[5] as int) - requests;
        host.rangeFirstByteMicros += (data[6] as int) - firstByteMicros;
        host.rangeSlotWaitMicros += (data[7] as int) - slotWaitMicros;
        seekEpoch = data[4] as int;
        requests = data[5] as int;
        firstByteMicros = data[6] as int;
        slotWaitMicros = data[7] as int;
        host.onAudioActivity?.call();
      } else if (data[0] == 'offlineGap') {
        if (valid()) unawaited(host.onOfflineGap?.call(source.trackId));
      } else if (data[0] == 'readerClosed') {
        // Revocation also releases a paused reader's pin; it must not wait for
        // the native decoder to request another block or destroy its AVIO.
        unawaited(close());
      } else if (data[0] == 'prepare' || data[0] == 'chunk') {
        // Cache writes are optional and bounded by worker-side credits. Their
        // acknowledgement never gates the next decoder read.
        tail = tail.then((_) async {
          try {
            if (!valid() || expectedRevision != host.cache.audioRevision(key)) {
              return;
            }
            if (data[0] == 'prepare') {
              await host.cache.prepareAudio(
                key,
                data[1] as int,
                data[2] as String?,
                Map<String, dynamic>.from(data[3] as Map),
                generation,
                reset: data[4] as bool,
              );
              expectedRevision = host.cache.audioRevision(key);
              workerRevision = data[5] as int;
            } else if (workerRevision == data[3]) {
              final saved = await host.cache.writeAudioRange(
                key,
                data[1] as int,
                data[2] as Uint8List,
                generation,
                expectedRevision,
              );
              if (saved &&
                  valid() &&
                  expectedRevision == host.cache.audioRevision(key)) {
                final entry = host.cache.lookup(key);
                if (entry != null) {
                  control?.send([
                    'cache',
                    generation,
                    workerRevision,
                    Map<String, dynamic>.from(entry),
                  ]);
                }
              }
              host.cache._scheduleRangeFlush();
            }
          } catch (_) {
            // A disk failure must not interrupt authorized network playback.
          } finally {
            if (data[0] == 'chunk') {
              control?.send((data[2] as Uint8List).length);
            }
          }
        });
      }
    },
    onClose: close,
  );
}

AudioInputReader _createCachedAudioWorkerReader(
  Object? configuration,
  SendPort events,
) {
  final data = configuration as Map<String, Object?>;
  return _WorkerCachedReader(data, events);
}

final class _WorkerCachedReader implements AudioInputReader {
  static final _networkSlots = _AudioSlots();
  _WorkerCachedReader(Map<String, Object?> data, this.events) {
    cache = _WorkerAudioCache(data, events);
    final source = data['source'] as ResolvedMediaSource;
    final permit = data['permit'] as List;
    final token = data['token'] as String;
    host = CachedAudioResolver(
      upstream: _WorkerSource(source),
      cache: cache,
      account: () => permit[0] as String,
      epoch: () => permit[1] as int,
      permissionExpires: (_) => data['expiry'] as DateTime?,
      onOfflineGap: (_) async => events.send(['offlineGap']),
      inputTrustedCertificates: data['certificates'] as List<int>?,
    );
    host._client.userAgent = data['userAgent'] as String?;
    host._audioSlots = _networkSlots;
    host._rangeMemoryLimit = 512 * 1024;
    host._sources[token] = source;
    host._permits[token] = List<dynamic>.from(permit);
    host._permissionGenerations[token] = 0;
    if (data['offline'] == true) host._offlineTokens.add(token);
    reader = _CachedInputReader(host, token);
    host._inputReaders.add(reader);
    var seekEpoch = 0;
    var backgroundEpoch = 0;
    host.onAudioActivity = () {
      events.send([
        'activity',
        reader._position,
        host.foregroundBusy,
        seekEpoch != host._foregroundSeekEpoch ||
            backgroundEpoch != host._backgroundEpoch,
        host._foregroundSeekEpoch,
        host.rangeRequestCount,
        host.rangeFirstByteMicros,
        host.rangeSlotWaitMicros,
      ]);
      seekEpoch = host._foregroundSeekEpoch;
      backgroundEpoch = host._backgroundEpoch;
    };
    commands.listen((message) {
      if (message == 'revoke') unawaited(close());
      if (message is int) cache.acknowledge(message);
      if (message is List && message[0] == 'expiry') {
        data['expiry'] = message[1] as DateTime?;
      }
      if (message is List && message[0] == 'cache') {
        cache.acceptPersistedEntry(
          data['key'] as String,
          message[1] as int,
          message[2] as int,
          Map<String, dynamic>.from(message[3] as Map),
        );
      }
    });
    events.send(['control', commands.sendPort]);
  }
  final SendPort events;
  final commands = ReceivePort();
  late final CachedAudioResolver host;
  late final _WorkerAudioCache cache;
  late final _CachedInputReader reader;
  Future<void>? _closing;
  @override
  int? get totalBytes => reader.totalBytes;
  @override
  Future<int?> length() => reader.length();
  @override
  Future<int> read(int offset, Uint8List destination) =>
      reader.read(offset, destination);
  @override
  Future<void> close() => _closing ??= () async {
    await host.close();
    cache.closeMailbox();
    cache.dispose();
    commands.close();
    events.send(['readerClosed']);
  }();
}

final class _WorkerSource implements PlaybackSourceResolver {
  const _WorkerSource(this.source);
  final ResolvedMediaSource source;
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  ) async => source;
}

/// A reader-local index snapshot and a bounded best-effort persistence mailbox.
/// Only owner-confirmed writes become locally readable; pending writes do not.
final class _WorkerAudioCache extends PlaybackCache {
  _WorkerAudioCache(Map<String, Object?> data, this.events)
    : super(
        Directory(data['directory'] as String),
        provider: data['provider'] as String,
      ) {
    _generation = data['generation'] as int;
    _available = data['available'] as bool;
    final key = data['key'] as String;
    _audioRevisions[key] = data['revision'] as int;
    _loaded.add(key);
    final entry = data['entry'] as Map?;
    if (entry != null) _entries[key] = Map<String, dynamic>.from(entry);
  }
  final SendPort events;
  // Shared across both native readers in this input isolate.
  static int _outstanding = 0;
  int _pendingBytes = 0;
  bool _mailboxClosed = false;
  void acceptPersistedEntry(
    String key,
    int generation,
    int revision,
    Map<String, dynamic> entry,
  ) {
    final current = _entries[key];
    if (_mailboxClosed ||
        generation != _generation ||
        revision != audioRevision(key) ||
        current == null ||
        current['version'] != entry['version'] ||
        PlaybackCache.audioLength(current) !=
            PlaybackCache.audioLength(entry)) {
      return;
    }
    _entries[key] = entry;
  }

  void acknowledge(int count) {
    final released = min(count, _pendingBytes);
    _pendingBytes -= released;
    _outstanding -= released;
  }

  void closeMailbox() {
    _mailboxClosed = true;
    acknowledge(_pendingBytes);
  }

  @override
  Future<void> validateEntry(String key) async {}
  @override
  void pin(String key) {}
  @override
  void unpin(String key) {}
  @override
  void _scheduleRangeFlush() {}
  @override
  Future<void> flushAudioWrites() async {}
  @override
  Future<void> prepareAudio(
    String key,
    int total,
    String? version,
    Map<String, dynamic> metadata,
    int generation, {
    bool reset = false,
  }) async {
    final old = _entries[key];
    if (!reset &&
        old != null &&
        PlaybackCache.audioLength(old) == total &&
        old['version'] == version) {
      return;
    }
    if (reset ||
        (old != null &&
            (PlaybackCache.audioLength(old) != total ||
                old['version'] != version))) {
      _audioRevisions.update(key, (v) => v + 1, ifAbsent: () => 1);
      _entries.remove(key);
    }
    _entries.putIfAbsent(
      key,
      () => {
        ...metadata,
        'kind': 'audio',
        'size': 0,
        'total': total,
        'version': version,
        'ranges': <List<int>>[],
        'fileName': '',
      },
    );
    events.send([
      'prepare',
      total,
      version,
      metadata,
      reset,
      audioRevision(key),
    ]);
  }

  @override
  void _queueAudioRange(
    String key,
    int offset,
    List<int> bytes,
    int generation,
    int revision, {
    bool allowEviction = true,
  }) {
    if (_mailboxClosed ||
        _outstanding + bytes.length > _inputWorkerMailboxBytes) {
      return;
    }
    _outstanding += bytes.length;
    _pendingBytes += bytes.length;
    events.send(['chunk', offset, Uint8List.fromList(bytes), revision]);
  }
}
