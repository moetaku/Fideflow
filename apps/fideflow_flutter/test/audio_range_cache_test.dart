import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_input_test_bridge.dart';
import 'flac_cache_fixture.dart';
import 'native_test_library.dart';
import 'playback_cache_test.dart' show wavFixture;
import 'process_cpu.dart';

final class _Source implements PlaybackSourceResolver {
  _Source(this.url);
  Uri url;
  String Function() resourceId = () => 'fixture-v1';
  bool offline = false;
  int calls = 0;
  int? totalBytes;
  bool fullContent = true;
  List<MediaByteRange> allowedRanges = const [];
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  ) async {
    calls++;
    if (offline) {
      throw const SocketException('offline');
    }
    return ResolvedMediaSource(
      trackId: id,
      uri: url,
      actualQuality: quality,
      resourceId: resourceId(),
      access: SongAccess.nonVip,
      resourceFree: true,
      fullContent: fullContent,
      totalBytes: totalBytes,
      allowedByteRanges: allowedRanges,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }
}

final class _Server {
  _Server({List<int>? bytes})
    : data = bytes ?? List<int>.generate(768 * 1024, (i) => i % 251);
  final List<int> data;
  int? gateFromByte;
  final List<(int, int, String?)> requests = [];
  late HttpServer server;
  String etag = '"v1"';
  bool ranges = true, noStore = false, malformed = false;
  Completer<void>? gate;
  Duration firstByteDelay = Duration.zero;
  Duration chunkDelay = Duration.zero;
  bool unknownLength = false;
  Future<void> open() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final match = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers.value('Range') ?? '');
        var begin = match == null ? 0 : int.parse(match[1]!);
        var end = match == null ? data.length : int.parse(match[2]!) + 1;
        end = end.clamp(0, data.length);
        final ifRange = request.headers.value('If-Range');
        requests.add((begin, end, ifRange));
        final partial = ranges && (ifRange == null || ifRange == etag);
        request.response.headers.set('ETag', etag);
        if (noStore) {
          request.response.headers.set('Cache-Control', 'no-store');
        }
        if (partial) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes ${malformed ? begin + 1 : begin}-${end - 1}/${data.length}',
          );
        } else {
          begin = 0;
          end = data.length;
        }
        if (!unknownLength) request.response.contentLength = end - begin;
        final pause = gate;
        if (pause != null && gateFromByte != null && begin >= gateFromByte!) {
          await pause.future;
        }
        if (firstByteDelay > Duration.zero) {
          await Future<void>.delayed(firstByteDelay);
        }
        final firstEnd = (begin + 64 * 1024).clamp(begin, end);
        request.response.add(data.sublist(begin, firstEnd));
        await request.response.flush();
        if (pause != null && gateFromByte == null) {
          await pause.future;
        }
        for (var position = firstEnd; position < end; position += 16 * 1024) {
          if (chunkDelay > Duration.zero) {
            await Future<void>.delayed(chunkDelay);
          }
          request.response.add(
            data.sublist(position, (position + 16 * 1024).clamp(position, end)),
          );
          await request.response.flush();
        }
        await request.response.close();
      } catch (_) {
        /* Readers deliberately cancel requests while seeking. */
      }
    });
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/song');
  Future<void> close() async {
    if (gate != null && !gate!.isCompleted) {
      gate!.complete();
    }
    await server.close(force: true);
  }
}

Future<List<int>> read(HttpClient client, Uri uri, {String? range}) async {
  final request = await client.getUrl(uri);
  if (range != null) {
    request.headers.set('Range', range);
  }
  final response = await request.close();
  if (response.statusCode >= 400) {
    throw HttpException('response.${response.statusCode}');
  }
  return response.fold<List<int>>([], (a, b) => a..addAll(b));
}

