import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_test_library.dart';
import 'playback_cache_test.dart' show wavFixture;

// The upstream must also remain responsive while the UI isolate is blocked.
Future<void> _serve(List<Object> args) async {
  final ready = args[0] as SendPort;
  final bytes = args[1] as Uint8List;
  final commands = ReceivePort();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var offline = false;
  server.listen((request) async {
    try {
      if (offline) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      final range = RegExp(
        r'bytes=(\d+)-(\d*)',
      ).firstMatch(request.headers.value('range') ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null || range[2]!.isEmpty
          ? bytes.length
          : min(bytes.length, int.parse(range[2]!) + 1);
      request.response.statusCode = range == null ? 200 : 206;
      request.response.headers.set('ETag', '"worker-fixture"');
      if (range != null) {
        request.response.headers.set(
          'Content-Range',
          'bytes $start-${end - 1}/${bytes.length}',
        );
      }
      request.response.contentLength = end - start;
      request.response.add(Uint8List.sublistView(bytes, start, end));
      await request.response.close();
    } catch (_) {
      /* seeks cancel pending responses */
    }
  });
  commands.listen((message) async {
    if (message is List && message[0] == 'offline') {
      offline = true;
      (message[1] as SendPort).send(true);
      return;
    }
    await server.close(force: true);
    commands.close();
    (message as SendPort).send(true);
  });
  ready.send([
    'http://127.0.0.1:${server.port}/fixture.wav',
    commands.sendPort,
  ]);
}

final class _Source implements PlaybackSourceResolver {
  _Source(this.uri);
  final Uri uri;
  bool fullContent = true;
  List<MediaByteRange> allowedRanges = const [];
  int? totalBytes;
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  ) async => ResolvedMediaSource(
    trackId: id,
    uri: uri,
    actualQuality: quality,
    resourceId: 'worker-fixture',
    resourceFree: true,
    fullContent: fullContent,
    allowedByteRanges: allowedRanges,
    totalBytes: totalBytes,
    access: SongAccess.nonVip,
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
}

Future<void> _runReader(List<Object?> args) async {
  final factory = args[0] as AudioInputReader Function(Object?, SendPort);
  final reader = factory(args[1], args[2] as SendPort);
  final commands = ReceivePort();
  (args[3] as SendPort).send(commands.sendPort);
  await for (final message in commands) {
    final data = message as List;
    final reply = data.last as SendPort;
    try {
      if (data[0] == 'close') {
        await reader.close();
        reply.send([true, null]);
        commands.close();
      } else {
        final bytes = Uint8List(data[2] as int);
        final count = await reader.read(data[1] as int, bytes);
        reply.send([true, Uint8List.sublistView(bytes, 0, count)]);
      }
    } catch (error) {
      reply.send([false, '$error']);
    }
  }
}

final class _ReaderHarness {
  _ReaderHarness(this.source);
  final AudioInputWorkerSource source;
  final events = ReceivePort();
  late final SendPort commands;
  Future<void> start() async {
    events.listen(source.onEvent);
    final ready = ReceivePort();
    await Isolate.spawn(_runReader, [
      source.createReader,
      source.configuration,
      events.sendPort,
      ready.sendPort,
    ]);
    commands = await ready.first as SendPort;
    ready.close();
  }

  Future<Object?> _call(List<Object> command) async {
    final response = ReceivePort();
    try {
      commands.send([...command, response.sendPort]);
      final result =
          await response.first.timeout(const Duration(seconds: 5)) as List;
      if (result[0] != true) throw StateError(result[1] as String);
      return result[1];
    } finally {
      response.close();
    }
  }

  Future<Uint8List> read(int offset, int count) async =>
      await _call(['read', offset, count]) as Uint8List;
  Future<void> close() async {
    await _call(['close']);
    await source.onClose();
    events.close();
  }
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('audio worker');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('worker source leases', () {
    late Directory directory;
    late PlaybackCache cache;
    late CachedAudioResolver audio;
    late _Source source;
    late SendPort server;
    Future<void> Function()? beforeWrite;
    final bytes = Uint8List.fromList(wavFixture(seconds: 8));
    setUp(() async {
      final ready = ReceivePort();
      await Isolate.spawn(_serve, [ready.sendPort, bytes]);
      final endpoint = await ready.first as List;
      ready.close();
      server = endpoint[1] as SendPort;
      source = _Source(Uri.parse(endpoint[0] as String));
      directory = await Directory.systemTemp.createTemp('ff-worker-lease-');
      beforeWrite = null;
      cache = PlaybackCache(
        directory,
        beforeAudioWrite: () async => await beforeWrite?.call(),
      );
      await cache.initialize();
      await cache.recovery;
      audio = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => 'A',
        epoch: () => 0,
      );
      await audio.initialize();
    });
    tearDown(() async {
      await audio.close();
      await cache.close();
      final stopped = ReceivePort();
      server.send(stopped.sendPort);
      await stopped.first;
      stopped.close();
      await directory.delete(recursive: true);
    });
    Future<_ReaderHarness> reader() async {
      final source = await audio.resolve(
        const TrackId('probe'),
        AudioQuality.high,
        NetworkPolicy.preferCache,
      );
      final harness = _ReaderHarness(
        await audio.prepareAudioInputWorker(int.parse(source.uri.host)),
      );
      await harness.start();
      addTearDown(harness.close);
      return harness;
    }

    test(
      'network bytes persist through the owner and cache clearing revokes the worker',
      () async {
        final input = await reader();
        final first = await input.read(0, 65536);
        expect(first, bytes.sublist(0, first.length));
        final seek = await input.read(700000, 32768);
        expect(seek, bytes.sublist(700000, 700000 + seek.length));
        final key = cache.key('A', 'probe', 'high');
        await _until(() => (cache.lookup(key)?['size'] as int? ?? 0) > 0);
        await cache.clear();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await expectLater(input.read(0, 100), throwsStateError);
      },
    );
    test('backward seek reuses newly persisted worker bytes', () async {
      final input = await reader();
      var offset = 0;
      while (offset < 256 * 1024) {
        final chunk = await input.read(offset, 65536);
        expect(chunk, bytes.sublist(offset, offset + chunk.length));
        offset += chunk.length;
      }
      final key = cache.key('A', 'probe', 'high');
      await _until(() {
        final entry = cache.lookup(key);
        return entry != null &&
            PlaybackCache.audioRanges(
              entry,
            ).any((range) => range[0] == 0 && range[1] >= 256 * 1024);
      });
      // Release the first fill's memory before seeking back into its disk range.
      await input.read(700000, 32768);
      final offline = ReceivePort();
      server.send(['offline', offline.sendPort]);
      await offline.first;
      offline.close();
      final requests = audio.rangeRequestCount;
      final again = await input.read(0, 32768);
      expect(again, bytes.sublist(0, again.length));
      expect(audio.rangeRequestCount, requests);
    });
    test(
      'pending cache writes do not block reads or become readable',
      () async {
        final gate = Completer<void>();
        final writing = Completer<void>();
        beforeWrite = () async {
          if (!writing.isCompleted) writing.complete();
          await gate.future;
        };
        try {
          final input = await reader();
          final first = await input.read(0, 65536);
          expect(first, bytes.sublist(0, first.length));
          await writing.future;
          expect(gate.isCompleted, isFalse);
          await input.read(700000, 32768);
          final requests = audio.rangeRequestCount;
          final again = await input.read(0, 32768);
          expect(again, bytes.sublist(0, again.length));
          expect(audio.rangeRequestCount, greaterThan(requests));
          final key = cache.key('A', 'probe', 'high');
          expect(PlaybackCache.audioRanges(cache.lookup(key)!), isEmpty);
        } finally {
          gate.complete();
        }
      },
    );
    test('failed cache writes keep network reads working', () async {
      beforeWrite = () async => throw const FileSystemException('test write');
      final input = await reader();
      final first = await input.read(0, 65536);
      expect(first, bytes.sublist(0, first.length));
      await input.read(700000, 32768);
      final requests = audio.rangeRequestCount;
      final again = await input.read(0, 32768);
      expect(again, bytes.sublist(0, again.length));
      expect(audio.rangeRequestCount, greaterThan(requests));
      final key = cache.key('A', 'probe', 'high');
      expect(PlaybackCache.audioRanges(cache.lookup(key)!), isEmpty);
    });
    test('preview bytes stay inside the admitted interval', () async {
      source.fullContent = false;
      source.allowedRanges = const [MediaByteRange(0, 100)];
      source.totalBytes = bytes.length;
      final input = await reader();
      expect(await input.read(0, 1024), bytes.sublist(0, 100));
      await expectLater(input.read(100, 100), throwsStateError);
    });
    test('permission deadline expires while the UI isolate is busy', () async {
      await audio.close();
      final expiry = DateTime.now().add(const Duration(seconds: 2));
      audio = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => 'A',
        epoch: () => 0,
        permissionExpires: (_) => expiry,
      );
      await audio.initialize();
      final input = await reader();
      expect(await input.read(0, 100), bytes.sublist(0, 100));
      final busy = Stopwatch()..start();
      while (DateTime.now().isBefore(
        expiry.add(const Duration(milliseconds: 300)),
      )) {}
      expect(busy.elapsedMilliseconds, greaterThan(500));
      await expectLater(input.read(100, 100), throwsStateError);
    });
  });
  final library = findNativeTestLibrary();
  for (final cached in [false, true]) {
    test(
      'isolated ${cached ? 'cached' : 'network'} input survives a busy UI isolate and seek',
      () async {
        final ready = ReceivePort();
        await Isolate.spawn(_serve, [
          ready.sendPort,
          Uint8List.fromList(wavFixture(seconds: 25)),
        ]);
        final server = await ready.first as List;
        ready.close();
        final directory = await Directory.systemTemp.createTemp('ff-worker-');
        final cache = PlaybackCache(directory);
        await cache.initialize();
        await cache.recovery;
        final audio = CachedAudioResolver(
          upstream: _Source(Uri.parse(server[0] as String)),
          cache: cache,
          account: () => 'A',
          epoch: () => 0,
        );
        await audio.initialize();
        if (cached) {
          expect(
            await audio.precache(
              const TrackId('probe'),
              AudioQuality.standard,
              valid: () => true,
            ),
            isTrue,
          );
          await cache.flushAudioWrites();
          expect(
            PlaybackCache.completeAudio(
              cache.lookup(cache.key('A', 'probe', 'standard'))!,
            ),
            isTrue,
          );
          final offline = ReceivePort();
          (server[1] as SendPort).send(['offline', offline.sendPort]);
          await offline.first;
          offline.close();
        }
        final api = openNativeTestLibrary(libraryPath: library);
        final controller = NativeMediaController(
          api: api,
          sourceResolver: audio,
        );
        final connection = await controller.attach();
        final subscription = connection.snapshots.listen((_) {});
        try {
          const track = Track(
            id: TrackId('probe'),
            title: 'Probe',
            artists: [],
            album: Album(id: AlbumId('probe'), title: 'Probe'),
            duration: Duration(seconds: 25),
          );
          expect(
            (await controller.execute(
              const LoadQueue(
                commandId: 'load',
                tracks: [track],
                autoplay: true,
              ),
            )).isAccepted,
            isTrue,
          );
          await _until(
            () =>
                ((controller.diagnosticsDocument()['counters']
                        as Map)['framesConsumed']
                    as int) >
                96000,
          );
          final before = controller.diagnosticsDocument();
          final watch = Stopwatch()..start();
          // Reproduces the scheduling failure found in the original investigation.
          while (watch.elapsedMilliseconds < 3000) {}
          final after = controller.diagnosticsDocument();
          final b = before['counters'] as Map;
          final a = after['counters'] as Map;
          expect(
            (a['framesConsumed'] as int) - (b['framesConsumed'] as int),
            greaterThan(48000 * 2.8),
          );
          expect(a['underruns'], b['underruns'], reason: '$before -> $after');
          expect((after['output'] as Map)['running'], isTrue);
          expect(
            (await controller.execute(
              const Seek(commandId: 'seek', position: Duration(seconds: 12)),
            )).isAccepted,
            isTrue,
          );
          await _until(
            () =>
                (controller.diagnosticsDocument()['isActuallyPlaying'] == true),
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
          audio.revokePermissions();
          await controller.close();
          await audio.close();
          await cache.flushAudioWrites();
        } finally {
          await subscription.cancel();
          await controller.close();
          await audio.close();
          await cache.close();
          final stopped = ReceivePort();
          (server[1] as SendPort).send(stopped.sendPort);
          await stopped.first;
          stopped.close();
          await directory.delete(recursive: true);
        }
      },
      skip: library == null ? 'build the native library' : false,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
