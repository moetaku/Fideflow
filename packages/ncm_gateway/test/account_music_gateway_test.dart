import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  late HttpServer server;
  late RemoteNcmProvider provider;
  late List<Uri> requests;
  Object? reply;
  bool hold = false;
  Object? Function(Uri)? responseFor;
  setUp(() async {
    requests = [];
    reply = {'code': 200};
    hold = false;
    responseFor = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      if (hold) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(responseFor?.call(request.uri) ?? reply),
      );
      await request.response.close();
    });
    provider = RemoteNcmProvider(
      config: RemoteProviderConfig(baseUrl: 'http://127.0.0.1:${server.port}'),
      timeout: const Duration(milliseconds: 100),
    );
    provider.setCookie('MUSIC_U=test-only');
  });
  tearDown(() async {
    provider.dispose();
    await server.close(force: true);
  });
  test(
    'all mutations send fixed provider route parameters and preserve text',
    () async {
      const playlist = PlaylistId('ncm-playlist-1234');
      const track = TrackId('ncm-5678');
      await provider.setTrackLiked(track, true);
      await provider.setTrackLiked(track, false);
      await provider.setPlaylistSubscribed(playlist, true);
      await provider.setPlaylistSubscribed(playlist, false);
      await provider.updatePlaylistName(playlist, '  名称"\\测试  ');
      await provider.updatePlaylistDescription(playlist, '');
      await provider.updatePlaylistTags(playlist, ['流行', '夜晚']);
      await provider.changePlaylistTracks(playlist, [track], add: true);
      await provider.changePlaylistTracks(playlist, [track], add: false);
      await provider.reorderPlaylist(playlist, [
        track,
        const TrackId('ncm-7890'),
      ]);
      await provider.deletePlaylist(playlist);
      expect(requests.map((u) => u.path), [
        '/like',
        '/like',
        '/playlist/subscribe',
        '/playlist/subscribe',
        '/playlist/name/update',
        '/playlist/desc/update',
        '/playlist/tags/update',
        '/playlist/tracks',
        '/playlist/tracks',
        '/song/order/update',
        '/playlist/delete',
      ]);
      expect(requests[0].queryParameters['like'], 'true');
      expect(requests[1].queryParameters['like'], 'false');
      expect(requests[2].queryParameters['t'], '1');
      expect(requests[3].queryParameters['t'], '2');
      expect(requests[4].queryParameters['name'], '名称"\\测试');
      expect(requests[5].queryParameters['desc'], '');
      expect(requests[6].queryParameters['tags'], '流行;夜晚');
      expect(requests[7].queryParameters['tracks'], '5678');
      expect(requests[8].queryParameters['op'], 'del');
      expect(jsonDecode(requests[9].queryParameters['ids']!), ['5678', '7890']);
      expect(requests[10].queryParameters['id'], '1234');
      expect(
        requests.every(
          (u) => u.queryParameters['cookie'] == 'MUSIC_U=test-only',
        ),
        isTrue,
      );
    },
  );
  test('album collection reads every page with canonical IDs', () async {
    responseFor = (uri) => {
      'code': 200,
      'data': [
        {'id': uri.queryParameters['offset'] == '0' ? 12345 : 67890},
      ],
      'hasMore': uri.queryParameters['offset'] == '0',
    };
    expect(await provider.getSubscribedAlbumIds(), {
      const AlbumId('ncm-album-12345'),
      const AlbumId('ncm-album-67890'),
    });
    expect(requests.map((uri) => uri.path), [
      '/album/sublist',
      '/album/sublist',
    ]);
    expect(requests.map((uri) => uri.queryParameters['offset']), ['0', '1']);
    expect(
      requests.every(
        (uri) => uri.queryParameters['cookie'] == 'MUSIC_U=test-only',
      ),
      isTrue,
    );
  });
  test(
    'album summaries preserve metadata and page order without detail reads',
    () async {
      responseFor = (uri) => {
        'code': 200,
        'data': [
          {
            'id': uri.queryParameters['offset'] == '0' ? 12345 : 67890,
            'name': '收藏专辑',
            'picUrl': 'https://example.com/cover.jpg',
            'size': 12,
            'artists': [
              {'name': '歌手甲'},
              {'name': '歌手乙'},
            ],
          },
        ],
        'hasMore': uri.queryParameters['offset'] == '0',
      };
      final albums = await provider.getSubscribedAlbums();
      expect(albums.map((a) => a.id.value), [
        'ncm-album-12345',
        'ncm-album-67890',
      ]);
      expect(localizedTestValue(albums.first.title), '收藏专辑');
      expect(albums.first.artistName, '歌手甲 / 歌手乙');
      expect(albums.first.trackCount, 12);
      expect(
        albums.first.artworkUri.toString(),
        'https://example.com/cover.jpg',
      );
      expect(requests.every((r) => r.path == '/album/sublist'), isTrue);
    },
  );
  test('empty complete album collection is known', () async {
    reply = {'code': 200, 'data': [], 'hasMore': false};
    expect(await provider.getSubscribedAlbumIds(), isEmpty);
  });
  for (final body in [
    {'code': 200, 'hasMore': false},
    {'code': 200, 'data': []},
    {
      'code': 200,
      'data': [
        {'id': 'foreign'},
      ],
      'hasMore': false,
    },
    {'code': 200, 'data': [], 'hasMore': true},
    {
      'code': 200,
      'data': [
        {'id': 12345},
      ],
      'hasMore': true,
    },
  ]) {
    test('malformed or incomplete album collection throws: $body', () async {
      reply = body;
      await expectLater(
        provider.getSubscribedAlbumIds(),
        throwsA(isA<AppError>()),
      );
      expect(requests.length, lessThanOrEqualTo(2));
    });
  }
  test(
    'album collection failure on a later page does not return a prefix',
    () async {
      responseFor = (uri) => uri.queryParameters['offset'] == '0'
          ? {
              'code': 200,
              'data': [
                {'id': 12345},
              ],
              'hasMore': true,
            }
          : {'code': 502};
      await expectLater(
        provider.getSubscribedAlbumIds(),
        throwsA(isA<AppError>()),
      );
      expect(requests, hasLength(2));
    },
  );
  test('private creation parses ownership and privacy', () async {
    reply = {
      'code': 200,
      'playlist': {
        'id': 1234,
        'name': '私密',
        'privacy': 10,
        'creator': {'userId': 42},
      },
    };
    final p = await provider.createPlaylist('私密', isPrivate: true);
    expect(p.creatorId, const UserId('42'));
    expect(p.privacy, 10);
    expect(requests.single.queryParameters['privacy'], '10');
    expect(requests.single.queryParameters['type'], 'NORMAL');
  });
  test('liked ids are complete and canonical', () async {
    reply = {
      'code': 200,
      'ids': [5678, 7890],
    };
    expect(await provider.getLikedTrackIds(const UserId('ncm-user-42')), {
      const TrackId('ncm-5678'),
      const TrackId('ncm-7890'),
    });
    expect(requests.single.queryParameters['uid'], '42');
  });
  for (final invalid in [
    null,
    [null],
    ['foreign'],
    {'id': 5678},
  ]) {
    test('malformed favorite IDs remain unknown: $invalid', () async {
      reply = {'code': 200, 'ids': invalid};
      await expectLater(
        provider.getLikedTrackIds(const UserId('42')),
        throwsA(isA<AppError>()),
      );
    });
  }
  for (final code in [null, 301, 403, 502]) {
    test('HTTP 200 with business $code is not mutation success', () async {
      reply = {'code': ?code};
      await expectLater(
        provider.setTrackLiked(const TrackId('ncm-5678'), true),
        throwsA(isA<AppError>()),
      );
    });
  }
  test('missing auth and local tracks do not send mutations', () async {
    provider.setCookie(null);
    await expectLater(
      provider.setTrackLiked(const TrackId('ncm-5678'), true),
      throwsA(isA<AppError>()),
    );
    provider.setCookie('MUSIC_U=test-only');
    await expectLater(
      provider.setTrackLiked(const TrackId('local-track'), true),
      throwsA(isA<AppError>()),
    );
    expect(requests, isEmpty);
  });
  test('timeout sends only one mutation and never retries', () async {
    hold = true;
    await expectLater(
      provider.setTrackLiked(const TrackId('ncm-5678'), true),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'network.timeout')),
    );
    expect(requests, hasLength(1));
  });
}
