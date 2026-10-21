import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('typed identifiers with different domains never compare equal', () {
    expect(const TrackId('42'), equals(const TrackId('42')));
    expect(const TrackId('42'), isNot(equals(const AlbumId('42'))));
  });

  test('Track fee, alias, and objectiveQuality default and retain values', () {
    const track1 = Track(
      id: TrackId('1'),
      title: 'Song 1',
      artists: [],
      album: Album(id: AlbumId('a1'), title: 'Album 1'),
      duration: Duration(minutes: 3),
    );
    expect(track1.fee, equals(TrackFee.unknown));
    expect(track1.alias, isEmpty);
    expect(track1.objectiveQuality, isNull);

    const track2 = Track(
      id: TrackId('2'),
      title: 'Song 2',
      artists: [],
      album: Album(id: AlbumId('a2'), title: 'Album 2'),
      duration: Duration(minutes: 4),
      fee: TrackFee.vip,
      alias: ['Alias A'],
      objectiveQuality: TrackQuality.hiRes,
    );
    expect(track2.fee, equals(TrackFee.vip));
    expect(track2.alias, equals(['Alias A']));
    expect(track2.objectiveQuality, equals(TrackQuality.hiRes));
  });

  test('PlaylistDetail backward compatibility and new entry accessors', () {
    const summary = PlaylistSummary(
      id: PlaylistId('p1'),
      title: 'Test Playlist',
      subtitle: 'Test Subtitle',
      trackCount: 3,
    );
    const trackA = Track(
      id: TrackId('tA'),
      title: 'Track A',
      artists: [],
      album: Album(id: AlbumId('a1'), title: 'Album 1'),
      duration: Duration(minutes: 3),
    );
    const trackB = Track(
      id: TrackId('tB'),
      title: 'Track B',
      artists: [],
      album: Album(id: AlbumId('a1'), title: 'Album 1'),
      duration: Duration(minutes: 3),
      availability: TrackAvailability.none,
    );

    // Legacy style construction
    const legacy = PlaylistDetail(
      summary: summary,
      tracks: [trackA, trackB],
      isPartial: false,
    );
    expect(legacy.tracks.length, equals(2));
    expect(legacy.isPartial, isFalse);
    expect(legacy.missingCount, equals(0));
    expect(
      legacy.queueCandidates.length,
      equals(1),
    ); // trackB availability is none
    expect(legacy.entries.length, equals(2));
    expect(legacy.entries.first.ordinal, equals(0));
    expect(legacy.entries.first.trackId, equals(const TrackId('tA')));

    // Modern style construction with missing/failed entries
    final modern = PlaylistDetail(
      summary: summary,
      header: const PlaylistHeaderMetadata(
        playCount: 1000,
        tags: ['ACG', '流行'],
      ),
      entries: [
        const PlaylistMemberEntry(
          ordinal: 0,
          trackId: TrackId('tA'),
          track: trackA,
          status: MemberStatus.loaded,
        ),
        const PlaylistMemberEntry(
          ordinal: 1,
          trackId: TrackId('tC'),
          track: null,
          status: MemberStatus.missing,
        ),
      ],
      membershipComplete: true,
      detailsComplete: false,
    );
    expect(modern.header.playCount, equals(1000));
    expect(modern.header.tags, equals(['ACG', '流行']));
    expect(modern.missingCount, equals(1));
    expect(modern.isPartial, isTrue);
    expect(modern.loadedTracks.length, equals(1));
    expect(modern.queueCandidates.length, equals(1));
  });

  test('PlaylistAccessVerdict validity and freshness check', () {
    final now = DateTime.now();
    final verdict = PlaylistAccessVerdict(
      namespace: 'ncm',
      target: const PlaylistId('123'),
      state: PlaylistAccessState.publicConfirmed,
      evidenceMode: RequestAuthMode.anonymous,
      evidenceKind: 'anonymousReadOk',
      fetchedAt: now,
      freshUntil: now.add(const Duration(minutes: 5)),
    );
    expect(verdict.isFreshAt(now.add(const Duration(minutes: 2))), isTrue);
    expect(verdict.isFreshAt(now.add(const Duration(minutes: 6))), isFalse);
  });
}
