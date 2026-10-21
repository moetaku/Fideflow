import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  test('demo accounts keep personal music independently', () async {
    final fake = FakeCatalogRepository(latency: Duration.zero);
    const a = UserId('ncm-user-1');
    const b = UserId('ncm-user-2');
    const song = TrackId('ncm-1001');
    fake.activateAccount(a);
    await fake.setTrackLiked(song, false);
    final own = await fake.createPlaylist('Only A', isPrivate: true);
    expect(own.creatorId, a);
    fake.activateAccount(b);
    expect(await fake.getLikedTrackIds(b), contains(song));
    expect(fake.managedUserPlaylists.any((p) => p.id == own.id), isFalse);
    final other = await fake.createPlaylist('Only B');
    expect(other.creatorId, b);
    fake.activateAccount(a);
    expect(await fake.getLikedTrackIds(a), isNot(contains(song)));
    expect(fake.managedUserPlaylists.any((p) => p.id == own.id), isTrue);
    fake.clearAccount(a);
    fake.activateAccount(b);
    expect(fake.managedUserPlaylists.any((p) => p.id == other.id), isTrue);
  });
  test('demo mutation cannot complete into a newly selected account', () async {
    final fake = FakeCatalogRepository(
      latency: const Duration(milliseconds: 20),
    );
    fake.activateAccount(const UserId('ncm-user-1'));
    final playlist = fake.managedUserPlaylists.first.id;
    final pending = fake.changePlaylistTracks(playlist, [
      const TrackId('ncm-1003'),
    ], add: true);
    final refused = expectLater(
      pending,
      throwsA(
        isA<AppError>().having((e) => e.code, 'code', 'auth.epochMismatch'),
      ),
    );
    fake.activateAccount(const UserId('ncm-user-2'));
    await refused;
    expect((await fake.getPlaylist(playlist)).tracks, hasLength(2));
  });
  test(
    'fake mutations update metadata, membership, order and user playlists',
    () async {
      final fake = FakeCatalogRepository(latency: Duration.zero);
      final p = await fake.createPlaylist(' 自建 ', isPrivate: true);
      expect(localizedTestValue(p.title), '自建');
      expect(p.privacy, 10);
      const first = TrackId('ncm-1001');
      const second = TrackId('ncm-1002');
      await fake.changePlaylistTracks(p.id, [first, second], add: true);
      await fake.reorderPlaylist(p.id, [second, first]);
      await fake.updatePlaylistName(p.id, '改名');
      await fake.updatePlaylistDescription(p.id, '');
      await fake.updatePlaylistTags(p.id, ['流行']);
      final detail = await fake.getPlaylist(p.id);
      expect(detail.tracks.map((t) => t.id), [second, first]);
      expect(localizedTestValue(detail.summary.title), '改名');
      expect(detail.header.tags, ['流行']);
      await fake.changePlaylistTracks(p.id, [first], add: false);
      expect((await fake.getPlaylist(p.id)).tracks.single.id, second);
      await fake.deletePlaylist(p.id);
      expect(fake.managedUserPlaylists.any((s) => s.id == p.id), isFalse);
      await expectLater(fake.getPlaylist(p.id), throwsA(isA<AppError>()));
    },
  );
  test(
    'fake favorites and liked playlist stay coherent after mutation',
    () async {
      final fake = FakeCatalogRepository(latency: Duration.zero);
      const user = UserId('ncm-user-fake');
      const track = TrackId('ncm-1001');
      await fake.setTrackLiked(track, false);
      final ids = await fake.getLikedTrackIds(user);
      final detail = await fake.getPlaylist(fake.fakeLikedSummary.id);
      expect(ids, isNot(contains(track)));
      expect(detail.tracks.map((t) => t.id).toSet(), ids);
      expect(fake.fakeLikedSummary.trackCount, ids.length);
      await fake.setTrackLiked(track, true);
      expect(await fake.getLikedTrackIds(user), contains(track));
    },
  );
  test(
    'fake subscription changes are visible on subsequent detail reads',
    () async {
      final fake = FakeCatalogRepository(latency: Duration.zero);
      const id = PlaylistId('playlist-night-drive');
      await fake.setPlaylistSubscribed(id, false);
      expect(
        (await fake.getPlaylist(id)).accountState!.subscription,
        SubscriptionEvidence.unsubscribed,
      );
      await fake.setPlaylistSubscribed(id, true);
      expect(
        (await fake.getPlaylist(id)).accountState!.subscription,
        SubscriptionEvidence.subscribed,
      );
    },
  );
}
