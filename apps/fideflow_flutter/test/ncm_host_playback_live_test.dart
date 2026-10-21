import 'dart:io';

import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'live Rust NCM Host feeds Dart audio cache and native playback clock',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fideflow-host-audio-',
      );
      final api = FfiMediaCoreApi.open(
        libraryPath: Platform.environment['FF_NCM_HOST_TEST_LIBRARY'],
      );
      final provider = RemoteNcmProvider(
        transport: NativeNcmTransport(api),
        deviceIdProvider: InstallDeviceIdStore(
          homeDirectory: directory.path,
        ).loadOrCreate,
      );
      final cache = PlaybackCache(Directory('${directory.path}/audio'));
      final resolver = CachedAudioResolver(
        upstream: provider,
        cache: cache,
        account: () => 'guest',
        epoch: () => 0,
      );
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      try {
        final found = await provider.searchTracks(
          const SearchQuery(keywords: '晴天', limit: 1),
        );
        expect(found.items.isNotEmpty, isTrue);
        expect(
          (await controller.executeHostCommand(
            const SetVolume(commandId: 'mute', permille: 0),
          )).isAccepted,
          isTrue,
        );
        expect(
          (await controller.executeHostCommand(
            LoadQueue(
              commandId: 'host-live',
              tracks: found.items,
              autoplay: true,
            ),
          )).isAccepted,
          isTrue,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        var snapshot = await controller.getSnapshot();
        while (snapshot.position < const Duration(milliseconds: 500) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          snapshot = await controller.getSnapshot();
        }
        expect(
          snapshot.position >= const Duration(milliseconds: 500),
          isTrue,
          reason: 'Native playback must consume Host-resolved audio bytes',
        );
        expect(api.inputBytesWritten, greaterThan(0));
        await controller.executeHostCommand(const Stop(commandId: 'stop'));
      } finally {
        provider.dispose();
        await controller.close();
        await resolver.close();
        await cache.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['FF_NCM_HOST_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