void main() {
  late Directory directory;
  late PlaybackCache cache;
  late CachedAudioResolver audio;
  late _Server server;
  late _Source source;
  late HttpClient client;
  late Uri uri;
  String getKey() => cache.key('A', 'song', 'high');
  Future<void> openAudio() async {
    audio = CachedAudioResolver(
      upstream: source,
      cache: cache,
      account: () => 'A',
      epoch: () => 0,
    );
    await audio.initialize();
    uri = await testInputUri(
      audio,
      (await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      )).uri,
    );
  }

  Future<void> waitFor(bool Function() predicate) async {
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (!predicate()) {
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('condition');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-range-');
    cache = PlaybackCache(directory);
    await cache.initialize();
    await cache.recovery;
    server = _Server();
    await server.open();
    source = _Source(server.url)..resourceId = () => server.etag;
    client = HttpClient();
    await openAudio();
  });
  tearDown(() async {
    client.close(force: true);
    await audio.close();
    await server.close();
    await cache.close();
    await directory.delete(recursive: true);
  });

  test(
    'direct input reuses a sequential response with unknown length',
    () async {
      server.ranges = false;
      server.unknownLength = true;
      server.noStore = true;
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      expect(resolved.uri.scheme, 'ffinput');
      expect(resolved.uri.hasPort, isFalse);
      final reader = await audio.openAudioInput(int.parse(resolved.uri.host));
      try {
        expect(await reader.length(), isNull);
        final output = Uint8List(64 * 1024);
        var offset = 0;
        while (true) {
          final count = await reader.read(offset, output);
          if (count == 0) break;
          expect(
            output.sublist(0, count),
            server.data.sublist(offset, offset + count),
          );
          offset += count;
        }
        expect(offset, server.data.length);
        expect(reader.totalBytes, server.data.length);
        expect(server.requests, hasLength(2));
        expect(cache.lookup(getKey()), isNull);
      } finally {
        await reader.close();
      }
    },
  );

  test('preview input does not cache an unrestricted Range fallback', () async {
    server.ranges = false;
    source.fullContent = false;
    source.totalBytes = server.data.length;
    source.allowedRanges = const [MediaByteRange(1024, 65536)];
    audio.revokeTrack(const TrackId('song'));
    final resolved = await audio.resolve(
      const TrackId('song'),
      AudioQuality.high,
      NetworkPolicy.preferCache,
    );
    final reader = await audio.openAudioInput(int.parse(resolved.uri.host));
    try {
      final output = Uint8List(4096);
      await expectLater(reader.read(1024, output), throwsStateError);
      await expectLater(reader.read(65536, output), throwsA(anything));
    } finally {
      await reader.close();
    }
    expect(cache.lookup(getKey()), isNull);
  });

  test('direct input refuses a read after cache clear', () async {
    final resolved = await audio.resolve(
      const TrackId('song'),
      AudioQuality.high,
      NetworkPolicy.preferCache,
    );
    final reader = await audio.openAudioInput(int.parse(resolved.uri.host));
    try {
      expect(await reader.read(0, Uint8List(32)), 32);
      await cache.clear();
      await expectLater(reader.read(32, Uint8List(32)), throwsStateError);
    } finally {
      await reader.close();
    }
  });

  test('closing a stalled direct reader completes its pending read', () async {
    server.gate = Completer<void>();
    final resolved = await audio.resolve(
      const TrackId('song'),
      AudioQuality.high,
      NetworkPolicy.preferCache,
    );
    final reader = await audio.openAudioInput(int.parse(resolved.uri.host));
    final first = Uint8List(64 * 1024);
    var received = 0;
    while (received < first.length) {
      received += await reader.read(
        received,
        Uint8List.sublistView(first, received),
      );
    }
    expect(received, first.length);
    final pending = reader.read(first.length, Uint8List(64 * 1024));
    final checked = expectLater(pending, throwsA(anything));
    await reader.close().timeout(const Duration(seconds: 1));
    await checked.timeout(const Duration(seconds: 1));
    server.gate!.complete();
  });

  test('repeated precaching preserves the foreground source URL', () async {
    for (var i = 0; i < 512; i++) {
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isTrue,
      );
    }
    expect(
      await read(client, uri, range: 'bytes=0-1023'),
      server.data.sublist(0, 1024),
    );
  });

  test(
    'sequential fallback stays foreground busy until download ends',
    () async {
      server.ranges = false;
      server.gate = Completer<void>();
      final foreground = read(client, uri);
      await waitFor(() => server.requests.length >= 2);
      final busy = audio.foregroundBusy;
      server.gate!.complete();
      server.gate = null;
      expect(await foreground, server.data);
      await waitFor(() => audio.foregroundRequests == 0);
      expect(busy, isTrue);
      expect(audio.foregroundBusy, isFalse);
    },
  );

  test(
    'precache completes audio and playback needs no more remote bytes',
    () async {
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isTrue,
      );
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
      final requests = server.requests.length;
      expect(await read(client, uri), server.data);
      expect(server.requests.length, requests);
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isTrue,
      );
      expect(server.requests.length, requests);
    },
  );

  test(
    'playback precache skips earlier holes then re-prioritizes after backward seek',
    () async {
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final input = await audio.openAudioInput(int.parse(resolved.uri.host));
      final middle = server.data.length ~/ 2;
      try {
        expect(await input.read(middle, Uint8List(32)), 32);
        await waitFor(() => !audio.foregroundBusy);
        await cache.flushAudioWrites();
        final requests = server.requests.length;
        expect(
          await audio.precache(
            const TrackId('song'),
            AudioQuality.high,
            valid: () => true,
            prioritizePlayback: true,
          ),
          isTrue,
        );
        final starts = server.requests.skip(requests).map((r) => r.$1).toList();
        expect(starts.first, greaterThan(middle));
        expect(starts.every((start) => start >= middle), isTrue);
        expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isFalse);
        final beforeSeek = server.requests.length;
        expect(await input.read(0, Uint8List(32)), 32);
        expect(server.requests.length, beforeSeek);
        expect(
          await audio.precache(
            const TrackId('song'),
            AudioQuality.high,
            valid: () => true,
            prioritizePlayback: true,
          ),
          isTrue,
        );
        final newRequests = server.requests.skip(beforeSeek);
        expect(newRequests, isNotEmpty);
        expect(newRequests.every((r) => r.$1 >= 32 && r.$2 <= middle), isTrue);
        expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
        expect(await cache.file(getKey()).readAsBytes(), server.data);
      } finally {
        await input.close();
      }
    },
  );

  test(
    'cached seeks retain the download when the nearest forward hole is unchanged',
    () async {
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final input = await audio.openAudioInput(int.parse(resolved.uri.host));
      try {
        expect(await input.read(0, Uint8List(32)), 32);
        await waitFor(() => !audio.foregroundBusy);
        await cache.flushAudioWrites();
        server.gate = Completer<void>();
        server.gateFromByte = 256 * 1024;
        final background = audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
          prioritizePlayback: true,
        );
        await waitFor(() => server.requests.any((r) => r.$1 >= 256 * 1024));
        final epoch = audio.backgroundEpoch;
        final requests = server.requests.length;
        for (final offset in [4096, 128, 8192, 32]) {
          expect(await input.read(offset, Uint8List(32)), 32);
          expect(
            await audio.precacheMatchesPlayback(
              const TrackId('song'),
              AudioQuality.high,
              null,
            ),
            isTrue,
          );
          expect(audio.backgroundEpoch, epoch);
          expect(server.requests.length, requests);
        }
        server.gate!.complete();
        expect(await background, isTrue);
      } finally {
        await input.close();
      }
    },
  );

  test(
    'sequential cached reads do not cancel an active forward cache fill',
    () async {
      final key = getKey();
      await cache.prepareAudio(
        key,
        server.data.length,
        'provider:"v1"',
        {},
        cache.generation,
      );
      await cache.writeAudioRange(
        key,
        0,
        server.data.sublist(0, 256 * 1024),
        cache.generation,
        cache.audioRevision(key),
      );
      await cache.flushAudioWrites();
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final input = await audio.openAudioInput(int.parse(resolved.uri.host));
      server.gate = Completer<void>();
      server.gateFromByte = 256 * 1024;
      try {
        expect(await input.read(0, Uint8List(32)), 32);
        final task = audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
          prioritizePlayback: true,
        );
        await waitFor(() => server.requests.isNotEmpty);
        final epoch = audio.backgroundEpoch;
        for (var i = 1; i <= 8; i++) {
          expect(await input.read(i * 32, Uint8List(32)), 32);
          expect(audio.backgroundEpoch, epoch);
        }
        server.gate!.complete();
        expect(await task, isTrue);
        expect(PlaybackCache.completeAudio(cache.lookup(key)!), isTrue);
      } finally {
        await input.close();
      }
    },
  );

  test(
    'latest playback time overrides a retained native reader offset',
    () async {
      await audio.close();
      await server.close();
      final bytes = wavFixture(seconds: 4);
      server = _Server(bytes: bytes);
      await server.open();
      source.url = server.url;
      source.totalBytes = bytes.length;
      await openAudio();
      final key = getKey();
      await cache.prepareAudio(
        key,
        bytes.length,
        'provider:"v1"',
        {},
        cache.generation,
      );
      for (final range in [
        [0, 196608],
        [393216, 458752],
        [589824, bytes.length],
      ]) {
        await cache.writeAudioRange(
          key,
          range[0],
          bytes.sublist(range[0], range[1]),
          cache.generation,
          cache.audioRevision(key),
        );
      }
      await cache.flushAudioWrites();
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final input = await audio.openAudioInput(int.parse(resolved.uri.host));
      try {
        expect(await input.read(589824, Uint8List(32)), 32);
        server.requests.clear();
        // Seek back is handled by native AVIO blocks, so Dart's read offset is
        // still near the tail. Scheduling must follow the new playback anchor.
        expect(
          await audio.precache(
            const TrackId('song'),
            AudioQuality.high,
            valid: () => true,
            prioritizePlayback: true,
            playbackFraction: .1,
          ),
          isTrue,
        );
        expect(server.requests.first.$1, 196608);
        expect(server.requests.last.$1, greaterThanOrEqualTo(458752));
        for (final request in server.requests) {
          expect(
            (request.$1 >= 196608 && request.$2 <= 393216) ||
                (request.$1 >= 458752 && request.$2 <= 589824),
            isTrue,
          );
        }
        expect(PlaybackCache.completeAudio(cache.lookup(key)!), isTrue);
      } finally {
        await input.close();
      }
    },
  );

  test(
    'tail playback remains partial until precache fills only missing bytes',
    () async {
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final reader = await audio.openAudioInput(int.parse(resolved.uri.host));
      final tail = server.data.length - 64 * 1024;
      final output = Uint8List(64 * 1024);
      var position = tail;
      try {
        while (position < server.data.length) {
          final count = await reader.read(position, output);
          expect(count, greaterThan(0));
          expect(
            output.sublist(0, count),
            server.data.sublist(position, position + count),
          );
          position += count;
        }
      } finally {
        await reader.close();
      }
      await cache.flushAudioWrites();
      final key = getKey();
      expect(await cache.file(key).length(), server.data.length);
      expect(PlaybackCache.completeAudio(cache.lookup(key)!), isFalse);
      final before = server.requests.length;
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isTrue,
      );
      // The tail has already been cached. Backfill must not download it again.
      for (final request in server.requests.skip(before)) {
        expect(request.$2, lessThanOrEqualTo(tail));
      }
      expect(PlaybackCache.completeAudio(cache.lookup(key)!), isTrue);
      expect(await cache.file(key).readAsBytes(), server.data);
      final requests = server.requests.length;
      final indexWrites = cache.indexWrites;
      for (final start in [tail, 0, tail, 256 * 1024, tail]) {
        final input = await audio.openAudioInput(int.parse(resolved.uri.host));
        try {
          final count = await input.read(start, output);
          expect(
            output.sublist(0, count),
            server.data.sublist(start, start + count),
          );
        } finally {
          await input.close();
        }
      }
      await cache.flushAudioWrites();
      expect(server.requests.length, requests);
      expect(cache.indexWrites, indexWrites);
    },
  );

  test(
    'foreground seek to another uncached interval interrupts background',
    () async {
      server.gateFromByte = 256 * 1024;
      server.gate = Completer<void>();
      final background = audio.precache(
        const TrackId('song'),
        AudioQuality.high,
        valid: () => true,
      );
      await waitFor(() => server.requests.length >= 2);
      final foreground = read(client, uri, range: 'bytes=655360-656383');
      expect(await background, isFalse);
      expect(cache.lookup(getKey()), isNotNull);
      server.gate!.complete();
      server.gate = null;
      expect(await foreground, server.data.sublist(655360, 656384));
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isTrue,
      );
    },
  );

  test(
    'ending a background permit does not truncate the foreground stream',
    () async {
      server.chunkDelay = const Duration(milliseconds: 20);
      final resolved = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final input = await audio.openAudioInput(int.parse(resolved.uri.host));
      final output = Uint8List(16 * 1024);
      var position = 0;
      try {
        final first = await input.read(position, output);
        expect(first, greaterThan(0));
        expect(output.sublist(0, first), server.data.sublist(0, first));
        position += first;
        final background = audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
          prioritizePlayback: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        audio.cancelPrecache();
        await background;
        while (position < server.data.length) {
          final count = await input.read(position, output);
          expect(count, greaterThan(0), reason: 'premature EOF at $position');
          expect(
            output.sublist(0, count),
            server.data.sublist(position, position + count),
          );
          position += count;
        }
        expect(await input.read(position, output), 0);
      } finally {
        await input.close();
      }
    },
  );

  test('precache cancellation stops a stalled network fill', () async {
    server.gate = Completer<void>();
    final background = audio.precache(
      const TrackId('song'),
      AudioQuality.high,
      valid: () => true,
    );
    await waitFor(() => server.requests.isNotEmpty);
    audio.cancelPrecache();
    await expectLater(
      background.timeout(const Duration(seconds: 2)),
      completes,
    );
  });

  test(
    'precache stops on no-store rather than downloading the queue',
    () async {
      server.noStore = true;
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isFalse,
      );
      expect(cache.lookup(getKey()), isNull);
    },
  );

  test(
    'preview precache fetches only authorized bytes including nonzero start',
    () async {
      source.fullContent = false;
      source.totalBytes = server.data.length;
      source.allowedRanges = const [MediaByteRange(1024, 65536)];
      audio.revokeTrack(const TrackId('song'));
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isTrue,
      );
      expect(
        server.requests.every((r) => r.$1 >= 1024 && r.$2 <= 65536),
        isTrue,
      );
      expect(PlaybackCache.audioRanges(cache.lookup(getKey())!), [
        [1024, 65536],
      ]);
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isFalse);
    },
  );

  test(
    'capacity prevents speculative download and preserves existing cache',
    () async {
      source.totalBytes = cache.limitGb * PlaybackCache.gb + 1;
      audio.revokeTrack(const TrackId('song'));
      expect(
        await audio.precache(
          const TrackId('song'),
          AudioQuality.high,
          valid: () => true,
        ),
        isFalse,
      );
      expect(server.requests, isEmpty);
      expect(cache.lookup(getKey()), isNull);
    },
  );

  test('account change invalidates stalled background work', () async {
    await audio.close();
    var owner = 'A';
    var epoch = 0;
    audio = CachedAudioResolver(
      upstream: source,
      cache: cache,
      account: () => owner,
      epoch: () => epoch,
    );
    await audio.initialize();
    server.gate = Completer<void>();
    final background = audio.precache(
      const TrackId('song'),
      AudioQuality.high,
      valid: () => true,
    );
    await waitFor(() => server.requests.isNotEmpty);
    owner = 'B';
    epoch++;
    expect(await background.timeout(const Duration(seconds: 2)), isFalse);
  });

  final seekModes =
      Platform.environment['FF_SEEK_MODES']?.split(',') ??
      ['full', 'partial', 'network', 'network-warm'];
  for (final mode in seekModes.where(
    const {'full', 'partial', 'network', 'network-warm'}.contains,
  )) {
    test(
      'seek benchmark $mode',
      () async {
        await audio.close();
        await server.close();
        final fixturePath = Platform.environment['FF_SEEK_FIXTURE'];
        final fixture = fixturePath == null
            ? wavFixture(seconds: 40)
            : await File(fixturePath).readAsBytes();
        final extension = fixturePath == null
            ? 'wav'
            : fixturePath.split('.').last;
        server = _Server(bytes: fixture);
        if (mode == 'partial') {
          server.gate = Completer<void>();
          server.gateFromByte = 256 * 1024;
        }
        if (mode == 'network' || mode == 'network-warm') {
          server.noStore = true;
          server.firstByteDelay = const Duration(milliseconds: 20);
        }
        await server.open();
        final track = Track(
          id: const TrackId('ncm-1'),
          title: 'Cache fixture',
          album: const Album(id: AlbumId('fixture'), title: 'Fixture'),
          duration: Duration.zero,
          artists: const [],
        );
        source.url = server.url;
        await openAudio();
        if (mode == 'full') {
          expect(
            await audio.precache(
              track.id,
              AudioQuality.standard,
              valid: () => true,
            ),
            isTrue,
          );
        }
        if (mode == 'partial') {
          final initial = await audio.resolve(
            track.id,
            AudioQuality.standard,
            NetworkPolicy.preferCache,
          );
          await read(
            client,
            await testInputUri(audio, initial.uri),
            range: 'bytes=0-262143',
          );
          await cache.flushAudioWrites();
        }
        final api = openNativeTestLibrary();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: audio,
        );
        final connection = await controller.attach();
        final subscription = connection.snapshots.listen((_) {});
        try {
          final startup = Stopwatch()..start();
          expect(
            (await controller.execute(
              LoadQueue(
                commandId: 'bench-load',
                tracks: [track],
                autoplay: true,
              ),
            )).isAccepted,
            isTrue,
          );
          await waitFor(
            () => controller.diagnosticsDocument()['isActuallyPlaying'] == true,
          );
          // ignore: avoid_print -- opt-in benchmark.
          print(
            'STARTUP_BENCH mode=$mode elapsed=${startup.elapsedMicroseconds}us',
          );
          final startupSamples = <int>[startup.elapsedMicroseconds];
          for (var attempt = 1; attempt < 10; attempt++) {
            final watch = Stopwatch()..start();
            await controller.execute(
              LoadQueue(
                commandId: 'startup-$attempt',
                tracks: [track],
                autoplay: true,
              ),
            );
            await waitFor(
              () =>
                  controller.diagnosticsDocument()['isActuallyPlaying'] == true,
            );
            startupSamples.add(watch.elapsedMicroseconds);
          }
          // ignore: avoid_print -- opt-in paired benchmark.
          print(
            'STARTUP_SAMPLES ${jsonEncode({'mode': mode, 'latencyMicros': startupSamples})}',
          );
          final sustainSeconds = int.tryParse(
            Platform.environment['FF_SUSTAIN_SECONDS'] ?? '',
          );
          if (sustainSeconds != null && sustainSeconds > 0) {
            // Exclude startup gating, then observe actual output consumption.
            await Future<void>.delayed(const Duration(seconds: 1));
            final before = controller.diagnosticsDocument()['counters'] as Map;
            final readsBefore = api.inputReadRequests;
            final bytesBefore = api.inputBytesWritten;
            await Future<void>.delayed(Duration(seconds: sustainSeconds));
            final after = controller.diagnosticsDocument()['counters'] as Map;
            final consumed =
                (after['framesConsumed'] as int) -
                (before['framesConsumed'] as int);
            final underruns =
                (after['underruns'] as int) - (before['underruns'] as int);
            expect(consumed, greaterThan(48000 * (sustainSeconds - 0.25)));
            expect(underruns, 0);
            // ignore: avoid_print -- opt-in sustained output measurement.
            print(
              'SUSTAIN_BENCH ${jsonEncode({'mode': mode, 'seconds': sustainSeconds, 'framesConsumed': consumed, 'underruns': underruns, 'ffiReads': api.inputReadRequests - readsBefore, 'ffiBytes': api.inputBytesWritten - bytesBefore, 'inputPool': controller.diagnosticsDocument()['compressedInput']})}',
            );
          }
          for (final paused in [false, true]) {
            if (paused) {
              await controller.execute(const Pause(commandId: 'bench-pause'));
            }
            final samples = <int>[];
            final primedSamples = <int>[];
            final cpuSamples = <int>[];
            final timingBefore =
                controller.diagnosticsDocument()['timing'] as Map;
            final networkBefore = audio.rangeFirstByteMicros;
            final requestsBefore = audio.rangeRequestCount;
            for (var i = 0; i < 30; i++) {
              if (mode == 'network-warm') {
                // Simulate seeking after normal read-ahead has settled.
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              final target = Duration(milliseconds: i.isEven ? 100 : 600);
              final cpuBefore = processCpuMicros();
              final watch = Stopwatch()..start();
              expect(
                (await controller.execute(
                  Seek(commandId: 'bench-$paused-$i', position: target),
                )).isAccepted,
                isTrue,
              );
              var primed = false;
              while (true) {
                final state = jsonDecode(api.snapshot()) as Map;
                final position = int.parse(state['positionMs'].toString());
                final ready =
                    state['phase'] == 'ready' &&
                    (position - target.inMilliseconds).abs() <= 50;
                if (ready && !primed) {
                  primedSamples.add(watch.elapsedMicroseconds);
                  primed = true;
                }
                final counters =
                    controller.diagnosticsDocument()['counters'] as Map;
                final consumed =
                    int.parse(counters['framesConsumed'].toString()) > 0;
                if (ready && (paused || consumed)) break;
                expect(
                  watch.elapsed,
                  lessThan(const Duration(seconds: 5)),
                  reason:
                      'mode=$mode paused=$paused iteration=$i '
                      'target=${target.inMilliseconds} snapshot=$state '
                      'diagnostics=${controller.diagnosticsDocument()}',
                );
                await Future<void>.delayed(const Duration(milliseconds: 1));
              }
              samples.add(watch.elapsedMicroseconds);
              cpuSamples.add(processCpuMicros() - cpuBefore);
            }
            // ignore: avoid_print -- opt-in paired benchmark.
            print(
              'SEEK_SAMPLES ${jsonEncode({'mode': mode, 'paused': paused, 'latencyMicros': samples, 'cpuMicros': cpuSamples})}',
            );
            samples.sort();
            cpuSamples.sort();
            primedSamples.sort();
            final timing = controller.diagnosticsDocument()['timing'] as Map;
            int delta(String key) =>
                (timing[key] as int? ?? 0) - (timingBefore[key] as int? ?? 0);
            // ignore: avoid_print -- opt-in benchmark emits measured results.
            print(
              'SEEK_BENCH format=$extension mode=$mode paused=$paused n=30 P50=${samples[14]}us P95=${samples[28]}us primedP95=${primedSamples[28]}us cpuP50=${cpuSamples[14]}us cpuP95=${cpuSamples[28]}us inputPool=${controller.diagnosticsDocument()['compressedInput']} ffiReads=${api.inputReadRequests} ffiBytes=${api.inputBytesWritten} upstreamFirstByteTotal=${audio.rangeFirstByteMicros - networkBefore}us upstreamRequests=${audio.rangeRequestCount - requestsBefore} reused=${delta('seekDecoderReused')} reopened=${delta('seekDecoderReopened')} fallbacks=${delta('seekDecoderFallbacks')}',
            );
          }
        } finally {
          await subscription.cancel();
          await controller.close();
        }
      },
      skip: Platform.environment['FF_SEEK_BENCHMARK'] != '1'
          ? 'opt-in audio latency benchmark'
          : null,
    );
  }

  for (final ranges in [true, false]) {
    test(
      'database failure keeps network playback working (Range: $ranges)',
      () async {
        await audio.close();
        await cache.close();
        var fail = false;
        cache = PlaybackCache(
          directory,
          beforeDatabaseCommit: () async {
            if (fail) throw StateError('database unavailable');
          },
        );
        await cache.initialize();
        await cache.recovery;
        server.ranges = ranges;
        fail = true;
        await openAudio();
        expect(await read(client, uri), server.data);
        // Local persistence can recover without recreating the resolver.
        fail = false;
        await cache.flushAudioWrites();
        expect(await read(client, uri), server.data);
      },
    );

    test('blocked disk does not stall audio (Range: $ranges)', () async {
      await audio.close();
      await cache.close();
      await server.close();
      server = _Server(
        bytes: List<int>.generate(
          PlaybackCache.maxPendingAudioBytes + 2 * 256 * 1024,
          (i) => i % 251,
        ),
      )..ranges = ranges;
      await server.open();
      source.url = server.url;
      final disk = Completer<void>();
      final started = Completer<void>();
      cache = PlaybackCache(
        directory,
        beforeAudioWrite: () async {
          if (!started.isCompleted) started.complete();
          await disk.future;
        },
      );
      await cache.initialize();
      await cache.recovery;
      await openAudio();
      try {
        final output = read(client, uri);
        await started.future.timeout(const Duration(seconds: 2));
        expect(await output.timeout(const Duration(seconds: 3)), server.data);
        expect(disk.isCompleted, isFalse);
        expect(cache.pendingAudioBytes, greaterThan(0));
        expect(
          cache.pendingAudioBytes,
          lessThanOrEqualTo(PlaybackCache.maxPendingAudioBytes),
        );
        expect(cache.lookup(getKey())!['size'], 0);
      } finally {
        disk.complete();
      }
      await cache.flushAudioWrites();
      expect(cache.pendingAudioBytes, 0);
      expect(
        cache.lookup(getKey())!['size'],
        inExclusiveRange(0, PlaybackCache.maxPendingAudioBytes + 1),
      );
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isFalse);
      final stored = await cache.file(getKey()).readAsBytes();
      for (final interval in PlaybackCache.audioRanges(
        cache.lookup(getKey())!,
      )) {
        expect(
          stored.sublist(interval[0], interval[1]),
          server.data.sublist(interval[0], interval[1]),
        );
      }
      if (ranges) {
        // Fetch dropped holes in bounded requests, then persist them.
        for (var start = 0; start < server.data.length; start += 256 * 1024) {
          expect(
            await read(
              client,
              uri,
              range: 'bytes=$start-${start + 256 * 1024 - 1}',
            ),
            server.data.sublist(start, start + 256 * 1024),
          );
          await cache.flushAudioWrites();
        }
        expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
      }
    });
  }

  test(
    'disk write failures leave audio usable and no readable cache holes',
    () async {
      await audio.close();
      await cache.close();
      cache = PlaybackCache(
        directory,
        beforeAudioWrite: () async {
          throw const FileSystemException('simulated disk failure');
        },
      );
      await cache.initialize();
      await cache.recovery;
      await openAudio();
      expect(await read(client, uri), server.data);
      await cache.flushAudioWrites();
      expect(cache.pendingAudioBytes, 0);
      expect(cache.lookup(getKey())!['size'], 0);
      expect(PlaybackCache.audioRanges(cache.lookup(getKey())!), isEmpty);
    },
  );

  test(
    'downloaded prefix is immediately readable while its fill is still blocked',
    () async {
      server.gate = Completer<void>();
      final first = read(client, uri, range: 'bytes=0-131071');
      final firstResult = expectLater(
        first,
        completion(server.data.sublist(0, 131072)),
      );
      await waitFor(
        () => (cache.lookup(getKey())?['size'] as int? ?? 0) >= 65536,
      );
      final back = await read(
        client,
        uri,
        range: 'bytes=8192-16383',
      ).timeout(const Duration(seconds: 1));
      expect(back, server.data.sublist(8192, 16384));
      expect(server.requests, hasLength(1));
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isFalse);
      server.gate!.complete();
      await firstResult;
    },
  );

  test(
    'cancelled prefix survives restart and resume fetches only missing bytes',
    () async {
      server.gate = Completer<void>();
      expect(
        await read(client, uri, range: 'bytes=0-65535'),
        server.data.sublist(0, 65536),
      );
      await audio.close();
      server.gate!.complete();
      server.gate = null;
      await cache.close();
      cache = PlaybackCache(directory);
      await cache.initialize();
      await cache.recovery;
      await cache.validateEntry(getKey());
      final prefix = PlaybackCache.audioRanges(
        cache.lookup(getKey())!,
      ).single[1];
      expect(prefix, lessThan(server.data.length));
      source.url = server.url.replace(queryParameters: {'renewed': 'yes'});
      server.requests.clear();
      await openAudio();
      expect(await read(client, uri), server.data);
      expect(server.requests, isNotEmpty);
      for (final (start, _, validator) in server.requests) {
        expect(start, greaterThanOrEqualTo(prefix));
        expect(validator, '"v1"');
      }
      await cache.flushAudioWrites();
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
      source.offline = true;
      server.requests.clear();
      expect(
        await read(client, uri, range: 'bytes=104857-120000'),
        server.data.sublist(104857, 120001),
      );
      expect(server.requests, isEmpty);
    },
  );

  test(
    'disjoint ranges leave no readable holes and use actual cached bytes for capacity',
    () async {
      expect(
        await read(client, uri, range: 'bytes=600000-650000'),
        server.data.sublist(600000, 650001),
      );
      await cache.flushAudioWrites();
      final entry = cache.lookup(getKey())!;
      final ranges = PlaybackCache.audioRanges(entry);
      // Closing the reader cancels unread read-ahead. Only bytes received
      // before cancellation are durable; their exact end is schedule-dependent.
      expect(ranges.last[0], 600000);
      expect(ranges.last[1], inInclusiveRange(650001, server.data.length));
      expect(entry['size'], lessThan(server.data.length));
      expect(await cache.file(getKey()).length(), ranges.last[1]);
      server.requests.clear();
      expect(
        await read(client, uri, range: 'bytes=600100-600199'),
        server.data.sublist(600100, 600200),
      );
      expect(server.requests, isEmpty);
      expect(await read(client, uri), server.data);
      await cache.flushAudioWrites();
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
      for (final (start, end, _) in server.requests) {
        expect(
          start < 650001 && end > 600000,
          isFalse,
          reason: 'cached tail must never be requested again',
        );
      }
    },
  );

  test(
    'overlapping readers share a fill; finishing one does not cancel the other',
    () async {
      server.gate = Completer<void>();
      final long = read(client, uri, range: 'bytes=0-131071');
      final result = expectLater(
        long,
        completion(server.data.sublist(0, 131072)),
      );
      await waitFor(
        () => (cache.lookup(getKey())?['size'] as int? ?? 0) >= 65536,
      );
      expect(
        await read(client, uri, range: 'bytes=0-65535'),
        server.data.sublist(0, 65536),
      );
      expect(server.requests, hasLength(1));
      server.gate!.complete();
      await result;
      expect(server.requests, hasLength(1));
    },
  );

  test('readers reuse authorization and share an active fill', () async {
    server.gate = Completer<void>();
    final first = read(client, uri, range: 'bytes=0-131071');
    final firstExpectation = expectLater(
      first,
      completion(server.data.sublist(0, 131072)),
    );
    await waitFor(
      () => (cache.lookup(getKey())?['size'] as int? ?? 0) >= 65536,
    );
    final secondSource = await audio.resolve(
      const TrackId('song'),
      AudioQuality.high,
      NetworkPolicy.preferCache,
    );
    final second = read(
      client,
      await testInputUri(audio, secondSource.uri),
      range: 'bytes=65536-131071',
    );
    final secondExpectation = expectLater(
      second,
      completion(server.data.sublist(65536, 131072)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(server.requests, hasLength(1));
    server.gate!.complete();
    await firstExpectation;
    await secondExpectation;
    expect(server.requests, hasLength(1));
    expect(source.calls, 1);
  });
  test(
    'changed validator refuses to join old and new bytes, then retry rebuilds',
    () async {
      server.gate = Completer<void>();
      await read(client, uri, range: 'bytes=0-65535');
      await audio.close();
      server.gate!.complete();
      server.gate = null;
      await cache.close();
      cache = PlaybackCache(directory);
      await cache.initialize();
      await cache.recovery;
      server.etag = '"v2"';
      server.data.fillRange(0, server.data.length, 99);
      await openAudio();
      await expectLater(read(client, uri), throwsA(anything));
      expect(cache.lookup(getKey())?['size'], 0);
      final retry = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(
        await read(client, await testInputUri(audio, retry.uri)),
        server.data,
      );
      await cache.flushAudioWrites();
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
    },
  );

  test(
    'server ignoring Range returns the correct offset and retains reusable ranges',
    () async {
      server.ranges = false;
      expect(
        await read(client, uri, range: 'bytes=400000-410000'),
        server.data.sublist(400000, 410001),
      );
      await cache.flushAudioWrites();
      server.requests.clear();
      expect(
        await read(client, uri, range: 'bytes=400100-400199'),
        server.data.sublist(400100, 400200),
      );
      expect(server.requests, isEmpty);
    },
  );

  test(
    'server ignoring Range uses one sequential response for a full read',
    () async {
      server.ranges = false;
      expect(await read(client, uri), server.data);
      // One capability probe and one sequential stream, regardless of file size.
      expect(server.requests, hasLength(2));
      await cache.flushAudioWrites();
      expect(PlaybackCache.completeAudio(cache.lookup(getKey())!), isTrue);
      server.requests.clear();
      expect(
        await read(client, uri, range: 'bytes=-100'),
        server.data.sublist(server.data.length - 100),
      );
      expect(server.requests, isEmpty);
    },
  );

  test(
    'online retry with no-store never reads previous cached bytes',
    () async {
      await read(client, uri);
      server.noStore = true;
      server.data.fillRange(0, server.data.length, 99);
      final retry = await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(
        await read(client, await testInputUri(audio, retry.uri)),
        server.data,
      );
    },
  );

  test(
    'sequential no-store fallback supports suffix ranges without caching',
    () async {
      server.ranges = false;
      server.noStore = true;
      expect(
        await read(client, uri, range: 'bytes=-100'),
        server.data.sublist(server.data.length - 100),
      );
      expect(server.requests, hasLength(2));
      expect(cache.lookup(getKey()), isNull);
    },
  );

  test(
    'native FLAC plays between consecutive seeks with background caching',
    () async {
      await audio.close();
      await server.close();
      final realFixture = Platform.environment['FF_SEEK_FLAC_FIXTURE'];
      final fixture = realFixture == null
          ? flacCacheFixture()
          : (await File(realFixture).openRead().fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            ));
      final prefixEnd = realFixture == null ? flacFrameOffset(10) : 1048576;
      server = _Server(bytes: fixture)
        ..gate = Completer<void>()
        ..gateFromByte = prefixEnd
        ..chunkDelay = const Duration(milliseconds: 30);
      await server.open();
      source.url = server.url;
      source.totalBytes = fixture.length;
      await openAudio();
      final key = getKey();
      await cache.prepareAudio(key, fixture.length, 'provider:"v1"', {
        'codec': 'flac',
      }, cache.generation);
      await cache.writeAudioRange(
        key,
        0,
        fixture.sublist(0, prefixEnd),
        cache.generation,
        cache.audioRevision(key),
      );
      await cache.flushAudioWrites();
      final api = openNativeTestLibrary();
      final controller = NativeMediaController(api: api, sourceResolver: audio);
      final connection = await controller.attach();
      final subscription = connection.snapshots.listen((_) {});
      final track = Track(
        id: const TrackId('song'),
        title: 'FLAC',
        artists: const [],
        album: const Album(id: AlbumId('fixture'), title: 'Fixture'),
        duration: Duration.zero,
      );
      try {
        await controller.execute(
          LoadQueue(
            commandId: 'flac-gap-load',
            tracks: [track],
            autoplay: true,
            quality: AudioQuality.high,
          ),
        );
        await waitFor(
          () => realFixture == null
              ? server.requests.any((r) => r.$1 >= prefixEnd)
              : [
                  'ready',
                  'error',
                ].contains(controller.diagnosticsDocument()['phase']),
        );
        server.gate!.complete();
        final targets = realFixture == null
            ? [1200, 2100, 1400, 2000]
            : [104000, 130000, 108000, 134000];
        for (final target in targets) {
          expect(
            (await controller.execute(
              Seek(
                commandId: 'flac-gap-$target',
                position: Duration(milliseconds: target),
              ),
            )).isAccepted,
            isTrue,
          );
          await waitFor(
            () => [
              'ready',
              'error',
            ].contains(controller.diagnosticsDocument()['phase']),
          );
          expect(
            controller.diagnosticsDocument()['phase'],
            'ready',
            reason: '${controller.diagnosticsDocument()}',
          );
          final background = audio.precache(
            const TrackId('song'),
            AudioQuality.high,
            valid: () => true,
            prioritizePlayback: true,
          );
          await Future<void>.delayed(
            Duration(milliseconds: realFixture == null ? 300 : 2000),
          );
          audio.cancelPrecache();
          await background;
          expect(
            controller.diagnosticsDocument()['phase'],
            isNot('error'),
            reason:
                'after playing at $target: ${controller.diagnosticsDocument()}',
          );
        }
        await waitFor(
          () => [
            'ready',
            'error',
          ].contains(controller.diagnosticsDocument()['phase']),
        );
        expect(
          controller.diagnosticsDocument()['phase'],
          'ready',
          reason: '${controller.diagnosticsDocument()}',
        );
        expect(
          int.parse(
            (jsonDecode(api.snapshot()) as Map)['positionMs'].toString(),
          ),
          inInclusiveRange(targets.last - 100, targets.last + 2500),
        );
      } finally {
        await cache.flushAudioWrites();
        final saved = cache.lookup(key);
        if (saved != null) {
          final persisted = await cache.file(key).readAsBytes();
          for (final range in PlaybackCache.audioRanges(saved)) {
            for (var byte = range[0]; byte < range[1]; byte++) {
              if (persisted[byte] != fixture[byte]) {
                fail(
                  'cache byte mismatch at $byte: ${persisted[byte]} != ${fixture[byte]}',
                );
              }
            }
          }
        }
        await subscription.cancel();
        await controller.close();
      }
    },
    skip: findNativeTestLibrary() == null ? 'requires native library' : null,
  );

  test(
    'native FLAC seek inside a colored cache interval needs no remote probes',
    () async {
      await audio.close();
      await server.close();
      final fixture = flacCacheFixture();
      server = _Server(bytes: fixture)
        ..gate = Completer<void>()
        ..gateFromByte = flacFrameOffset(10);
      await server.open();
      source.url = server.url;
      source.totalBytes = fixture.length;
      await openAudio();
      final key = getKey();
      await cache.prepareAudio(key, fixture.length, 'provider:"v1"', {
        'codec': 'flac',
      }, cache.generation);
      for (final range in [
        [0, flacFrameOffset(10)],
        [flacFrameOffset(20), fixture.length],
      ]) {
        await cache.writeAudioRange(
          key,
          range[0],
          fixture.sublist(range[0], range[1]),
          cache.generation,
          cache.audioRevision(key),
        );
      }
      await cache.flushAudioWrites();
      expect(PlaybackCache.completeAudio(cache.lookup(key)!), isFalse);
      final api = openNativeTestLibrary();
      final controller = NativeMediaController(api: api, sourceResolver: audio);
      final connection = await controller.attach();
      final subscription = connection.snapshots.listen((_) {});
      final track = Track(
        id: const TrackId('song'),
        title: 'FLAC',
        artists: const [],
        album: const Album(id: AlbumId('fixture'), title: 'Fixture'),
        duration: Duration.zero,
      );
      try {
        await controller.execute(
          LoadQueue(
            commandId: 'flac-load',
            tracks: [track],
            autoplay: false,
            quality: AudioQuality.high,
          ),
        );
        await waitFor(
          () => server.requests.any((r) => r.$1 >= flacFrameOffset(10)),
        );
        server.requests.clear();
        for (final target in [2400, 2200, 2700, 2100]) {
          final watch = Stopwatch()..start();
          expect(
            (await controller.execute(
              Seek(
                commandId: 'flac-$target',
                position: Duration(milliseconds: target),
              ),
            )).isAccepted,
            isTrue,
          );
          await waitFor(
            () => [
              'ready',
              'error',
            ].contains(controller.diagnosticsDocument()['phase']),
          );
          expect(
            controller.diagnosticsDocument()['phase'],
            'ready',
            reason: '${controller.diagnosticsDocument()}',
          );
          final snapshot = jsonDecode(api.snapshot()) as Map;
          expect(
            int.parse(snapshot['positionMs'].toString()),
            inInclusiveRange(target - 30, target + 30),
          );
          expect(
            server.requests,
            isEmpty,
            reason: 'cached FLAC seek must not binary-search remote holes',
          );
          expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        }
      } finally {
        await subscription.cancel();
        await controller.close();
      }
    },
    skip: findNativeTestLibrary() == null ? 'requires native library' : null,
  );

  test(
    'native seek back into an incomplete cache does not wait for the blocked CDN',
    () async {
      await audio.close();
      await server.close();
      final fixture = wavFixture(seconds: 40);
      server = _Server(bytes: fixture)
        ..gate = Completer<void>()
        ..gateFromByte = 256 * 1024;
      await server.open();
      source.url = server.url;
      await openAudio();
      final track = Track(
        id: const TrackId('ncm-1'),
        title: 'Cache fixture',
        album: const Album(id: AlbumId('fixture'), title: 'Fixture'),
        duration: Duration.zero,
        artists: const [],
      );
      final controller = NativeMediaController(
        api: openNativeTestLibrary(),
        sourceResolver: audio,
      );
      try {
        final connection = await controller.attach();
        final snapshots = connection.snapshots.asBroadcastStream();
        final playing = snapshots
            .firstWhere(
              (s) =>
                  s.status == PlaybackStatus.playing &&
                  s.position > Duration.zero,
            )
            .timeout(const Duration(seconds: 10));
        expect(
          (await controller.execute(
            LoadQueue(commandId: 'range-load', tracks: [track], autoplay: true),
          )).isAccepted,
          isTrue,
        );
        await playing;
        final key = cache.key('A', track.id.value, 'standard');
        expect(PlaybackCache.completeAudio(cache.lookup(key)!), isFalse);
        for (final target in [
          const Duration(milliseconds: 600),
          const Duration(milliseconds: 100),
        ]) {
          final resumed = snapshots
              .skipWhile((s) => s.phase != WirePhase.resolving)
              .firstWhere((s) => s.status == PlaybackStatus.playing)
              .timeout(const Duration(seconds: 2));
          final watch = Stopwatch()..start();
          expect(
            (await controller.execute(
              Seek(
                commandId: 'seek-${target.inMilliseconds}',
                position: target,
              ),
            )).isAccepted,
            isTrue,
          );
          await resumed;
          watch.stop();
          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
          expect(server.gate!.isCompleted, isFalse);
        }
      } finally {
        await controller.close();
      }
    },
    skip: findNativeTestLibrary() == null
        ? 'build the native library or set FF_MEDIA_CORE_LIBRARY for real native seek'
        : null,
  );

  test(
    'no-store can play with bounded memory without creating cache files',
    () async {
      server.noStore = true;
      expect(
        await read(client, uri, range: 'bytes=0-131071'),
        server.data.sublist(0, 131072),
      );
      expect(cache.lookup(getKey()), isNull);
      expect(cache.usedBytes, 0);
    },
  );

  test(
    'malformed Content-Range is rejected instead of marking bytes cached',
    () async {
      server.malformed = true;
      await expectLater(read(client, uri), throwsA(isA<HttpException>()));
      expect(cache.lookup(getKey()), isNull);
    },
  );
}
