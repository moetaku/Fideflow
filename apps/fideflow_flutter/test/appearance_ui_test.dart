import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/appearance.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/settings/appearance_settings.dart';
import 'package:fideflow/shared/widgets/category_picker.dart';
import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';
import 'support/appearance_doubles.dart';

void main() {
  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Future<void> pumpSettings(
    WidgetTester tester,
    AppearanceController c, {
    Size size = const Size(1100, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: c,
        builder: (context, _) => MaterialApp(
          theme: c.theme,
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: AppearanceSettings(controller: c),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> visibleTap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'extreme accents stay readable through chip selection and theme changes',
    (tester) async {
      var selected = false;
      for (final preset in [
        themePresets.first,
        themePresets.singleWhere((p) => p.id == 'material-light'),
      ]) {
        final theme = FideflowTheme.build(
          preset,
          accent: preset.brightness == Brightness.dark
              ? Colors.black
              : Colors.white,
        );
        final colors = theme.extension<AppColors>()!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Card(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CategoryTagChip(
                        label: '审计分类',
                        selected: selected,
                        onTap: () => setState(() => selected = !selected),
                      ),
                      const QualityVipBadge(),
                      TextButton(onPressed: () {}, child: const Text('操作')),
                      const TextButton(onPressed: null, child: Text('禁用')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.text('审计分类'));
          await tester.pumpAndSettle();
          final rich = tester.widget<RichText>(
            find
                .descendant(
                  of: find.byType(CategoryTagChip),
                  matching: find.byType(RichText),
                )
                .first,
          );
          final fg = (rich.text as TextSpan).style!.color!;
          expect(fg, selected ? colors.accentForeground : colors.muted);
          expect(contrastRatio(fg, colors.panel), greaterThanOrEqualTo(4.5));
        }
        final style = theme.textButtonTheme.style!.foregroundColor!;
        expect(style.resolve({}), colors.accentForeground);
        expect(style.resolve({WidgetState.disabled}), colors.faint);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'preset selection updates the entire theme and retains settings state',
    (tester) async {
      final c = AppearanceController(store: MemoryAppearanceStore());
      await pumpSettings(tester, c);
      final before = tester.state(find.byType(AppearanceSettings));
      await visibleTap(tester, find.text('Material Light'));
      expect(c.selectedId, 'material-light');
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.light,
      );
      expect(tester.state(find.byType(AppearanceSettings)), same(before));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'editor validates HEX, keeps an isolated draft and saves all semantic roles',
    (tester) async {
      final c = AppearanceController(store: MemoryAppearanceStore());
      await pumpSettings(tester, c);
      await visibleTap(tester, find.text('创建自定义主题'));
      await tester.enterText(field('主题名称'), '我的紫色主题');
      await tester.enterText(field('HEX 颜色'), '#bad');
      await tester.pump();
      expect(find.text('颜色必须为 #RRGGBB'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存并应用'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '强调色'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存并应用'))
            .onPressed,
        isNull,
      );
      expect(c.selectedId, 'material-dark');
      await tester.enterText(field('HEX 颜色'), '#ABCDEF');
      await tester.pump();
      expect(
        c.theme.colorScheme.primary,
        themePresets.first[ThemeColorRole.accent],
      );
      final hue = find.byType(Slider).first;
      await tester.ensureVisible(hue);
      await tester.tap(hue);
      await tester.pump();
      expect(
        tester.widget<TextField>(field('HEX 颜色')).controller!.text,
        startsWith('#'),
      );
      await tester.enterText(field('HEX 颜色'), '#ABCDEF');
      await visibleTap(tester, find.text('保存并应用'));
      expect(find.byType(ThemeEditor), findsNothing);
      expect(localizedTestValue(c.selected.name), '我的紫色主题');
      expect(c.selected[ThemeColorRole.accent], const Color(0xffabcdef));
      expect(c.selected.colors.length, 9);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('cancelled draft does not modify active theme or library', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    await pumpSettings(tester, c);
    await visibleTap(tester, find.text('创建自定义主题'));
    await tester.enterText(field('HEX 颜色'), '#FFFFFF');
    await visibleTap(tester, find.text('取消'));
    expect(c.themes.length, 15);
    expect(
      c.theme.colorScheme.primary,
      themePresets.first[ThemeColorRole.accent],
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('switching themes keeps the current scroll position', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    await pumpSettings(tester, c, size: const Size(320, 700));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(0));
    await c.select('material-light');
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(offset, .01));
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('failed save preserves editor draft and retry succeeds', (
    tester,
  ) async {
    final store = MemoryAppearanceStore()..fail = true;
    final c = AppearanceController(store: store);
    await pumpSettings(tester, c);
    await visibleTap(tester, find.text('创建自定义主题'));
    await tester.enterText(field('主题名称'), '保留草稿');
    await tester.enterText(field('HEX 颜色'), '#123456');
    await visibleTap(tester, find.text('保存并应用'));
    expect(find.byType(ThemeEditor), findsOneWidget);
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(
      tester.widget<TextField>(field('HEX 颜色')).controller!.text,
      '#123456',
    );
    expect(c.themes.length, 15);
    store.fail = false;
    await visibleTap(tester, find.text('保存并应用'));
    expect(localizedTestValue(c.selected.name), '保留草稿');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('quick accent validates HEX and resets to the selected preset', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    await pumpSettings(tester, c);
    final swatch = find
        .ancestor(of: find.byIcon(Icons.edit), matching: find.byType(InkWell))
        .last;
    await visibleTap(tester, swatch);
    await tester.enterText(field('HEX 颜色'), '#FFFFFF');
    await visibleTap(tester, find.text('应用'));
    expect(c.theme.colorScheme.primary, Colors.white);
    await visibleTap(tester, find.text('恢复默认色'));
    expect(
      c.theme.colorScheme.primary,
      themePresets.first[ThemeColorRole.accent],
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('custom theme menu edits, renames and confirms deletion', (
    tester,
  ) async {
    final c = AppearanceController(store: MemoryAppearanceStore());
    await c.save(themePresets.first.copyWith(id: 'custom-one', name: '自定义一'));
    await pumpSettings(tester, c);
    await visibleTap(tester, find.byTooltip('自定义一 操作'));
    await visibleTap(tester, find.text('编辑'));
    await tester.enterText(field('主题名称'), '编辑后');
    await visibleTap(tester, find.text('保存并应用'));
    expect(c.selectedId, 'custom-one');
    expect(c.themes.length, 16);
    await visibleTap(tester, find.byTooltip('编辑后 操作'));
    await visibleTap(tester, find.text('重命名'));
    await tester.enterText(field('主题名称'), '新主题名');
    await visibleTap(tester, find.text('保存'));
    expect(localizedTestValue(c.selected.name), '新主题名');
    await visibleTap(tester, find.byTooltip('新主题名 操作'));
    await visibleTap(tester, find.text('删除'));
    expect(find.textContaining('当前外观将切换到 MaterialDark'), findsOneWidget);
    await visibleTap(tester, find.text('取消'));
    expect(c.isCustom('custom-one'), isTrue);
    await visibleTap(tester, find.byTooltip('新主题名 操作'));
    await visibleTap(tester, find.text('删除'));
    await visibleTap(tester, find.widgetWithText(FilledButton, '删除'));
    expect(c.selectedId, 'material-dark');
    expect(c.themes.length, 15);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('import displays errors and adds valid themes without applying', (
    tester,
  ) async {
    final files = FakeThemeFiles()..imported = '{}';
    final c = AppearanceController(
      store: MemoryAppearanceStore(),
      files: files,
    );
    await pumpSettings(tester, c);
    await visibleTap(tester, find.text('导入 JSON'));
    expect(find.text('主题格式或版本无效'), findsOneWidget);
    files.imported = jsonEncode(themePresets[1].toJson());
    await visibleTap(tester, find.text('导入 JSON'));
    expect(c.themes.length, 16);
    expect(c.selectedId, 'material-dark');
    expect(find.textContaining('点击主题可应用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'theme library and editor fit ${width.toInt()}px and every preset',
      (tester) async {
        final c = AppearanceController(store: MemoryAppearanceStore());
        await pumpSettings(tester, c, size: Size(width, 900));
        for (final theme in themePresets) {
          await c.select(theme.id);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await visibleTap(tester, find.text('创建自定义主题'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await visibleTap(tester, find.text('取消'));
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }

  testWidgets('app theme switch retains navigation, queue and playback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dependencies = AppDependencies.create(
      platformPaths: const PlatformPaths(),
      environment: const {},
      openApi: () => throw ArgumentError('fake backend'),
    );
    await tester.pumpWidget(FideflowApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.text('极光夜航').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放全部'));
    await tester.pumpAndSettle();
    final home = tester.state(find.byType(HomeScreen));
    final playback = dependencies.homeController.current.playback;
    await dependencies.appearance.select('material-light');
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(HomeScreen)), same(home));
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(
      dependencies.homeController.current.playback.sessionId,
      playback.sessionId,
    );
    expect(
      dependencies.homeController.current.playback.queueRevision,
      playback.queueRevision,
    );
    expect(
      dependencies.homeController.current.playback.currentTrack?.id,
      playback.currentTrack?.id,
    );
    await tester.pumpWidget(const SizedBox());
    final disposing = dependencies.dispose();
    await tester.pump();
    await disposing;
  });

  testWidgets('render theme library and editor previews for visual inspection', (
    tester,
  ) async {
    if (Platform.environment['FF_THEME_SCREENSHOTS'] != '1') return;
    await tester.runAsync(() async {
      final font = File(
        Platform.environment['FF_THEME_PREVIEW_FONT'] ??
            'C:/Windows/Fonts/msyh.ttc',
      );
      if (await font.exists()) {
        final bytes = await font.readAsBytes();
        for (final family in ['ThemePreviewFont', 'Roboto']) {
          await (FontLoader(
            family,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      }
      final icons = File(
        Platform.environment['FF_THEME_ICON_FONT'] ??
            'D:/DevTools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await icons.exists()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
      }
    });
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = AppearanceController(store: MemoryAppearanceStore());
    final key = GlobalKey();
    Future<void> capture(String name) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/theme-previews/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: c.theme.copyWith(
              textTheme: c.theme.textTheme.apply(
                fontFamily: 'ThemePreviewFont',
              ),
              primaryTextTheme: c.theme.primaryTextTheme.apply(
                fontFamily: 'ThemePreviewFont',
              ),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: AppearanceSettings(controller: c),
              ),
            ),
          ),
        ),
      ),
    );
    for (final theme in themePresets) {
      await c.select(theme.id);
      await tester.pumpAndSettle();
      await capture(theme.id);
    }
    await visibleTap(tester, find.text('创建自定义主题'));
    await capture('editor-light');
    await tester.ensureVisible(find.text('实时预览'));
    await tester.pumpAndSettle();
    await capture('editor-controls');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();

    final dependencies = AppDependencies.create(
      platformPaths: const PlatformPaths(),
      environment: const {},
      openApi: () => throw ArgumentError('visual fake backend'),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: FideflowApp(dependencies: dependencies),
      ),
    );
    await tester.pumpAndSettle();
    for (final theme in themePresets) {
      await dependencies.appearance.select(theme.id);
      await tester.pumpAndSettle();
      await capture('home-${theme.id}');
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('极光夜航').first);
    await tester.pumpAndSettle();
    for (final theme in themePresets) {
      await dependencies.appearance.select(theme.id);
      await tester.pumpAndSettle();
      await capture('playlist-${theme.id}');
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('播放全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    tester.widget<PlayerBar>(find.byType(PlayerBar)).onOpenDetails();
    await tester.pumpAndSettle();
    for (final id in ['material-dark', 'material-light']) {
      await dependencies.appearance.select(id);
      await tester.pumpAndSettle();
      await capture('player-$id');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    final disposing = dependencies.dispose();
    await tester.pump();
    await disposing;
  });
}
