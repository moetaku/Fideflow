import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/appearance.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';
import 'support/appearance_doubles.dart';

void main() {
  ThemeDefinition custom(String id, String name) =>
      themePresets.first.copyWith(id: id, name: name);

  test('disabled switches remain visually distinct in every preset', () {
    for (final preset in themePresets) {
      for (final accent in [Colors.black, Colors.white]) {
        final theme = FideflowTheme.build(preset, accent: accent);
        final switches = theme.switchTheme;
        for (final selected in [false, true]) {
          final enabled = <WidgetState>{if (selected) WidgetState.selected};
          final disabled = {...enabled, WidgetState.disabled};
          expect(
            switches.thumbColor!.resolve(disabled),
            isNot(switches.thumbColor!.resolve(enabled)),
            reason: preset.id,
          );
          expect(
            switches.trackOutlineColor!.resolve(disabled),
            isNot(switches.trackOutlineColor!.resolve(enabled)),
            reason: preset.id,
          );
        }
      }
    }
  });

  test('fifteen presets build with exact semantics and correct brightness', () {
    expect(themePresets.length, 15);
    expect(
      themePresets.where((t) => t.brightness == Brightness.light).length,
      4,
    );
    for (final preset in themePresets) {
      final theme = FideflowTheme.build(preset);
      expect(theme.brightness, preset.brightness);
      expect(theme.scaffoldBackgroundColor, preset[ThemeColorRole.background]);
      expect(theme.colorScheme.primary, preset[ThemeColorRole.accent]);
      expect(theme.colorScheme.onSurface, preset[ThemeColorRole.text]);
      expect(theme.extension<AppColors>()!.definition.colors, preset.colors);
      expect(
        ThemeDefinition.fromJson(preset.toJson(), id: preset.id).colors,
        preset.colors,
      );
    }
    expect(
      FideflowTheme.dark().colorScheme.primary,
      themePresets.first[ThemeColorRole.accent],
    );
  });

  test('all presets meet WCAG AA contrast standards across text and muted', () {
    for (final preset in themePresets) {
      final colors = AppColors(definition: preset);
      expect(
        contrastRatio(
          preset[ThemeColorRole.text],
          preset[ThemeColorRole.background],
        ),
        greaterThanOrEqualTo(4.5),
        reason: '${preset.id}: text vs background',
      );
      expect(
        contrastRatio(
          preset[ThemeColorRole.text],
          preset[ThemeColorRole.panel],
        ),
        greaterThanOrEqualTo(4.5),
        reason: '${preset.id}: text vs panel',
      );
      expect(
        contrastRatio(
          preset[ThemeColorRole.muted],
          preset[ThemeColorRole.background],
        ),
        greaterThanOrEqualTo(4.5),
        reason: '${preset.id}: muted vs background',
      );
      expect(
        contrastRatio(
          preset[ThemeColorRole.muted],
          preset[ThemeColorRole.panel],
        ),
        greaterThanOrEqualTo(4.5),
        reason: '${preset.id}: muted vs panel',
      );
      expect(
        contrastRatio(colors.accentForeground, colors.selected),
        greaterThanOrEqualTo(4.5),
        reason: '${preset.id}: accentForeground vs selected',
      );
      expect(
        contrastRatio(
          preset[ThemeColorRole.text],
          preset[ThemeColorRole.muted],
        ),
        greaterThanOrEqualTo(1.35),
        reason: '${preset.id}: text vs muted hierarchy',
      );
    }
  });

  test('contrast correction chooses a reachable direction', () {
    const gray = Color(0xff777777);
    expect(
      contrastRatio(ensureContrast(gray, gray), gray),
      greaterThanOrEqualTo(4.5),
    );
    expect(ensureContrast(Colors.black, Colors.white), Colors.black);
  });

  test('accent foreground is readable on every supported surface', () {
    for (final preset in themePresets) {
      for (final accent in [
        Colors.black,
        Colors.white,
        const Color(0xff123456),
        const Color(0xffffff00),
        preset[ThemeColorRole.accent],
      ]) {
        final c = AppColors(
          definition: preset.copyWith(
            colors: {...preset.colors, ThemeColorRole.accent: accent},
          ),
        );
        for (final bg in [c.background, c.panel, c.selected, c.hover]) {
          expect(
            contrastRatio(c.accentForeground, bg),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.id}: $accent on $bg',
          );
        }
      }
    }
  });

  test('progress contrast increases from track through cache to played', () {
    for (final preset in themePresets) {
      final c = AppColors(definition: preset);
      expect(
        contrastRatio(c.progressCached, c.background),
        greaterThan(contrastRatio(c.progressTrack, c.background)),
      );
      expect(
        contrastRatio(c.accent, c.background),
        greaterThan(contrastRatio(c.progressCached, c.background)),
      );
    }
  });

  test('extreme accents have readable foreground and keep other roles', () {
    for (final accent in [
      Colors.white,
      Colors.black,
      const Color(0xff123456),
    ]) {
      final theme = FideflowTheme.build(themePresets.first, accent: accent);
      expect(
        contrastRatio(theme.colorScheme.primary, theme.colorScheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        theme.scaffoldBackgroundColor,
        themePresets.first[ThemeColorRole.background],
      );
      expect(theme.colorScheme.error, themePresets.first[ThemeColorRole.error]);
    }
  });

  test('cover overlay preserves existing text contrast on extreme covers', () {
    for (final preset in themePresets) {
      final colors = AppColors(definition: preset);
      for (final cover in [
        Colors.white,
        Colors.black,
        const Color(0xffff0000),
        const Color(0xffffff00),
      ]) {
        final result = colors.artworkBackground(cover);
        expect(
          contrastRatio(colors.lyricUpcoming, result),
          greaterThanOrEqualTo(3.0),
          reason: '${preset.id}: unsung lyrics',
        );
        expect(
          contrastRatio(colors.text, result),
          greaterThanOrEqualTo(
            contrastRatio(colors.text, colors.background).clamp(1, 4.5) - .001,
          ),
        );
        expect(
          contrastRatio(colors.muted, result),
          greaterThanOrEqualTo(
            contrastRatio(colors.muted, colors.background).clamp(1, 4.5) - .001,
          ),
        );
      }
    }
  });

  test(
    'select and per-theme accents survive restart and reset independently',
    () async {
      final store = MemoryAppearanceStore();
      final c = AppearanceController(store: store);
      await c.setAccent(Colors.white);
      await c.select('dracula');
      await c.setAccent(Colors.black);
      final restored = AppearanceController(store: store);
      await restored.load();
      expect(restored.selectedId, 'dracula');
      expect(restored.theme.colorScheme.primary, Colors.black);
      await restored.select('material-dark');
      expect(restored.theme.colorScheme.primary, Colors.white);
      await restored.setAccent(null);
      expect(
        restored.theme.colorScheme.primary,
        themePresets.first[ThemeColorRole.accent],
      );
      await restored.select('dracula');
      expect(restored.theme.colorScheme.primary, Colors.black);
      c.dispose();
      restored.dispose();
    },
  );

  test(
    'custom save, edit, rename and current deletion preserve library rules',
    () async {
      final store = MemoryAppearanceStore();
      final c = AppearanceController(store: store);
      await c.save(custom('custom-one', ' 我的主题 '));
      expect(localizedTestValue(c.selected.name), '我的主题');
      await c.save(
        c.selected.copyWith(
          colors: {
            ...c.selected.colors,
            ThemeColorRole.background: Colors.black,
          },
        ),
      );
      expect(c.themes.length, 16);
      expect(c.selectedId, 'custom-one');
      await c.rename('custom-one', '新名字');
      await c.save(custom('custom-two', '另一主题'));
      final restored = AppearanceController(store: store);
      await restored.load();
      expect(restored.themes.length, 17);
      expect(
        localizedTestValue(
          restored.themes.singleWhere((t) => t.id == 'custom-one').name,
        ),
        '新名字',
      );
      await c.delete('custom-two');
      expect(c.selectedId, 'material-dark');
      expect(c.themes.length, 16);
      await expectLater(c.delete('dracula'), throwsFormatException);
      await expectLater(c.rename('dracula', '其他'), throwsFormatException);
      await expectLater(
        c.save(custom('custom-three', 'Dracula')),
        throwsFormatException,
      );
      await expectLater(
        c.save(custom('custom-three', ' ')),
        throwsFormatException,
      );
      await expectLater(
        c.save(custom('custom-three', List.filled(41, 'a').join())),
        throwsFormatException,
      );
      c.dispose();
      restored.dispose();
    },
  );

  test(
    'save failure rolls back selection, accents, edits and deletion',
    () async {
      final store = MemoryAppearanceStore();
      final c = AppearanceController(store: store);
      await c.save(custom('custom-one', '我的主题'));
      store.fail = true;
      await expectLater(
        c.select('dracula'),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.selectedId, 'custom-one');
      await expectLater(
        c.setAccent(Colors.black),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        c.theme.colorScheme.primary,
        themePresets.first[ThemeColorRole.accent],
      );
      await expectLater(
        c.save(c.selected.copyWith(name: '修改')),
        throwsA(isA<FileSystemException>()),
      );
      expect(localizedTestValue(c.selected.name), '我的主题');
      await expectLater(
        c.delete('custom-one'),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.isCustom('custom-one'), isTrue);
      expect(c.saving, isFalse);
      expect(c.error, isNotNull);
      store.fail = false;
      await c.select('dracula');
      expect(c.error, isNull);
      c.dispose();
    },
  );

  test('a pending save cannot be submitted twice', () async {
    final store = MemoryAppearanceStore()..pending = Completer<void>();
    final c = AppearanceController(store: store);
    final operation = c.select('dracula');
    expect(c.saving, isTrue);
    await expectLater(c.select('nord'), throwsStateError);
    expect(c.selectedId, 'material-dark');
    store.pending!.complete();
    await operation;
    expect(c.selectedId, 'dracula');
    c.dispose();
  });

  test(
    'invalid records are skipped and unknown selection falls back',
    () async {
      final store = MemoryAppearanceStore()
        ..value = {
          'schemaVersion': 1,
          'selectedId': 'missing',
          'customThemes': [
            {'id': 'custom-valid', ...custom('custom-valid', '有效主题').toJson()},
            {'id': 'custom-bad', 'schemaVersion': 1, 'name': '坏主题'},
            {'id': 'dracula', ...custom('dracula', '冒充预设').toJson()},
          ],
          'accents': {
            'material-dark': 'bad',
            'dracula': '#123456',
            'missing': '#ABCDEF',
          },
        };
      final c = AppearanceController(store: store);
      await c.load();
      expect(c.themes.length, 16);
      expect(c.selectedId, 'material-dark');
      expect(
        c.theme.colorScheme.primary,
        themePresets.first[ThemeColorRole.accent],
      );
      await c.select('dracula');
      expect(c.theme.colorScheme.primary, const Color(0xff123456));
      c.dispose();
    },
  );

  test(
    'no settings directory allows temporary changes and explains persistence',
    () async {
      final c = AppearanceController();
      await c.load();
      await c.select('material-light');
      await c.save(custom('custom-one', '临时主题'));
      expect(c.isCustom('custom-one'), isTrue);
      expect(localizedTestValue(c.persistenceNotice), contains('本次运行'));
      c.dispose();
    },
  );

  test(
    'file store overwrites atomically and ignores damaged configuration',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fideflow-appearance-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = FileAppearanceStore(root.path);
      final c = AppearanceController(store: store);
      await c.select('dracula');
      await c.select('nord');
      final restored = AppearanceController(store: store);
      await restored.load();
      expect(restored.selectedId, 'nord');
      expect(root.listSync().length, 1);
      await store.file.writeAsString('{');
      expect(await store.read(), isNull);
      await store.file.delete();
      expect(await store.read(), isNull);
      c.dispose();
      restored.dispose();
    },
  );

  test(
    'JSON export is standalone and import creates a new identity without applying',
    () async {
      final files = FakeThemeFiles();
      final c = AppearanceController(
        store: MemoryAppearanceStore(),
        files: files,
      );
      await c.setAccent(const Color(0xff123456));
      expect(await c.exportTheme(c.selected), isTrue);
      final json = jsonDecode(files.exported!) as Map;
      expect(json['schemaVersion'], 1);
      expect(json.containsKey('id'), isFalse);
      expect((json['colors'] as Map)['accent'], '#123456');
      files.imported = files.exported;
      final imported = (await c.importTheme())!;
      expect(imported.id, startsWith('custom-'));
      expect(imported.name, 'MaterialDark (2)');
      expect(imported[ThemeColorRole.accent], const Color(0xff123456));
      expect(c.selectedId, 'material-dark');
      expect((await c.importTheme())!.name, 'MaterialDark (3)');
      c.dispose();
    },
  );

  test(
    'invalid import and cancelled dialogs leave the library unchanged',
    () async {
      final files = FakeThemeFiles();
      final c = AppearanceController(
        store: MemoryAppearanceStore(),
        files: files,
      );
      expect(await c.importTheme(), isNull);
      files.cancelExport = true;
      expect(await c.exportTheme(c.selected), isFalse);
      final invalid = [
        '{',
        '[]',
        jsonEncode({...c.selected.toJson(), 'schemaVersion': 2}),
        jsonEncode({...c.selected.toJson(), 'brightness': 'system'}),
        jsonEncode({
          ...c.selected.toJson(),
          'colors': {'accent': '#123456'},
        }),
        jsonEncode({
          ...c.selected.toJson(),
          'colors': {
            for (final r in ThemeColorRole.values)
              r.name: r == ThemeColorRole.accent ? '#80123456' : '#123456',
          },
        }),
      ];
      for (final text in invalid) {
        files.imported = text;
        await expectLater(c.importTheme(), throwsFormatException);
        expect(c.themes.length, 15);
        expect(c.selectedId, 'material-dark');
      }
      c.dispose();
    },
  );
}
