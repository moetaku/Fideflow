// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fideflow/app/playback_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> length(String path) async {
  final file = File(path);
  return await file.exists() ? file.length() : 0;
}

int percentile(List<int> samples, double quantile) {
  final sorted = List<int>.of(samples)..sort();
  return sorted[((sorted.length - 1) * quantile).round()];
}

void main() {
  for (final n in [1000, 5000]) {
    for (final multi in [false, true]) {
      test('thin directory $n resources multi=$multi', () async {
        final dir = await Directory.systemTemp.createTemp('ff-thin-benchmark-');
        var cache = PlaybackCache(dir);
        final rssBefore = ProcessInfo.currentRss;
        var messageBytes = 0;
        cache = PlaybackCache(
          dir,
          onDatabaseDelta: (delta) {
            messageBytes += utf8.encode(jsonEncode(delta.toMessage())).length;
          },
        );
        String key(int i) => cache.key(
          'A',
          '${multi ? i ~/ 2 : i}',
          multi && i.isOdd ? 'lossless' : 'high',
        );
        // Realistic logical music size and bounded partial cached data. These
        // bytes are synthetic and do not measure codec or network throughput.
        const total = 5 * 1024 * 1024;
        final bytes = Uint8List(64 * 1024);
        final samples = <int>[];
        var peakWal = 0, indexWritten = 0;
        final timer = Stopwatch()..start();
        try {
          await cache.initialize();
          await cache.recovery;
          for (var i = 0; i < n; i++) {
            final watch = Stopwatch()..start();
            await cache.prepareAudio(key(i), total, 'v1', {}, cache.generation);
            await cache.writeAudioRange(
              key(i),
              0,
              bytes,
              cache.generation,
              cache.audioRevision(key(i)),
            );
            await cache.flushAudioWrites();
            samples.add(watch.elapsedMicroseconds);
            indexWritten += await length(
              '${dir.path}/${cache.lookup(key(i))!['indexName']}',
            );
            if (i % 50 == 0) {
              final wal = await length('${dir.path}/cache.sqlite-wal');
              if (wal > peakWal) peakWal = wal;
            }
          }
          final createMs = timer.elapsedMilliseconds;
          final commitCount = cache.databaseCommits;
          final memorySongs = cache.loadedSongs;
          final rssSteady = ProcessInfo.currentRss;
          final peakRss = ProcessInfo.maxRss;
          await cache.close();
          final dbBytes = await length('${dir.path}/cache.sqlite');
          var fileBytes = 0, fileCount = 0;
          await for (final entity in dir.list()) {
            if (entity is File) {
              fileBytes += await entity.length();
              fileCount++;
            }
          }
          final allocated = await Process.run('du', ['-sk', dir.path]);
          cache = PlaybackCache(dir);
          timer.reset();
          await cache.initialize();
          final startupUs = timer.elapsedMicroseconds;
          timer.reset();
          await cache.recovery;
          final recoveryUs = timer.elapsedMicroseconds;
          expect(cache.loadedSongs, 0);
          timer.reset();
          await cache.validateEntry(key(0));
          final firstOpenUs = timer.elapsedMicroseconds;
          timer.reset();
          for (var i = 0; i < 100; i++) {
            await cache
                .file(key(0))
                .openRead(
                  (i * 431) % (bytes.length - 4096),
                  (i * 431) % (bytes.length - 4096) + 4096,
                )
                .drain<void>();
          }
          final localReadsUs = timer.elapsedMicroseconds;
          final seekCommits = <int>[];
          for (var i = 0; i < 25; i++) {
            timer.reset();
            await cache.writeAudioRange(
              key(0),
              (i + 1) * 128 * 1024,
              bytes,
              cache.generation,
              cache.audioRevision(key(0)),
            );
            await cache.flushAudioWrites();
            seekCommits.add(timer.elapsedMicroseconds);
          }
          print(
            jsonEncode({
              'format': 'thin-v2',
              'resources': n,
              'multiQuality': multi,
              'filesystemCache': 'warm; application restarted',
              'createMs': createMs,
              'publishP50Us': percentile(samples, .5),
              'publishP95Us': percentile(samples, .95),
              'seekPublishP50Us': percentile(seekCommits, .5),
              'seekPublishP95Us': percentile(seekCommits, .95),
              'transactions': commitCount,
              'messageEquivalentBytes': messageBytes,
              'indexWrittenBytes': indexWritten,
              'peakSampledWalBytes': peakWal,
              'databaseBytes': dbBytes,
              'logicalFilesBytes': fileBytes,
              'fileCount': fileCount,
              'allocatedKiB': allocated.exitCode == 0
                  ? '${allocated.stdout}'.trim().split(RegExp(r'\s+')).first
                  : null,
              'effectiveBytes': n * bytes.length,
              'rssBefore': rssBefore,
              'rssSteady': rssSteady,
              'processPeakRss': peakRss,
              'loadedSongs': memorySongs,
              'startupUs': startupUs,
              'backgroundRecoveryUs': recoveryUs,
              'firstSongOpenUs': firstOpenUs,
              '100LocalReadsUs': localReadsUs,
            }),
          );
        } finally {
          await cache.close();
          await dir.delete(recursive: true);
        }
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  }
}
