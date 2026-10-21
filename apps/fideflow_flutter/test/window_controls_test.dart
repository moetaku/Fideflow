import 'package:fideflow/app/desktop_window.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/discovery/home_sidebar.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow/l10n/ui_text.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_viewport.dart';

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  });
  const commands = ['closeWindow', 'minimize', 'toggleMaximize'];

  testWidgets(
    'toolbar buttons navigate immediately while blank areas keep window gestures',
    (tester) async {
      await setTestViewport(tester, const Size(1280, 800));
      addTearDown(() => setTestViewport(tester, null));
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DesktopWindow.channel,
        (call) async {
          if (call.method == 'isMaximized') return false;
          calls.add(call.method);
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DesktopWindow.channel,
          null,
        );
      });
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        FakeMediaController(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: HomeScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.library_music_outlined));
      await tester.pumpAndSettle();
      final back = find.byIcon(Icons.arrow_back_ios_new_rounded);
      final forward = find.widgetWithIcon(
        IconButton,
        Icons.arrow_forward_ios_rounded,
      );
      await tester.tap(back);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<IconButton>(forward).onPressed, isNotNull);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);

      // The top strip above the search field is blank; controls still receive
      // normal hits in front of this window-gesture layer.
      final blank =
          tester.getTopLeft(
            find.byKey(const ValueKey('home-topbar-drag-area')),
          ) +
          const Offset(300, 4);
      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(blank);
      await tester.pumpAndSettle();
      expect(calls, ['titlebarDoubleClick']);
      calls.clear();
      final drag = await tester.startGesture(blank);
      await drag.moveBy(const Offset(40, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(calls, ['startDragging']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    variant: platforms,
  );

  testWidgets('expanded navigation labels fit every locale at large text', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(1280, 1000));
    addTearDown(() => setTestViewport(tester, null));
    for (final locale in AppLocalizations.supportedLocales) {
      for (final scale in [1.0, 2.0, 3.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                key: ValueKey('$locale-$scale'),
                body: HomeSidebar(
                  selectedDestination: null,
                  onSelected: (_) {},
                  onOpenSettings: () {},
                  onToggleCollapsed: () {},
                  settingsSelected: false,
                  collapsed: false,
                  width: 200,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final copy = lookupAppLocalizations(locale);
        for (final data in [
          UiMessages.featuredPlaylists,
          UiMessages.myMusic,
          UiMessages.settings,
          copy.collapseSidebar,
        ]) {
          final localized = find.byWidgetPredicate(
            (widget) => widget is LocalizedText && widget.data == data,
          );
          await tester.scrollUntilVisible(
            localized,
            100,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 100,
          );
          expect(localized, findsOneWidget);
          final item = find.ancestor(
            of: localized,
            matching: find.byType(InkWell),
          );
          final label = find.descendant(
            of: localized,
            matching: find.byType(RichText),
          );
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(paragraph.maxLines, isNull);
          expect(
            paragraph.size.height,
            greaterThanOrEqualTo(
              paragraph.getMaxIntrinsicHeight(paragraph.size.width) - 0.01,
            ),
            reason: '$locale at $scale: ${paragraph.text.toPlainText()}',
          );
          expect(tester.getSize(item.first).height, greaterThanOrEqualTo(48));
        }
        expect(tester.takeException(), isNull);
      }
    }
  }, variant: platforms);

  testWidgets(
    'Windows uses native controls and synchronizes navigation theme colors',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DesktopWindow.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DesktopWindow.channel,
          null,
        );
      });
      for (final preset in themePresets) {
        for (final collapsed in [true, false]) {
          final theme = FideflowTheme.build(preset);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: DesktopWindowTheme(
                child: Scaffold(
                  body: HomeSidebar(
                    selectedDestination: null,
                    onSelected: (_) {},
                    onOpenSettings: () {},
                    onToggleCollapsed: () {},
                    settingsSelected: false,
                    collapsed: collapsed,
                    width: collapsed ? 80 : 200,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final command in commands) {
            expect(find.byKey(ValueKey('window-$command')), findsNothing);
          }
          final colors = theme.extension<AppColors>()!;
          final background = Color.alphaBlend(
            colors.panel.withValues(alpha: 0.72),
            colors.background,
          );
          final sidebar = tester.widget<Container>(
            find.byKey(const ValueKey('desktop-sidebar')),
          );
          expect(sidebar.color, background);
          if (defaultTargetPlatform == TargetPlatform.windows) {
            expect(calls.last.method, 'setWindowTheme');
            expect(calls.last.arguments, {
              'background': background.toARGB32(),
              'foreground': readableOn(background).toARGB32(),
              'dark': background.computeLuminance() < 0.179,
            });
          } else {
            expect(calls, isEmpty);
          }
          expect(tester.takeException(), isNull);
        }
      }
    },
    variant: platforms,
  );

  testWidgets('titlebar double click is distinct from the maximize button', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DesktopWindow.channel,
      (call) async {
        calls.add(call.method);
        return true;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DesktopWindow.channel,
        null,
      );
    });
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: DesktopDragArea(child: SizedBox.expand()),
      ),
    );
    await tester.tap(find.byType(DesktopDragArea));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(DesktopDragArea));
    await tester.pumpAndSettle();
    expect(calls, ['titlebarDoubleClick']);
  }, variant: platforms);
}
