import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('references round trip without storing translated text', () {
    final reference = UiMessage.tryDecode(UiMessages.creator3('歌单创建者'))!;
    expect(reference.key, 'creator3');
    expect(reference.arguments, ['歌单创建者']);
    expect(
      UiMessage.fromJson(reference.toJson())!.encode(),
      reference.encode(),
    );
    expect(UiMessage.tryDecode(UiMessages.play)!.key, 'play');
    expect(UiMessage.tryDecode('播放'), isNull);
    expect(UiMessage.tryDecode('A user title'), isNull);
    expect(UiMessage.fromJson({'key': 'invalid key', 'arguments': []}), isNull);
    expect(UiMessage.fromJson({'key': 'play', 'arguments': 'invalid'}), isNull);
  });

  test(
    'optional metadata preserves the existing text constructor interface',
    () {
      const album = Album(
        id: AlbumId('unknown'),
        title: '',
        titleMessage: UiMessage('unknownAlbum'),
      );
      expect(album.titleMessage!.key, 'unknownAlbum');
      expect(album.title, UiMessages.unknownAlbum);
      const artist = Artist(id: ArtistId('1'), name: '接口返回歌手');
      expect(artist.name, '接口返回歌手');
      expect(artist.nameMessage, isNull);
    },
  );

  test(
    'upstream category identifiers are independent of application language',
    () {
      expect(NcmPlaylistCategory.all, '全部');
      expect(NcmPlaylistCategory.official, '官方');
      expect(UiMessage.tryDecode(NcmPlaylistCategory.all), isNull);
    },
  );
}
