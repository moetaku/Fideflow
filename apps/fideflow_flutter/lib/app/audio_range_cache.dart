part of 'playback_cache.dart';

const _audioRangeBytes = 256 * 1024;

String? _sourceVersion(ResolvedMediaSource source) {
  if (source.resourceId == null) return null;
  if (source.fullContent == true) return 'provider:${source.resourceId}';
  final scope = jsonEncode([
    for (final r in source.allowedByteRanges) [r.start, r.end],
  ]);
  return 'provider:${source.resourceId}:preview:${sha256.convert(utf8.encode(scope))}';
}

String? _audioVersion(ResolvedMediaSource source, HttpHeaders headers) {
  if (source.resourceId != null) return _sourceVersion(source);
  final etag = headers.value(HttpHeaders.etagHeader);
  if (etag != null && !etag.startsWith('W/')) {
    return 'etag:$etag';
  }
  final modified = headers.value(HttpHeaders.lastModifiedHeader);
  return modified == null ? null : 'modified:$modified';
}

Map<String, dynamic> _audioMetadata(
  ResolvedMediaSource source,
  HttpHeaders headers,
) => {
  'codec': source.codec,
  'bitrate': source.bitrateKbps,
  'sampleRate': source.sampleRateHz,
  'resourceId': source.resourceId,
  'fullContent': source.fullContent,
  'allowedByteRanges': [
    for (final r in source.allowedByteRanges) [r.start, r.end],
  ],
  'contentType': headers.value(HttpHeaders.contentTypeHeader),
  'etag': headers.value(HttpHeaders.etagHeader),
  'lastModified': headers.value(HttpHeaders.lastModifiedHeader),
};

final class _RangeUnsupported implements Exception {}

final class _AudioChanged implements Exception {}

// One lease per input reader, so seek/cancellation cannot cancel another reader's fill.
final class _RangeReader {
  _RangeReader(this.valid, {this.background = false});
  final bool background;
  final bool Function() valid;
  bool closed = false;
  bool outputStarted = false;
  final Set<_RangeFill> fills = {};
  bool get active => !closed && valid();
  void use(_RangeFill fill) {
    if (fills.add(fill)) {
      fill.users++;
    }
  }

  void releaseBefore(int position) {
    for (final fill in fills.where((f) => f.end <= position).toList()) {
      fills.remove(fill);
      fill.users--;
      if (fill.users == 0) {
        if (!fill.done) {
          fill.abort();
        } else {
          fill.releaseMemory();
        }
      }
    }
  }

  void close() {
    if (closed) {
      return;
    }
    closed = true;
    for (final fill in fills) {
      fill.users--;
      if (fill.users == 0) {
        if (!fill.done) {
          fill.abort();
        } else {
          fill.releaseMemory();
        }
      }
    }
    fills.clear();
  }
}

final class _AudioSlots {
  int active = 0;
  final List<Completer<void>> waiting = [];
  Future<void> acquire() async {
    if (active < 2) {
      active++;
      return;
    }
    final ready = Completer<void>();
    waiting.add(ready);
    await ready.future;
  }

  void release() {
    if (waiting.isNotEmpty) {
      waiting.removeAt(0).complete();
    } else {
      active--;
    }
  }
}

extension _RangeTransport on CachedAudioResolver {
  // Extension state is held on the resolver: one bounded scheduler across all songs.
  _AudioRangeSession _rangeSession(
    String token,
    List<dynamic> data,
    String key,
    bool Function() valid,
    int cacheGeneration,
  ) {
    _rangeSessions.removeWhere(
      (_, session) => session.idle && !session.valid(),
    );
    if (_rangeSessions.length >= 128) {
      for (final name in _rangeSessions.keys.toList()) {
        if (_rangeSessions[name]!.idle) _rangeSessions.remove(name);
        if (_rangeSessions.length < 128) break;
      }
    }
    final resolved = _sources[token]!;
    final version = _sourceVersion(resolved);
    final sessionKey = jsonEncode([
      key,
      version ?? token,
      resolved.totalBytes,
      data[0],
      data[1],
      _permissionGenerations[token],
      cacheGeneration,
      data[5],
    ]);
    Future<ResolvedMediaSource> permittedSource() async {
      final source = _sources[token];
      if (source == null || !valid()) throw StateError('playback.cancelled');
      return source;
    }

    var session = _rangeSessions[sessionKey];
    if (session == null || session.revision != cache.audioRevision(key)) {
      session = _AudioRangeSession(
        this,
        key,
        cacheGeneration,
        bypass: data[5] == true,
      );
      _rangeSessions[sessionKey] = session;
    }
    session.addPermit(token, valid, permittedSource);
    return session;
  }
}

