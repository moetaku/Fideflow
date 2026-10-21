import 'dart:convert';
import 'dart:io';

import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'startup verifies current VIP status and downgrades before restoring playback',
    () async {
      var vip = 11;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': 200,
            'profile': {'userId': 1, 'nickname': 'Account', 'vipType': vip},
          }),
        );
        await request.response.close();
      });
      final remote = RemoteNcmProvider(
        config: RemoteProviderConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      addTearDown(remote.dispose);
      final credentials = InMemoryCredentialStorage();
      await credentials.write('session_token', 'MUSIC_U=fixture');
      final directory = Directory.systemTemp.createTempSync(
        'ff-quality-startup',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      await FileQualityPreferenceStore(
        directory.path,
      ).write(AudioQuality.hiRes);

      Future<void> launch(AudioQuality expected) async {
        final media = FakeMediaController();
        final quality = QualityController(
          media: media,
          accountStore: (account) => FileQualityPreferenceStore(
            directory.path,
            account: account,
            migrateLegacy: account != 'guest',
          ),
        );
        late CredentialCoordinator auth;
        var restored = false;
        auth = CredentialCoordinator(
          storage: credentials,
          authClient: remote,
          restorePlayback: (account) async {
            await quality.activateAccount(
              account,
              isVip: (auth.currentSession?.user.vipType ?? 0) > 0,
            );
            expect(quality.preference, expected);
            expect(media.preferredQuality, expected);
            restored = true;
          },
        );
        try {
          final session = await auth.restoreSession();
          expect(session!.user.vipType, vip);
          expect(restored, isTrue);
          expect(
            await FileQualityPreferenceStore(
              directory.path,
              account: 'ncm-user-1',
            ).read(),
            expected,
          );
        } finally {
          auth.dispose();
          await quality.dispose();
        }
      }

      await launch(AudioQuality.hiRes);
      vip = 0; // Membership expired since the previous successful launch.
      await launch(AudioQuality.high);
      await launch(AudioQuality.high);
    },
  );

  test(
    'VIP to free to VIP retains cached quality menu and source isolation',
    () async {
      var login = 'VIP';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final vip = (req.uri.queryParameters['cookie'] ?? '').contains(
          'MUSIC_U=VIP',
        );
        final body = switch (req.uri.path) {
          '/login/qr/check' => {'code': 803, 'cookie': 'MUSIC_U=$login'},
          '/user/account' => {
            'code': 200,
            'profile': {
              'userId': vip ? 1 : 2,
              'nickname': vip ? 'VIP' : 'Free',
              'vipType': vip ? 11 : 0,
            },
          },
          '/song/detail' => {
            'code': 200,
            'songs': [
              {
                'id': 1,
                'name': 'Same song',
                'dt': 180000,
                'ar': [
                  {'id': 1, 'name': 'Artist'},
                ],
                'al': {'id': 1, 'name': 'Album'},
              },
            ],
            'privileges': [
              {
                'id': 1,
                'fee': 0,
                'flLevel': 'standard',
                'pl': vip ? 999000 : 128000,
                'playMaxbr': vip ? 999000 : 128000,
                'playMaxBrLevel': vip ? 'hires' : 'standard',
              },
            ],
          },
          '/song/url/v1' => {
            'code': 200,
            'data': [
              {
                'id': 1,
                'url': vip
                    ? 'https://cdn.example/vip.flac'
                    : 'https://cdn.example/free.mp3',
                'level': vip ? 'hires' : 'standard',
                'expi': 1200,
              },
            ],
          },
          _ => {'code': 200},
        };
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
      final remote = RemoteNcmProvider(
        config: RemoteProviderConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      addTearDown(remote.dispose);
      final broker = PlaybackSourceBroker(resolver: remote);
      final auth = CredentialCoordinator(
        storage: InMemoryCredentialStorage(),
        authClient: remote,
        broker: broker,
      );
      addTearDown(auth.dispose);
      final dir = Directory.systemTemp.createTempSync('ff-vip-audit');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = SqliteMetadataCacheStore.open(path: '${dir.path}/cache.db');
      addTearDown(store.close);
      final cached = CachedCatalogRepository(
        remote: remote,
        store: store,
        accountContext: () => CatalogCacheContext(
          namespace: 'ncm',
          accountId: auth.currentSession!.user.userId.value,
          accountEpoch: auth.authEpoch,
        ),
        backgroundRefresh: false,
      );
      addTearDown(cached.dispose);
      const id = TrackId('ncm-1');
      await auth.completeLogin('qr');
      final first = await cached.getTrack(
        id,
        policy: RefreshPolicy.forceRefresh,
      );
      final vipSource = await broker.resolve(
        id,
        AudioQuality.hiRes,
        NetworkPolicy.onlineOnly,
      );
      expect(auth.currentSession!.user.vipType, 11);
      expect(first.maxPotentialQuality, TrackQuality.hiRes);
      expect(supportedQualitiesFor(first), contains(AudioQuality.hiRes));
      expect(vipSource.uri.path, '/vip.flac');
      login = 'FREE';
      await auth.completeLogin('qr');
      final free = await cached.getTrack(
        id,
        policy: RefreshPolicy.forceRefresh,
      );
      final freeSource = await broker.resolve(
        id,
        AudioQuality.hiRes,
        NetworkPolicy.onlineOnly,
      );
      expect(auth.currentSession!.user.vipType, 0);
      expect(free.maxPotentialQuality, TrackQuality.standard);
      expect(supportedQualitiesFor(free), [AudioQuality.standard]);
      expect(freeSource.uri.path, '/free.mp3');
      expect(freeSource.actualQuality, AudioQuality.standard);
      await auth.switchAccount(const UserId('ncm-user-1'));
      final again = await cached.getTrack(id, policy: RefreshPolicy.localOnly);
      final againSource = await broker.resolve(
        id,
        AudioQuality.hiRes,
        NetworkPolicy.onlineOnly,
      );
      expect(auth.currentSession!.user.vipType, 11);
      expect(again.maxPotentialQuality, TrackQuality.hiRes);
      expect(supportedQualitiesFor(again), contains(AudioQuality.hiRes));
      expect(again.availability, TrackAvailability.full);
      expect(againSource.uri.path, '/vip.flac');
    },
  );
}
