import 'dart:io';

/// Resolves app resources from either the repository or app working directory.
String testResourcePath(String relativePath) {
  var directory = Directory.current.absolute;
  while (true) {
    for (final candidate in [
      directory,
      Directory.fromUri(directory.uri.resolve('apps/fideflow_flutter/')),
    ]) {
      if (File.fromUri(candidate.uri.resolve('pubspec.yaml')).existsSync() &&
          File.fromUri(
            candidate.uri.resolve('lib/l10n/app_zh_Hans.arb'),
          ).existsSync()) {
        final resource = File.fromUri(candidate.uri.resolve(relativePath));
        if (!resource.existsSync()) {
          throw FileSystemException(
            'Test resource does not exist',
            resource.path,
          );
        }
        return resource.path;
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw FileSystemException(
        'Cannot locate the Flutter app from ${Directory.current.path}',
        relativePath,
      );
    }
    directory = parent;
  }
}
