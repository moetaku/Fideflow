import 'dart:convert';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:test/test.dart';

void main() {
  test('cached placeholder references retain optional message metadata', () {
    final track = Track(
      id: const TrackId('local:1'),
      title: UiMessages.loadingTrackInformation,
      artists: const [
        Artist(id: ArtistId('unknown'), name: UiMessages.unknownArtist),
      ],
      album: const Album(
        id: AlbumId('unknown'),
        title: UiMessages.unknownAlbum,
      ),
      duration: Duration.zero,
    );
    final map = encodeTrackToMap(track);
    expect((map['titleMessage'] as Map)['key'], 'loadingTrackInformation');
    final restored = decodeTrackFromMap(jsonDecode(jsonEncode(map)))!;
    expect(restored.titleMessage!.key, track.titleMessage!.key);
    expect(restored.album.titleMessage!.key, 'unknownAlbum');
    expect(restored.artists.single.nameMessage!.key, 'unknownArtist');
    expect(restored.title, track.title);
  });

  test('legacy cached content and service text stay unchanged', () {
    final track = decodeTrackFromMap({
      'id': '1',
      'title': '接口歌曲',
      'artists': [
        {'id': '2', 'name': '接口歌手'},
      ],
      'album': {'id': '3', 'title': '接口专辑'},
      'durationMs': 0,
    })!;
    expect(track.title, '接口歌曲');
    expect(track.titleMessage, isNull);
    expect(track.artists.single.name, '接口歌手');
    expect(track.album.title, '接口专辑');
    final playlist = decodePlaylistSummaries(
      '[{"id":"1","title":"服务端歌单","subtitle":"服务端说明"}]',
    ).single;
    expect(playlist.title, '服务端歌单');
    expect(playlist.subtitle, '服务端说明');
  });

  test('playlist summaries and artists round trip resource arguments', () {
    final playlist = PlaylistSummary(
      id: const PlaylistId('1'),
      title: UiMessages.favoriteMusic,
      subtitle: UiMessages.popularTracks(3),
      trackCount: 3,
    );
    final restored = decodePlaylistSummaries(
      encodePlaylistSummaries([playlist]),
    ).single;
    expect(restored.titleMessage!.key, 'favoriteMusic');
    expect(restored.subtitleMessage!.arguments, [3]);
    final artists = decodeArtists(
      encodeArtists(const [
        Artist(id: ArtistId('unknown'), name: UiMessages.unknownArtist),
      ]),
    );
    expect(artists.single.nameMessage!.key, 'unknownArtist');
  });
}
