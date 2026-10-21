import 'dart:io';

import 'platform_paths.dart';

/// File name the Rust media host is packaged under. Kept in step with
/// `tooling/native/macos/rust.sh` and `tooling/check_contracts.py`.
const mediaCoreLibraryName = 'libff_media_core.dylib';
const windowsMediaCoreLibraryName = 'ff_media_core.dll';
const linuxMediaCoreLibraryName = 'libff_media_core.so';

/// Environment override, for a dev tree or a test that builds the library by
/// hand: `FF_MEDIA_CORE_LIBRARY=/path/to/libff_media_core.dylib`.
const mediaCoreLibraryEnv = 'FF_MEDIA_CORE_LIBRARY';

/// Where the native media host lives, or null when this platform has none yet.
///
/// Packaged resources:
///
/// * the app bundle, next to the FFmpeg libraries that the Rust host links
///   (`Contents/MacOS/<exe>` -> `Contents/Frameworks`), and
/// * Windows: the DLL beside the application executable, and
/// * the `FF_MEDIA_CORE_LIBRARY` override.
///
/// Returning null is not an error: the composition root falls back to the fake
/// controller, which is exactly what a Debug build without a Rust toolchain
/// gets.
String? resolveMediaCoreLibraryPath({
  Map<String, String>? environment,
  String? executablePath,
  DesktopPlatform? platform,
}) {
  final override = (environment ?? Platform.environment)[mediaCoreLibraryEnv];
  if (override != null && override.isNotEmpty) {
    return override;
  }
  final target = platform ?? currentDesktopPlatform;
  if (target == DesktopPlatform.unsupported) {
    return null;
  }
  if (target == DesktopPlatform.android) return linuxMediaCoreLibraryName;
  final executable = executablePath ?? Platform.resolvedExecutable;
  if (target == DesktopPlatform.linux) {
    final candidate = File(
      '${File(executable).parent.path}/lib/$linuxMediaCoreLibraryName',
    );
    return candidate.existsSync() ? candidate.path : null;
  }
  if (target == DesktopPlatform.windows) {
    final candidate = File(
      '${File(executable).parent.path}/$windowsMediaCoreLibraryName',
    );
    return candidate.existsSync() ? candidate.path : null;
  }
  if (target == DesktopPlatform.ios) {
    return '${File(executable).parent.path}/Frameworks/FFMediaCore.framework/FFMediaCore';
  }
  final candidate = File(
    '${File(executable).parent.parent.path}/Frameworks/$mediaCoreLibraryName',
  );
  return candidate.existsSync() ? candidate.path : null;
}
