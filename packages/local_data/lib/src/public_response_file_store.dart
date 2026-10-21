import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';

/// A bounded file adapter for the two anonymous playlist taxonomy responses.
///
/// The response paths are translated to fixed filenames; caller-provided keys
/// never become filesystem paths. Cache persistence is best effort: unreadable
/// data is a miss and failed writes are ignored.
final class PublicResponseFileStore implements PublicResponseCacheStore {
  PublicResponseFileStore(this.directory);

  /// Directory owned by the app for local provider cache responses.
  final String directory;

  static const int _schemaVersion = 1;
  static const int _maxFileBytes = 1024 * 1024;
  static const _files = <String, String>{
    '/playlist/catlist': 'taxonomy-catlist.json',
    '/playlist/hot': 'taxonomy-hot.json',
  };

  Future<void> _writeQueue = Future<void>.value();
  int _temporaryFileSequence = 0;

  File? _fileFor(String key) {
    final name = _files[key];
    return name == null ? null : File('$directory/$name');
  }

  @override
  Future<PublicResponseCacheEntry?> read(String key) async {
    final file = _fileFor(key);
    if (file == null) return null;
    await _writeQueue;

    try {
      if (await file.length() > _maxFileBytes) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != _schemaVersion ||
          decoded['fetchedAt'] is! String ||
          decoded['body'] is! Map<String, dynamic>) {
        return null;
      }
      final fetchedAt = DateTime.tryParse(decoded['fetchedAt']! as String);
      if (fetchedAt == null) return null;
      final body = (decoded['body']! as Map<String, dynamic>)
          .cast<String, Object?>();
      return PublicResponseCacheEntry(fetchedAt: fetchedAt.toUtc(), body: body);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  Future<void> write(String key, PublicResponseCacheEntry entry) {
    final file = _fileFor(key);
    if (file == null) return Future<void>.value();

    final operation = _writeQueue.then((_) => _writeBestEffort(file, entry));
    _writeQueue = operation.catchError((Object _) {});
    return _writeQueue;
  }

  Future<void> _writeBestEffort(
    File file,
    PublicResponseCacheEntry entry,
  ) async {
    File? temp;
    try {
      await file.parent.create(recursive: true);
      final sequence = _temporaryFileSequence++;
      temp = File('${file.path}.$pid.$sequence.tmp');
      final text = jsonEncode({
        'schemaVersion': _schemaVersion,
        'fetchedAt': entry.fetchedAt.toUtc().toIso8601String(),
        'body': entry.body,
      });
      if (utf8.encode(text).length > _maxFileBytes) return;
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    } on FileSystemException {
      // Persistence is best effort; a later read will report a cache miss.
    } on JsonUnsupportedObjectError {
      // An unsupported body must not disrupt the caller's network result.
    } finally {
      if (temp != null) {
        try {
          if (await temp.exists()) await temp.delete();
        } on FileSystemException {
          // Best-effort cleanup of a partial temporary file.
        }
      }
    }
  }
}
