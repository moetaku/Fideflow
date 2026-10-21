import 'dart:convert';
import 'dart:io';

import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations_zh.dart';
import '../l10n/ui_text.dart';
import 'json_settings_file.dart';

abstract interface class AppearanceStore {
  Future<Object?> read();
  Future<void> write(Map<String, Object?> value);
}

final class FileAppearanceStore implements AppearanceStore {
  FileAppearanceStore(this.directory)
    : _settings = JsonSettingsFile(File('$directory/appearance.json'));
  final String directory;
  final JsonSettingsFile _settings;
  File get file => _settings.file;

  @override
  Future<Object?> read() => _settings.read();

  @override
  Future<void> write(Map<String, Object?> value) => _settings.write(value);
}

abstract interface class ThemeFileAccess {
  Future<String?> importTheme();
  Future<bool> exportTheme(String name, String json);
}

final class NativeThemeFileAccess implements ThemeFileAccess {
  NativeThemeFileAccess({String Function(String)? translate})
    : translate = translate ?? _simplified;
  final String Function(String) translate;
  static String _simplified(String text) =>
      resolveUiText(AppLocalizationsZhHans(), text);
  XTypeGroup get type => XTypeGroup(
    label: translate(UiMessages.fideflowTheme),
    extensions: ['json'],
    uniformTypeIdentifiers: ['public.json'],
  );
  @override
  Future<String?> importTheme() async {
    final file = await openFile(acceptedTypeGroups: [type]);
    if (file == null) return null;
    if (await file.length() > 1024 * 1024) {
      throw const FormatException(UiMessages.theThemeFileIsTooLarge);
    }
    return file.readAsString();
  }

  @override
  Future<bool> exportTheme(String name, String json) async {
    final safeName = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    final location = await getSaveLocation(
      suggestedName: '$safeName.fideflow-theme.json',
      acceptedTypeGroups: [type],
    );
    if (location == null) return false;
    await XFile.fromData(
      utf8.encode(json),
      mimeType: 'application/json',
    ).saveTo(location.path);
    return true;
  }
}

final class AppearanceController extends ChangeNotifier {
  AppearanceController({this.store, ThemeFileAccess? files})
    : files = files ?? NativeThemeFileAccess();
  final AppearanceStore? store;
  final ThemeFileAccess files;
  String _selected = themePresets.first.id;
  List<ThemeDefinition> _custom = [];
  Map<String, Color> _accents = {};
  bool saving = false;
  String? error;
  String? get persistenceNotice => store == null
      ? UiMessages.theSettingsDirectoryIsUnavailableAppearanceChangesApply
      : null;
  List<ThemeDefinition> get themes =>
      List.unmodifiable([...themePresets, ..._custom]);
  String get selectedId => _selected;
  ThemeDefinition get selected => themes.firstWhere(
    (t) => t.id == _selected,
    orElse: () => themePresets.first,
  );
  bool isCustom(String id) => _custom.any((t) => t.id == id);
  ThemeDefinition effective(ThemeDefinition theme) => theme.copyWith(
    colors: {
      ...theme.colors,
      ThemeColorRole.accent: _accents[theme.id] ?? theme[ThemeColorRole.accent],
    },
  );
  ThemeData get theme => FideflowTheme.build(effective(selected));
  ThemeData themeForLocale(Locale locale) =>
      FideflowTheme.build(effective(selected), locale: locale);
  String newId() => 'custom-${DateTime.now().microsecondsSinceEpoch}';

  Future<void> load() async {
    final Object? data;
    try {
      data = await store?.read();
    } catch (_) {
      return;
    }
    if (data is! Map || data['schemaVersion'] != 1) return;
    final custom = <ThemeDefinition>[];
    final ids = themePresets.map((t) => t.id).toSet();
    final names = themePresets.map((t) => t.name.toLowerCase()).toSet();
    if (data['customThemes'] case final List entries) {
      for (final entry in entries) {
        try {
          if (entry is! Map ||
              entry['id'] is! String ||
              !(entry['id'] as String).startsWith('custom-')) {
            continue;
          }
          final t = ThemeDefinition.fromJson(entry, id: entry['id'] as String);
          if (ids.contains(t.id) || names.contains(t.name.toLowerCase())) {
            continue;
          }
          custom.add(t);
          ids.add(t.id);
          names.add(t.name.toLowerCase());
        } on FormatException {
          /* Skip only the invalid record. */
        }
      }
    }
    _custom = custom;
    _accents = {};
    if (data['accents'] case final Map accents) {
      for (final entry in accents.entries) {
        if (!ids.contains(entry.key)) continue;
        try {
          _accents[entry.key as String] = parseThemeColor(entry.value);
        } on FormatException {
          /* Use theme accent. */
        }
      }
    }
    _selected = ids.contains(data['selectedId'])
        ? data['selectedId'] as String
        : themePresets.first.id;
    notifyListeners();
  }

