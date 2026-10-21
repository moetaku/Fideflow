import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_input_test_bridge.dart';
import 'native_test_library.dart';

final class Resolver implements PlaybackSourceResolver {
  Resolver(this.url);
  final Uri url;
  int calls = 0;
  bool offline = false;
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  ) async {
    calls++;
    if (offline) throw const SocketException('offline');
    return ResolvedMediaSource(
      trackId: id,
      uri: url,
      actualQuality: quality,
      resourceId: 'fixture-v1',
      access: SongAccess.nonVip,
      resourceFree: true,
      fullContent: true,
      headers: {'X-Test': 'owned-by-app'},
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }
}

final class Lyrics implements LyricsRepository {
  int calls = 0;
  @override
  Future<LyricTimeline> getLyrics(TrackId id) async {
    calls++;
    return const LyricTimeline(
      status: LyricsStatus.synchronized,
      offset: Duration(milliseconds: 5),
      lines: [
        LyricLine(
          start: Duration.zero,
          end: Duration(seconds: 2),
          text: '原词',
          translation: '译文',
          transliteration: 'roman',
          words: [
            LyricWord(
              start: Duration.zero,
              end: Duration(seconds: 1),
              text: '原',
            ),
          ],
        ),
      ],
    );
  }
}

List<int> wavFixture({int seconds = 4}) {
  final frames = 44100 * seconds;
  final data = ByteData(44 + frames * 4);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 176400, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  return data.buffer.asUint8List();
}

