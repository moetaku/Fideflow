import 'dart:io';

import 'json_settings_file.dart';

abstract interface class SidebarPreferenceStore {
  Future<bool?> readCollapsed();
  Future<void> writeCollapsed(bool collapsed);
}

final class FileSidebarPreferenceStore implements SidebarPreferenceStore {
  FileSidebarPreferenceStore(this.directory)
    : _settings = directory == null
          ? null
          : JsonSettingsFile(File('$directory/sidebar.json'));

  final String? directory;
  final JsonSettingsFile? _settings;

  @override
  Future<bool?> readCollapsed() async {
    final value = await _settings?.read();
    return value is Map && value['collapsed'] is bool
        ? value['collapsed'] as bool
        : null;
  }

  @override
  Future<void> writeCollapsed(bool collapsed) async {
    await _settings?.write({'collapsed': collapsed});
  }

  Future<void> flush() async => _settings?.flush();
}
