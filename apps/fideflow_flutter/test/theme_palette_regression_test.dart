import 'package:fideflow/app/appearance.dart';
import 'package:fideflow/features/settings/appearance_settings.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/appearance_doubles.dart';

void main() {
  Finder hexField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == 'HEX 颜色',
  );

  Future<void> openEditor(
    WidgetTester tester,
    AppearanceController c,
    ThemeDefinition initial, {
    Locale locale = const Locale('zh', 'Hans'),
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: c.theme,
        home: Scaffold(
          body: ThemeEditor(controller: c, initial: initial),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('editing accent preserves every existing non-accent role', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    addTearDown(c.dispose);
    final initial = themePresets.first.copyWith(
      id: 'custom-test',
      name: 'Test',
    );
    await openEditor(tester, c, initial);
    await tester.enterText(hexField(), '#ABCDEF');
    await tester.pump();
    final preview = Theme.of(
      tester.element(find.text('实时预览')),
    ).extension<AppColors>()!.definition;
    expect(preview[ThemeColorRole.accent], const Color(0xffabcdef));
    for (final role in ThemeColorRole.values.where(
      (r) => r != ThemeColorRole.accent,
    )) {
      expect(preview[role], initial[role], reason: role.name);
    }
  });

  testWidgets('theme name field does not overlap the editor title', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(800, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'Hans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: c.theme,
        home: Scaffold(
          body: ThemeEditor(controller: c, initial: themePresets.first),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleRect = tester.getRect(find.text('自定义主题'));
    final nameFieldRect = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '主题名称',
      ),
    );
    expect(nameFieldRect.top, greaterThanOrEqualTo(titleRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fine-tuned slots survive collapse, accent and base tone changes',
    (tester) async {
      final c = AppearanceController(store: MemoryAppearanceStore());
      addTearDown(c.dispose);
      await openEditor(tester, c, themePresets.first);
      await tester.tap(find.text('高级自定义 / 精细微调'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '背景'));
      await tester.pumpAndSettle();
      await tester.enterText(hexField(), '#123456');
      await tester.pump();
      await tester.tap(find.text('高级自定义 / 精细微调'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '强调色'));
      await tester.pumpAndSettle();
      await tester.enterText(hexField(), '#ABCDEF');
      await tester.pump();
      await tester.tap(find.text('清爽纯白'));
      await tester.pumpAndSettle();
      final preview = Theme.of(
        tester.element(find.text('实时预览')),
      ).extension<AppColors>()!.definition;
      expect(preview[ThemeColorRole.background], const Color(0xff123456));
      expect(preview[ThemeColorRole.accent], const Color(0xffabcdef));
      expect(preview.brightness, Brightness.light);
      expect(preview[ThemeColorRole.panel], const Color(0xfff3f4f6));
    },
  );

  testWidgets('custom card badge stays readable with extreme accents', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    addTearDown(c.dispose);
    for (final pair in [
      (themePresets.first, Colors.black),
      (themePresets.singleWhere((t) => t.id == 'material-light'), Colors.white),
    ]) {
      final t = pair.$1.copyWith(
        id: 'custom-extreme',
        name: 'Extreme',
        colors: {...pair.$1.colors, ThemeColorRole.accent: pair.$2},
      );
      await c.save(t);
      await tester.pumpWidget(
        MaterialApp(
          theme: c.theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AppearanceSettings(controller: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('theme-card-custom-extreme'));
      final badge = tester.widget<Text>(
        find.descendant(of: card, matching: find.text('自定义')),
      );
      final surface = Color.alphaBlend(
        pair.$2.withValues(alpha: .15),
        t[ThemeColorRole.background],
      );
      expect(
        contrastRatio(badge.style!.color!, surface),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  testWidgets('selecting a theme does not change theme card height', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'Hans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: c.theme,
        home: Scaffold(
          body: SingleChildScrollView(child: AppearanceSettings(controller: c)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final materialLight = find.byKey(
      const ValueKey('theme-card-material-light'),
    );
    final before = tester.getSize(materialLight);
    await tester.tap(materialLight);
    await tester.pumpAndSettle();
    final after = tester.getSize(materialLight);

    expect(after.height, before.height);
    expect(after.width, before.width);
  });
}
