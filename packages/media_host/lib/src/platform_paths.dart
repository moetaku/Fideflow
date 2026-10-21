import 'dart:io';

/// Explicit platform selection keeps path and packaging tests host-independent.
enum DesktopPlatform { macos, windows, linux, android, ios, unsupported }

DesktopPlatform get currentDesktopPlatform => Platform.isMacOS
    ? DesktopPlatform.macos
    : Platform.isWindows
    ? DesktopPlatform.windows
    : Platform.isLinux
    ? DesktopPlatform.linux
    : Platform.isAndroid
    ? DesktopPlatform.android
    : Platform.isIOS
    ? DesktopPlatform.ios
    : DesktopPlatform.unsupported;

/// Application-owned writable locations. Resolving paths never creates files.
final class PlatformPaths {
  const PlatformPaths({this.dataDirectory, this.cacheDirectory});

  factory PlatformPaths.resolve({
    Map<String, String>? environment,
    DesktopPlatform? platform,
  }) {
    final env = environment ?? Platform.environment;
    final target = platform ?? currentDesktopPlatform;
    String? value(String key) {
      final result = env[key];
      return result == null || result.trim().isEmpty ? null : result;
    }

    if (target == DesktopPlatform.windows) {
      final local = value('LOCALAPPDATA');
      if (local == null) return const PlatformPaths();
      return PlatformPaths(
        dataDirectory: '$local/Fideflow',
        cacheDirectory: '$local/Fideflow/cache',
      );
    }
    if (target == DesktopPlatform.linux) {
      final home = value('HOME');
      final usableHome = home != null && home.startsWith('/') ? home : null;
      final xdgData = value('XDG_DATA_HOME');
      final xdgCache = value('XDG_CACHE_HOME');
      final dataRoot = _absolutePosix(value('XDG_DATA_HOME'))
          ? xdgData
          : usableHome == null
          ? null
          : '$usableHome/.local/share';
      final cacheRoot = _absolutePosix(value('XDG_CACHE_HOME'))
          ? xdgCache
          : usableHome == null
          ? null
          : '$usableHome/.cache';
      return PlatformPaths(
        dataDirectory: dataRoot == null ? null : '$dataRoot/Fideflow',
        cacheDirectory: cacheRoot == null ? null : '$cacheRoot/Fideflow',
      );
    }
    if (target == DesktopPlatform.android || target == DesktopPlatform.ios) {
      throw StateError(
        'Mobile paths must be resolved by the application before composition',
      );
    }
    if (target != DesktopPlatform.macos) return const PlatformPaths();
    // Preserve existing macOS paths.
    final home = value('HOME');
    if (home == null) return const PlatformPaths();
    return PlatformPaths(
      dataDirectory: '$home/Library/Application Support/Fideflow',
      cacheDirectory: '$home/Library/Caches/Fideflow',
    );
  }

  final String? dataDirectory;
  final String? cacheDirectory;
  String? dataFile(String name) =>
      dataDirectory == null ? null : '$dataDirectory/$name';
  String? cacheFile(String name) =>
      cacheDirectory == null ? null : '$cacheDirectory/$name';
  String? get settingsDirectory => dataFile('settings');
  String? get credentialsDirectory => dataFile('credentials');
  String? get playbackDirectory => dataFile('playback');
  String? get fakePlaybackDirectory => dataFile('fake-playback');
  String? get metadataDirectory => dataFile('cache');
  String? get artworkDirectory => cacheFile('artwork');
  String? get playbackCacheDirectory => cacheFile('playback');
}

bool _absolutePosix(String? path) => path != null && path.startsWith('/');

/// Moves the two known Linux-era mislocated directories into the Linux data
/// and cache roots. Existing destinations always win; old data is left intact
/// when a destination already exists or a move cannot be completed.
Future<void> migrateLegacyLinuxDirectories({
  required PlatformPaths paths,
  required String? homeDirectory,
}) async {
  if (homeDirectory == null || !homeDirectory.startsWith('/')) return;
  await _moveIfDestinationMissing(
    '${homeDirectory.replaceFirst(RegExp(r'/$'), '')}/Library/Application Support/Fideflow',
    paths.dataDirectory,
  );
  await _moveIfDestinationMissing(
    '${homeDirectory.replaceFirst(RegExp(r'/$'), '')}/Library/Caches/Fideflow',
    paths.cacheDirectory,
  );
}

Future<void> _moveIfDestinationMissing(
  String sourcePath,
  String? destinationPath,
) async {
  if (destinationPath == null || sourcePath == destinationPath) return;
  final source = Directory(sourcePath);
  if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
          FileSystemEntityType.directory ||
      await FileSystemEntity.type(destinationPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
    return;
  }
  try {
    await Directory(destinationPath).parent.create(recursive: true);
    await source.rename(destinationPath);
  } on FileSystemException {
    // Directory.rename is atomic and never merges into an existing target.
    // Cross-filesystem moves need a user-mediated copy; leave the source intact.
    stderr.writeln(
      'Fideflow: could not move legacy data at $sourcePath to $destinationPath; '
      'the original data was preserved',
    );
  }
}
