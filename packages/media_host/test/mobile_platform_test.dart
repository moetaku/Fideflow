import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

void main() {
  test('Android resolves the loader soname without desktop paths', () {
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.android,
        environment: {},
      ),
      'libff_media_core.so',
    );
  });
  test('iOS resolves the embedded dynamic framework', () {
    expect(
      resolveMediaCoreLibraryPath(
        platform: DesktopPlatform.ios,
        environment: {},
        executablePath: '/private/app/Runner.app/Runner',
      ),
      '/private/app/Runner.app/Frameworks/FFMediaCore.framework/FFMediaCore',
    );
  });
  test('mobile paths must be injected instead of guessing HOME', () {
    for (final platform in [DesktopPlatform.android, DesktopPlatform.ios]) {
      expect(
        () => PlatformPaths.resolve(
          platform: platform,
          environment: {'HOME': '/wrong'},
        ),
        throwsStateError,
      );
    }
  });
}
