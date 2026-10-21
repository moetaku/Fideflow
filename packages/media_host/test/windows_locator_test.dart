import 'dart:io';

import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('ff-资源 定位-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('Windows packaged resources live beside the executable', () {
    final exe = '${root.path}/fideflow.exe';
    File('${root.path}/ff_media_core.dll').writeAsStringSync('');
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.windows,
        environment: const {},
        executablePath: exe,
      ),
      '${root.path}/ff_media_core.dll',
    );
  });

  test('missing Windows DLL does not load a macOS library', () {
    File('${root.path}/libff_media_core.dylib').writeAsStringSync('');
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.windows,
        environment: const {},
        executablePath: '${root.path}/fideflow.exe',
      ),
      isNull,
    );
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.unsupported,
        environment: const {},
        executablePath: '${root.path}/fideflow',
      ),
      isNull,
    );
  });

  test(
    'explicit overrides win even when missing; empty overrides use packaging',
    () {
      File('${root.path}/ff_media_core.dll').writeAsStringSync('');
      final exe = '${root.path}/fideflow.exe';
      expect(
        resolveMediaCoreLibraryPath(
          platform: DesktopPlatform.windows,
          environment: const {mediaCoreLibraryEnv: 'D:/custom.dll'},
          executablePath: exe,
        ),
        'D:/custom.dll',
      );
      expect(
        resolveMediaCoreLibraryPath(
          platform: DesktopPlatform.windows,
          environment: const {mediaCoreLibraryEnv: ''},
          executablePath: exe,
        ),
        '${root.path}/ff_media_core.dll',
      );
    },
  );
}
