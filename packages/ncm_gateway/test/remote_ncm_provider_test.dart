import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

/// One song of a fixture playlist, identified by its position in it.
Map<String, Object?> _playlistSong(int index) => {
  'name': '歌曲 $index',
  'id': 100000 + index,
  'dt': 200000,
  'ar': [
    {'id': 11127, 'name': 'Beyond'},
  ],
  'al': {'id': 34185, 'name': '华语金曲 $index'},
};

void main() {
  group('extractNcmTrackId', () {
    test('accepts a bare numeric id', () {
      expect(extractNcmTrackId('3340137263'), '3340137263');
      expect(extractNcmTrackId(' 3340137263\n'), '3340137263');
    });

    test('reads the id query parameter of a share URL', () {
      expect(
        extractNcmTrackId('https://music.163.com/song?id=3340137263&userid=1'),
        '3340137263',
      );
    });

    test('reads a path-segment id of the short share shape', () {
      expect(
        extractNcmTrackId('https://music.163.com/song/3340137263/'),
        '3340137263',
      );
    });

    test('pulls the id out of wrapped share prose', () {
      expect(
        extractNcmTrackId('分享一首歌 https://music.163.com/song?id=3340137263 快听'),
        '3340137263',
      );
    });

    test('reads the id out of the hash route a share uses', () {
      expect(
        extractNcmTrackId('https://music.163.com/#/song?id=3340137263'),
        '3340137263',
      );
      expect(
        extractNcmTrackId(
          'https://y.music.163.com/m/song?id=3340137263&uct2=x',
        ),
        '3340137263',
      );
    });

    test('refuses a link that is not a song, whatever number it carries', () {
      for (final input in [
        // A playlist id is a number too. Treating one as a song would resolve
        // the wrong thing instead of saying the input is unsupported.
        'https://music.163.com/playlist?id=3340137263',
        'https://music.163.com/album?id=3340137263',
        'https://music.163.com/artist?id=3340137263',
        'https://music.163.com/djradio?id=3340137263',
        'https://music.163.com/discover/toplist?id=3340137263',
      ]) {
        expect(
          () => extractNcmTrackId(input),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'ncm.invalidId',
            ),
          ),
          reason: '$input is not a song link',
        );
      }
    });

    test('refuses a numeric path on somebody else’s host', () {
      for (final input in [
        'https://example.com/song/3340137263',
        'https://music.163.com.evil.test/song?id=3340137263',
        'https://example.com/?id=3340137263',
      ]) {
        expect(
          () => extractNcmTrackId(input),
          throwsA(isA<AppError>()),
          reason: '$input is not this service',
        );
      }
    });

    test('rejects prose without any id and a too-short number', () {
      expect(
        () => extractNcmTrackId('没有链接的一句话'),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'ncm.invalidId',
          ),
        ),
      );
      expect(() => extractNcmTrackId('123'), throwsA(isA<AppError>()));
    });
  });

  group('RemoteNcmProvider', () {
    late HttpServer server;
    late RemoteNcmProvider provider;
    late RemoteNcmProvider closer;
    final requests = <Uri>[];

    /// The detail body of the song the live service returned for 3340137263.
    final detailBody = jsonEncode({
      'songs': [
        {
          'name': '靛青宇宙',
          'id': 3340137263,
          'dt': 147900,
          'ar': [
            {'id': 61908633, 'name': '鸣潮先约电台'},
            {'id': 122477658, 'name': '飞行雪绒'},
          ],
          'al': {
            'id': 358645146,
            'name': '飞行雪绒',
            'picUrl': 'https://p4.music.126.net/x/109951172603135736.jpg',
          },
        },
      ],
      'code': 200,
    });

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider = RemoteNcmProvider(
        config: RemoteProviderConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      closer = provider;
    });

    tearDown(() async {
      closer.dispose();
      await server.close(force: true);
    });

    /// Answers every request with [status] and [body].
    ///
    /// [statusOf] overrides the status per request, for the routes that have to
    /// fail while another still answers; [setCookieOf] adds `Set-Cookie` headers,
    /// for the routes whose cookies only exist there.
    void serve(
      Object? Function(Uri request) body, {
      int status = 200,
      int Function(Uri request)? statusOf,
      List<String> Function(Uri request)? setCookieOf,
    }) {
      server.listen((request) async {
        requests.add(request.requestedUri);
        final payload = body(request.requestedUri);
        request.response.statusCode =
            statusOf?.call(request.requestedUri) ?? status;
        request.response.headers.contentType = ContentType.json;
        for (final cookie
            in setCookieOf?.call(request.requestedUri) ?? const <String>[]) {
          request.response.headers.add(HttpHeaders.setCookieHeader, cookie);
        }
        request.response.write(
          payload is String ? payload : jsonEncode(payload),
        );
        await request.response.close();
      });
    }

    test(
      'normalization metadata follows the adopted resource and retains zero',
      () async {
        Object? gain = -10.2522;
        Object? closedGain = -6;
        Object? peak = 1;
        serve(
          (uri) => uri.path == '/song/detail'
              ? detailBody
              : {
                  'code': 200,
                  'data': [
                    {
                      'id': 3340137263,
                      'url': 'https://cdn.test/song.mp3',
                      'level': 'standard',
                      'type': 'mp3',
                      'gain': gain,
                      'closedGain': closedGain,
                      'peak': peak,
                      'expi': 1200,
                    },
                  ],
                },
        );
        Future<ResolvedMediaSource> resolve() => provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.high,
          NetworkPolicy.onlineOnly,
        );
        final first = await resolve();
        expect(first.actualQuality, AudioQuality.standard);
        expect(first.normalizationGainDb, closeTo(-4.2522, 1e-10));
        expect(first.normalizationPeak, 1);
        gain = 1.5004;
        peak = 0;
        final boosted = await resolve();
        expect(boosted.normalizationGainDb, closeTo(7.5004, 1e-10));
        expect(boosted.normalizationPeak, isNull);
        gain = 0;
        closedGain = 0;
        peak = 0;
        final zero = await resolve();
        expect(zero.normalizationGainDb, 0.0);
        expect(zero.normalizationPeak, isNull);
        gain = '3.0815';
        peak = -1;
        final invalid = await resolve();
        expect(invalid.normalizationGainDb, isNull);
        expect(invalid.normalizationPeak, isNull);
        gain = 1.5004;
        for (final bad in <Object?>[null, '-6', true]) {
          closedGain = bad;
          expect((await resolve()).normalizationGainDb, isNull);
        }
        gain = 1e308;
        closedGain = -1e308;
        expect((await resolve()).normalizationGainDb, isNull);
      },
    );

    test(
      'all song-list entrances retain id-matched external privileges',
      () async {
        final songs = [_playlistSong(0), _playlistSong(1)];
        final privileges = [
          {'id': 100001, 'maxBrLevel': 'lossless'},
          {'id': 100000, 'maxbr': 192000},
          {'id': 999999, 'maxBrLevel': 'hires'},
        ];
        serve(
          (uri) => switch (uri.path) {
            '/playlist/detail' => {
              'playlist': {
                'id': 123456,
                'name': 'Playlist',
                'trackCount': 2,
                'tracks': songs,
              },
              'privileges': privileges,
            },
            '/playlist/track/all' => {'songs': songs, 'privileges': privileges},
            '/cloudsearch' => {
              'result': {'songs': songs, 'songCount': 2},
              'privileges': privileges,
            },
            '/artists' => {
              'artist': {'id': 123456, 'name': 'Artist'},
              'hotSongs': songs,
              'privileges': privileges,
            },
            '/recommend/songs' => {
              'data': {'dailySongs': songs, 'privileges': privileges},
            },
            '/personalized/newsong' => {
              'result': [
                for (final song in songs)
                  {
                    'song': song,
                    'privilege': privileges.firstWhere(
                      (p) => p['id'] == song['id'],
                    ),
                  },
              ],
            },
            '/playmode/intelligence/list' => {
              'data': [
                for (final song in songs)
                  {
                    'songInfo': song,
                    'privilege': privileges.firstWhere(
                      (p) => p['id'] == song['id'],
                    ),
                  },
              ],
            },
            _ => {},
          },
        );
        void check(Iterable<Track> tracks) => expect(
          tracks.map((t) => t.maxPotentialQuality),
          [TrackQuality.high, TrackQuality.lossless],
        );
        check(
          (await provider.getPlaylist(
            const PlaylistId('ncm-playlist-123456'),
          )).tracks,
        );
        check(
          (await provider.getPlaylistTracks(
            const PlaylistId('ncm-playlist-123456'),
          )).items,
        );
        check(
          (await provider.searchTracks(
            const SearchQuery(keywords: 'song'),
          )).items,
        );
        check(
          (await provider.search(
            const SearchQuery(keywords: 'song'),
          )).items.whereType<TrackItem>().map((item) => item.track),
        );
        check(
          (await provider.getArtist(
            const ArtistId('ncm-artist-123456'),
          )).tracks,
        );
        check(
          (await provider.getDailySongs()).snapshot.songs.map(
            (entry) => entry.track,
          ),
        );
        check(await provider.getNewSongs());
        check(
          await provider.getIntelligenceTracks(
            seed: const TrackId('ncm-100000'),
            playlist: const PlaylistId('ncm-playlist-123456'),
          ),
        );
      },
    );

    test(
      'malformed fields and legacy 192k masters do not invent upper tiers',
      () async {
        serve(
          (uri) => {
            'songs': [
              {
                ..._playlistSong(0),
                'hr': false,
                'sq': 'invalid',
                'h': [],
                'mMusic': {'bitrate': 192000},
              },
              {
                ..._playlistSong(1),
                'bMusic': {'bitrate': 128000},
              },
            ],
          },
        );
        final tracks = await provider.getPlaylistTracks(
          const PlaylistId('ncm-playlist-123456'),
        );
        expect(tracks.items.map((t) => t.maxPotentialQuality), [
          TrackQuality.high,
          TrackQuality.standard,
        ]);
      },
    );

    test(
      'external privileges never replace or fill an embedded privilege',
      () async {
        serve(
          (uri) => {
            'songs': [
              {
                ..._playlistSong(0),
                'privilege': {'maxBrLevel': 'lossless', 'fee': 0},
              },
              {
                ..._playlistSong(1),
                'privilege': {'fee': 0},
              },
              _playlistSong(2),
            ],
            'privileges': [
              {'id': 100000, 'maxBrLevel': null, 'fee': 1},
              {'id': 100001, 'maxBrLevel': 'hires', 'fee': 1},
              {'id': 100002, 'maxBrLevel': 'exhigh'},
            ],
          },
        );
        final result = await provider.getPlaylistTracks(
          const PlaylistId('ncm-playlist-123456'),
        );
        expect(result.items.map((t) => t.maxPotentialQuality), [
          TrackQuality.lossless,
          TrackQuality.unknown,
          TrackQuality.high,
        ]);
        expect(result.items.first.fee, TrackFee.free);
        expect(result.items[1].fee, TrackFee.free);
      },
    );

    test(
      'album master privileges and lossless bitrate do not invent Hi-Res',
      () async {
        serve(
          (uri) => {
            'album': {'id': 73985, 'name': 'Album', 'size': 4},
            'songs': [
              {
                ..._playlistSong(0),
                'hr': null,
                'sq': {'br': 1073570, 'sr': 44100},
                'privilege': {'maxBrLevel': 'jymaster', 'maxbr': 999000},
              },
              {
                ..._playlistSong(1),
                'hr': null,
                'sq': {'br': 703271},
                'privilege': {'maxBrLevel': 'hires'},
              },
              {
                ..._playlistSong(2),
                'hr': null,
                'sq': null,
                'h': {'br': 320000},
                'privilege': {'maxbr': 1500000},
              },
              {
                ..._playlistSong(3),
                'hr': {'br': 2300000},
                'sq': {'br': 999000},
                'privilege': {'maxBrLevel': 'lossless'},
              },
            ],
          },
        );
        final album = await provider.getAlbum(const AlbumId('ncm-album-73985'));
        expect(album.tracks.map((t) => t.maxPotentialQuality), [
          TrackQuality.lossless,
          TrackQuality.lossless,
          TrackQuality.high,
          TrackQuality.hiRes,
        ]);
        expect(requests.map((r) => r.path), ['/album']);
      },
    );

    test(
      'album songs use top-level privileges without extra requests',
      () async {
        serve(
          (uri) => {
            'album': {'id': 34185, 'name': 'Album', 'size': 2},
            'songs': [_playlistSong(0), _playlistSong(1)],
            'privileges': [
              {'id': 100001, 'maxBrLevel': 'lossless'},
              {'id': 100000, 'maxBrLevel': 'exhigh'},
            ],
          },
        );
        final album = await provider.getAlbum(const AlbumId('ncm-album-34185'));
        expect(album.tracks.map((t) => t.maxPotentialQuality), [
          TrackQuality.high,
          TrackQuality.lossless,
        ]);
        expect(requests.map((r) => r.path), ['/album']);
      },
    );

    test(
      'album enriches only songs with missing quality and retains album metadata',
      () async {
        serve((uri) {
          if (uri.path == '/album') {
            return {
              'album': {'id': 34185, 'name': 'Album', 'size': 2},
              'songs': [
                _playlistSong(0),
                {
                  ..._playlistSong(1),
                  'sq': {'br': 999000},
                },
              ],
            };
          }
          return {
            'songs': [
              {'id': 100000, 'name': 'Detail name'},
            ],
            'privileges': [
              {'id': 100000, 'maxBrLevel': 'standard'},
            ],
          };
        });
        final album = await provider.getAlbum(const AlbumId('ncm-album-34185'));
        expect(album.tracks.map((t) => t.maxPotentialQuality), [
          TrackQuality.standard,
          TrackQuality.lossless,
        ]);
        expect(localizedTestValue(album.tracks.first.title), '歌曲 0');
        expect(localizedTestValue(album.tracks.first.album.title), '华语金曲 0');
        expect(requests.map((r) => r.path), ['/album', '/song/detail']);
        expect(requests.last.queryParameters['ids'], '100000');
      },
    );

    test(
      'failed album quality enrichment retains its playable track list',
      () async {
        serve(
          (uri) => uri.path == '/album'
              ? {
                  'album': {'id': 34185, 'name': 'Album', 'size': 1},
                  'songs': [_playlistSong(0)],
                }
              : {'code': 500},
          statusOf: (uri) => uri.path == '/album' ? 200 : 500,
        );
        final album = await provider.getAlbum(const AlbumId('ncm-album-34185'));
        expect(album.tracks, hasLength(1));
        expect(localizedTestValue(album.tracks.first.title), '歌曲 0');
      },
    );

    test('songs preserve five artists, zero ids and translations', () async {
      final songs = <Map<String, Object?>>[
        {
          'id': 28612684,
          'name': 'Song one',
          'alias': <String>[],
          'ar': [
            {'id': 16501, 'name': 'Artist 1'},
            {'id': 16282, 'name': 'Artist 2'},
            {'id': 16812, 'name': 'Artist 3'},
            {'id': 16402, 'name': 'Artist 4'},
            {'id': 17918, 'name': 'Artist 5'},
          ],
          'al': {'id': 2848391, 'name': 'Album one'},
        },
        {
          'id': 2676687608,
          'name': 'Song two',
          'transNames': ['译名'],
          'ar': [
            {'id': 47877241, 'name': 'Band'},
            {'id': 0, 'name': 'Virtual'},
          ],
          'al': {'id': 263373004, 'name': 'Album two'},
        },
      ];
      serve(
        (uri) => {
          'code': 200,
          'songs': [
            songs.singleWhere(
              (song) => '${song['id']}' == uri.queryParameters['ids'],
            ),
          ],
        },
      );
      final first = await provider.getTrack(const TrackId('ncm-28612684'));
      expect(first.artists.map((a) => a.id.value), [
        'ncm-artist-16501',
        'ncm-artist-16282',
        'ncm-artist-16812',
        'ncm-artist-16402',
        'ncm-artist-17918',
      ]);
      expect(first.alias, isEmpty);
      expect(first.translationNames, isEmpty);
      expect(first.album.id.value, 'ncm-album-2848391');
      final second = await provider.getTrack(const TrackId('ncm-2676687608'));
      expect(second.translationNames, ['译名']);
      expect(second.artists.last.name, 'Virtual');
      expect(second.artists.last.id.value, 'ncm-artist-0');
      expect(second.album.id.value, 'ncm-album-263373004');
    });

    test(
      'new and legacy names are filtered and merged without inventing album ids',
      () async {
        serve(
          (_) => {
            'songs': [
              {
                'id': 28612684,
                'name': 'Title',
                'alia': [' Alias ', '', 42],
                'alias': ['Alias', 'Other'],
                'tns': ['译名', null, ' '],
                'transNames': ['译名', 'Translation'],
                'ar': [
                  {'id': 0, 'name': 'First'},
                  {'id': 0, 'name': 'Second'},
                  {'name': 'Missing'},
                  {'id': 12, 'name': 'A / B & C'},
                ],
                'al': {
                  'name': 'Album',
                  'alias': ['Not a song alias'],
                },
              },
            ],
          },
        );
        final track = await provider.getTrack(const TrackId('ncm-28612684'));
        expect(track.alias, ['Alias', 'Other']);
        expect(track.translationNames, ['译名', 'Translation']);
        expect(track.artists.map((a) => a.name), [
          'First',
          'Second',
          'Missing',
          'A / B & C',
        ]);
        expect(track.artists[2].id.value, 'ncm-artist-unknown');
        expect(track.album.id.value, 'ncm-album-unknown');
      },
    );

    test('shares concurrent detail reads but refreshes later reads', () async {
      serve((_) => detailBody);
      final tracks = await Future.wait([
        provider.getTrack(const TrackId('ncm-3340137263')),
        provider.getTrack(const TrackId('3340137263')),
        provider.getTracks([const TrackId('ncm-3340137263')]),
      ]);
      expect(tracks, hasLength(3));
      expect(requests.where((r) => r.path == '/song/detail'), hasLength(1));
      await provider.getTrack(const TrackId('ncm-3340137263'));
      expect(requests.where((r) => r.path == '/song/detail'), hasLength(2));
    });

    test('maps song/detail into the domain track', () async {
      serve((_) => detailBody);

      final track = await provider.getTrack(const TrackId('ncm-3340137263'));

      expect(localizedTestValue(track.title), '靛青宇宙');
      expect(track.duration, const Duration(milliseconds: 147900));
      expect(
        localizedTestValue([for (final artist in track.artists) artist.name]),
        ['鸣潮先约电台', '飞行雪绒'],
      );
      expect(localizedTestValue(track.album.title), '飞行雪绒');
      expect(
        track.album.artworkUri.toString(),
        'https://p4.music.126.net/x/109951172603135736.jpg',
      );
      final request = requests.single;
      expect(request.path, '/song/detail');
      expect(request.queryParameters['ids'], '3340137263');
    });

    test('getLyrics reads word-level content from /lyric/new', () async {
      serve(
        (_) => {
          'lrc': {'lyric': '[00:01.00]line level fallback'},
          'yrc': {'lyric': '[1000,2000](1000,900,0)word(1900,1100,0)ed'},
          'tlyric': {'lyric': '[00:01.00]translated'},
          'nolyric': false,
          'code': 200,
        },
      );

      final sheet = await provider.getLyrics(const TrackId('ncm-3340137263'));

      expect(sheet.isWordLevel, isTrue);
      expect(sheet.lines.single.text, 'worded');
      expect(sheet.lines.single.translation, 'translated');
      expect(requests.single.path, '/lyric/new');
      expect(requests.single.queryParameters['id'], '3340137263');
    });

    test(
      'getLyrics falls back to /lyric when /lyric/new is not served',
      () async {
        // A deployment that predates the word-level route answers 404 there.
        serve(
          (request) => request.path == '/lyric'
              ? {
                  'lrc': {'lyric': '[00:01.00]only line level'},
                  'code': 200,
                }
              : {'code': 404},
          statusOf: (request) => request.path == '/lyric' ? 200 : 404,
        );

        final sheet = await provider.getLyrics(const TrackId('ncm-3340137263'));

        expect(sheet.status, LyricsStatus.synchronized);
        expect(sheet.lines.single.text, 'only line level');
        expect(
          [for (final request in requests) request.path],
          ['/lyric/new', '/lyric'],
        );
      },
    );

    for (final legacy in [false, true]) {
      for (final flag in ['pureMusic', 'nolyric']) {
        test(
          'getLyrics honors $flag on ${legacy ? '/lyric' : '/lyric/new'}',
          () async {
            serve(
              (request) => legacy && request.path == '/lyric/new'
                  ? {'code': 404}
                  : {
                      'pureMusic': false,
                      'nolyric': false,
                      flag: true,
                      'lrc': {'lyric': '[00:05.00]placeholder'},
                      'yrc': {'lyric': '[5000,2000](5000,2000,0)placeholder'},
                      'code': 200,
                    },
              statusOf: (request) =>
                  legacy && request.path == '/lyric/new' ? 404 : 200,
            );
            final sheet = await provider.getLyrics(const TrackId('ncm-165602'));
            expect(sheet.status, LyricsStatus.instrumental);
            expect(sheet.lines.single.text, 'placeholder');
            expect(sheet.isSynchronized, isFalse);
            expect(requests.last.queryParameters['id'], '165602');
          },
        );
      }
    }

    test('getLyrics reports an instrumental', () async {
      serve((_) => {'nolyric': true, 'code': 200});

      final sheet = await provider.getLyrics(const TrackId('ncm-3340137263'));

      expect(sheet.status, LyricsStatus.instrumental);
    });

    test(
      'getLyrics is unavailable for an id this provider does not own',
      () async {
        serve((_) => {'code': 200});

        final sheet = await provider.getLyrics(const TrackId('local-abcdef'));

        expect(sheet.status, LyricsStatus.unavailable);
        // No request was made: a local id has no sheet here to ask about, and
        // asking would only be refused and translated back into "none".
        expect(requests, isEmpty);
      },
    );

    test(
      'getLyrics turns a failing read into unavailable, never an error',
      () async {
        serve((_) => {'code': 500}, status: 500);

        final sheet = await provider.getLyrics(const TrackId('ncm-3340137263'));

        expect(sheet.status, LyricsStatus.unavailable);
      },
    );

    test('getTrack reports a missing song as ncm.trackNotFound', () async {
      serve((_) => jsonEncode({'songs': [], 'code': 200}));

      await expectLater(
        provider.getTrack(const TrackId('ncm-1')),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'ncm.trackNotFound',
          ),
        ),
      );
    });

    void servePlayback(Object? Function(Uri request) body, {int status = 200}) {
      serve((request) {
        if (request.path == '/song/detail') return detailBody;
        return body(request);
      }, statusOf: (request) => request.path == '/song/detail' ? 200 : status);
    }

    test('resolve takes the first level that carries a URL (exhigh)', () async {
      servePlayback((request) {
        if (request.path == '/song/url/v1') {
          if (request.queryParameters['level'] == 'exhigh') {
            return {
              'data': [
                {
                  'id': 3340137263,
                  'url': 'http://m801.music.126.net/a.mp3?vuutv=x',
                  'br': 320000,
                  'sr': 48000,
                  'md5': 'stable-representation-md5',
                  'type': 'mp3',
                  'level': 'exhigh',
                  'expi': 1200,
                  'code': 200,
                },
              ],
              'code': 200,
            };
          }
        }
        return {'code': 405};
      });

      final source = await provider.resolve(
        const TrackId('ncm-3340137263'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );

      expect(source.uri.host, 'm801.music.126.net');
      expect(source.actualQuality, AudioQuality.high);
      expect(source.codec, 'mp3');
      // What the service says it serves travels with the source, so the player
      // can describe the audio rather than only the level it asked for.
      expect(source.bitrateKbps, 320);
      expect(source.sampleRateHz, 48000);
      expect(source.resourceId, 'stable-representation-md5');
      expect(
        source.expiresAt.difference(DateTime.now().toUtc()).inMinutes,
        inInclusiveRange(19, 21),
      );
      expect(
        [
          for (final request in requests.where((r) => r.path == '/song/url/v1'))
            request.queryParameters['level'],
        ],
        ['exhigh'],
      );
    });

    test(
      'resolve reports the level the service actually echoed (lossless)',
      () async {
        servePlayback((request) {
          return {
            'data': [
              {
                'id': 3340137263,
                'url': 'http://m801.music.126.net/b.flac',
                'type': 'flac',
                // The account is entitled to lossless here, so the service answers
                // above the requested HQ level and says so.
                'level': 'lossless',
                'expi': 1200,
              },
            ],
            'code': 200,
          };
        });

        final source = await provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.high,
          NetworkPolicy.onlineOnly,
        );

        expect(source.actualQuality, AudioQuality.lossless);
        expect(source.codec, 'flac');
      },
    );

    test(
      'resolve degrades exhigh → higher → standard when URLs are empty',
      () async {
        var call = 0;
        servePlayback((request) {
          if (request.path != '/song/url/v1') return {'code': 405};
          final levels = ['exhigh', 'higher', 'standard'];
          final asked = request.queryParameters['level'];
          expect(asked, levels[call], reason: 'levels must be tried in order');
          call++;
          return {
            'data': [
              {
                'id': 3340137263,
                'url': call == 3 ? 'http://m701.music.126.net/f.mp3' : '',
                'level': asked,
                'expi': 1200,
              },
            ],
            'code': 200,
          };
        });

        final source = await provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.high,
          NetworkPolicy.onlineOnly,
        );

        expect(call, 3);
        expect(source.actualQuality, AudioQuality.standard);
        expect(source.uri.host, 'm701.music.126.net');
      },
    );

    test(
      'resolve honours the preferred quality when it picks a level',
      () async {
        final asked = <String>[];
        servePlayback((request) {
          if (request.path != '/song/url/v1') return {'code': 405};
          asked.add('${request.queryParameters['level']}');
          return {
            'data': [
              {
                'id': 3340137263,
                'url': 'http://m801.music.126.net/a.mp3',
                'level': request.queryParameters['level'],
                'expi': 1200,
              },
            ],
            'code': 200,
          };
        });

        // A caller that asked for the standard level is never served a higher
        // request: the preference shapes the request, not only the label.
        final standard = await provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.standard,
          NetworkPolicy.onlineOnly,
        );
        expect(asked, ['standard']);
        expect(standard.actualQuality, AudioQuality.standard);

        asked.clear();
        final lossless = await provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.lossless,
          NetworkPolicy.onlineOnly,
        );
        expect(asked, [
          'lossless',
        ], reason: 'lossless starts at the best level');
        expect(lossless.actualQuality, AudioQuality.lossless);
      },
    );

    test(
      'resolve refuses a free-trial clip instead of serving it as the song',
      () async {
        servePlayback(
          (_) => {
            'data': [
              {
                'id': 3340137263,
                'url': 'http://m801.music.126.net/clip.mp3',
                'type': 'mp3',
                'level': 'exhigh',
                'expi': 1200,
                'freeTrialInfo': {'start': 0, 'end': 30},
              },
            ],
            'code': 200,
          },
        );

        await expectLater(
          provider.resolve(
            const TrackId('ncm-3340137263'),
            AudioQuality.high,
            NetworkPolicy.onlineOnly,
          ),
          throwsA(
            isA<AppError>()
                .having((error) => error.code, 'code', 'ncm.previewOnly')
                .having((error) => error.retryable, 'retryable', isFalse),
          ),
        );
        expect(
          requests,
          hasLength(2),
          reason:
              'a preview belongs to the account, not the level: no lower level is tried',
        );
      },
    );

    test('resolve reads the "null" freeTrialInfo as no trial at all', () async {
      servePlayback(
        (_) => {
          'data': [
            {
              'id': 3340137263,
              'url': 'http://m801.music.126.net/full.mp3',
              'type': 'mp3',
              'level': 'exhigh',
              'expi': 1200,
              // The literal string the Node deployment has produced for
              // "there is no trial", which is not a trial.
              'freeTrialInfo': 'null',
            },
          ],
          'code': 200,
        },
      );

      final source = await provider.resolve(
        const TrackId('ncm-3340137263'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );

      expect(source.uri.host, 'm801.music.126.net');
      expect(source.actualQuality, AudioQuality.high);
    });

    test('the level chains are ordered best-first and end at standard', () {
      expect(ncmQualityLevelsFor(AudioQuality.standard), ['standard']);
      expect(ncmQualityLevelsFor(AudioQuality.high), [
        'exhigh',
        'higher',
        'standard',
      ]);
      expect(ncmQualityLevelsFor(AudioQuality.lossless), [
        'lossless',
        'exhigh',
        'higher',
        'standard',
      ]);
      // Hi-Res falls back through lossless and the lower tiers.
      expect(ncmQualityLevelsFor(AudioQuality.hiRes), [
        'hires',
        'lossless',
        'exhigh',
        'higher',
        'standard',
      ]);
    });

    test(
      'the level it asked for is adopted without a second request',
      () async {
        final asked = <String>[];
        servePlayback((request) {
          asked.add('${request.queryParameters['level']}');
          return _urlAnswer(
            level: 'exhigh',
            url: 'http://m801.music.126.net/a.mp3',
          );
        });

        final source = await provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.high,
          NetworkPolicy.onlineOnly,
        );

        expect(asked, ['exhigh']);
        expect(source.actualQuality, AudioQuality.high);
      },
    );

    test(
      'a lower echoed level ends the search rather than asking again',
      () async {
        final asked = <String>[];
        servePlayback((request) {
          asked.add('${request.queryParameters['level']}');
          // The service degraded on its own: `higher` is below `exhigh` but still
          // above everything left to try, so asking again would only repeat it.
          return _urlAnswer(
            level: 'higher',
            url: 'http://m801.music.126.net/b.mp3',
          );
        });

        final source = await provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.high,
          NetworkPolicy.onlineOnly,
        );

        expect(asked, ['exhigh']);
        expect(source.actualQuality, AudioQuality.high);
        expect(source.uri.path, '/b.mp3');
      },
    );

    test('a high tier answering low still tries 无损 first', () async {
      final asked = <String>[];
      servePlayback((request) {
        final level = '${request.queryParameters['level']}';
        asked.add(level);
        // Hi-Res is unavailable, and the service answers with standard — which
        // must not be taken as the final answer while 无损 is untried.
        if (level == 'hires') {
          return _urlAnswer(level: 'standard', url: 'http://cdn.test/s.mp3');
        }
        if (level == 'lossless') {
          return _urlAnswer(level: 'lossless', url: 'http://cdn.test/l.flac');
        }
        return _urlAnswer(level: level, url: null);
      });

      final source = await provider.resolve(
        const TrackId('ncm-3340137263'),
        AudioQuality.hiRes,
        NetworkPolicy.onlineOnly,
      );

      expect(asked, ['hires', 'lossless']);
      expect(source.actualQuality, AudioQuality.lossless);
      expect(source.uri.path, '/l.flac');
    });

    test('a stashed lower answer is used when 无损 never arrives', () async {
      final asked = <String>[];
      servePlayback((request) {
        final level = '${request.queryParameters['level']}';
        asked.add(level);
        if (level == 'hires') {
          return _urlAnswer(level: 'standard', url: 'http://cdn.test/s.mp3');
        }
        return _urlAnswer(level: level, url: null);
      });

      final source = await provider.resolve(
        const TrackId('ncm-3340137263'),
        AudioQuality.hiRes,
        NetworkPolicy.onlineOnly,
      );

      expect(asked, ['hires', 'lossless', 'exhigh', 'higher', 'standard']);
      expect(source.actualQuality, AudioQuality.standard);
    });

    test('an unsupported echoed tier falls back to lossless', () async {
      final asked = <String>[];
      servePlayback((request) {
        final level = '${request.queryParameters['level']}';
        asked.add(level);
        if (level == 'hires') {
          return _urlAnswer(level: 'jyeffect', url: 'http://cdn.test/je.flac');
        }
        if (level == 'lossless') {
          return _urlAnswer(level: 'lossless', url: 'http://cdn.test/l.flac');
        }
        return _urlAnswer(level: level, url: null);
      });

      final source = await provider.resolve(
        const TrackId('ncm-3340137263'),
        AudioQuality.hiRes,
        NetworkPolicy.onlineOnly,
      );

      expect(asked, ['hires', 'lossless']);
      expect(source.actualQuality, AudioQuality.lossless);
    });

    test('a level this app cannot name is never adopted', () async {
      servePlayback(
        (_) => _urlAnswer(level: 'jymaster', url: 'http://cdn.test/m.flac'),
      );

      await expectLater(
        provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.lossless,
          NetworkPolicy.onlineOnly,
        ),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'ncm.urlUnavailable',
          ),
        ),
      );
    });

    test('an address it cannot play counts as no address at all', () async {
      final asked = <String>[];
      servePlayback((request) {
        final level = '${request.queryParameters['level']}';
        asked.add(level);
        if (level == 'exhigh') {
          // A scheme the decoder cannot open: not a candidate, and not an error
          // either — the chain simply moves on.
          return _urlAnswer(level: 'exhigh', url: 'file:///tmp/hq.flac');
        }
        return _urlAnswer(level: level, url: 'http://cdn.test/high.mp3');
      });

      final source = await provider.resolve(
        const TrackId('ncm-3340137263'),
        AudioQuality.high,
        NetworkPolicy.onlineOnly,
      );

      expect(asked, ['exhigh', 'higher']);
      expect(source.actualQuality, AudioQuality.high);
      expect(source.uri.path, '/high.mp3');
    });

    test('a failed request stops the chain instead of stepping down', () async {
      final asked = <String>[];
      servePlayback((request) {
        asked.add('${request.queryParameters['level']}');
        return _urlAnswer(level: 'hires', url: null);
      }, status: 500);

      await expectLater(
        provider.resolve(
          const TrackId('ncm-3340137263'),
          AudioQuality.hiRes,
          NetworkPolicy.onlineOnly,
        ),
        throwsA(isA<AppError>()),
      );
      expect(asked, [
        'hires',
      ], reason: 'a failure is not fixed by asking for less');
    });

    test(
      'resolve reports ncm.urlUnavailable when no level yields a URL',
      () async {
        servePlayback(
          (_) => {
            'data': [
              {'id': 3340137263, 'url': null, 'level': 'exhigh'},
            ],
            'code': 200,
          },
        );

        await expectLater(
          provider.resolve(
            const TrackId('ncm-3340137263'),
            AudioQuality.lossless,
            NetworkPolicy.onlineOnly,
          ),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'ncm.urlUnavailable',
            ),
          ),
        );
      },
    );

    test(
      'free songs above provider free ceiling require music rights',
      () async {
        serve(
          (request) => request.path == '/song/detail'
              ? {
                  'code': 200,
                  'songs': [
                    {'id': 1, 'name': 'free', 'fee': 0},
                  ],
                  'privileges': [
                    {'id': 1, 'fee': 0, 'st': 0, 'flLevel': 'exhigh'},
                  ],
                }
              : {
                  'code': 200,
                  'data': [
                    {
                      'id': 1,
                      'url': 'https://example.test/audio',
                      'level': 'lossless',
                      'fee': 0,
                      'payed': 0,
                      'md5': 'version',
                    },
                  ],
                },
        );
        final source = await provider.resolve(
          const TrackId('ncm-1'),
          AudioQuality.lossless,
          NetworkPolicy.onlineOnly,
        );
        expect(source.access, SongAccess.nonVip);
        expect(source.resourceFree, isFalse);
        expect(source.requiredEntitlements, {'music'});
        expect(requests.map((r) => r.path), ['/song/detail', '/song/url/v1']);
      },
    );
    test(
      'provider free ceiling permits downgraded free resource, absent ceiling stays unknown',
      () async {
        serve(
          (request) => request.path == '/song/detail'
              ? {
                  'code': 200,
                  'songs': [
                    {'id': 1, 'name': 'free', 'fee': 0},
                  ],
                  'privileges': [
                    {'id': 1, 'fee': 0, 'st': 0, 'flLevel': 'exhigh'},
                  ],
                }
              : {
                  'code': 200,
                  'data': [
                    {
                      'id': 1,
                      'url': 'https://example.test/audio',
                      'level': 'exhigh',
                      'fee': 0,
                      'payed': 0,
                    },
                  ],
                },
        );
        final source = await provider.resolve(
          const TrackId('ncm-1'),
          AudioQuality.lossless,
          NetworkPolicy.onlineOnly,
        );
        expect(source.actualQuality, AudioQuality.high);
        expect(source.resourceFree, isTrue);
        expect(source.requiredEntitlements, isEmpty);
      },
    );
    test(
      'account entitlement records preserve independent types and exact deadlines',
      () async {
        serve(
          (request) => {
            'code': 200,
            'data': {
              'musicPackage': {'vipCode': 100, 'expireTime': 1900000000000},
              'redplus': {'vipCode': 200, 'expireTime': 1910000000000},
            },
          },
        );
        final rights = await provider.getAccountEntitlements();
        expect(rights.map((r) => r.kind), ['music', 'redplus']);
        expect(rights.first.expiresAt!.millisecondsSinceEpoch, 1900000000000);
        expect(rights.last.expiresAt!.millisecondsSinceEpoch, 1910000000000);
        expect(requests.single.path, '/vip/info/v2');
      },
    );
    test('a foreign track id never reaches the network', () async {
      await expectLater(
        provider.getTrack(const TrackId('local-abc')),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'ncm.invalidId',
          ),
        ),
      );
      expect(requests, isEmpty);
    });

    test('a bare netease id names the same track as the prefixed one', () async {
      // The app routes an id to this provider by its shape, not by a prefix it
      // may not have, and an id that arrived as a plain number from a share or
      // a search box is the same entity as the prefixed one.
      serve((_) => detailBody);

      final track = await provider.getTrack(const TrackId('3340137263'));

      expect(track.id, const TrackId('ncm-3340137263'));
      expect(requests.single.queryParameters['ids'], '3340137263');
    });

    test(
      'a prefixed id whose tail is not a number never reaches the network',
      () async {
        // `ncm-track-1` names no netease track. Sending its tail upstream would
        // ask the service about somebody else's identifier instead of saying the
        // id is not one of ours.
        await expectLater(
          provider.getTrack(const TrackId('ncm-track-1')),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'ncm.invalidId',
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );

    test('non-200 answers become stable provider errors', () async {
      serve((_) => {'code': 404}, status: 404);

      await expectLater(
        provider.getTrack(const TrackId('ncm-3340137263')),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'ncm.trackNotFound',
          ),
        ),
      );
    });

    group('getTracks', () {
      late RemoteNcmProvider batchProvider;

      Map<String, Object?> song(int id) => {
        'name': '曲目 $id',
        'id': id,
        'dt': 147900,
        'ar': [
          {'id': 1, 'name': '艺人'},
        ],
        'al': {
          'id': 2,
          'name': '专辑',
          'picUrl': 'https://p3.music.126.net/cover.jpg',
        },
      };

      String details(Iterable<int> ids) => jsonEncode({
        'songs': [for (final id in ids) song(id)],
        'code': 200,
      });

      setUp(() {
        batchProvider = RemoteNcmProvider(
          config: RemoteProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
          supportsBatchTrackDetails: true,
        );
      });

      tearDown(() => batchProvider.dispose());

      test('reads several ids in one call and keys the answer by id', () async {
        serve((_) => details([3340137263, 347230]));

        final tracks = await batchProvider.getTracks([
          const TrackId('ncm-3340137263'),
          const TrackId('ncm-347230'),
        ]);

        expect(requests.length, 1);
        expect(requests.single.path, '/song/detail');
        expect(requests.single.queryParameters['ids'], '3340137263,347230');
        expect(
          localizedTestValue(tracks[const TrackId('ncm-347230')]!.title),
          '曲目 347230',
        );
        expect(tracks.length, 2);
      });

      test('duplicate ids are asked for once', () async {
        serve((_) => details([3340137263]));

        await batchProvider.getTracks([
          const TrackId('ncm-3340137263'),
          const TrackId('ncm-3340137263'),
        ]);

        expect(requests.length, 1);
        expect(requests.single.queryParameters['ids'], '3340137263');
      });

      test('two spellings of one track are one id, asked for once', () async {
        serve((_) => details([3340137263]));

        final tracks = await batchProvider.getTracks([
          const TrackId('ncm-3340137263'),
          const TrackId('3340137263'),
        ]);

        expect(requests.length, 1);
        expect(requests.single.queryParameters['ids'], '3340137263');
        expect(tracks.keys, [const TrackId('ncm-3340137263')]);
      });

      test(
        'an id the service did not answer is absent, not invented',
        () async {
          serve((_) => details([3340137263]));

          final tracks = await batchProvider.getTracks([
            const TrackId('ncm-3340137263'),
            const TrackId('ncm-999'),
          ]);

          expect(tracks.keys, [const TrackId('ncm-3340137263')]);
        },
      );

      test('an id nobody asked for is not adopted', () async {
        serve((_) => details([111, 222]));

        final tracks = await batchProvider.getTracks([
          const TrackId('ncm-111'),
        ]);

        expect(tracks.keys, [const TrackId('ncm-111')]);
      });

      test('a batch larger than the limit is split', () async {
        serve((uri) {
          final ids = uri.queryParameters['ids']!.split(',').map(int.parse);
          return details(ids);
        });

        final tracks = await batchProvider.getTracks([
          for (var id = 1; id <= 51; id++) TrackId('ncm-$id'),
        ]);

        expect(tracks.length, 51);
        final batchSizes = [
          for (final uri in requests)
            uri.queryParameters['ids']!.split(',').length,
        ]..sort();
        expect(batchSizes, [1, 50]);
      });

      test('no ids means no request', () async {
        expect(await batchProvider.getTracks(const []), isEmpty);
        expect(requests, isEmpty);
      });

      test('a foreign id never reaches the network', () async {
        await expectLater(
          batchProvider.getTracks([const TrackId('local-abc')]),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'ncm.invalidId',
            ),
          ),
        );
        expect(requests, isEmpty);
      });

      test('an unreadable batch shape falls back and stays off', () async {
        serve((uri) {
          final ids = uri.queryParameters['ids']!;
          if (ids.contains(',')) return {'songs': 'not-a-list', 'code': 200};
          return details([int.parse(ids)]);
        });

        final tracks = await batchProvider.getTracks([
          const TrackId('ncm-1'),
          const TrackId('ncm-2'),
        ]);

        expect(
          tracks.keys,
          containsAll([const TrackId('ncm-1'), const TrackId('ncm-2')]),
        );
        expect(batchProvider.supportsBatchTrackDetails, isFalse);
        expect(requests.first.queryParameters['ids'], '1,2');

        requests.clear();
        await batchProvider.getTracks([const TrackId('ncm-3')]);
        expect(requests.single.queryParameters['ids'], '3');
      });

      test(
        'batching stays off by default and a missing track is absent',
        () async {
          serve((uri) {
            final ids = uri.queryParameters['ids']!;
            if (ids == '1') return details([1]);
            return {'songs': <Object?>[], 'code': 200};
          });

          expect(provider.supportsBatchTrackDetails, isFalse);
          final tracks = await provider.getTracks([
            const TrackId('ncm-1'),
            const TrackId('ncm-2'),
          ]);

          expect(tracks.keys, [const TrackId('ncm-1')]);
          expect(requests.length, 2);
          expect(
            requests.every((uri) => !uri.queryParameters['ids']!.contains(',')),
            isTrue,
          );
        },
      );
    });

    test(
      'searchTracks maps /cloudsearch results to SearchResult<Track>',
      () async {
        serve(
          (_) => {
            'result': {
              'songs': [
                {
                  'name': '海阔天空',
                  'id': 347230,
                  'dt': 324000,
                  'ar': [
                    {'id': 11127, 'name': 'Beyond'},
                  ],
                  'al': {
                    'id': 34209,
                    'name': '海阔天空',
                    'picUrl': 'https://p1.music.126.net/cover.jpg',
                  },
                },
              ],
              'songCount': 100,
            },
            'code': 200,
          },
        );

        final result = await provider.searchTracks(
          const SearchQuery(keywords: '海阔天空', limit: 10, offset: 0),
        );
        expect(result.items.length, 1);
        expect(result.hasMore, isTrue);
        expect(result.totalCount, 100);
        final track = result.items.first;
        expect(track.id.value, 'ncm-347230');
        expect(localizedTestValue(track.title), '海阔天空');
        expect(track.artistLabel, 'Beyond');
        expect(localizedTestValue(track.album.title), '海阔天空');

        final request = requests.single;
        expect(request.path, '/cloudsearch');
        expect(request.queryParameters['keywords'], '海阔天空');
        expect(request.queryParameters['limit'], '10');
        expect(request.queryParameters['offset'], '0');
      },
    );

    test('searchTracks with empty keywords returns immediately', () async {
      final result = await provider.searchTracks(
        const SearchQuery(keywords: '   '),
      );
      expect(result.items, isEmpty);
      expect(result.hasMore, isFalse);
      expect(result.totalCount, 0);
      expect(requests, isEmpty);
    });

    test(
      'playlist access response is consumed once by the content load',
      () async {
        serve(
          (_) => {
            'code': 200,
            'playlist': {
              'id': 24381616,
              'name': 'checked playlist',
              'trackCount': 1,
              'tracks': [_playlistSong(0)],
              'subscribed': true,
            },
          },
        );
        const id = PlaylistId('ncm-playlist-24381616');
        final verdict = await provider.getPlaylistAccess(id);
        final detail = await provider.getPlaylist(
          id,
          policy: RefreshPolicy.forceRefresh,
        );
        expect(verdict.state, PlaylistAccessState.publicConfirmed);
        expect(detail.tracks, hasLength(1));
        expect(
          detail.accountState?.subscription,
          SubscriptionEvidence.subscribed,
        );
        expect(requests, hasLength(1));
        await provider.getPlaylist(id);
        expect(requests, hasLength(2), reason: 'reuse is single use');
        await provider.getPlaylistAccess(id);
        provider.setCookie('MUSIC_U=another-account');
        await provider.getPlaylist(id);
        expect(
          requests,
          hasLength(4),
          reason: 'account switch discards the checked body',
        );
      },
    );

    test('getPlaylist maps /playlist/detail to PlaylistDetail', () async {
      serve(
        (_) => {
          'playlist': {
            'id': 24381616,
            'name': '华语流行经典',
            'description': '经典老歌回顾',
            'coverImgUrl': 'https://p1.music.126.net/playlist.jpg',
            // The response carries every song it declares, so no paging happens.
            'trackCount': 1,
            'creator': {'nickname': '音乐推荐官'},
            'tracks': [
              {
                'name': '光辉岁月',
                'id': 346576,
                'dt': 303000,
                'ar': [
                  {'id': 11127, 'name': 'Beyond'},
                ],
                'al': {'id': 34185, 'name': '命运派对'},
              },
            ],
          },
          'code': 200,
        },
      );

      final detail = await provider.getPlaylist(
        const PlaylistId('ncm-playlist-24381616'),
      );
      expect(localizedTestValue(detail.summary.title), '华语流行经典');
      expect(localizedTestValue(detail.summary.subtitle), '创建者: 音乐推荐官');
      expect(detail.summary.trackCount, 1);
      expect(detail.summary.description, '经典老歌回顾');
      expect(
        detail.summary.artworkUri.toString(),
        'https://p1.music.126.net/playlist.jpg',
      );
      expect(detail.tracks.length, 1);
      expect(localizedTestValue(detail.tracks.first.title), '光辉岁月');

      final request = requests.single;
      expect(request.path, '/playlist/detail');
      expect(request.queryParameters['id'], '24381616');
    });

    test(
      'getPlaylist pages a long playlist and stops at the declared count',
      () async {
        const declared = 2500;
        serve((request) {
          if (request.path == '/playlist/detail') {
            return {
              'playlist': {
                'id': 24381616,
                'name': '华语流行经典',
                'trackCount': declared,
                'creator': {'nickname': '音乐推荐官'},
                'tracks': [
                  for (var index = 0; index < 30; index++) _playlistSong(index),
                ],
              },
              'code': 200,
            };
          }
          if (request.path == '/playlist/track/all') {
            final offset = int.parse(request.queryParameters['offset']!);
            final limit = int.parse(request.queryParameters['limit']!);
            final end = offset + limit;
            return {
              'songs': [
                for (var index = offset; index < end; index++)
                  _playlistSong(index),
              ],
              'code': 200,
            };
          }
          return {'code': 404};
        });

        final detail = await provider.getPlaylist(
          const PlaylistId('ncm-playlist-24381616'),
        );

        // The declared count is kept, and the queue gets the songs in full.
        expect(detail.summary.trackCount, declared);
        expect(detail.tracks, hasLength(declared));
        expect(localizedTestValue(detail.tracks.first.title), '歌曲 0');
        expect(localizedTestValue(detail.tracks.last.title), '歌曲 2499');

        final pages = [
          for (final request in requests)
            if (request.path == '/playlist/track/all') request,
        ];
        expect(
          [for (final page in pages) page.queryParameters['offset']],
          ['0', '1000', '2000'],
        );
        expect(
          [for (final page in pages) page.queryParameters['limit']],
          ['1000', '1000', '500'],
        );
      },
    );

    test(
      'getPlaylist stops when the service serves fewer songs than it declares',
      () async {
        serve((request) {
          if (request.path == '/playlist/detail') {
            return {
              'playlist': {
                'id': 24381616,
                'name': '华语流行经典',
                'trackCount': 5000,
                'tracks': [_playlistSong(0)],
              },
              'code': 200,
            };
          }
          if (request.path == '/playlist/track/all') {
            final offset = int.parse(request.queryParameters['offset']!);
            return {
              'songs': [
                for (var index = offset; index < offset + 5; index++)
                  _playlistSong(index),
              ],
              'code': 200,
            };
          }
          return {'code': 404};
        });

        final detail = await provider.getPlaylist(
          const PlaylistId('ncm-playlist-24381616'),
        );

        // What the service will serve is what is taken; no request is issued to
        // chase the rest.
        expect(detail.summary.trackCount, 5000);
        expect(detail.tracks, hasLength(5));
        final pages = [
          for (final request in requests)
            if (request.path == '/playlist/track/all') request,
        ];
        expect(pages, hasLength(1), reason: 'a short page ends the read');
      },
    );

    test(
      'getPlaylist keeps the detail songs when the paged endpoint answers nothing',
      () async {
        serve((request) {
          if (request.path == '/playlist/detail') {
            return {
              'playlist': {
                'id': 24381616,
                'name': '华语流行经典',
                'trackCount': 50,
                'tracks': [_playlistSong(0)],
              },
              'code': 200,
            };
          }
          return {'songs': [], 'code': 200};
        });

        final detail = await provider.getPlaylist(
          const PlaylistId('ncm-playlist-24381616'),
        );

        expect(detail.summary.trackCount, 50);
        expect(
          detail.tracks,
          hasLength(1),
          reason:
              'a service that cannot serve the rest must not erase the songs it has',
        );
        expect(localizedTestValue(detail.tracks.single.title), '歌曲 0');
      },
    );

    test(
      'getPlaylist keeps the detail songs when completing the list fails',
      () async {
        serve(
          (request) {
            if (request.path == '/playlist/detail') {
              return {
                'playlist': {
                  'id': 24381616,
                  'name': '华语流行经典',
                  'trackCount': 50,
                  'tracks': [_playlistSong(0)],
                },
                'code': 200,
              };
            }
            return {'code': 500, 'msg': 'boom'};
          },
          statusOf: (request) =>
              request.path == '/playlist/track/all' ? 500 : 200,
        );

        final detail = await provider.getPlaylist(
          const PlaylistId('ncm-playlist-24381616'),
        );

        expect(detail.summary.trackCount, 50);
        expect(detail.isPartial, isTrue);
        expect(
          detail.tracks,
          hasLength(1),
          reason: 'a failed completion must not erase the songs the detail had',
        );
        expect(localizedTestValue(detail.tracks.single.title), '歌曲 0');
      },
    );

    test(
      'getPlaylistTracks maps /playlist/track/all to SearchResult',
      () async {
        serve(
          (_) => {
            'songs': [
              {
                'name': '真的爱你',
                'id': 346089,
                'dt': 275000,
                'ar': [
                  {'id': 11127, 'name': 'Beyond'},
                ],
                'al': {'id': 34185, 'name': 'Beyond IV'},
              },
            ],
            'code': 200,
          },
        );

        final result = await provider.getPlaylistTracks(
          const PlaylistId('24381616'),
          limit: 10,
          offset: 20,
        );
        expect(result.items.length, 1);
        expect(localizedTestValue(result.items.first.title), '真的爱你');

        final request = requests.single;
        expect(request.path, '/playlist/track/all');
        expect(request.queryParameters['id'], '24381616');
        expect(request.queryParameters['limit'], '10');
        expect(request.queryParameters['offset'], '20');
      },
    );

    test(
      'logout verifies the supplied cookie without changing active credentials',
      () async {
        serve(
          (request) => request.path == '/logout'
              ? {'code': 200}
              : {'code': 200, 'profile': null},
        );
        provider.setCookie('MUSIC_U=fake-token');

        await provider.logout();
        await expectLater(provider.getUserAccount(), throwsA(isA<AppError>()));

        expect(requests[0].path, '/logout');
        expect(requests[0].queryParameters['cookie'], 'MUSIC_U=fake-token');
        expect(requests[1].path, '/user/account');
        expect(requests[1].queryParameters['cookie'], 'MUSIC_U=fake-token');
        expect(requests[2].path, '/user/account');
        expect(requests[2].queryParameters['cookie'], 'MUSIC_U=fake-token');
      },
    );

    test(
      'installation device ID accompanies anonymous and authenticated calls',
      () async {
        const deviceId = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
        provider.dispose();
        provider = RemoteNcmProvider(
          config: RemoteProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
          deviceIdProvider: () async => deviceId,
        );
        closer = provider;
        var signedOut = false;
        serve(
          (request) => switch (request.path) {
            '/login/qr/key' => {'code': 200, 'unikey': 'qr-key'},
            '/login/qr/create' => {
              'code': 200,
              'data': {'qrurl': 'https://music.163.com/login?codekey=qr-key'},
            },
            '/login/qr/check' => {'code': 801},
            '/user/account' => {
              'code': 200,
              'profile': signedOut ? null : {'userId': 123, 'nickname': '测试用户'},
            },
            '/song/detail' => jsonDecode(detailBody),
            '/logout' => (() {
              signedOut = true;
              return {'code': 200};
            })(),
            _ => {'code': 404},
          },
        );

        await provider.createQrCodeSession();
        await provider.checkQrCodeStatus('qr-key');
        provider.setCookie('MUSIC_U=fake-token');
        await provider.getUserAccount();
        await provider.getTrack(const TrackId('ncm-3340137263'));
        await provider.logout();
        provider.setCookie(null); // Credential owner commits local sign-out.
        await provider.getTrack(const TrackId('ncm-3340137263'));

        expect(requests.map((request) => request.path), [
          '/login/qr/key',
          '/login/qr/create',
          '/login/qr/check',
          '/user/account',
          '/song/detail',
          '/logout',
          '/user/account',
          '/song/detail',
        ]);
        for (final request in requests) {
          expect(
            request.queryParameters['cookie'],
            contains('deviceId=$deviceId'),
          );
        }
        for (final request in requests.take(3)) {
          expect(request.queryParameters['cookie'], 'deviceId=$deviceId');
        }
        for (final request in requests.skip(3).take(4)) {
          expect(
            request.queryParameters['cookie'],
            'MUSIC_U=fake-token; deviceId=$deviceId',
          );
        }
        expect(requests.last.queryParameters['cookie'], 'deviceId=$deviceId');
      },
    );

    test(
      'device identity failure prevents requests before the provider fallback',
      () async {
        provider.dispose();
        provider = RemoteNcmProvider(
          config: RemoteProviderConfig(
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
          deviceIdProvider: () async => throw const AppError(
            category: AppErrorCategory.provider,
            code: 'provider.deviceIdUnavailable',
            retryable: true,
          ),
        );
        closer = provider;
        serve((_) => {'code': 200});

        await expectLater(
          provider.createQrCodeSession(),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'provider.deviceIdUnavailable',
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );

    test('logout keeps the cookie when the old session still works', () async {
      serve(
        (request) => request.path == '/logout'
            ? {'code': 200}
            : {
                'code': 200,
                'profile': {'userId': 123, 'nickname': '测试用户'},
              },
      );
      provider.setCookie('MUSIC_U=fake-token');

      await expectLater(
        provider.logout(),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'auth.logoutUnverified',
          ),
        ),
      );
      await provider.getUserAccount();

      expect(requests[1].queryParameters['cookie'], 'MUSIC_U=fake-token');
      expect(requests[2].queryParameters['cookie'], 'MUSIC_U=fake-token');
    });

    test('logout rejects a non-success body and retains the cookie', () async {
      serve(
        (request) => request.path == '/logout'
            ? {'code': 201}
            : {
                'code': 200,
                'profile': {'userId': 123, 'nickname': '测试用户'},
              },
      );
      provider.setCookie('MUSIC_U=fake-token');

      await expectLater(
        provider.logout(),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'auth.logoutRejected',
          ),
        ),
      );
      await provider.getUserAccount();

      expect(requests[1].queryParameters['cookie'], 'MUSIC_U=fake-token');
    });

    test('createQrCodeSession accepts the pinned provider response', () async {
      serve(
        (request) => switch (request.path) {
          '/login/qr/key' => {'code': 200, 'unikey': 'test-unikey-123'},
          '/login/qr/create' => {
            'code': 200,
            'data': {
              'qrurl': 'https://music.163.com/login?codekey=test-unikey-123',
              'qrimg': '',
            },
          },
          _ => {'code': 404},
        },
      );

      final session = await provider.createQrCodeSession();
      expect(session.unikey, 'test-unikey-123');
      expect(
        session.qrUrl,
        'https://music.163.com/login?codekey=test-unikey-123',
      );
      expect(session.qrImageBytes, isNull);
      expect(requests.length, 2);
      expect(requests[0].path, '/login/qr/key');
      expect(requests[1].path, '/login/qr/create');
      expect(requests[1].queryParameters['key'], 'test-unikey-123');
    });

    test('createQrCodeSession also accepts a nested unikey', () async {
      serve(
        (request) => switch (request.path) {
          '/login/qr/key' => {
            'code': 200,
            'data': {'unikey': 'nested-key'},
          },
          '/login/qr/create' => {
            'code': 200,
            'data': {'qrurl': 'https://music.163.com/login?codekey=nested-key'},
          },
          _ => {'code': 404},
        },
      );

      expect((await provider.createQrCodeSession()).unikey, 'nested-key');
    });

    test(
      'SVG QR responses use the URL renderer instead of bitmap bytes',
      () async {
        final svgImage =
            'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"/>'))}';
        serve(
          (request) => switch (request.path) {
            '/login/qr/key' => {
              'code': 200,
              'data': {'code': 200, 'unikey': 'rust-sdk-key'},
            },
            '/login/qr/create' => {
              'code': 200,
              'data': {
                'qrurl': 'https://music.163.com/login?codekey=rust-sdk-key',
                'qrimg': svgImage,
              },
            },
            _ => {'code': 404},
          },
        );

        final session = await provider.createQrCodeSession();
        expect(session.unikey, 'rust-sdk-key');
        expect(
          session.qrUrl,
          'https://music.163.com/login?codekey=rust-sdk-key',
        );
        expect(session.qrImg, svgImage);
        expect(session.qrImageBytes, isNull);
      },
    );

    test('PNG QR responses retain bitmap bytes', () async {
      const pngImage =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6xoAAAAASUVORK5CYII=';
      serve(
        (request) => switch (request.path) {
          '/login/qr/key' => {'code': 200, 'unikey': 'png-key'},
          '/login/qr/create' => {
            'code': 200,
            'data': {
              'qrurl': 'https://music.163.com/login?codekey=png-key',
              'qrimg': pngImage,
            },
          },
          _ => {'code': 404},
        },
      );

      final session = await provider.createQrCodeSession();
      expect(session.qrImageBytes, base64Decode(pngImage.split(',').last));
    });

    test('checkQrCodeStatus maps 801, 802, 803, 800 correctly', () async {
      var currentCode = 801;
      String? returnedCookie;
      serve((_) => {'code': currentCode, 'cookie': ?returnedCookie});

      final s1 = await provider.checkQrCodeStatus('test-key');
      expect(s1.status, QrCodeScanStatus.waitingForScan);
      expect(s1.cookie, isNull);

      currentCode = 802;
      final s2 = await provider.checkQrCodeStatus('test-key');
      expect(s2.status, QrCodeScanStatus.waitingForConfirmation);

      currentCode = 803;
      returnedCookie = 'MUSIC_U=fake_token_abc; Path=/;';
      final s3 = await provider.checkQrCodeStatus('test-key');
      expect(s3.status, QrCodeScanStatus.authorized);
      expect(s3.cookie, 'MUSIC_U=fake_token_abc; Path=/;');

      currentCode = 800;
      returnedCookie = null;
      final s4 = await provider.checkQrCodeStatus('test-key');
      expect(s4.status, QrCodeScanStatus.expired);
    });

    test('getUserAccount maps /user/account to UserProfile', () async {
      serve(
        (_) => {
          'code': 200,
          'profile': {
            'userId': 998877,
            'nickname': '极光音乐家',
            'avatarUrl': 'https://p1.music.126.net/avatar.jpg',
            'vipType': 11,
            'signature': '夜航与星光',
          },
        },
      );

      final user = await provider.getUserAccount(cookie: 'fake-cookie');
      expect(user.userId.value, 'ncm-user-998877');
      expect(localizedTestValue(user.nickname), '极光音乐家');
      expect(user.avatarUri.toString(), 'https://p1.music.126.net/avatar.jpg');
      expect(user.vipType, 11);
      expect(user.signature, '夜航与星光');

      final request = requests.single;
      expect(request.path, '/user/account');
      expect(request.queryParameters['cookie'], 'fake-cookie');
    });

    test(
      'getUserPlaylists maps /user/playlist to List<PlaylistSummary>',
      () async {
        serve(
          (_) => {
            'code': 200,
            'playlist': [
              {
                'id': 112233,
                'name': '我喜欢的音乐',
                'trackCount': 42,
                'coverImgUrl': 'https://p1.music.126.net/fav.jpg',
                'description': '个人歌单简介',
                'playCount': 120,
                'subscribedCount': 8,
                'createTime': 1700000000000,
                'tags': ['流行'],
                'creator': {
                  'nickname': '极光音乐家',
                  'userId': 998877,
                  'avatarUrl': 'https://example.com/user.jpg',
                },
              },
            ],
          },
        );

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );
        expect(playlists.length, 1);
        expect(playlists.first.id.value, 'ncm-playlist-112233');
        expect(localizedTestValue(playlists.first.title), '我喜欢的音乐');
        expect(playlists.first.trackCount, 42);
        final summary = playlists.first;
        expect(summary.playCount, 120);
        expect(summary.creatorNickname, '极光音乐家');
        expect(summary.header.description, '个人歌单简介');
        expect(summary.header.playCount, 120);
        expect(summary.header.subscribedCount, 8);
        expect(summary.header.tags, ['流行']);
        expect(
          summary.header.createTime!.millisecondsSinceEpoch,
          1700000000000,
        );
        expect(
          summary.header.creator!.avatarUri.toString(),
          'https://example.com/user.jpg',
        );
        expect(summary.header.creator!.userId, const UserId('998877'));

        final request = requests.single;
        expect(request.path, '/user/playlist');
        expect(request.queryParameters['uid'], '998877');
      },
    );

    test('getUserPlaylists follows `more` to the end of the account', () async {
      serve((request) {
        final offset = int.parse(request.queryParameters['offset']!);
        final limit = int.parse(request.queryParameters['limit']!);
        final end = offset + limit < 45 ? offset + limit : 45;
        return {
          'code': 200,
          'more': end < 45,
          'playlist': [
            for (var index = offset; index < end; index++)
              {'id': 1000 + index, 'name': '歌单 $index'},
          ],
        };
      });

      final playlists = await provider.getUserPlaylists(
        const UserId('ncm-user-998877'),
      );

      expect(playlists, hasLength(45));
      expect(
        [for (final request in requests) request.queryParameters['offset']],
        ['0', '30'],
      );
    });

    test(
      'getUserPlaylists keeps the pages it read when a later page fails',
      () async {
        serve(
          (request) {
            final offset = int.parse(request.queryParameters['offset']!);
            if (offset == 0) {
              return {
                'code': 200,
                'more': true,
                'playlist': [
                  for (var index = 0; index < 30; index++)
                    {'id': 1000 + index, 'name': '歌单 $index'},
                ],
              };
            }
            return {'code': 500, 'msg': 'boom'};
          },
          statusOf: (request) =>
              request.queryParameters['offset'] == '0' ? 200 : 500,
        );

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );

        expect(playlists, hasLength(30));
        expect(
          playlists,
          isA<UserPlaylists>().having(
            (it) => it.isPartial,
            'isPartial',
            isTrue,
          ),
        );
        expect(requests, hasLength(2));
      },
    );

    test(
      'getUserPlaylists continues when a short page still sets more: true',
      () async {
        serve((request) {
          final offset = int.parse(request.queryParameters['offset']!);
          if (offset == 0) {
            // A short page of only 10 items (less than limit 30), but more: true.
            return {
              'code': 200,
              'more': true,
              'playlist': [
                for (var index = 0; index < 10; index++)
                  {'id': 1000 + index, 'name': '歌单 $index'},
              ],
            };
          }
          return {
            'code': 200,
            'more': false,
            'playlist': [
              for (var index = 0; index < 5; index++)
                {'id': 2000 + index, 'name': '歌单续 $index'},
            ],
          };
        });

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );

        expect(playlists, hasLength(15));
        expect(
          playlists,
          isA<UserPlaylists>().having(
            (it) => it.isPartial,
            'isPartial',
            isFalse,
          ),
        );
        expect(
          [for (final req in requests) req.queryParameters['offset']],
          ['0', '10'],
        );
      },
    );

    test(
      'getUserPlaylists terminates when server returns empty list with more: true',
      () async {
        serve(
          (_) => {
            'code': 200,
            'more': true,
            'playlist': <Map<String, Object?>>[],
          },
        );

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );

        expect(playlists, isEmpty);
        // `more: true` on an empty page is an illegal answer, not a finished
        // account: the caller must not treat the empty list as the whole of it.
        expect(
          playlists,
          isA<UserPlaylists>().having(
            (it) => it.isPartial,
            'isPartial',
            isTrue,
          ),
        );
        expect(requests, hasLength(1));
      },
    );

    test(
      'getUserPlaylists terminates when server returns duplicate page with more: true',
      () async {
        serve(
          (_) => {
            'code': 200,
            'more': true,
            'playlist': [
              {'id': 111, 'name': '重复歌单'},
            ],
          },
        );

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );

        expect(playlists, hasLength(1));
        // First page adds 111; second page has no new IDs and terminates
        expect(requests, hasLength(2));
        // The repeating server still claims more, so the one playlist read is a
        // prefix of the account rather than all of it.
        expect(
          playlists,
          isA<UserPlaylists>().having(
            (it) => it.isPartial,
            'isPartial',
            isTrue,
          ),
        );
      },
    );

    test(
      'getUserPlaylists reports a complete list when the last page sets more: false',
      () async {
        serve((request) {
          final offset = int.parse(request.queryParameters['offset']!);
          return {
            'code': 200,
            'more': false,
            'playlist': [
              {'id': 1000 + offset, 'name': '歌单 $offset'},
            ],
          };
        });

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );

        expect(playlists, hasLength(1));
        expect(
          playlists,
          isA<UserPlaylists>()
              .having((it) => it.isPartial, 'isPartial', isFalse)
              .having((it) => it.hasMore, 'hasMore', isFalse),
        );
      },
    );

    test(
      'getUserPlaylists marks result as partial when 20 pages limit is reached with more: true',
      () async {
        serve((request) {
          final offset = int.parse(request.queryParameters['offset']!);
          return {
            'code': 200,
            'more': true,
            'playlist': [
              {'id': 1000 + offset, 'name': '歌单 $offset'},
            ],
          };
        });

        final playlists = await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        );

        expect(requests, hasLength(20));
        expect(playlists, hasLength(20));
        expect(
          playlists,
          isA<UserPlaylists>()
              .having((it) => it.isPartial, 'isPartial', isTrue)
              .having((it) => it.hasMore, 'hasMore', isTrue),
        );
      },
    );

    test('getUserPlaylists keeps the liked marker the service set', () async {
      serve(
        (_) => {
          'code': 200,
          'more': false,
          'playlist': [
            {'id': 998877, 'name': '我喜欢的音乐', 'specialType': 5},
            {'id': 112233, 'name': '别的歌单', 'specialType': 0},
          ],
        },
      );

      final playlists = await provider.getUserPlaylists(
        const UserId('ncm-user-998877'),
      );

      expect(localizedTestValue(playlists.first.title), '我喜欢的音乐');
      expect(playlists.first.specialType, 5);
      expect(playlists.last.specialType, 0);
    });

    test(
      'getUserPlaylists reads a field of the wrong type as absent',
      () async {
        serve(
          (_) => {
            'code': 200,
            'more': false,
            'playlist': [
              {
                'id': 112233,
                'name': 42,
                'trackCount': 'many',
                'coverImgUrl': false,
                'description': 7,
                'creator': {'nickname': 3},
              },
            ],
          },
        );

        final summary = (await provider.getUserPlaylists(
          const UserId('ncm-user-998877'),
        )).single;

        expect(localizedTestValue(summary.title), '歌单');
        expect(summary.trackCount, 0);
        expect(summary.artworkUri, isNull);
        expect(summary.description, isNull);
        expect(localizedTestValue(summary.subtitle), '网易云歌单');
      },
    );

    test(
      'checkQrCodeStatus reads the 803 cookie from Set-Cookie too',
      () async {
        serve(
          (_) => {'code': 803},
          setCookieOf: (_) => [
            'MUSIC_U=fake_token_abc; Max-Age=3600; Path=/; HTTPOnly',
            '__csrf=csrf_value; Path=/',
          ],
        );

        final status = await provider.checkQrCodeStatus('test-key');

        expect(status.status, QrCodeScanStatus.authorized);
        expect(
          status.cookie,
          'MUSIC_U=fake_token_abc',
          reason:
              'the cookie is its header\'s first name=value without the '
              'attributes, and only the login cookie is a credential',
        );
      },
    );

    test(
      'checkQrCodeStatus does not mistake a tracking cookie for a login',
      () async {
        // Measured on the pinned provider: an anonymous QR poll answers 801 and
        // still sets `NMTID`. Treating that as a session would report a login
        // that never happened.
        serve(
          (_) => {'code': 801, 'message': '等待扫码'},
          setCookieOf: (_) => [
            'NMTID=tracking_value; Max-Age=315360000; Path=/;',
          ],
        );

        final status = await provider.checkQrCodeStatus('test-key');

        expect(status.status, QrCodeScanStatus.waitingForScan);
        expect(status.cookie, isNull);
      },
    );

    test('checkQrCodeStatus prefers the cookie the body carries', () async {
      serve(
        (_) => {'code': 803, 'cookie': 'MUSIC_U=from_body'},
        setCookieOf: (_) => ['MUSIC_U=from_header; Path=/'],
      );

      final status = await provider.checkQrCodeStatus('test-key');

      expect(status.cookie, 'MUSIC_U=from_body');
    });

    test(
      'checkQrCodeStatus drops a Set-Cookie that carries no credential',
      () async {
        serve(
          (_) => {'code': 803},
          setCookieOf: (_) => ['MUSIC_U=; Max-Age=0', 'NMTID'],
        );

        final status = await provider.checkQrCodeStatus('test-key');

        expect(status.status, QrCodeScanStatus.authorized);
        expect(
          status.cookie,
          isNull,
          reason: 'a deletion and a malformed header are not credentials',
        );
      },
    );

    test('checkQrCodeStatus treats a non-string cookie as absent', () async {
      serve(
        (_) => {
          'code': 803,
          'cookie': {'MUSIC_U': 'x'},
        },
      );

      final status = await provider.checkQrCodeStatus('test-key');

      expect(status.status, QrCodeScanStatus.authorized);
      expect(status.cookie, isNull);
    });

    test('getUserAccount reads a field of the wrong type as absent', () async {
      serve(
        (_) => {
          'code': 200,
          'profile': {
            'userId': 998877,
            'nickname': 42,
            'avatarUrl': 7,
            'vipType': '11',
            'signature': <String>[],
          },
        },
      );

      final user = await provider.getUserAccount(cookie: 'fake-cookie');

      expect(localizedTestValue(user.nickname), '网易云用户');
      expect(user.avatarUri, isNull);
      expect(user.vipType, 0);
      expect(user.signature, isNull);
    });

    test('createQrCodeSession reads a non-string qrimg as none', () async {
      serve(
        (request) => switch (request.path) {
          '/login/qr/key' => {'code': 200, 'unikey': 'k'},
          '/login/qr/create' => {
            'code': 200,
            'data': {
              'qrurl': 'https://music.163.com/login?codekey=k',
              'qrimg': 7,
            },
          },
          _ => {'code': 404},
        },
      );

      final session = await provider.createQrCodeSession();

      expect(session.qrUrl, 'https://music.163.com/login?codekey=k');
      expect(session.qrImg, isNull);
      expect(session.qrImageBytes, isNull);
    });

    test(
      'createQrCodeSession reports a wrong-shaped qrurl as a schema change',
      () async {
        serve(
          (request) => switch (request.path) {
            '/login/qr/key' => {'code': 200, 'unikey': 'k'},
            '/login/qr/create' => {
              'code': 200,
              'data': {'qrurl': 7},
            },
            _ => {'code': 404},
          },
        );

        await expectLater(
          provider.createQrCodeSession(),
          throwsA(
            isA<AppError>().having(
              (error) => error.code,
              'code',
              'provider.schemaChanged',
            ),
          ),
        );
      },
    );
  });
}

/// One `/song/url/v1` answer: a single entry echoing [level] with [url].
///
/// It exists so the quality cases read as "this request answered that way", which
/// is what the adoption rules are about; the field names mirror what the real
/// service sends.
Map<String, Object?> _urlAnswer({
  required String level,
  required String? url,
  String type = 'flac',
  Object? freeTrialInfo,
}) {
  final entry = <String, Object?>{
    'id': 3340137263,
    'url': url,
    'br': 320000,
    'sr': 48000,
    'type': type,
    'level': level,
    'expi': 1200,
  };
  final trial = freeTrialInfo;
  if (trial != null) entry['freeTrialInfo'] = trial;
  return {
    'data': [entry],
    'code': 200,
  };
}
