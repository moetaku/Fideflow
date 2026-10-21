import 'dart:convert';
import 'dart:io';

/// App-owned settings keep one instance per file for the lifetime of the app.
/// Writes preserve edit order and replace the destination only after flushing.
final class JsonSettingsFile {
  JsonSettingsFile(this.file);

  final File file;
  Future<void> _writes = Future.value();

  Future<Object?> read() async {
    await flush();
    try {
      return jsonDecode(await file.readAsString());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(Object? value) async {
    // Capture the draft before queued work starts; callers may mutate maps.
    final contents = jsonEncode(value);
    final pending = _writes.then((_) => _replace(contents));
    // Report failure to this caller without blocking subsequent edits.
    _writes = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await pending;
  }

  Future<void> flush() => _writes;

  Future<void> _replace(String contents) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(contents, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
