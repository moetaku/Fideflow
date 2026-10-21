import 'dart:io';

import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ff-locator-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Creates a bundle-shaped directory tree and returns its main executable path.
  String bundleWith({required bool library}) {
    final bundle = '${root.path}/fideflow.app';
    final executable = '$bundle/Contents/MacOS/fideflow';
    Directory('$bundle/Contents/MacOS').createSync(recursive: true);
    Directory('$bundle/Contents/Frameworks').createSync(recursive: true);
    File(executable).writeAsStringSync('');
    if (library) {
      File(
        '$bundle/Contents/Frameworks/$mediaCoreLibraryName',
      ).writeAsStringSync('');
    }
    return executable;
  }

  test('finds the packaged library next to the app bundle frameworks', () {
    final executable = bundleWith(library: true);

    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.macos,
        environment: const {},
        executablePath: executable,
      ),
      '${root.path}/fideflow.app/Contents/Frameworks/$mediaCoreLibraryName',
    );
  });

  test('reports no library when the bundle carries none', () {
    final executable = bundleWith(library: false);

    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.macos,
        environment: const {},
        executablePath: executable,
      ),
      isNull,
      reason: 'a Debug build without a native prefix must fall back, not fail',
    );
  });

  test('finds the Linux library in the install root lib directory', () {
    final bundle = '${root.path}/bundle';
    final executable = '$bundle/fideflow';
    Directory(bundle).createSync(recursive: true);
    Directory('$bundle/lib').createSync(recursive: true);
    File(executable).writeAsStringSync('');
    File('$bundle/lib/$linuxMediaCoreLibraryName').writeAsStringSync('');
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.linux,
        environment: const {},
        executablePath: executable,
      ),
      '$bundle/lib/$linuxMediaCoreLibraryName',
    );
  });
  test('prefers an explicit override, including one that names nothing', () {
    final executable = bundleWith(library: true);

    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.macos,
        environment: {mediaCoreLibraryEnv: '/opt/ff/libff_media_core.dylib'},
        executablePath: executable,
      ),
      '/opt/ff/libff_media_core.dylib',
      reason:
          'the override is how a dev tree or a test points at a fresh build',
    );
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.macos,
        environment: {mediaCoreLibraryEnv: ''},
        executablePath: executable,
      ),
      '${root.path}/fideflow.app/Contents/Frameworks/$mediaCoreLibraryName',
      reason: 'an empty override falls back to the bundle',
    );
  });
}