Future<Uri> inputUri(CachedAudioResolver audio, ResolvedMediaSource s) =>
    testInputUri(audio, s.uri);
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
    dir = await Directory.systemTemp.createTemp('ff-playback-cache-');
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
  });
  tearDown(() async {
    await cache.close();
    await dir.delete(recursive: true);
  });

  test(
    'complete files persist; short reads and cancellation never become hits',
    () async {
      final key = cache.key('A', 'song', 'high');
      await cache.record(key, Stream.value([1, 2, 3]), {
        'kind': 'audio',
      }, expectedLength: 3).drain<void>();
      expect(cache.usedBytes, 3);
      final bad = cache.key('A', 'bad', 'high');
      await cache.record(bad, Stream.value([1]), {
        'kind': 'audio',
      }, expectedLength: 2).drain<void>();
      expect(cache.lookup(bad), isNull);
      final cancel = cache.key('A', 'cancel', 'high');
      await cache.record(
        cancel,
        Stream.fromIterable([
          [1],
          [2],
        ]),
        {'kind': 'audio'},
      ).first;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cache.lookup(cancel), isNull);
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      expect(cache.lookup(key)?['size'], 3);
      expect(await cache.file(key).readAsBytes(), [1, 2, 3]);
    },
  );

  test('clear protects reads and deletes their files when released', () async {
    final key = cache.key('A', 'song', 'high');
    await cache.record(key, Stream.value([1, 2]), {
      'kind': 'audio',
    }).drain<void>();
    cache.pin(key);
    await cache.clear();
    expect(await cache.file(key).exists(), isTrue);
    cache.unpin(key);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(cache.lookup(key), isNull);
  });

  test('clearing cache fences reads started before the clear', () async {
    final before = cache.generation;
    await cache.clear();
    final key = cache.key('A', 'old-request', 'high');
    await cache.record(key, Stream.value([1, 2, 3]), {
      'kind': 'audio',
    }, expectedGeneration: before).drain<void>();
    expect(cache.lookup(key), isNull);
    expect(await cache.file(key).exists(), isFalse);
  });

  test('capacity persists and rejects values outside 1–10 GB', () async {
    await cache.setLimit(7);
    expect(() => cache.setLimit(0), throwsRangeError);
    expect(() => cache.setLimit(11), throwsRangeError);
    await cache.close();
    cache = PlaybackCache(dir);
    await cache.initialize();
    await cache.recovery;
    await hydrate(cache, dir);
    expect(cache.limitGb, 7);
  });

  test(
    'old global index is ignored; account removal retains shared audio',
    () async {
      final audio = cache.key('A', 'song', 'high');
      await cache.record(audio, Stream.value([1, 2]), {
        'kind': 'audio',
      }).drain<void>();
      await cache.clear(account: 'A');
      expect(cache.lookup(audio), isNotNull);
      expect(cache.key('B', 'song', 'high'), audio);
      await cache.close();
      await File(
        '${dir.path}/index.json',
      ).writeAsString(jsonEncode({'limitGb': 9, 'entries': {}}));
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      expect(cache.limitGb, 2);
      expect(cache.lookup(audio), isNotNull);
    },
  );

  test(
    'pending audio writes remain protected after the reader finishes',
    () async {
      final key = cache.key('A', 'song', 'high');
      final total = PlaybackCache.gb + 1;
      final prefix = PlaybackCache.gb - 1;
      await cache.setLimit(1);
      await cache.prepareAudio(key, total, 'v1', {}, cache.generation);
      final fileName = cache.lookup(key)!['indexName'] as String;
      final handle = await cache.file(key).open(mode: FileMode.append);
      await handle.truncate(prefix);
      await handle.close();
      // Preparation no longer publishes an empty index implicitly.
      await cache.flushAudioWrites();
      final index = File('${dir.path}/$fileName');
      final doc = await readQuality(index);
      doc['size'] = prefix;
      doc['ranges'] = [
        [0, prefix],
      ];
      await cache.close();
      await writeQuality(index, doc);
      final disk = Completer<void>();
      final started = Completer<void>();
      cache = PlaybackCache(
        dir,
        beforeAudioWrite: () async {
          if (!started.isCompleted) started.complete();
          await disk.future;
        },
      );
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      cache.pin(key);
      try {
        await cache
            .recordAudioRange(
              key,
              Stream.fromIterable([
                [1],
                [2],
              ]),
              prefix,
              total,
              'v1',
              {},
              cache.generation,
            )
            .drain<void>()
            .timeout(const Duration(seconds: 3));
        await started.future.timeout(const Duration(seconds: 3));
      } finally {
        cache.unpin(key);
        disk.complete();
      }
      await cache.flushAudioWrites();
      expect(cache.pendingAudioBytes, 0);
      expect(cache.lookup(key)?['size'], PlaybackCache.gb);
      expect(cache.usedBytes, PlaybackCache.gb);
      expect(PlaybackCache.audioRanges(cache.lookup(key)!), [
        [0, PlaybackCache.gb],
      ]);
      expect(await cache.file(key).length(), PlaybackCache.gb);

      // Completed writes must release their protection so clear can delete them.
      await cache.clear();
      expect(cache.lookup(key), isNull);
      expect(await cache.file(key).exists(), isFalse);
    },
  );

  test(
    'lyrics preserve words, translations and offset across restart',
    () async {
      final remote = Lyrics();
      final repo = CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'A',
      );
      await repo.getLyrics(const TrackId('song'));
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      await cache.recovery;
      await hydrate(cache, dir);
      final restored = await CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'A',
      ).getLyrics(const TrackId('song'));
      expect(remote.calls, 1);
      expect(restored.lines.single.translation, '译文');
      expect(restored.lines.single.words.single.text, '原');
      expect(restored.offset, const Duration(milliseconds: 5));
      await CachedLyricsRepository(
        upstream: remote,
        cache: cache,
        account: () => 'B',
      ).getLyrics(const TrackId('song'));
      expect(remote.calls, 1);
    },
  );

  test(
    'real native player reads host HTTP audio, seeks and replays offline',
    () async {
      final fixture = wavFixture();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = fixture.length;
        request.response.add(fixture);
        await request.response.close();
      });
      final remote = Resolver(
        Uri.parse('http://127.0.0.1:${server.port}/fixture.wav'),
      );
      final audio = CachedAudioResolver(
        upstream: remote,
        cache: cache,
        account: () => 'A',
        epoch: () => 0,
      );
      final api = openNativeTestLibrary();
      final controller = NativeMediaController(api: api, sourceResolver: audio);
      final track = Track(
        id: const TrackId('ncm-1'),
        title: 'Cache fixture',
        album: const Album(id: AlbumId('fixture'), title: 'Fixture'),
        duration: Duration.zero,
        artists: const [],
      );
      try {
        final connection = await controller.attach();
        final snapshots = connection.snapshots.asBroadcastStream();
        Future<PlaybackSnapshot> nextPlaying() => snapshots
            .firstWhere(
              (s) =>
                  s.status == PlaybackStatus.playing &&
                  s.position > Duration.zero,
            )
            .timeout(const Duration(seconds: 15));
        final playing = nextPlaying();
        final loaded = await controller.execute(
          LoadQueue(commandId: 'online', tracks: [track], autoplay: true),
        );
        expect(loaded.isAccepted, isTrue, reason: loaded.errorCode);
        await playing.catchError((Object error) {
          throw StateError(
            'online timeout: ${controller.diagnosticsDocument()}',
          );
        });
        final seek = await controller.execute(
          const Seek(commandId: 'seek', position: Duration(seconds: 2)),
        );
        expect(seek.isAccepted, isTrue, reason: seek.errorCode);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(
          (await controller.getSnapshot()).position,
          greaterThan(const Duration(seconds: 1)),
        );
        await controller.execute(const Stop(commandId: 'stop'));
        // The small WAV has been fully read during probing/priming.
        expect(
          cache.lookup(cache.key('A', track.id.value, 'standard')),
          isNotNull,
        );
        remote.offline = true;
        final again = nextPlaying();
        final replay = await controller.execute(
          LoadQueue(commandId: 'offline', tracks: [track], autoplay: true),
        );
        expect(replay.isAccepted, isTrue, reason: replay.errorCode);
        await again.catchError((Object error) {
          throw StateError(
            'offline timeout: ${controller.diagnosticsDocument()}',
          );
        });
      } finally {
        await controller.close();
        await audio.close();
        await server.close(force: true);
      }
    },
    skip: findNativeTestLibrary() == null
        ? 'build the native library or set FF_MEDIA_CORE_LIBRARY to test real audio output'
        : null,
  );

  test(
    'app requests headers, caches qualities, serves offline Range and fences account changes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      int downloads = 0;
      server.listen((request) async {
        downloads++;
        expect(request.headers.value('X-Test'), 'owned-by-app');
        request.response.contentLength = 5;
        request.response.add([10, 20, 30, 40, 50]);
        await request.response.close();
      });
      final remote = Resolver(
        Uri.parse('http://127.0.0.1:${server.port}/audio'),
      );
      var account = 'A';
      var epoch = 0;
      final audio = CachedAudioResolver(
        upstream: remote,
        cache: cache,
        account: () => account,
        epoch: () => epoch,
      );
      await audio.initialize();
      final client = HttpClient();
      try {
        final high = await audio.resolve(
          const TrackId('song'),
          AudioQuality.high,
          NetworkPolicy.preferCache,
        );
        final first = await (await client.getUrl(
          await inputUri(audio, high),
        )).close();
        expect(await first.fold<List<int>>([], (a, b) => a..addAll(b)), [
          10,
          20,
          30,
          40,
          50,
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await audio
            .resolve(
              const TrackId('song'),
              AudioQuality.lossless,
              NetworkPolicy.preferCache,
            )
            .then((s) async {
              final response = await (await client.getUrl(
                await inputUri(audio, s),
              )).close();
              await response.drain<void>();
            });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        remote.offline = true;
        final cached = await audio.resolve(
          const TrackId('song'),
          AudioQuality.high,
          NetworkPolicy.preferCache,
        );
        final request = await client.getUrl(await inputUri(audio, cached));
        request.headers.set('Range', 'bytes=1-3');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          20,
          30,
          40,
        ]);
        // Each quality probes Range support once, then uses one sequential GET.
        expect(downloads, 4);
        expect(cache.lookup(cache.key('A', 'song', 'high')), isNotNull);
        expect(cache.lookup(cache.key('A', 'song', 'lossless')), isNotNull);
        account = 'B';
        epoch++;
        final refused = await (await client.getUrl(
          await inputUri(audio, cached),
        )).close();
        expect(refused.statusCode, 403);
        await refused.drain<void>();
        await expectLater(
          audio.resolve(
            const TrackId('song'),
            AudioQuality.high,
            NetworkPolicy.preferCache,
          ),
          throwsA(isA<SocketException>()),
        );
        remote.offline = false;
        await audio.resolve(
          const TrackId('song'),
          AudioQuality.high,
          NetworkPolicy.preferCache,
        );
        remote.offline = true;
        await expectLater(
          audio.resolve(
            const TrackId('song'),
            AudioQuality.high,
            NetworkPolicy.preferCache,
          ),
          completes,
        );
        account = 'A';
        epoch++;
        await expectLater(
          audio.resolve(
            const TrackId('song'),
            AudioQuality.high,
            NetworkPolicy.preferCache,
          ),
          completes,
        );
        await cache.clearAccount('B');
        account = 'B';
        epoch++;
        await expectLater(
          audio.resolve(
            const TrackId('song'),
            AudioQuality.high,
            NetworkPolicy.preferCache,
          ),
          throwsA(isA<SocketException>()),
        );
        account = 'A';
        epoch++;
        await expectLater(
          audio.resolve(
            const TrackId('song'),
            AudioQuality.high,
            NetworkPolicy.preferCache,
          ),
          completes,
        );
      } finally {
        client.close(force: true);
        await audio.close();
        await server.close(force: true);
      }
    },
  );
}
