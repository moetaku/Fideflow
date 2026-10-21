import 'dart:convert';
import 'dart:io';

import 'playback_checkpoint.dart';
import 'playback_checkpoint_store.dart';

/// A one-file-per-account store for the app's application-data directory.
///
/// Writes go to a temporary file and are renamed over the target, so a crash
/// mid-write leaves the previous checkpoint intact rather than a half-written
/// one. A read that finds anything it cannot parse reports "no checkpoint"
/// instead of throwing: a restore is best-effort and must never block a launch.
final class FilePlaybackCheckpointStore implements PlaybackCheckpointStore {
  FilePlaybackCheckpointStore(this.directory);

  /// The directory the per-account files live in. Created on first write.
  final String directory;

  static final RegExp _unsafe = RegExp(r'[^A-Za-z0-9._-]');

  File _fileFor(String account) {
    final safe = account.isEmpty ? 'guest' : account.replaceAll(_unsafe, '_');
    return File('$directory/playback-$safe.json');
  }

  @override
  Future<PlaybackCheckpoint?> read(String account) async {
    final file = _fileFor(account);
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      // Absent, unreadable or gone: all mean "nothing to restore".
      return null;
    }
    try {
      return PlaybackCheckpoint.fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(PlaybackCheckpoint checkpoint) async {
    final file = _fileFor(checkpoint.accountId);
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(jsonEncode(checkpoint.toJson()), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Future<void> clear(String account) async {
    final file = _fileFor(account);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone, or not ours to delete: the goal is "no checkpoint", and a
      // failed delete is reported by the next read finding nothing usable.
    }
  }
}
