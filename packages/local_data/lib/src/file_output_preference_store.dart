import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';

/// Device-wide output intent, independent of account checkpoints.
final class FileOutputPreferenceStore {
  FileOutputPreferenceStore(this.directory);
  final String directory;
  File get _file => File('$directory/output-preference.json');
  Future<
    ({
      String? deviceUid,
      bool exclusive,
      bool resamplingEnabled,
      int targetSampleRate,
    })?
  >
  read() async {
    try {
      final value = jsonDecode(await _file.readAsString());
      if (value is! Map ||
          value['version'] != 1 ||
          value['exclusive'] is! bool) {
        return null;
      }
      final uid = value['deviceUid'];
      if (uid != null &&
          (uid is! String ||
              uid.isEmpty ||
              utf8.encode(uid).length > 1023 ||
              uid.contains('\u0000'))) {
        return null;
      }
      final enabled = value['resamplingEnabled'] ?? false;
      final rate = value['targetSampleRate'] ?? 48000;
      if (enabled is! bool ||
          rate is! int ||
          !resamplingSampleRates.contains(rate)) {
        return null;
      }
      return (
        deviceUid: uid as String?,
        exclusive: value['exclusive'] as bool,
        resamplingEnabled: enabled,
        targetSampleRate: rate,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(
    String? deviceUid,
    bool exclusive, {
    bool resamplingEnabled = false,
    int targetSampleRate = 48000,
  }) async {
    if (!resamplingSampleRates.contains(targetSampleRate)) {
      throw ArgumentError.value(targetSampleRate, 'targetSampleRate');
    }
    final file = _file;
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'deviceUid': deviceUid,
          'exclusive': exclusive,
          'resamplingEnabled': resamplingEnabled,
          'targetSampleRate': targetSampleRate,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
