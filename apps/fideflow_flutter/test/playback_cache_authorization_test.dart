import 'dart:io';
import 'dart:typed_data';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_input_test_bridge.dart';

final class Source implements PlaybackSourceResolver {
  int calls = 0;
  Object? error;
  SongAccess access = SongAccess.nonVip;
  bool free = true;
  bool? fullContent = true;
  List<MediaByteRange> allowed = [];
  Set<String> rights = {};
  DateTime? expiry;
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  ) async {
    calls++;
    if (error != null) throw error!;
    return ResolvedMediaSource(
      trackId: id,
      uri: Uri.parse('http://127.0.0.1:1/unneeded'),
      actualQuality: quality,
      expiresAt: expiry ?? DateTime.now().add(const Duration(hours: 1)),
      resourceId: 'v1',
      normalizationGainDb: 3.0815,
      normalizationPeak: 0.6215,
      access: access,
      resourceFree: free,
      fullContent: fullContent,
      allowedByteRanges: allowed,
      totalBytes: 4,
      requiredEntitlements: rights,
    );
  }
}

void main() {
  late Directory dir;
  late PlaybackCache cache;
  late CachedAudioResolver audio;
  late Source source;
  late HttpClient client;
  var account = 'A';
  var epoch = 0;
  var permissions = 0;
  setUp(() async {
    account = 'A';
    epoch = 0;
    permissions = 0;
    dir = await Directory.systemTemp.createTemp('ff-playback-cache-auth-');
    cache = PlaybackCache(dir);
    await cache.initialize();
    final key = cache.key('A', 'song', 'high');
    await cache.prepareAudio(key, 4, 'provider:v1', {
      'resourceId': 'v1',
    }, cache.generation);
    await cache.writeAudioRange(
      key,
      0,
      [1, 2, 3, 4],
      cache.generation,
      cache.audioRevision(key),
    );
    await cache.flushAudioWrites();
    source = Source();
    audio = CachedAudioResolver(
      upstream: source,
      cache: cache,
      account: () => account,
      epoch: () => epoch,
      permissionEpoch: () => permissions,
    );
    await audio.initialize();
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await audio.close();
    await cache.close();
    await dir.delete(recursive: true);
  });
  Future<ResolvedMediaSource> resolve() => audio.resolve(
    const TrackId('song'),
    AudioQuality.high,
    NetworkPolicy.preferCache,
  );
  Future<int> read(ResolvedMediaSource s) async {
    final response = await (await client.getUrl(
      await testInputUri(audio, s.uri),
    )).close();
    await response.drain<void>();
    return response.statusCode;
  }

  test('completed precache is reused for foreground playback', () async {
    expect(
      await audio.precache(
        const TrackId('song'),
        AudioQuality.high,
        valid: () => true,
      ),
      isTrue,
    );
    expect(source.calls, 1);
    expect(await read(await resolve()), 200);
    expect(source.calls, 1);
  });

  test(
    'complete cached audio survives URL expiry within authorization window',
    () async {
      var time = DateTime.now();
      source.expiry = time.add(const Duration(minutes: 1));
      await audio.close();
      audio = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => account,
        epoch: () => epoch,
        permissionEpoch: () => permissions,
        now: () => time,
      );
      await resolve();
      time = time.add(const Duration(minutes: 2));
      source.error = const SocketException('expired URL must not be refreshed');
      expect(await read(await resolve()), 200);
      expect(source.calls, 1);
      await cache.clear();
      await expectLater(resolve(), throwsA(isA<SocketException>()));
      expect(source.calls, 2);
    },
  );

  test('admitted local input outlives reuse window and CDN expiry', () async {
    var time = DateTime.now();
    source.expiry = time.add(const Duration(minutes: 30));
    await audio.close();
    audio = CachedAudioResolver(
      upstream: source,
      cache: cache,
      account: () => account,
      epoch: () => epoch,
      permissionEpoch: () => permissions,
      now: () => time,
    );
    await resolve();
    time = time.add(const Duration(minutes: 29));
    final local = await resolve();
    final reader = await audio.openAudioInput(int.parse(local.uri.host));
    final bytes = Uint8List(4);
    expect(await reader.read(0, bytes), 4);
    expect(bytes, [1, 2, 3, 4]);
    time = time.add(const Duration(minutes: 2));
    expect(local.expiresAt.isBefore(time), isTrue);
    expect(await reader.read(0, bytes), 4);
    expect(bytes, [1, 2, 3, 4]);
    expect(source.calls, 1);
    await reader.close();
    // Continuing this input does not extend admission of new inputs.
    await resolve();
    expect(source.calls, 2);
  });

  for (final completeCache in [true, false]) {
    test(
      'broker refreshes ${completeCache ? 'local' : 'CDN'} authorization at 30 minutes without interrupting an open input',
      () async {
        final start = DateTime.now();
        var time = start;
        source.expiry = start.add(const Duration(hours: 2));
        if (!completeCache) await cache.clear();
        await audio.close();
        audio = CachedAudioResolver(
          upstream: source,
          cache: cache,
          account: () => account,
          epoch: () => epoch,
          permissionEpoch: () => permissions,
          now: () => time,
        );
        // Precache authorization predates the broker's first foreground read.
        await resolve();
        time = start.add(const Duration(minutes: 10));
        final broker = PlaybackSourceBroker(resolver: audio, clock: () => time);
        Future<ResolvedMediaSource> play(String id) => broker.resolve(
          TrackId(id),
          AudioQuality.high,
          NetworkPolicy.preferCache,
        );
        final playing = await play('song');
        expect(playing.expiresAt, start.add(const Duration(minutes: 30)));
        final reader = await audio.openAudioInput(int.parse(playing.uri.host));
        try {
          if (completeCache) expect(await reader.read(0, Uint8List(4)), 4);
          // Even a broker refresh inside its safety margin must not extend
          // the original authorization window.
          time = start.add(const Duration(minutes: 29));
          final nearExpiry = await play('song');
          expect(nearExpiry.expiresAt, playing.expiresAt);
          expect(source.calls, 1);
          time = start.add(const Duration(minutes: 30));
          if (completeCache) expect(await reader.read(0, Uint8List(4)), 4);
          expect(await reader.length(), 4);
          expect(source.calls, 1);
          await play('other');
          await play('song');
          expect(source.calls, 3);
          // Reauthorizing the next playback also preserves the old reader.
          expect(await reader.length(), 4);
          if (completeCache) expect(await reader.read(0, Uint8List(4)), 4);
        } finally {
          await reader.close();
        }
      },
    );
  }

  for (final invalidation in [
    'account',
    'permissions',
    'revocation',
    'expiry',
  ]) {
    test('local input still checks $invalidation after reuse window', () async {
      var time = DateTime.now();
      final rightsExpiry = time.add(const Duration(minutes: 32));
      source.access = SongAccess.vip;
      source.rights = {'music'};
      await audio.close();
      audio = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => account,
        epoch: () => epoch,
        permissionEpoch: () => permissions,
        permissionExpires: (rights) =>
            rights.contains('music') ? rightsExpiry : null,
        now: () => time,
      );
      await resolve();
      time = time.add(const Duration(minutes: 29));
      final local = await resolve();
      final reader = await audio.openAudioInput(int.parse(local.uri.host));
      time = time.add(const Duration(minutes: 2));
      expect(await reader.read(0, Uint8List(4)), 4);
      switch (invalidation) {
        case 'account':
          account = 'B';
          epoch++;
        case 'permissions':
          permissions++;
        case 'revocation':
          audio.revokeRights({'music'});
        case 'expiry':
          time = rightsExpiry;
      }
      await expectLater(reader.read(0, Uint8List(4)), throwsStateError);
      expect(source.calls, 1);
      await reader.close();
    });
  }

  test('switching back reuses a source with a fresh input token', () async {
    final first = await resolve();
    await audio.resolve(
      const TrackId('other'),
      AudioQuality.high,
      NetworkPolicy.preferCache,
    );
    final again = await resolve();
    expect(source.calls, 2);
    expect(again.uri, isNot(first.uri));
    expect(await read(again), 200);
  });

  test('reuse lasts 30 minutes without extending on each switch', () async {
    var time = DateTime.now();
    source.expiry = time.add(const Duration(hours: 2));
    await audio.close();
    audio = CachedAudioResolver(
      upstream: source,
      cache: cache,
      account: () => account,
      epoch: () => epoch,
      permissionEpoch: () => permissions,
      now: () => time,
    );
    await resolve();
    time = time.add(const Duration(minutes: 29));
    await resolve();
    expect(source.calls, 1);
    time = time.add(const Duration(minutes: 1));
    await resolve();
    expect(source.calls, 2);
  });

  test('source expiry, quality and forced retry bypass reuse', () async {
    await cache.clear();
    source.expiry = DateTime.now().add(const Duration(seconds: 20));
    await resolve();
    await resolve();
    expect(source.calls, 2);
    source.expiry = DateTime.now().add(const Duration(hours: 1));
    await resolve();
    await audio.resolve(
      const TrackId('song'),
      AudioQuality.standard,
      NetworkPolicy.preferCache,
    );
    expect(source.calls, 4);
    await audio.resolve(
      const TrackId('song'),
      AudioQuality.high,
      NetworkPolicy.onlineOnly,
    );
    expect(source.calls, 5);
    await resolve();
    expect(source.calls, 5);
    audio.revokeTrack(const TrackId('song'));
    await resolve();
    expect(source.calls, 6);
  });

  test(
    'permission changes and revocation invalidate reusable sources',
    () async {
      await resolve();
      permissions++;
      await resolve();
      expect(source.calls, 2);
      audio.revokePermissions();
      await resolve();
      expect(source.calls, 3);
    },
  );

  test(
    'online and offline cached sources preserve provider song gain',
    () async {
      final online = await resolve();
      expect(online.normalizationGainDb, 3.0815);
      expect(online.normalizationPeak, 0.6215);
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      final offline = await resolve();
      expect(offline.normalizationGainDb, 3.0815);
      expect(offline.normalizationPeak, 0.6215);
      expect(offline.resourceId, online.resourceId);
    },
  );

  test('legacy cached raw gain is not interpreted as effective gain', () async {
    await resolve();
    await audio.close();
    await cache.close();
    final store = await PlaybackCacheStore.open('${dir.path}/cache.sqlite');
    try {
      final snapshot = await store.load();
      final qualifications = snapshot['qualifications'] as Map;
      final key = qualifications.keys.single as String;
      final legacy = Map<String, dynamic>.from(qualifications[key] as Map)
        ..remove('normalizationFormula');
      await store.applyDelta(PlaybackCacheDelta(qualifications: {key: legacy}));
    } finally {
      await store.close();
    }
    cache = PlaybackCache(dir);
    await cache.initialize();
    audio = CachedAudioResolver(
      upstream: source,
      cache: cache,
      account: () => account,
      epoch: () => epoch,
      permissionEpoch: () => permissions,
    );
    await audio.initialize();
    audio.revokeTrack(const TrackId('song'));
    source.error = const SocketException('offline');
    final offline = await resolve();
    expect(offline.normalizationGainDb, isNull);
    expect(offline.normalizationPeak, isNull);
    audio.revokeTrack(const TrackId('song'));
    source.error = null;
    final fresh = await resolve();
    expect(fresh.normalizationGainDb, 3.0815);
    audio.revokeTrack(const TrackId('song'));
    source.error = const SocketException('offline');
    expect((await resolve()).normalizationGainDb, 3.0815);
  });

  test(
    'cache hit verifies each account and rejects explicitly denied accounts',
    () async {
      expect(await read(await resolve()), 200);
      expect(source.calls, 1);
      account = 'B';
      epoch++;
      audio.revokeTrack(const TrackId('song'));
      source.error = const AppError(
        category: AppErrorCategory.permission,
        code: 'denied',
        retryable: false,
      );
      await expectLater(resolve(), throwsA(isA<AppError>()));
      expect(source.calls, 2);
      expect(cache.usedBytes, 4);
      audio.revokeTrack(const TrackId('song'));
      source.error = null;
      expect(await read(await resolve()), 200);
      expect(source.calls, 3);
      expect(cache.usedBytes, 4);
    },
  );
  test(
    'revoking music leaves independently authorized free input usable',
    () async {
      source.rights = {'music'};
      final restricted = await resolve();
      source.rights = {};
      // Force a new permission verdict, then admit cached bytes with it.
      await audio.resolve(
        const TrackId('song'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final free = await resolve();
      permissions++;
      audio.revokeRights({'music'});
      expect(await read(restricted), 403);
      expect(await read(free), 200);
    },
  );

  test('unknown resource scope cannot admit shared cached bytes', () async {
    source.fullContent = null;
    await expectLater(resolve(), throwsStateError);
    expect(cache.usedBytes, 4);
  });

  test(
    'partial offline cache reports a gap without requesting the CDN',
    () async {
      final key = cache.key('A', 'song', 'high');
      await cache.prepareAudio(
        key,
        4,
        'provider:v1',
        {'resourceId': 'v1'},
        cache.generation,
        reset: true,
      );
      await cache.writeAudioRange(
        key,
        0,
        [1, 2],
        cache.generation,
        cache.audioRevision(key),
      );
      await cache.flushAudioWrites();
      await resolve();
      await audio.close();
      var gaps = 0;
      audio = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => account,
        epoch: () => epoch,
        onOfflineGap: (_) async {
          gaps++;
        },
      );
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      final input = await resolve();
      final request = await client.getUrl(await testInputUri(audio, input.uri));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-3');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 503);
      expect(gaps, 1);
    },
  );

  test('only confirmed nonVip free resources may play offline', () async {
    await resolve();
    audio.revokeTrack(const TrackId('song'));
    source.error = const SocketException('offline');
    expect(await read(await resolve()), 200);
    audio.revokeTrack(const TrackId('song'));
    source.error = null;
    source.access = SongAccess.vip;
    await resolve();
    audio.revokeTrack(const TrackId('song'));
    source.error = const SocketException('offline');
    await expectLater(resolve(), throwsA(isA<SocketException>()));
  });
  test(
    'free song with restricted resource and unknown classification deny offline',
    () async {
      source.free = false;
      await resolve();
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      await expectLater(resolve(), throwsA(isA<SocketException>()));
      audio.revokeTrack(const TrackId('song'));
      source.error = null;
      source.free = true;
      source.access = SongAccess.unknown;
      await resolve();
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      await expectLater(resolve(), throwsA(isA<SocketException>()));
    },
  );
  test(
    'database rebuild cannot recover eligibility from audio bytes',
    () async {
      await resolve();
      await audio.close();
      await cache.close();
      await File('${dir.path}/cache.sqlite').delete();
      cache = PlaybackCache(dir);
      await cache.initialize();
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      audio = CachedAudioResolver(
        upstream: source,
        cache: cache,
        account: () => account,
        epoch: () => epoch,
      );
      await expectLater(resolve(), throwsA(isA<SocketException>()));
      expect(cache.usedBytes, 4);
    },
  );
  test(
    'old tokens are rejected after account or permission generation changes',
    () async {
      final old = await resolve();
      permissions++;
      expect(await read(old), 403);
      final current = await resolve();
      account = 'B';
      epoch++;
      expect(await read(current), 403);
    },
  );
  test(
    'explicit denial removes stale free eligibility instead of allowing fallback',
    () async {
      await resolve();
      audio.revokeTrack(const TrackId('song'));
      source.error = const AppError(
        category: AppErrorCategory.permission,
        code: 'removed',
        retryable: false,
      );
      await expectLater(resolve(), throwsA(isA<AppError>()));
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      await expectLater(resolve(), throwsA(isA<SocketException>()));
    },
  );
  test(
    'trial scope cannot expose complete shared audio or grant offline eligibility',
    () async {
      source.fullContent = false;
      await expectLater(resolve(), throwsStateError);
      source.allowed = [const MediaByteRange(0, 2)];
      final trial = await resolve();
      final request = await client.getUrl(await testInputUri(audio, trial.uri));
      request.headers.set('Range', 'bytes=2-3');
      final response = await request.close();
      expect(response.statusCode, 403);
      await response.drain<void>();
      audio.revokeTrack(const TrackId('song'));
      source.error = const SocketException('offline');
      await expectLater(resolve(), throwsA(isA<SocketException>()));
    },
  );
}