final class _AudioRangeSession {
  _AudioRangeSession(
    this.host,
    this.key,
    this.generation, {
    required this.bypass,
  }) : revision = host.cache.audioRevision(key),
       cacheReadable = !bypass;
  final CachedAudioResolver host;
  final String key;
  final int generation;
  // A shared fill outlives any single background permit. Keep foreground
  // admission valid when a precache task releases its equally scoped token.
  final Map<String, (bool Function(), Future<ResolvedMediaSource> Function())>
  _permits = {};
  void addPermit(
    String token,
    bool Function() valid,
    Future<ResolvedMediaSource> Function() source,
  ) {
    _permits.removeWhere((_, permit) => !permit.$1());
    _permits.remove(token);
    _permits[token] = (valid, source);
  }

  bool valid() => _permits.values.any((permit) => permit.$1());
  Future<ResolvedMediaSource> source() {
    for (final permit in _permits.values.toList().reversed) {
      if (permit.$1()) return permit.$2();
    }
    throw StateError('playback.cancelled');
  }

  Future<ResolvedMediaSource>? _sourceInFlight;
  Future<ResolvedMediaSource> getSource() =>
      _sourceInFlight ??= source().whenComplete(() {
        _sourceInFlight = null;
      });
  final bool bypass;
  bool cacheReadable;
  int revision;
  int? total;
  bool validated = false;
  bool initialized = false;
  final List<_RangeFill> fills = [];
  PlaybackCache get cache => host.cache;
  bool get idle => fills.every((f) => f.users == 0);
  bool get current =>
      valid() &&
      cache.generation == generation &&
      revision == cache.audioRevision(key);
  void abort() {
    for (final fill in fills) {
      fill.abort();
    }
  }

  void prune() {
    fills.removeWhere((f) {
      if (f.done && f.users == 0) {
        f.releaseMemory();
        return true;
      }
      return false;
    });
  }

  Future<void> initialize(_RangeReader reader) async {
    if (initialized) {
      return;
    }
    if (!bypass) {
      final resolved = await getSource();
      if (cacheReadable) await cache.validateEntry(key);
      final entry = cacheReadable ? cache.lookup(key) : null;
      if (entry != null &&
          entry['kind'] == 'audio' &&
          resolved.resourceId != null &&
          entry['version'] == _sourceVersion(resolved) &&
          (resolved.totalBytes == null ||
              resolved.totalBytes == PlaybackCache.audioLength(entry))) {
        total = PlaybackCache.audioLength(entry);
        initialized = true;
        validated = true;
        return;
      }
    }
    final fill = ensureFill(0, _audioRangeBytes, reader);
    await fill.ready.future;
    if (fill.error != null) {
      throw fill.error!;
    }
    initialized = true;
  }

  _RangeFill ensureFill(int start, int end, _RangeReader reader) {
    prune();
    for (final fill in fills) {
      if (!fill.aborted && fill.start <= start && start < fill.end) {
        reader.use(fill);
        if (!reader.background) {
          if (!host._backgroundReaders.any(
            (r) => r.active && r.fills.contains(fill),
          )) {
            host.cancelPrecache();
          }
          host.onAudioActivity?.call();
        }
        return fill;
      }
    }
    final fill = _RangeFill(this, start, end);
    fills.add(fill);
    reader.use(fill);
    if (!reader.background) {
      host.cancelPrecache();
      host.onAudioActivity?.call();
    }
    final task = fill.run();
    host._rangeTasks.add(task);
    unawaited(
      task.then<void>((_) {
        host._rangeTasks.remove(task);
      }),
    );
    return fill;
  }

