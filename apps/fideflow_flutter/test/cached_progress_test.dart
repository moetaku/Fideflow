import 'dart:io';
import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow/features/player/cached_progress.dart';
import 'package:fideflow/features/player/player_progress.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'flac_cache_fixture.dart';

void main() {
  testWidgets(
    'cached bars show holes, update on clear and seek at the selected time',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ff-cached-progress-'),
      ))!;
      late PlaybackCache cache;
      final seeks = <Duration>[];
      await tester.runAsync(() async {
        cache = PlaybackCache(dir);
        await cache.initialize();
        await cache.recovery;
        final bytes = flacCacheFixture();
        final key = cache.key('A', 'song', 'lossless');
        await cache.prepareAudio(key, bytes.length, 'v1', {}, cache.generation);
        for (final range in [
          [0, flacFrameOffset(10)],
          [flacFrameOffset(20), bytes.length],
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
        await cache.cachedPlaybackRanges(
          const TrackId('song'),
          AudioQuality.lossless,
        );
      });
      final snapshot = PlaybackSnapshot(
        sessionId: 's',
        sessionRevision: 1,
        queueRevision: 1,
        status: PlaybackStatus.paused,
        playWhenReady: false,
        currentIndex: 0,
        position: const Duration(milliseconds: 500),
        duration: const Duration(seconds: 4),
        quality: const PlaybackQuality(
          level: AudioQuality.lossless,
          confirmed: true,
        ),
        queue: [
          Track(
            id: const TrackId('song'),
            title: 'Fixture',
            artists: const [],
            album: const Album(id: AlbumId('a'), title: 'a'),
            duration: const Duration(seconds: 4),
          ),
        ],
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 720,
                  height: 100,
                  child: Column(
                    children: [
                      PlayerProgress(
                        snapshot: snapshot,
                        cache: cache,
                        onSeek: seeks.add,
                      ),
                      TopPlayerProgressBar(
                        snapshot: snapshot,
                        cache: cache,
                        onSeek: seeks.add,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        final painted = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is CachedProgressPainter,
        );
        final painter =
            tester.widget<CustomPaint>(painted).painter
                as CachedProgressPainter;
        expect(painter.ranges.map((r) => (r.start, r.end)), [
          (0.0, .25),
          (.5, 1.0),
        ]);
        final rect = tester.getRect(find.byType(TopPlayerProgressBar));
        await tester.tapAt(Offset(rect.left + rect.width * .8, rect.center.dy));
        await tester.pump();
        expect(seeks.single, const Duration(milliseconds: 3200));
        await tester.runAsync(() async {
          final bytes = flacCacheFixture();
          final key = cache.key('A', 'song', 'lossless');
          await cache.writeAudioRange(
            key,
            flacFrameOffset(10),
            bytes.sublist(flacFrameOffset(10), flacFrameOffset(20)),
            cache.generation,
            cache.audioRevision(key),
          );
          await cache.flushAudioWrites();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        expect(
          (tester.widget<CustomPaint>(painted).painter as CachedProgressPainter)
              .ranges
              .map((r) => (r.start, r.end)),
          [(0.0, 1.0)],
        );
        await tester.runAsync(cache.clear);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(
          (tester.widget<CustomPaint>(painted).painter as CachedProgressPainter)
              .ranges,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await cache.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );
}
