import 'dart:async';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

void main() {
  group('PlaybackSourceBroker', () {
    test('returns cached source when valid and within safety margin', () async {
      var callCount = 0;
      var now = DateTime(2026, 9, 24, 12, 0, 0);

      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) async {
          callCount++;
          return ResolvedMediaSource(
            trackId: id,
            uri: Uri.parse('https://example.com/song.mp3'),
            actualQuality: quality,
            // Expires in 20 minutes
            expiresAt: now.add(const Duration(minutes: 20)),
          );
        },
      );

      final broker = PlaybackSourceBroker(
        resolver: fakeResolver,
        safetyMargin: const Duration(minutes: 3),
        clock: () => now,
      );

      const trackId = TrackId('track-1');

      // 1. First resolve: hits resolver
      final source1 = await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 1);
      expect(source1.uri.toString(), 'https://example.com/song.mp3');

      // 2. Second resolve 5 minutes later: returns cached (expires in 15 mins > 3 mins)
      now = now.add(const Duration(minutes: 5));
      final source2 = await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 1, reason: 'Cache hit, resolver not called');
      expect(source2, source1);

      // 3. Third resolve 13 minutes later (total 18 mins elapsed, 2 mins left < 3 min safety margin):
      // Must refresh from resolver!
      now = now.add(const Duration(minutes: 13));
      final source3 = await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 2, reason: 'Safety margin breached, refreshed');
      expect(source3.expiresAt, now.add(const Duration(minutes: 20)));
    });

    test('deduplicates concurrent in-flight requests for same track', () async {
      var callCount = 0;
      final completer = Completer<ResolvedMediaSource>();

      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) {
          callCount++;
          return completer.future;
        },
      );

      final broker = PlaybackSourceBroker(resolver: fakeResolver);

      const trackId = TrackId('track-dup');

      final future1 = broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final future2 = broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );

      expect(callCount, 1, reason: 'Deduplicated in-flight request');

      completer.complete(
        ResolvedMediaSource(
          trackId: trackId,
          uri: Uri.parse('https://example.com/dup.mp3'),
          actualQuality: AudioQuality.high,
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        ),
      );

      final s1 = await future1;
      final s2 = await future2;
      expect(s1.uri, s2.uri);
      expect(callCount, 1);
    });

    test('bounds concurrency to maxConcurrent', () async {
      var activeCount = 0;
      var maxActiveObserved = 0;
      final completers = <Completer<ResolvedMediaSource>>[];

      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) {
          activeCount++;
          if (activeCount > maxActiveObserved) {
            maxActiveObserved = activeCount;
          }
          final c = Completer<ResolvedMediaSource>();
          completers.add(c);
          return c.future.whenComplete(() => activeCount--);
        },
      );

      final broker = PlaybackSourceBroker(
        resolver: fakeResolver,
        maxConcurrent: 2,
      );

      // Launch 5 requests simultaneously
      final f1 = broker.resolve(
        const TrackId('t1'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final f2 = broker.resolve(
        const TrackId('t2'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final f3 = broker.resolve(
        const TrackId('t3'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final f4 = broker.resolve(
        const TrackId('t4'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final f5 = broker.resolve(
        const TrackId('t5'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );

      await Future<void>.delayed(Duration.zero);

      // Only 2 should be active!
      expect(activeCount, 2);
      expect(maxActiveObserved, 2);
      expect(completers.length, 2);

      // Complete first 2
      final now = DateTime.now().add(const Duration(minutes: 10));
      completers[0].complete(
        ResolvedMediaSource(
          trackId: const TrackId('t1'),
          uri: Uri.parse('https://1'),
          actualQuality: AudioQuality.high,
          expiresAt: now,
        ),
      );
      completers[1].complete(
        ResolvedMediaSource(
          trackId: const TrackId('t2'),
          uri: Uri.parse('https://2'),
          actualQuality: AudioQuality.high,
          expiresAt: now,
        ),
      );

      await Future<void>.delayed(Duration.zero);

      // Next 2 should now be active
      expect(maxActiveObserved, 2);
      expect(completers.length, 4);

      completers[2].complete(
        ResolvedMediaSource(
          trackId: const TrackId('t3'),
          uri: Uri.parse('https://3'),
          actualQuality: AudioQuality.high,
          expiresAt: now,
        ),
      );
      completers[3].complete(
        ResolvedMediaSource(
          trackId: const TrackId('t4'),
          uri: Uri.parse('https://4'),
          actualQuality: AudioQuality.high,
          expiresAt: now,
        ),
      );

      await Future<void>.delayed(Duration.zero);

      expect(completers.length, 5);
      completers[4].complete(
        ResolvedMediaSource(
          trackId: const TrackId('t5'),
          uri: Uri.parse('https://5'),
          actualQuality: AudioQuality.high,
          expiresAt: now,
        ),
      );

      await Future.wait([f1, f2, f3, f4, f5]);
      expect(maxActiveObserved, 2);
    });

    test('prefetch fills cache without blocking', () async {
      var callCount = 0;
      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) async {
          callCount++;
          return ResolvedMediaSource(
            trackId: id,
            uri: Uri.parse('https://example.com/prefetch.mp3'),
            actualQuality: quality,
            expiresAt: DateTime.now().add(const Duration(minutes: 15)),
          );
        },
      );

      final broker = PlaybackSourceBroker(resolver: fakeResolver);
      const trackId = TrackId('t-pre');

      await broker.prefetch(trackId, AudioQuality.high);
      expect(callCount, 1);

      // Subsequent resolve is cache hit
      final source = await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 1);
      expect(source.uri.toString(), 'https://example.com/prefetch.mp3');
    });

    test('invalidate clears cached track', () async {
      var callCount = 0;
      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) async {
          callCount++;
          return ResolvedMediaSource(
            trackId: id,
            uri: Uri.parse('https://example.com/t.mp3'),
            actualQuality: quality,
            expiresAt: DateTime.now().add(const Duration(minutes: 15)),
          );
        },
      );

      final broker = PlaybackSourceBroker(resolver: fakeResolver);
      const trackId = TrackId('t-inv');

      await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 1);

      broker.invalidate(trackId);

      await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 2, reason: 'Cache was invalidated');
    });

    test('an answer from a previous account is discarded, not cached', () async {
      var callCount = 0;
      final completers = <Completer<ResolvedMediaSource>>[];
      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) {
          callCount++;
          final completer = Completer<ResolvedMediaSource>();
          completers.add(completer);
          return completer.future;
        },
      );

      final broker = PlaybackSourceBroker(resolver: fakeResolver);
      const trackId = TrackId('t-account');
      final expiresAt = DateTime.now().add(const Duration(minutes: 15));

      // Account A starts resolving.
      final accountA = broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      await Future<void>.delayed(Duration.zero);
      expect(callCount, 1);

      // The user signs out — or switches accounts — while A is still in flight.
      broker.beginAccountEpoch(1);

      completers[0].complete(
        ResolvedMediaSource(
          trackId: trackId,
          uri: Uri.parse('https://example.com/account-a.mp3'),
          actualQuality: AudioQuality.high,
          expiresAt: expiresAt,
        ),
      );
      await expectLater(accountA, throwsA(isA<AppError>()));

      // Account B asks for the same song: A's answer is not a cache hit, and A's
      // in-flight request is not this account's to reuse.
      final accountB = broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      await Future<void>.delayed(Duration.zero);
      expect(callCount, 2, reason: 'B resolves again instead of reusing A');
      completers[1].complete(
        ResolvedMediaSource(
          trackId: trackId,
          uri: Uri.parse('https://example.com/account-b.mp3'),
          actualQuality: AudioQuality.high,
          expiresAt: expiresAt,
        ),
      );
      final sourceB = await accountB;
      expect(sourceB.uri.toString(), 'https://example.com/account-b.mp3');

      // B's own answer is what the cache now holds.
      final again = await broker.resolve(
        trackId,
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      expect(callCount, 2, reason: "the new account's answer is cached");
      expect(again.uri.toString(), 'https://example.com/account-b.mp3');
    });

    test('queued work is refused when the account changes', () async {
      final completers = <Completer<ResolvedMediaSource>>[];
      final fakeResolver = _CountingResolver(
        onResolve: (id, quality, policy) {
          final completer = Completer<ResolvedMediaSource>();
          completers.add(completer);
          return completer.future;
        },
      );

      final broker = PlaybackSourceBroker(
        resolver: fakeResolver,
        maxConcurrent: 1,
      );

      final running = broker.resolve(
        const TrackId('t-running'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      final queued = broker.resolve(
        const TrackId('t-queued'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );
      await Future<void>.delayed(Duration.zero);
      expect(completers, hasLength(1), reason: 'the second request waits');

      broker.beginAccountEpoch(1);

      // The queued request never reaches the resolver, and the one already
      // running is not allowed to answer either.
      await expectLater(queued, throwsA(isA<AppError>()));
      completers[0].complete(
        ResolvedMediaSource(
          trackId: const TrackId('t-running'),
          uri: Uri.parse('https://example.com/running.mp3'),
          actualQuality: AudioQuality.high,
          expiresAt: DateTime.now().add(const Duration(minutes: 15)),
        ),
      );
      await expectLater(running, throwsA(isA<AppError>()));
      expect(completers, hasLength(1), reason: 'the queued task was dropped');
    });
  });
}

final class _CountingResolver implements PlaybackSourceResolver {
  _CountingResolver({required this.onResolve});

  final Future<ResolvedMediaSource> Function(
    TrackId id,
    AudioQuality quality,
    NetworkPolicy policy,
  )
  onResolve;

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) => onResolve(id, preferredQuality, networkPolicy);
}
