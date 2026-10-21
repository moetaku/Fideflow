import 'dart:convert';
import 'dart:io';

/// Device-wide effects preferences, independent of account playback records.
final class FilePlaybackEffectsStore {
  FilePlaybackEffectsStore(this.directory);
  final String directory;
  File get _file => File('$directory/playback-effects.json');
  Future<({bool fadeEnabled, bool volumeNormalizationEnabled})?> read() async {
    try {
      final value = jsonDecode(await _file.readAsString());
      if (value is! Map ||
          value['version'] != 1 ||
          value['fadeEnabled'] is! bool ||
          value['volumeNormalizationEnabled'] is! bool) {
        return null;
      }
      return (
        fadeEnabled: value['fadeEnabled'] as bool,
        volumeNormalizationEnabled: value['volumeNormalizationEnabled'] as bool,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(bool fadeEnabled, bool volumeNormalizationEnabled) async {
    final file = _file;
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'fadeEnabled': fadeEnabled,
          'volumeNormalizationEnabled': volumeNormalizationEnabled,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
