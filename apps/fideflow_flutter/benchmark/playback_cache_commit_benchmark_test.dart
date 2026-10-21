// This benchmark runs with flutter test outside the regular test directory.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'package:fideflow/app/playback_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final n in [1000, 5000]) {
    test('incremental commit $n', () async {
      final dir = await Directory.systemTemp.createTemp(
        'ff-cache-after-bench-',
      );
      var messageBytes = 0;
      final cache = PlaybackCache(
        dir,
        onDatabaseDelta: (delta) {
          messageBytes += utf8.encode(jsonEncode(delta.toMessage())).length;
        },
      );
      try {
        await cache.initialize();
        await cache.recovery;
        final timer = Stopwatch()..start();
        for (var i = 0; i < n; i++) {
          final key = cache.key('A', '$i', 'high');
          await cache.prepareAudio(key, 4, 'v1', {}, cache.generation);
          await cache.writeAudioRange(
            key,
            0,
            [1, 2, 3, 4],
            cache.generation,
            cache.audioRevision(key),
          );
          await cache.flushAudioWrites();
        }
        final createMs = timer.elapsedMilliseconds;
        final initialCommits = cache.databaseCommits;
        final initialMessages = messageBytes;
        final initialEncoded = cache.databaseDocumentsEncoded;
        final indexWrites = cache.indexWrites;
        final key = cache.key('A', '0', 'high');
        timer.reset();
        for (var i = 0; i < 20; i++) {
          cache.lookup(key);
          await cache.flushAudioWrites();
        }
        final repeatedMs = timer.elapsedMilliseconds;
        final latency = <int>[];
        for (var i = 0; i < 25; i++) {
          timer.reset();
          await cache.flushAudioWrites();
          latency.add(timer.elapsedMicroseconds);
        }
        latency.sort();
        // ignore: avoid_print
        print(
          jsonEncode({
            'version': 'incremental',
            'n': n,
            'createMs': createMs,
            'commits': initialCommits,
            'messageBytes': initialMessages,
            'encodedDocuments': initialEncoded,
            'indexWrites': indexWrites,
            'repeatMs': repeatedMs,
            'repeatCommits': cache.databaseCommits - initialCommits,
            'repeatIndexWrites': cache.indexWrites - indexWrites,
            'flushP50Us': latency[12],
            'flushP95Us': latency[23],
          }),
        );
      } finally {
        await cache.close();
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 40)));
  }
}