  Stream<List<int>> read(int start, int end, _RangeReader reader) async* {
    var position = start;
    while (position < end) {
      if (reader.closed) return;
      reader.releaseBefore(position);
      prune();
      if (!reader.active || !current) {
        throw StateError('playback.cancelled');
      }
      List<int>? live;
      for (final fill in reader.fills) {
        if (!fill.aborted) live ??= fill.memoryAt(position, end);
      }
      if (live != null) {
        position += live.length;
        reader.outputStarted = true;
        yield live;
        continue;
      }
      final entry = cacheReadable && validated ? cache.lookup(key) : null;
      final ranges = entry == null
          ? <List<int>>[]
          : PlaybackCache.audioRanges(entry);
      List<int>? cached;
      int gapEnd = end;
      for (final r in ranges) {
        if (r[0] <= position && position < r[1]) {
          cached = r;
          break;
        }
        if (r[0] > position) {
          gapEnd = min(gapEnd, r[0]);
          break;
        }
      }
      if (cached != null) {
        final stop = min(end, cached[1]);
        await for (final bytes in cache.file(key).openRead(position, stop)) {
          if (reader.closed) return;
          if (!reader.active || !current) {
            throw StateError('playback.cancelled');
          }
          position += bytes.length;
          reader.outputStarted = true;
          yield bytes;
        }
        continue;
      }
      final fill = ensureFill(
        position,
        min(gapEnd, position + _audioRangeBytes),
        reader,
      );
      await fill.ready.future;
      if (reader.closed) return;
      if (fill.aborted) throw StateError('playback.cancelled');
      if (fill.error != null) {
        throw fill.error!;
      }
      final bytes = fill.memoryAt(position, end);
      if (bytes != null) {
        if (!current || !reader.active) {
          throw StateError('playback.cancelled');
        }
        position += bytes.length;
        reader.outputStarted = true;
        yield bytes;
        continue;
      }
      if (fill.error != null) {
        throw fill.error!;
      }
      if (fill.done) {
        throw StateError('audio.shortRead');
      }
      await fill.changed.future;
    }
  }
}

final class _RangeFill {
  _RangeFill(this.session, this.start, this.end);
  final _AudioRangeSession session;
  final int start;
  int end;
  final Completer<void> ready = Completer<void>();
  Completer<void> changed = Completer<void>();
  final List<(int, List<int>)> memory = [];
  HttpClientRequest? request;
  StreamIterator<List<int>>? _body;
  int users = 0;
  bool done = false, aborted = false;
  Object? error;
  void signal() {
    final previous = changed;
    changed = Completer<void>();
    if (!previous.isCompleted) {
      previous.complete();
    }
  }

  int _memoryBytes = 0;
  void releaseMemory() {
    session.host._liveAudioBytes -= _memoryBytes;
    _memoryBytes = 0;
    memory.clear();
  }

  void abort() {
    aborted = true;
    releaseMemory();
    request?.abort(StateError('playback.cancelled'));
    final body = _body;
    if (body != null) unawaited(body.cancel());
    signal();
  }

  List<int>? memoryAt(int position, int stop) {
    for (final (offset, bytes) in memory) {
      if (offset <= position && position < offset + bytes.length) {
        final start = position - offset, end = min(bytes.length, stop - offset);
        return bytes is Uint8List
            ? Uint8List.sublistView(bytes, start, end)
            : bytes.sublist(start, end);
      }
    }
    return null;
  }

