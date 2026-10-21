import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  group('RemoteNcmProvider - Recommend & PlaylistSquare', () {
    late HttpServer server;
    late RemoteNcmProvider provider;
    late Map<String, Object?> Function(HttpRequest request) handleRequest;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider = RemoteNcmProvider(
        endpoint: StaticProviderEndpoint(
          RemoteProviderConfig(
            baseUrl: 'http://${server.address.address}:${server.port}',
          ),
        ),
      );
      server.listen((request) async {
        final body = handleRequest(request);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await request.response.close();
      });
    });

    tearDown(() async {
      provider.dispose();
      await server.close(force: true);
    });

    test(
      'heart recommendations send seed, liked playlist and active credentials',
      () async {
        provider.setCookie('MUSIC_U=heart-fixture');
        handleRequest = (request) {
          expect(request.uri.path, '/playmode/intelligence/list');
          expect(request.uri.queryParameters['id'], '1001');
          expect(request.uri.queryParameters['pid'], '9001');
          expect(
            request.uri.queryParameters['cookie'],
            contains('MUSIC_U=heart-fixture'),
          );
          return {
            'code': 200,
            'data': [
              {
                'songInfo': {
                  'id': 1002,
                  'name': '心动歌曲',
                  'dt': 180000,
                  'ar': [
                    {'id': 201, 'name': '歌手'},
                  ],
                  'al': {'id': 301, 'name': '专辑'},
                },
              },
              {
                'songInfo': {'id': 'invalid'},
              },
              {'id': 1003},
            ],
          };
        };
        final tracks = await provider.getIntelligenceTracks(
          seed: const TrackId('ncm-1001'),
          playlist: const PlaylistId('ncm-playlist-9001'),
        );
        expect(tracks.map((t) => t.id.value), ['ncm-1002']);
        expect(localizedTestValue(tracks.single.title), '心动歌曲');
      },
    );

    for (final code in [301, 401, 403, 400]) {
      test('home sections classify business error $code by its code', () async {
        handleRequest = (_) => {'code': code, 'message': '401 login required'};
        for (final kind in [
          HomeSectionKind.dailyRecommendations,
          HomeSectionKind.recentPlaylists,
        ]) {
          final section = await provider.getHomeSection(kind);
          final needsAuth = code == 301 || code == 401;
          expect(section.requiresAuth, needsAuth);
          expect(
            section.status,
            needsAuth
                ? HomeSectionStatus.requiresAuth
                : HomeSectionStatus.failed,
          );
        }
      });
    }

    test('heart empty responses and provider errors are surfaced', () async {
      handleRequest = (_) => {'code': 200, 'data': []};
      expect(
        await provider.getIntelligenceTracks(
          seed: const TrackId('ncm-1001'),
          playlist: const PlaylistId('ncm-playlist-9001'),
        ),
        isEmpty,
      );
      handleRequest = (_) => {'code': 301, 'message': 'login required'};
      await expectLater(
        provider.getIntelligenceTracks(
          seed: const TrackId('ncm-1001'),
          playlist: const PlaylistId('ncm-playlist-9001'),
        ),
        throwsA(isA<AppError>()),
      );
    });

    test('getDailySongs parses songs, reasons, and dates', () async {
      handleRequest = (request) {
        expect(request.uri.path, '/recommend/songs');
        return {
          'code': 200,
          'data': {
            'dailySongs': [
              {
                'id': 1001,
                'name': '每日单曲 1',
                'ar': [
                  {'id': 201, 'name': '歌手 A'},
                ],
                'al': {
                  'id': 301,
                  'name': '专辑 A',
                  'picUrl': 'https://example.com/cover1.jpg',
                },
                'dt': 180000,
                'fee': 1,
                'alia': ['别名 1'],
                'hr': {'size': 1000},
                'reason': '超80%人收藏',
              },
            ],
            'recommendReasons': [
              {'songId': 1001, 'reason': '超80%人收藏'},
            ],
          },
        };
      };

      final result = await provider.getDailySongs();
      expect(result.source, DailySongsSource.network);
      expect(result.snapshot.songs.length, 1);
      final entry = result.snapshot.songs.first;
      expect(localizedTestValue(entry.track.title), '每日单曲 1');
      expect(entry.track.fee, TrackFee.vip);
      expect(entry.track.alias, ['别名 1']);
      expect(entry.track.objectiveQuality, TrackQuality.hiRes);
      expect(entry.reason, '超80%人收藏');
    });

    test(
      'getRecommendedPlaylists falls back to /personalized when anonymous',
      () async {
        handleRequest = (request) {
          expect(request.uri.path, '/personalized');
          return {
            'code': 200,
            'result': [
              {
                'id': 5001,
                'name': '大众推荐歌单',
                'picUrl': 'https://example.com/p5001.jpg',
                'playCount': 10000,
                'trackCount': 20,
                'copywriter': '热门精选',
              },
            ],
          };
        };

        final result = await provider.getRecommendedPlaylists();
        expect(result.isFallback, true);
        expect(result.playlists.length, 1);
        expect(localizedTestValue(result.playlists.first.title), '大众推荐歌单');
        expect(result.playlists.first.playCount, 10000);
        expect(result.playlists.first.recommendationText, '热门精选');
      },
    );

    test('getNewSongs parses newsongs response', () async {
      handleRequest = (request) {
        expect(request.uri.path, '/personalized/newsong');
        expect(request.uri.queryParameters['limit'], '5');
        return {
          'code': 200,
          'result': [
            {
              'id': 6001,
              'name': '新歌 1',
              'song': {
                'id': 6001,
                'name': '新歌 1',
                'artists': [
                  {'id': 701, 'name': '新歌手'},
                ],
                'album': {
                  'id': 801,
                  'name': '新专辑',
                  'picUrl': 'https://example.com/new.jpg',
                },
                'duration': 210000,
                'fee': 0,
                'sqMusic': {'size': 2000, 'br': 948239, 'sr': 44100},
              },
            },
          ],
        };
      };

      final tracks = await provider.getNewSongs(limit: 5);
      expect(tracks.length, 1);
      expect(localizedTestValue(tracks.first.title), '新歌 1');
      expect(tracks.first.fee, TrackFee.free);
      expect(tracks.first.objectiveQuality, TrackQuality.lossless);
      expect(tracks.first.audioSpecs.single.quality, TrackQuality.lossless);
      expect(tracks.first.audioSpecs.single.bitrateKbps, 948);
      expect(tracks.first.audioSpecs.single.sampleRateHz, 44100);
    });

    test('getCategoryTree and getHotTags parse tags properly', () async {
      handleRequest = (request) {
        if (request.uri.path == '/playlist/catlist') {
          return {
            'code': 200,
            'all': {'name': '全部', 'category': 0, 'hot': false},
            'categories': {'0': '语种', '1': '风格'},
            'sub': [
              {'name': '华语', 'category': 0, 'hot': true},
              {'name': '流行', 'category': 1, 'hot': true},
            ],
          };
        }
        if (request.uri.path == '/playlist/hot') {
          return {
            'code': 200,
            'tags': [
              {'id': 1, 'name': '华语', 'category': 0},
            ],
          };
        }
        return {'code': 404};
      };

      final tree = await provider.getCategoryTree();
      expect(localizedTestValue(tree.all?.name), '全部');
      expect(tree.categories['0'], '语种');
      expect(tree.sub.length, 2);

      final hotTags = await provider.getHotTags();
      expect(hotTags.length, 1);
      expect(localizedTestValue(hotTags.first.name), '华语');
      expect(hotTags.first.hot, true);
    });

    test(
      'getHighQualityPlaylist and getSquarePlaylists work correctly',
      () async {
        handleRequest = (request) {
          if (request.uri.path == '/top/playlist/highquality') {
            return {
              'code': 200,
              'playlists': [
                {
                  'id': 8801,
                  'name': '精品华语',
                  'coverImgUrl': 'https://example.com/hq.jpg',
                  'tag': '华语',
                  'copywriter': '殿堂之作',
                  'playCount': 500000,
                  'trackCount': 50,
                  'creator': {'nickname': '官方编辑'},
                },
              ],
            };
          }
          if (request.uri.path == '/top/playlist') {
            return {
              'code': 200,
              'total': 100,
              'more': true,
              'playlists': [
                {
                  'id': 8802,
                  'name': '广场歌单 1',
                  'coverImgUrl': 'https://example.com/sq1.jpg',
                  'playCount': 30000,
                  'trackCount': 30,
                  'description': '广场简介',
                  'subscribedCount': 99,
                  'createTime': 1700000000000,
                  'tags': ['华语'],
                  'creator': {
                    'nickname': '达人',
                    'userId': 7,
                    'avatarUrl': 'https://example.com/avatar.jpg',
                  },
                },
              ],
            };
          }
          return {'code': 404};
        };

        final hq = await provider.getHighQualityPlaylist('华语');
        expect(hq, isNotNull);
        expect(localizedTestValue(hq!.summary.title), '精品华语');
        expect(hq.tag, '华语');
        expect(hq.copywriter, '殿堂之作');

        final square = await provider.getSquarePlaylists(cat: '华语', limit: 10);
        expect(square.items.length, 1);
        expect(localizedTestValue(square.items.first.title), '广场歌单 1');
        expect(square.items.first.header.description, '广场简介');
        expect(square.items.first.header.subscribedCount, 99);
        expect(square.items.first.header.creator!.userId, const UserId('7'));
        expect(
          square.items.first.header.creator!.avatarUri.toString(),
          'https://example.com/avatar.jpg',
        );
        expect(square.items.first.header.tags, ['华语']);
        expect(
          square.items.first.header.createTime!.millisecondsSinceEpoch,
          1700000000000,
        );
        expect(square.hasMore, true);
        expect(square.totalCount, 100);
      },
    );

    test(
      'getPlaylistAccess reports publicConfirmed for accessible playlist',
      () async {
        handleRequest = (request) {
          expect(request.uri.path, '/playlist/detail');
          return {
            'code': 200,
            'playlist': {'id': 9901, 'name': '公开歌单'},
          };
        };

        final verdict = await provider.getPlaylistAccess(
          const PlaylistId('ncm-playlist-9901'),
        );
        expect(verdict.state, PlaylistAccessState.publicConfirmed);
        expect(verdict.evidenceMode, RequestAuthMode.anonymous);
      },
    );

    test(
      'getRecentListeningResources parses title, resources, coverUrlList and landingUrl',
      () async {
        provider.setCookie('MUSIC_U=test-cookie');
        handleRequest = (request) {
          expect(request.uri.path, '/recent/listen/list');
          return {
            'code': 200,
            'data': {
              'title': '继续播放与常听',
              'resources': [
                {
                  'resourceId': 12345,
                  'resourceType': 'PLAYLIST',
                  'title': '常听歌单 1',
                  'tag': '歌单',
                  'coverUrlList': ['https://example.com/cover_recent.jpg'],
                  'landingUrl': 'orpheus://playlist/12345',
                  'playOrUpdateTime': 1727589200000,
                  'star': false,
                  'update': false,
                },
                {
                  'resourceId': 67890,
                  'resourceType': 'ALBUM',
                  'title': '常听专辑 1',
                  'tag': '专辑',
                  'coverUrlList': ['https://example.com/album_recent.jpg'],
                  'landingUrl': 'orpheus://album/67890',
                  'playOrUpdateTime': 1727580000000,
                  'star': false,
                  'update': false,
                },
              ],
            },
            'message': 'success',
          };
        };

        final result = await provider.getRecentListeningResources();
        expect(localizedTestValue(result.title), '继续播放与常听');
        expect(result.resources.length, 2);

        final pRes = result.resources[0];
        expect(pRes.resourceId, '12345');
        expect(localizedTestValue(pRes.title), '常听歌单 1');
        expect(pRes.tag, '歌单');
        expect(
          pRes.coverUrl,
          Uri.parse('https://example.com/cover_recent.jpg'),
        );
        expect(pRes.isPlaylist, isTrue);
        expect(pRes.isAlbum, isFalse);
        expect(pRes.playlistId, const PlaylistId('ncm-playlist-12345'));
        expect(pRes.playOrUpdateTime, isNotNull);

        final aRes = result.resources[1];
        expect(aRes.resourceId, '67890');
        expect(localizedTestValue(aRes.title), '常听专辑 1');
        expect(aRes.tag, '专辑');
        expect(
          aRes.coverUrl,
          Uri.parse('https://example.com/album_recent.jpg'),
        );
        expect(aRes.isPlaylist, isFalse);
        expect(aRes.isAlbum, isTrue);
        expect(aRes.albumId, const AlbumId('ncm-album-67890'));
      },
    );
  });

  group('FakeCatalogRepository - Recommend & PlaylistSquare', () {
    final repo = FakeCatalogRepository(latency: Duration.zero);

    test('implements RecommendRepository methods', () async {
      final daily = await repo.getDailySongs();
      expect(daily.snapshot.songs.isNotEmpty, true);

      final recommended = await repo.getRecommendedPlaylists();
      expect(recommended.playlists.isNotEmpty, true);

      final newSongs = await repo.getNewSongs(limit: 2);
      expect(newSongs.length, 2);

      final listen = await repo.getRecentListeningResources();
      expect(listen.resources.isNotEmpty, true);
    });

    test('implements PlaylistSquareRepository methods', () async {
      final tree = await repo.getCategoryTree();
      expect(localizedTestValue(tree.all?.name), '全部歌单');

      final hotTags = await repo.getHotTags();
      expect(hotTags.isNotEmpty, true);

      final hq = await repo.getHighQualityPlaylist('华语');
      expect(hq, isNotNull);

      final square = await repo.getSquarePlaylists(cat: '全部');
      expect(square.items.isNotEmpty, true);
    });

    test('implements getPlaylistAccess', () async {
      final verdict = await repo.getPlaylistAccess(const PlaylistId('test'));
      expect(verdict.state, PlaylistAccessState.publicConfirmed);
    });
  });
}
