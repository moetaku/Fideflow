import 'dart:io';
import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'flac_cache_fixture.dart';
import 'playback_cache_test.dart' show wavFixture;

void main() {
  late Directory directory;
  late PlaybackCache cache;
  late String key;
  late List<int> bytes;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-cache-timeline-');
    cache = PlaybackCache(directory);
    await cache.initialize();
    await cache.recovery;
    key = cache.key('A', 'song', 'lossless');
    bytes = flacCacheFixture();
    await cache.prepareAudio(key, bytes.length, 'v1', {
      'codec': 'flac',
    }, cache.generation);
  });
  tearDown(() async {
    await cache.close();
    await directory.delete(recursive: true);
  });
  Future<void> write(int start, int end) async {
    await cache.writeAudioRange(
      key,
      start,
      bytes.sublist(start, end),
      cache.generation,
      cache.audioRevision(key),
    );
    await cache.flushAudioWrites();
  }

  test(
    'FLAC shows disjoint media ranges and never colors a byte hole',
    () async {
      await write(0, flacFrameOffset(10));
      await write(flacFrameOffset(20), bytes.length);
      final ranges = await cache.cachedPlaybackRanges(
        const TrackId('song'),
        AudioQuality.lossless,
      );
      expect(ranges.map((r) => (r.start, r.end)), [(0.0, .25), (.5, 1.0)]);
      expect(
        await cache.cachedPlaybackRanges(
          const TrackId('song'),
          AudioQuality.high,
        ),
        isEmpty,
      );
      await write(flacFrameOffset(10), flacFrameOffset(20));
      expect(
        (await cache.cachedPlaybackRanges(
          const TrackId('song'),
          AudioQuality.lossless,
        )).single.end,
        1,
      );
      await cache.clear();
      expect(
        await cache.cachedPlaybackRanges(
          const TrackId('song'),
          AudioQuality.lossless,
        ),
        isEmpty,
      );
    },
  );
  test('PCM WAV maps disjoint byte intervals to exact sample times', () async {
    bytes = wavFixture(seconds: 4);
    await cache.prepareAudio(key, bytes.length, 'wav', {}, cache.generation);
    final dataLength = bytes.length - 44;
    await write(0, 44 + dataLength ~/ 4);
    await write(44 + dataLength ~/ 2, 44 + dataLength * 3 ~/ 4);
    final ranges = await cache.cachedPlaybackRanges(
      const TrackId('song'),
      AudioQuality.lossless,
    );
    expect(ranges.map((r) => (r.start, r.end)), [(0.0, .25), (.5, .75)]);
  });

  test(
    'cached bytes without the format header are not promised seekable',
    () async {
      await write(flacFrameOffset(20), bytes.length);
      expect(
        await cache.cachedPlaybackRanges(
          const TrackId('song'),
          AudioQuality.lossless,
        ),
        isEmpty,
      );
      await write(0, flacHeaderBytes);
      expect(
        (await cache.cachedPlaybackRanges(
          const TrackId('song'),
          AudioQuality.lossless,
        )).single.start,
        .5,
      );
    },
  );
}