  Future<void> run() async {
    final host = session.host;
    Timer? watchdog;
    bool slot = false;
    try {
      final slotWatch = Stopwatch()..start();
      await host._audioSlots.acquire();
      host.rangeSlotWaitMicros += slotWatch.elapsedMicroseconds;
      slot = true;
      if (aborted || !session.current || users == 0) {
        throw StateError('playback.cancelled');
      }
      final source = await session.getSource();
      if (aborted || !session.current || users == 0) {
        throw StateError('playback.cancelled');
      }
      if (source.fullContent != true) {
        final scope = source.allowedByteRanges
            .where((r) => r.start <= start && r.end > start)
            .firstOrNull;
        if (scope == null) throw StateError('playback.previewRange');
        end = min(end, scope.end);
      }
      final networkWatch = Stopwatch()..start();
      host.rangeRequestCount++;
      request = await host._client.getUrl(source.uri);
      host._requests.add(request!);
      if (aborted || !session.current || users == 0) {
        throw StateError('playback.cancelled');
      }
      source.headers.forEach(
        (name, value) => request!.headers.set(name, value),
      );
      request!.headers.set('Accept-Encoding', 'identity');
      request!.headers.set('Range', 'bytes=$start-${end - 1}');
      final old = session.cache.lookup(session.key);
      final etag = old?['etag'] as String?;
      final validator = etag != null && !etag.startsWith('W/')
          ? etag
          : old?['lastModified'];
      if (validator != null) {
        request!.headers.set('If-Range', validator);
      }
      watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (aborted || !session.current || users == 0) {
          abort();
        }
      });
      final response = await request!.close().timeout(
        const Duration(seconds: 20),
      );
      host.rangeFirstByteMicros += networkWatch.elapsedMicroseconds;
      final encoding = response.headers.value('Content-Encoding');
      if (encoding != null && encoding != 'identity') {
        throw StateError('audio.encodedRange');
      }
      int begin, stop, total, bodyPosition;
      if (response.statusCode == 206) {
        final match = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+)$',
        ).firstMatch(response.headers.value('Content-Range') ?? '');
        if (match == null) {
          throw StateError('audio.invalidContentRange');
        }
        begin = int.parse(match[1]!);
        stop = int.parse(match[2]!) + 1;
        total = int.parse(match[3]!);
        bodyPosition = begin;
        if (begin != start ||
            stop <= begin ||
            stop > end ||
            stop > total ||
            (response.contentLength >= 0 &&
                response.contentLength != stop - begin)) {
          throw StateError('audio.invalidContentRange');
        }
      } else if (response.statusCode == 200) {
        // If-Range also returns 200 when the representation changed. Invalidate
        // partial bytes before falling back, especially after cached output.
        final old = session.cache.lookup(session.key);
        final version = _audioVersion(source, response.headers);
        if (!session.bypass &&
            old != null &&
            (old['size'] as int) > 0 &&
            (PlaybackCache.audioLength(old) != response.contentLength ||
                old['version'] != version ||
                (version == null && !session.validated))) {
          await session.cache
              .prepareAudio(
                session.key,
                response.contentLength > 0
                    ? response.contentLength
                    : PlaybackCache.audioLength(old),
                version,
                _audioMetadata(source, response.headers),
                session.generation,
                reset: true,
              )
              .catchError((Object _) {});
          throw _AudioChanged();
        }
        // Switch to a single sequential proxy request instead of downloading
        // the whole prefix again for every 256 KiB fill.
        throw _RangeUnsupported();
      } else {
        throw HttpException('audio.range.${response.statusCode}');
      }
      end = stop;
      final version = _audioVersion(source, response.headers);
      final noStore = (response.headers.value('Cache-Control') ?? '').contains(
        'no-store',
      );
      final existing = session.cache.lookup(session.key);
      final hasOld = existing != null && (existing['size'] as int) > 0;
      final changed =
          hasOld &&
          (PlaybackCache.audioLength(existing) != total ||
              existing['version'] != version ||
              (version == null && !session.validated));
      if (changed && !session.bypass) {
        await session.cache
            .prepareAudio(
              session.key,
              total,
              version,
              _audioMetadata(source, response.headers),
              session.generation,
              reset: true,
            )
            .catchError((Object _) {});
        throw _AudioChanged();
      }
      if (!session.current) {
        throw StateError('playback.cancelled');
      }
      session.total = total;
      var retain = !noStore;
      if (!noStore) {
        try {
          await session.cache.prepareAudio(
            session.key,
            total,
            version,
            _audioMetadata(source, response.headers),
            session.generation,
            reset: session.bypass && !session.validated,
          );
          session.cacheReadable = true;
        } catch (_) {
          // Keep serving the bounded network buffer when local persistence
          // fails; no uncommitted cache representation may be read or filled.
          retain = false;
          session.cacheReadable = false;
        }
        session.revision = session.cache.audioRevision(session.key);
      }
      session.validated = true;
      ready.complete();
      signal();
      int position = begin;
      _body = StreamIterator(response.timeout(const Duration(seconds: 20)));
      while (await _body!.moveNext()) {
        final chunk = _body!.current;
        if (aborted || !session.current) {
          throw StateError('playback.cancelled');
        }
        final chunkEnd = bodyPosition + chunk.length;
        if (response.statusCode == 206 && chunkEnd > stop) {
          throw StateError('audio.overflow');
        }
        final low = max(0, begin - bodyPosition),
            high = min(chunk.length, stop - bodyPosition);
        if (high > low) {
          final bytes = chunk is Uint8List
              ? Uint8List.sublistView(chunk, low, high)
              : chunk.sublist(low, high);
          if (retain) {
            session.cache._queueAudioRange(
              session.key,
              position,
              bytes,
              session.generation,
              session.revision,
              allowEviction: !host._backgroundReaders.any(
                (reader) => reader.fills.contains(this),
              ),
            );
          }
          if (host._liveAudioBytes + bytes.length > host._rangeMemoryLimit) {
            throw StateError('audio.inputCapacity');
          }
          host._liveAudioBytes += bytes.length;
          _memoryBytes += bytes.length;
          memory.add((position, bytes));
          position += bytes.length;
          signal();
        }
        bodyPosition = chunkEnd;
        if (position == stop) {
          break;
        }
      }
      if (position != stop) {
        throw StateError('audio.shortRead');
      }
    } catch (failure) {
      error = failure;
      if (!ready.isCompleted) {
        ready.complete();
      }
    } finally {
      done = true;
      signal();
      watchdog?.cancel();
      await _body?.cancel();
      if (request != null) {
        request!.abort();
        host._requests.remove(request);
      }
      if (slot) {
        host._audioSlots.release();
      }
      // Coalesce persistence without retaining completed fill buffers while the
      // disk is blocked. Resolver/cache close explicitly drains pending writes.
      session.cache._scheduleRangeFlush();
    }
  }
}