  String uniqueName(String base) {
    final names = themes.map((t) => t.name.toLowerCase()).toSet();
    var result = base.characters.take(40).toString();
    var i = 2;
    while (names.contains(result.toLowerCase())) {
      final suffix = ' ($i)';
      result = '${base.characters.take(40 - suffix.length)}$suffix';
      i++;
    }
    return result;
  }

  void validateName(String name, {String? exceptId}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.characters.length > 40) {
      throw const FormatException(
        UiMessages.themeNamesMustContain140Characters,
      );
    }
    if (themes.any(
      (t) => t.id != exceptId && t.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      throw const FormatException(UiMessages.aThemeWithThisNameAlreadyExists);
    }
  }

  Future<void> _commit({
    String? selected,
    List<ThemeDefinition>? custom,
    Map<String, Color>? accents,
  }) async {
    if (saving) throw StateError(UiMessages.savingPleaseWait);
    final nextId = selected ?? _selected;
    final nextCustom = custom ?? _custom;
    final nextAccents = accents ?? _accents;
    saving = true;
    error = null;
    notifyListeners();
    try {
      await store?.write({
        'schemaVersion': 1,
        'selectedId': nextId,
        'customThemes': [
          for (final t in nextCustom) {'id': t.id, ...t.toJson()},
        ],
        'accents': {
          for (final e in nextAccents.entries) e.key: colorHex(e.value),
        },
      });
      _selected = nextId;
      _custom = nextCustom;
      _accents = nextAccents;
    } catch (_) {
      error = UiMessages.couldNotSaveAppearancePleaseTryAgain;
      rethrow;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> select(String id) async {
    if (!themes.any((t) => t.id == id)) {
      throw const FormatException(UiMessages.themeNotFound);
    }
    await _commit(selected: id);
  }

  Future<void> setAccent(Color? color) => _commit(
    accents: {..._accents}
      ..remove(_selected)
      ..addAll(
        color == null ? {} : {_selected: parseThemeColor(colorHex(color))},
      ),
  );
  Future<void> save(ThemeDefinition theme) async {
    validateName(theme.name, exceptId: theme.id);
    if (!theme.id.startsWith('custom-') ||
        themePresets.any((t) => t.id == theme.id)) {
      throw const FormatException(UiMessages.presetThemesCannotBeModified);
    }
    final saved = theme.copyWith(name: theme.name.trim());
    await _commit(
      selected: saved.id,
      custom: [..._custom.where((t) => t.id != saved.id), saved],
      accents: {..._accents}..remove(saved.id),
    );
  }

  Future<void> rename(String id, String name) async {
    validateName(name, exceptId: id);
    if (!isCustom(id)) {
      throw const FormatException(UiMessages.presetThemesCannotBeModified);
    }
    await _commit(
      custom: [
        for (final t in _custom) t.id == id ? t.copyWith(name: name.trim()) : t,
      ],
    );
  }

  Future<void> delete(String id) async {
    if (!isCustom(id)) {
      throw const FormatException(UiMessages.presetThemesCannotBeDeleted);
    }
    await _commit(
      selected: _selected == id ? themePresets.first.id : _selected,
      custom: _custom.where((t) => t.id != id).toList(),
      accents: {..._accents}..remove(id),
    );
  }

  Future<ThemeDefinition?> importTheme() async {
    final json = await files.importTheme();
    if (json == null) return null;
    final t = ThemeDefinition.fromJson(jsonDecode(json), id: newId());
    final imported = t.copyWith(name: uniqueName(t.name));
    await _commit(custom: [..._custom, imported]);
    return imported;
  }

  Future<bool> exportTheme(ThemeDefinition t) => files.exportTheme(
    t.name,
    const JsonEncoder.withIndent('  ').convert(effective(t).toJson()),
  );
}

class AppearanceScope extends InheritedWidget {
  const AppearanceScope({
    required this.controller,
    required super.child,
    super.key,
  });
  final AppearanceController controller;
  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.controller;
  @override
  bool updateShouldNotify(AppearanceScope oldWidget) =>
      controller != oldWidget.controller;
}
