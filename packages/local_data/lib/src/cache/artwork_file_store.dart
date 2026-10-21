import 'dart:io';

/// The artwork files the index points at (design §4, §8).
///
/// Bytes are staged in a temporary file beside their destination, verified by
/// the caller, and renamed into place only then, so a committed index row never
/// points at a file a reader could catch half-written. Every path is relative to
/// [root], which keeps moving the cache root from invalidating the index.
///
/// This layer does no networking and no policy: it stores and removes bytes. It
/// refuses a path that could escape [root], which matters because a path is
/// derived from a provider-supplied asset key.
final class ArtworkFileStore {
  ArtworkFileStore({required this.root});

  /// The artwork cache root, created lazily on the first write.
  final String root;

  /// Writes [bytes] aside [relativePath] and returns the staged file's path.
  ///
  /// The caller verifies the staged file — media type, dimensions, that it
  /// decodes — and then either [commit]s it or [discard]s it.
  Future<String> stage(String relativePath, List<int> bytes) async {
    final target = _file(relativePath);
    await target.parent.create(recursive: true);
    final staged = File(
      '${target.path}.part-${DateTime.now().microsecondsSinceEpoch}',
    );
    await staged.writeAsBytes(bytes, flush: true);
    return staged.path;
  }

  /// Renames a staged file over [relativePath], replacing any older version.
  Future<void> commit(String stagedPath, String relativePath) async {
    await File(stagedPath).rename(_file(relativePath).path);
  }

  /// Removes a staged file whose verification failed.
  Future<void> discard(String stagedPath) async {
    try {
      final staged = File(stagedPath);
      if (staged.existsSync()) await staged.delete();
    } on FileSystemException {
      // A staged file that is already gone is the outcome this wanted.
    }
  }

  /// The bytes at [relativePath], or null when there is no readable file.
  ///
  /// A missing, unreadable or directory-shaped path is a miss: a cover is not
  /// worth taking a page down for (design §4).
  Future<List<int>?> read(String relativePath) async {
    try {
      final file = _file(relativePath);
      if (!file.existsSync()) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// Removes one file, ignoring a path that is already gone.
  Future<void> delete(String relativePath) async {
    try {
      final file = _file(relativePath);
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Nothing to remove is not a failure.
    }
  }

  /// Removes several files, as the store reports them when a row is evicted.
  Future<void> deleteAll(Iterable<String> relativePaths) async {
    for (final path in relativePaths) {
      await delete(path);
    }
  }

  File _file(String relativePath) {
    if (relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.contains('\\') ||
        relativePath.contains(':') ||
        relativePath.contains('\u0000') ||
        relativePath.split('/').contains('..')) {
      // A path is built from an opaque asset key, so this can only be a bug or a
      // tampered index row; refusing it keeps the cache inside its root.
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'not a safe path',
      );
    }
    return File('$root/$relativePath');
  }
}