/// One logical FFmpeg reader. Its stream remains open across adjacent reads;
/// seeking closes only this reader's fill leases, preserving other consumers.
final class _CachedInputReader implements AudioInputReader {
  _CachedInputReader(this.host, this.token)
    : _cacheGeneration = host.cache.generation,
      totalBytes = host._sources[token]!.totalBytes,
      key = host.cache.key(
        host._permits[token]![0] as String,
        host._permits[token]![2] as String,
        host._permits[token]![3] as String,
      ) {
    host.cache.pin(key);
    _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!valid) host._removeSource(token);
    });
  }
  final int _cacheGeneration;
  Timer? _watchdog;
  final CachedAudioResolver host;
  final String token;
  final String key;
  @override
  int? totalBytes;
  StreamIterator<List<int>>? _body;
  _RangeReader? _reader;
  HttpClientRequest? _request;
  List<int>? _pending;
  int _pendingOffset = 0;
  int _position = 0;
  bool _closed = false;
  bool _busy = false;
  bool _sequential = false;
  bool _cachedStream = false;
  bool _sequentialSlot = false;
  @override
  Future<int?> length() async {
    if (!valid) throw StateError("playback.cancelled");
    if (totalBytes == null && _body == null) await _start(0);
    return totalBytes;
  }

  bool get valid =>
      !_closed &&
      _cacheGeneration == host.cache.generation &&
      host._validInput(token);

  Future<void> _reset() async {
    final body = _body;
    _body = null;
    _reader?.close();
    _reader = null;
    _request?.abort();
    if (_request != null) host._requests.remove(_request);
    _request = null;
    _pending = null;
    _pendingOffset = 0;
    if (body != null) {
      try {
        await body.cancel();
      } catch (_) {}
    }
    if (_sequentialSlot) {
      _sequentialSlot = false;
      host._audioSlots.release();
    }
  }

  Future<void> _start(int offset) async {
    await _reset();
    if (!valid) throw StateError('playback.cancelled');
    final source = host._sources[token]!;
    final data = host._permits[token]!;
    final offline = host._offlineTokens.contains(token);
    if (data[5] != true) await host.cache.validateEntry(key);
    final hit = data[5] == true ? null : host.cache.lookup(key);
    _cachedStream = false;
    if (!offline &&
        hit != null &&
        source.resourceId != null &&
        hit['version'] == _sourceVersion(source) &&
        (source.totalBytes == null ||
            source.totalBytes == PlaybackCache.audioLength(hit)) &&
        await host.cache._regular(hit['fileName'] as String)) {
      final interval = PlaybackCache.audioRanges(
        hit,
      ).where((r) => r[0] <= offset && r[1] > offset).firstOrNull;
      if (interval != null) {
        totalBytes = PlaybackCache.audioLength(hit);
        _cachedStream = true;
        _body = StreamIterator(
          host.cache.file(key).openRead(offset, interval[1]),
        );
        _position = offset;
        return;
      }
    }
    if (offline) {
      totalBytes = hit == null ? 0 : PlaybackCache.audioLength(hit);
      final interval = hit == null
          ? null
          : PlaybackCache.audioRanges(
              hit,
            ).where((r) => r[0] <= offset && r[1] > offset).firstOrNull;
      if (interval == null ||
          !await host.cache._regular(hit!['fileName'] as String)) {
        await host.onOfflineGap?.call(source.trackId);
        throw StateError('playback.offlineGap');
      }
      _body = StreamIterator(
        host.cache.file(key).openRead(offset, interval[1]),
      );
      _position = offset;
      return;
    }
    if (!_sequential &&
        host.cache._available &&
        !host._noRangeTokens.contains(token)) {
      final reader = _RangeReader(() => valid);
      _reader = reader;
      final session = host._rangeSession(
        token,
        data,
        key,
        () => host._validInput(token),
        host.cache.generation,
      );
      try {
        await session.initialize(reader);
        if (!valid) throw StateError('playback.cancelled');
        totalBytes = session.total;
        var end = totalBytes!;
        if (source.fullContent != true) {
          final scope = source.allowedByteRanges
              .where((r) => r.start <= offset && offset < r.end)
              .firstOrNull;
          if (scope == null) throw StateError('playback.previewRange');
          end = min(end, scope.end);
        }
        _body = StreamIterator(session.read(offset, end, reader));
        _position = offset;
        return;
      } on _RangeUnsupported {
        reader.close();
        _reader = null;
        _sequential = true;
        host._noRangeTokens.add(token);
      }
    }
    host.cancelPrecache();
    await host._audioSlots.acquire();
    _sequentialSlot = true;
    if (!valid) {
      await _reset();
      throw StateError('playback.cancelled');
    }
    final request = await host._client.getUrl(source.uri);
    if (!valid) {
      request.abort();
      throw StateError('playback.cancelled');
    }
    _request = request;
    host._requests.add(request);
    source.headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    if (source.fullContent != true) {
      final scope = source.allowedByteRanges
          .where((r) => r.start <= offset && offset < r.end)
          .firstOrNull;
      if (scope == null) throw StateError('playback.previewRange');
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$offset-${scope.end - 1}',
      );
    }
    host.rangeRequestCount++;
    final watch = Stopwatch()..start();
    final response = await request.close().timeout(const Duration(seconds: 20));
    host.rangeFirstByteMicros += watch.elapsedMicroseconds;
    if (!valid) throw StateError('playback.cancelled');
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('audio.read.${response.statusCode}');
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding != 'identity') {
      throw StateError('audio.encodedRange');
    }
    var begin = 0;
    if (response.statusCode == 206) {
      final range = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+|\*)$',
      ).firstMatch(response.headers.value('Content-Range') ?? '');
      if (range == null || int.parse(range[1]!) != offset) {
        throw StateError('audio.invalidContentRange');
      }
      begin = offset;
      final responseEnd = int.parse(range[2]!) + 1;
      totalBytes = int.tryParse(range[3]!);
      if (responseEnd <= begin ||
          (totalBytes != null && responseEnd > totalBytes!) ||
          (response.contentLength >= 0 &&
              response.contentLength != responseEnd - begin) ||
          (source.fullContent != true &&
              !source.allowedByteRanges.any(
                (r) => r.start <= begin && responseEnd <= r.end,
              ))) {
        throw StateError('audio.invalidContentRange');
      }
    } else {
      totalBytes = response.contentLength >= 0 ? response.contentLength : null;
    }
    Stream<List<int>> bytes = response.timeout(const Duration(seconds: 20));
    final noStore = (response.headers.value('cache-control') ?? '').contains(
      'no-store',
    );
    if (!noStore &&
        (source.fullContent == true || response.statusCode == 206) &&
        source.actualQuality != null &&
        totalBytes != null &&
        totalBytes! > 0) {
      bytes = host.cache.recordAudioRange(
        key,
        bytes,
        begin,
        totalBytes!,
        _audioVersion(source, response.headers),
        _audioMetadata(source, response.headers),
        host.cache.generation,
        reset: response.statusCode == 200,
      );
    }
    if (begin < offset) {
      bytes = host._sequentialInterval(
        bytes,
        offset,
        totalBytes ?? 0x7fffffffffffffff,
        allowEof: totalBytes == null,
      );
    }
    _body = StreamIterator(bytes);
    _position = offset;
  }

  @override
  Future<int> read(int offset, Uint8List destination) async {
    if (!valid) throw StateError('playback.cancelled');
    if (_busy) throw StateError('audio.concurrentRead');
    if (destination.isEmpty) return 0;
    final source = host._sources[token]!;
    if (offset < 0 ||
        (source.fullContent != true &&
            !source.allowedByteRanges.any(
              (r) => r.start <= offset && offset < r.end,
            ))) {
      throw StateError('playback.previewRange');
    }
    if (totalBytes != null && offset >= totalBytes!) return 0;
    _busy = true;
    host.foregroundRequests++;
    // A seek changes download priority. Sequential cached reads don't compete
    // for the network and must not repeatedly cancel the forward cache task.
    if (_body == null || offset != _position) {
      host._foregroundSeekEpoch++;
    }
    host.onAudioActivity?.call();
    try {
      if (_sequential && _body != null && offset > _position) {
        // A forward seek in a sequential origin can reuse its current response.
        while (_position < offset) {
          if (_pending == null || _pendingOffset == _pending!.length) {
            if (!await _body!.moveNext()) throw StateError('audio.shortRead');
            _pending = _body!.current;
            _pendingOffset = 0;
          }
          final skip = min(
            offset - _position,
            _pending!.length - _pendingOffset,
          );
          _position += skip;
          _pendingOffset += skip;
          if (!valid) throw StateError('playback.cancelled');
        }
      }
      if (_body == null || offset != _position) await _start(offset);
      if (_pending == null || _pendingOffset == _pending!.length) {
        var next = await _body!.moveNext();
        if (!next &&
            _cachedStream &&
            totalBytes != null &&
            _position < totalBytes!) {
          await _start(_position);
          next = await _body!.moveNext();
        }
        if (!valid) throw StateError('playback.cancelled');
        if (!next) {
          if (totalBytes == null) {
            totalBytes = _position;
            return 0;
          }
          if (_position < totalBytes!) {
            if (host._offlineTokens.contains(token)) {
              await host.onOfflineGap?.call(source.trackId);
            }
            throw StateError('audio.shortRead');
          }
          return 0;
        }
        _pending = _body!.current;
        _pendingOffset = 0;
      }
      if (!valid) throw StateError('playback.cancelled');
      var count = min(destination.length, _pending!.length - _pendingOffset);
      if (source.fullContent != true) {
        final scope = source.allowedByteRanges.firstWhere(
          (r) => r.start <= offset && offset < r.end,
        );
        count = min(count, scope.end - offset);
      }
      destination.setRange(0, count, _pending!, _pendingOffset);
      _pendingOffset += count;
      _position += count;
      return count;
    } catch (_) {
      if (!valid) await _reset();
      rethrow;
    } finally {
      _busy = false;
      host.foregroundRequests--;
      host.onAudioActivity?.call();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _watchdog?.cancel();
    await _reset();
    host._inputReaders.remove(this);
    host.cache.unpin(key);
  }
}
