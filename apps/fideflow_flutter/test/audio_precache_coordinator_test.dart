import 'dart:async';
import 'dart:io';

import 'package:fideflow/app/audio_precache_coordinator.dart';
import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow/app/playback_permissions.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

Track track(String id) => Track(
  id: TrackId(id),
  title: id,
  artists: const [],
  album: const Album(id: AlbumId('album'), title: 'album'),
  duration: const Duration(minutes: 3),
);
PlaybackSnapshot snapshot(
  List<String> ids,
  int current, {
  PlaybackMode mode = PlaybackMode.listLoop,
  String? intelligence,
}) => PlaybackSnapshot(
  sessionId: 'session',
  sessionRevision: 1,
  queueRevision: 1,
  status: PlaybackStatus.playing,
  queue: ids.map(track).toList(),
  currentIndex: current,
  position: Duration.zero,
  playWhenReady: true,
  mode: mode,
  intelligenceSessionId: intelligence,
);

final class _Source implements PlaybackSourceResolver {
  final calls = <String>[];
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  ) async {
    calls.add('${id.value}:${quality.name}');
    return ResolvedMediaSource(
      trackId: id,
      uri: Uri.parse('file:///already-local'),
      actualQuality: null,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('next range follows effective shuffle order and wraps once', () {
    final state = snapshot(['c', 'a', 'd', 'b'], 2, mode: PlaybackMode.shuffle);
    expect(precacheTracks(state, 5).map((t) => t.id.value), [
      'd',
      'b',
      'c',
      'a',
    ]);
    expect(precacheTracks(state, 1).map((t) => t.id.value), ['d', 'b']);
  });
  test('repeat one prepares manual next; sequential and heart never wrap', () {
    expect(
      precacheTracks(
        snapshot(['a', 'b'], 1, mode: PlaybackMode.repeatOne),
        1,
      ).map((t) => t.id.value),
      ['b', 'a'],
    );
    expect(
      precacheTracks(
        snapshot(['a', 'b'], 1, mode: PlaybackMode.sequential),
        5,
      ).map((t) => t.id.value),
      ['b'],
    );
    expect(
      precacheTracks(
        snapshot(['a', 'b'], 1, intelligence: 'heart'),
        5,
      ).map((t) => t.id.value),
      ['b'],
    );
  });
  test('whole queue starts with current and deduplicates audio resources', () {
    expect(
      precacheTracks(
        snapshot(['a', 'b', 'c', 'b'], 1),
        0,
      ).map((t) => t.id.value),
      ['b', 'c', 'a'],
    );
  });

  test('defaults and selection persist; clear keeps preferences', () async {
    final dir = await Directory.systemTemp.createTemp('precache-settings-');
    var cache = PlaybackCache(dir);
    try {
      await cache.initialize();
      expect(cache.autoCacheEnabled, isTrue);
      expect(cache.autoCacheCount, 1);
      await cache.setAutoCache(enabled: false, count: 0);
      await cache.clear();
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      expect(cache.autoCacheEnabled, isFalse);
      expect(cache.autoCacheCount, 0);
      await cache.setAutoCache(count: 20);
      await cache.close();
      cache = PlaybackCache(dir);
      await cache.initialize();
      expect(cache.autoCacheCount, 20);
      await expectLater(cache.setAutoCache(count: 21), throwsArgumentError);
      await expectLater(cache.setAutoCache(count: -1), throwsArgumentError);
    } finally {
      await cache.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'coordinator reacts to settings, quality and clear without polling completed work',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'precache-coordinator-',
      );
      final cache = PlaybackCache(dir);
      final source = _Source();
      final resolver = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => 'A',
        epoch: () => 0,
      );
      final media = FakeMediaController();
      final quality = QualityController(
        media: media,
        initial: AudioQuality.high,
      );
      final permissions = PlaybackPermissions(
        account: () => 'A',
        accountEpoch: () => 0,
        load: () async => [],
        onRevoked: (_) async {},
      );
      final coordinator = AudioPrecacheCoordinator(
        media: media,
        quality: quality,
        resolver: resolver,
        cache: cache,
        permissions: permissions,
      );
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        await coordinator.initialize();
        await media.execute(
          LoadQueue(
            commandId: 'load',
            tracks: ['a', 'b', 'c'].map(track).toList(),
            quality: AudioQuality.high,
          ),
        );
        final state = await media.getSnapshot();
        expect(state.queue.length, 3);
        expect(state.currentIndex, 0);
        final activity = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => resolver.onAudioActivity?.call(),
        );
        try {
          await settle();
        } finally {
          activity.cancel();
        }
        expect(source.calls, ['a:high', 'b:high']);
        await settle();
        expect(source.calls.length, 2);
        await cache.setAutoCache(count: 0);
        await settle();
        expect(source.calls.sublist(2), ['c:high']);
        await cache.setAutoCache(count: 1);
        await settle();
        await cache.setAutoCache(count: 2);
        await settle();
        expect(source.calls.length, 3);
        await cache.clear();
        await settle();
        expect(source.calls.length, 3);
        await cache.setAutoCache(enabled: false);
        await quality.select(AudioQuality.standard);
        await settle();
        expect(source.calls.length, 3);
        await cache.setAutoCache(enabled: true, count: 2);
        await settle();
        expect(source.calls.sublist(3), [
          'a:standard',
          'b:standard',
          'c:standard',
        ]);
        final completed = source.calls.length;
        await media.execute(
          const Seek(
            commandId: 'seek-forward',
            position: Duration(seconds: 60),
          ),
        );
        await settle();
        expect(source.calls.length, completed + 1);
        expect(source.calls.last, 'a:standard');
        await media.execute(
          const Seek(commandId: 'seek-back', position: Duration(seconds: 10)),
        );
        await settle();
        expect(source.calls.length, completed + 2);
        expect(source.calls.last, 'a:standard');
      } finally {
        await coordinator.dispose();
        permissions.dispose();
        await quality.dispose();
        await resolver.close();
        await cache.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
