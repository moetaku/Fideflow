import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/appearance.dart';

class MemoryAppearanceStore implements AppearanceStore {
  Object? value;
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<Object?> read() async => value;
  @override
  Future<void> write(Map<String, Object?> next) async {
    await pending?.future;
    if (fail) throw const FileSystemException('test write failure');
    value = jsonDecode(jsonEncode(next));
  }
}

class FakeThemeFiles implements ThemeFileAccess {
  String? imported;
  String? exported;
  bool cancelExport = false;
  @override
  Future<String?> importTheme() async => imported;
  @override
  Future<bool> exportTheme(String name, String json) async {
    if (cancelExport) return false;
    exported = json;
    return true;
  }
}
