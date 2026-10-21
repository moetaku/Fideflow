import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

void main() {
  const scope = CacheScope.public(namespace: 'ncm-fixture');
  final fetched = DateTime.utc(2026, 9, 28, 12);

  group('CacheEnvelope', () {
    test('classifies fresh, stale and miss at the window edges', () {
      final envelope = CacheEnvelope.fresh(
        scope: scope,
        at: fetched,
        window: const FreshnessWindow(
          fresh: Duration(minutes: 10),
          maxStale: Duration(hours: 1),
        ),
      );

      expect(envelope.freshnessAt(fetched), CacheFreshness.fresh);
      expect(
        envelope.freshnessAt(
          fetched.add(const Duration(minutes: 9, seconds: 59)),
        ),
        CacheFreshness.fresh,
      );
      expect(
        envelope.freshnessAt(fetched.add(const Duration(minutes: 10))),
        CacheFreshness.stale,
      );
      expect(
        envelope.freshnessAt(fetched.add(const Duration(hours: 1))),
        CacheFreshness.stale,
      );
      expect(
        envelope.freshnessAt(fetched.add(const Duration(hours: 1, seconds: 1))),
        CacheFreshness.miss,
      );
    });

    test('a clock that moved backwards reads as stale, never fresher', () {
      final envelope = CacheEnvelope.fresh(
        scope: scope,
        at: fetched,
        window: const FreshnessWindow(
          fresh: Duration(days: 7),
          maxStale: Duration(days: 90),
        ),
      );

      expect(
        envelope.freshnessAt(fetched.subtract(const Duration(days: 1))),
        CacheFreshness.stale,
      );
    });

    test('revalidation restarts both windows from the success', () {
      final envelope = CacheEnvelope.fresh(
        scope: scope,
        at: fetched,
        window: const FreshnessWindow(
          fresh: Duration(minutes: 10),
          maxStale: Duration(hours: 1),
        ),
      );
      final later = fetched.add(const Duration(minutes: 30));
      final revalidated = envelope.revalidatedAt(
        later,
        CacheContentKind.trackDetail.window,
      );

      expect(revalidated.validatedAt, later);
      expect(revalidated.freshnessAt(later), CacheFreshness.fresh);
      expect(
        revalidated.freshnessAt(later.add(const Duration(days: 7))),
        CacheFreshness.stale,
      );
      expect(
        revalidated.freshnessAt(later.add(const Duration(days: 91))),
        CacheFreshness.miss,
      );
    });

    test('access time never changes freshness', () {
      final envelope = CacheEnvelope.fresh(
        scope: scope,
        at: fetched,
        window: const FreshnessWindow(
          fresh: Duration(minutes: 10),
          maxStale: Duration(hours: 1),
        ),
      );
      final accessed = envelope.accessedAt(
        fetched.add(const Duration(minutes: 30)),
      );

      expect(accessed.lastAccessAt, isNotNull);
      expect(accessed.freshUntil, envelope.freshUntil);
      expect(accessed.staleUntil, envelope.staleUntil);
    });
  });

  group('CacheContentKind', () {
    test('an absent track is believed briefly and never shown stale', () {
      final window = CacheContentKind.absentTrack.window;
      expect(window.fresh, const Duration(minutes: 5));
      expect(window.maxStale, Duration.zero);

      final record = AbsentTrackRecord(
        trackId: const TrackId('ncm-1'),
        envelope: CacheEnvelope.fresh(
          scope: scope,
          at: fetched,
          window: window,
        ),
      );
      expect(record.isBelievableAt(fetched), isTrue);
      expect(
        record.isBelievableAt(fetched.add(const Duration(minutes: 6))),
        isFalse,
      );
    });
  });

  group('CacheGeneration', () {
    test('a late answer is rejected once a newer request started', () {
      const started = CacheGeneration(accountEpoch: 3, cacheGeneration: 7);
      final first = started.nextRequest();
      final second = started.nextRequest().nextRequest();

      expect(first.isCurrentIn(first), isTrue);
      expect(first.isCurrentIn(second), isFalse);
      expect(first.sharesPartitionWith(second), isTrue);
    });

    test('an account or cache generation bump invalidates every result', () {
      const result = CacheGeneration(accountEpoch: 3, cacheGeneration: 7);

      expect(
        result.sharesPartitionWith(result.copyWith(accountEpoch: 4)),
        isFalse,
      );
      expect(
        result.sharesPartitionWith(result.copyWith(cacheGeneration: 8)),
        isFalse,
      );
    });
  });

  group('CachedTrack', () {
    const track = Track(
      id: TrackId('ncm-1'),
      title: '标题',
      artists: [Artist(id: ArtistId('a'), name: '艺人')],
      album: Album(id: AlbumId('al'), title: '专辑'),
      duration: Duration(minutes: 3),
    );

    CachedTrack cachedWith(Map<TrackFieldGroup, CacheEnvelope> groups) =>
        CachedTrack(
          track: track,
          groups: groups,
          envelope: CacheEnvelope.fresh(
            scope: scope,
            at: fetched,
            window: CacheContentKind.trackDetail.window,
          ),
        );

    CacheEnvelope at(Duration ago, CacheContentKind kind) =>
        CacheEnvelope.fresh(
          scope: scope,
          at: fetched.subtract(ago),
          window: kind.window,
        );

    test('a stale display group makes the row stale', () {
      final cached = cachedWith({
        TrackFieldGroup.title: at(
          const Duration(days: 10),
          CacheContentKind.trackDetail,
        ),
        TrackFieldGroup.artists: at(
          Duration.zero,
          CacheContentKind.trackDetail,
        ),
      });

      expect(cached.freshnessAt(fetched), CacheFreshness.stale);
    });

    test('an expired cover never hides a displayable track', () {
      final cached = cachedWith({
        TrackFieldGroup.title: at(Duration.zero, CacheContentKind.trackDetail),
        TrackFieldGroup.artwork: at(
          const Duration(days: 200),
          CacheContentKind.artwork,
        ),
      });

      expect(cached.freshnessAt(fetched), CacheFreshness.fresh);
      expect(
        cached.freshnessOf(TrackFieldGroup.artwork, fetched),
        CacheFreshness.miss,
      );
    });

    test('a display group past its maximum age makes the row a miss', () {
      final cached = cachedWith({
        TrackFieldGroup.title: at(
          const Duration(days: 91),
          CacheContentKind.trackDetail,
        ),
      });

      expect(cached.freshnessAt(fetched), CacheFreshness.miss);
    });

    test('an unknown group is absent rather than empty', () {
      final cached = cachedWith({
        TrackFieldGroup.title: at(Duration.zero, CacheContentKind.trackDetail),
      });

      expect(cached.knows(TrackFieldGroup.album), isFalse);
      expect(
        cached.freshnessOf(TrackFieldGroup.album, fetched),
        CacheFreshness.miss,
      );
    });

    test('a row with no known group is a miss', () {
      expect(cachedWith(const {}).freshnessAt(fetched), CacheFreshness.miss);
    });
  });

  group('CacheResult', () {
    test('a miss carries no value and reports no refresh', () {
      const result = CacheResult<String>.miss();
      expect(result.isHit, isFalse);
      expect(result.value, isNull);
      expect(result.isRefreshing, isFalse);
    });

    test(
      'a stale value that is not being refreshed still needs the network',
      () {
        const result = CacheResult<String>.stale('old');
        expect(result.isHit, isTrue);
        expect(result.needsRefresh, isTrue);

        const refreshing = CacheResult<String>.stale('old', isRefreshing: true);
        expect(refreshing.needsRefresh, isFalse);
      },
    );
  });

  group('CacheScope', () {
    test('the public partition is distinct from an account partition', () {
      const public_ = CacheScope.public(namespace: 'ncm');
      const account = CacheScope(namespace: 'ncm', accountId: '42');

      expect(public_.isPublic, isTrue);
      expect(account.isPublic, isFalse);
      expect(public_ == account, isFalse);
      expect(const CacheScope.public(namespace: 'ncm'), equals(public_));
    });
  });

  group('ArtworkSizeBucket', () {
    test('selects the smallest covering bucket and caps at the largest', () {
      expect(ArtworkSizeBucket.forDisplay(40, 2), ArtworkSizeBucket.px128);
      expect(ArtworkSizeBucket.forDisplay(120, 2), ArtworkSizeBucket.px256);
      expect(ArtworkSizeBucket.forDisplay(300, 2), ArtworkSizeBucket.px1024);
      expect(ArtworkSizeBucket.forDisplay(1024, 3), ArtworkSizeBucket.px1024);
      expect(ArtworkSizeBucket.px512.pixels, 512);
      expect(ArtworkLimits.maxDownloadBytes, 10 * 1024 * 1024);
    });
  });
}
