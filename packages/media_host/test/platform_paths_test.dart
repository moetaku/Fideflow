import 'dart:io';

import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows uses LOCALAPPDATA independently of HOME and working directory',
    () {
      final paths = PlatformPaths.resolve(
        platform: DesktopPlatform.windows,
        environment: const {
          'LOCALAPPDATA': 'C:/Users/测试 用户/AppData/Local',
          'HOME': '/wrong',
        },
      );
      const base = 'C:/Users/测试 用户/AppData/Local/Fideflow';
      expect(paths.dataDirectory, base);
      expect(paths.settingsDirectory, '$base/settings');
      expect(paths.credentialsDirectory, '$base/credentials');
      expect(paths.playbackDirectory, '$base/playback');
      expect(paths.fakePlaybackDirectory, '$base/fake-playback');
      expect(paths.metadataDirectory, '$base/cache');
      expect(paths.artworkDirectory, '$base/cache/artwork');
      expect(paths.playbackCacheDirectory, '$base/cache/playback');
    },
  );

  test('macOS retains both Application Support and Caches layouts', () {
    final paths = PlatformPaths.resolve(
      platform: DesktopPlatform.macos,
      environment: const {'HOME': '/Users/test', 'LOCALAPPDATA': '/wrong'},
    );
    expect(
      paths.dataDirectory,
      '/Users/test/Library/Application Support/Fideflow',
    );
    expect(
      paths.metadataDirectory,
      '/Users/test/Library/Application Support/Fideflow/cache',
    );
    expect(
      paths.artworkDirectory,
      '/Users/test/Library/Caches/Fideflow/artwork',
    );
    expect(
      paths.playbackCacheDirectory,
      '/Users/test/Library/Caches/Fideflow/playback',
    );
  });

  test('Linux uses absolute XDG roots and ignores relative overrides', () {
    final paths = PlatformPaths.resolve(
      platform: DesktopPlatform.linux,
      environment: const {
        'HOME': '/home/tester',
        'XDG_DATA_HOME': 'relative/data',
        'XDG_CACHE_HOME': '/mnt/cache-root',
      },
    );
    expect(paths.dataDirectory, '/home/tester/.local/share/Fideflow');
    expect(paths.cacheDirectory, '/mnt/cache-root/Fideflow');
    final noHome = PlatformPaths.resolve(
      platform: DesktopPlatform.linux,
      environment: const {'XDG_DATA_HOME': '/data', 'XDG_CACHE_HOME': 'cache'},
    );
    expect(noHome.dataDirectory, '/data/Fideflow');
    expect(noHome.cacheDirectory, isNull);
  });

  test(
    'Linux migration moves legacy directories without overwriting',
    () async {
      final home = await Directory.systemTemp.createTemp('ff-linux-home-');
      try {
        final oldData = Directory(
          '${home.path}/Library/Application Support/Fideflow',
        )..createSync(recursive: true);
        File('${oldData.path}/settings.json').writeAsStringSync('legacy');
        final oldCache = Directory('${home.path}/Library/Caches/Fideflow')
          ..createSync(recursive: true);
        File('${oldCache.path}/cover.bin').writeAsStringSync('cached');
        final paths = PlatformPaths(
          dataDirectory: '${home.path}/.local/share/Fideflow',
          cacheDirectory: '${home.path}/.cache/Fideflow',
        );

        await migrateLegacyLinuxDirectories(
          paths: paths,
          homeDirectory: home.path,
        );

        expect(
          await File('${paths.dataDirectory}/settings.json').readAsString(),
          'legacy',
        );
        expect(
          await File('${paths.cacheDirectory}/cover.bin').readAsString(),
          'cached',
        );
        expect(await oldData.exists(), isFalse);
        expect(await oldCache.exists(), isFalse);

        final conflictingLegacy = Directory(
          '${home.path}/Library/Application Support/Fideflow',
        )..createSync(recursive: true);
        File(
          '${conflictingLegacy.path}/settings.json',
        ).writeAsStringSync('keep-old');
        File(
          '${paths.dataDirectory}/settings.json',
        ).writeAsStringSync('keep-new');
        await migrateLegacyLinuxDirectories(
          paths: paths,
          homeDirectory: home.path,
        );
        expect(
          await File('${conflictingLegacy.path}/settings.json').readAsString(),
          'keep-old',
        );
        expect(
          await File('${paths.dataDirectory}/settings.json').readAsString(),
          'keep-new',
        );
      } finally {
        await home.delete(recursive: true);
      }
    },
  );

  test(
    'missing or blank roots do not borrow another platform or current directory',
    () {
      for (final env in <Map<String, String>>[
        {},
        {'LOCALAPPDATA': '  ', 'HOME': '/wrong'},
      ]) {
        final paths = PlatformPaths.resolve(
          platform: DesktopPlatform.windows,
          environment: env,
        );
        expect(paths.dataDirectory, isNull);
        expect(paths.playbackCacheDirectory, isNull);
      }
      expect(
        PlatformPaths.resolve(
          platform: DesktopPlatform.macos,
          environment: const {},
        ).dataDirectory,
        isNull,
      );
    },
  );

  test(
    'injected Windows storage persists one device ID across store instances',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ff-windows-identity-',
      );
      try {
        final paths = PlatformPaths.resolve(
          platform: DesktopPlatform.windows,
          environment: {'LOCALAPPDATA': root.path},
        );
        final ids = await Future.wait([
          InstallDeviceIdStore(paths: paths).loadOrCreate(),
          InstallDeviceIdStore(paths: paths).loadOrCreate(),
        ]);
        expect(ids.toSet(), hasLength(1));
        expect(
          await File(paths.dataFile('device-id')!).readAsString(),
          ids.first,
        );
        expect(
          await InstallDeviceIdStore(paths: paths).loadOrCreate(),
          ids.first,
        );
        expect(await Directory('${root.path}/Library').exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
