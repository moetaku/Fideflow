import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';

import 'quality_preference_store.dart';

/// A store with one file per account in the app's application-data directory.
///
/// Writes go to a temporary file and are renamed over the target, so a crash
/// mid-write leaves the previous preference intact rather than a half-written
/// one. Unrecognized saved data falls back to lossless SQ; an absent or
/// unreadable file reports nothing stored and does not block playback.
final class FileQualityPreferenceStore implements QualityPreferenceStore {
  FileQualityPreferenceStore(
    this.directory, {
    this.account,
    this.migrateLegacy = false,
  });

  /// Only the first verified account may adopt the old device-wide setting.
  /// Guests and demo accounts must never consume it.
  final bool migrateLegacy;

  /// Null retains the legacy file; account keys use separate immutable paths.
  final String? account;

  /// The directory the file lives in. Created on first write.
  final String directory;

  File get _file {
    final owner = account;
    final name = owner == null
        ? 'quality-preference'
        : 'quality-preference-${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}';
    return File('$directory/$name.json');
  }

  @override
  Future<AudioQuality?> read() async {
    final String text;
    try {
      if (account != null && migrateLegacy && !await _file.exists()) {
        final legacy = File('$directory/quality-preference.json');
        if (await legacy.exists()) await legacy.rename(_file.path);
      }
      text = await _file.readAsString();
    } on FileSystemException {
      // Absent, unreadable or gone: all mean "nothing stored".
      return null;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) return AudioQuality.lossless;
      final name = decoded['quality'];
      return qualityPreferenceFromName(name is String ? name : null);
    } on FormatException {
      return AudioQuality.lossless;
    }
  }

  @override
  Future<void> write(AudioQuality quality) async {
    final file = _file;
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(
        jsonEncode({'quality': qualityPreferenceName(quality)}),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
