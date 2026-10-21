import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['FF_NCM_HOST_LIVE'] == '1';
  test(
    'live Host anonymous search, playlists, QR status and source resolution',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fideflow-host-live-',
      );
      final api = FfiMediaCoreApi.open(
        libraryPath: Platform.environment['FF_NCM_HOST_TEST_LIBRARY'],
      );
      final identity = InstallDeviceIdStore(homeDirectory: directory.path);
      final provider = RemoteNcmProvider(
        transport: NativeNcmTransport(api),
        deviceIdProvider: identity.loadOrCreate,
      );
      try {
        final tracks = await provider.searchTracks(
          const SearchQuery(keywords: '晴天', limit: 3),
        );
        expect(tracks.items.isNotEmpty, isTrue);
        final playlists = await provider.getRecommendedPlaylists();
        expect(playlists.playlists.isNotEmpty, isTrue);
        final detail = await provider.getPlaylist(playlists.playlists.first.id);
        expect(detail.tracks.isNotEmpty, isTrue);
        final qr = await provider.createQrCodeSession();
        expect(qr.unikey.isNotEmpty, isTrue);
        final scan = await provider.checkQrCodeStatus(qr.unikey);
        expect(scan.status, isNot(QrCodeScanStatus.authorized));
        final source = await provider.resolve(
          tracks.items.first.id,
          AudioQuality.standard,
          NetworkPolicy.onlineOnly,
        );
        expect(source.uri.scheme, anyOf('http', 'https'));
      } finally {
        provider.dispose();
        api.close();
        await directory.delete(recursive: true);
      }
    },
    skip: enabled
        ? false
        : 'Set FF_NCM_HOST_LIVE=1 and FF_NCM_HOST_TEST_LIBRARY for a real upstream probe',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
