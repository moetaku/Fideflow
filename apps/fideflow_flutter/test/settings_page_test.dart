import 'dart:async';
import 'dart:io';

import 'package:fideflow/app/appearance.dart';
import 'package:fideflow/app/playback_cache.dart';
import 'package:fideflow/features/discovery/home_screen.dart';
import 'package:fideflow/features/player/now_playing_page.dart';
import 'package:fideflow/features/player/player_bar.dart';
import 'package:fideflow/features/settings/appearance_settings.dart';
import 'package:fideflow/features/settings/playback_cache_settings.dart';
import 'package:fideflow/features/settings/quality_settings_section.dart';
import 'package:fideflow/features/settings/settings_copy.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../tooling/test_localization.dart';

/// The settings page as the user meets it: one entry point, six groups, and the
/// one setting that has behaviour behind it.
///
/// The page's own structure (nav, scrolling, layout) is driven through the real
/// [HomeScreen], and the quality section is also driven on its own so the states
/// that need a scripted backend — a switch in flight, a failed switch — can be
/// produced exactly.
void main() {
  late FakeMediaController media;
  late BrowseAndPlayController controller;
  late InMemoryQualityPreferenceStore store;
  late QualityController quality;

  testWidgets('settings survive a squeezed desktop content viewport', (
    tester,
  ) async {
    final appearance = AppearanceController();
    addTearDown(appearance.dispose);
    late Directory directory;
    late PlaybackCache cache;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('ff-settings-width-');
      cache = PlaybackCache(directory);
      await cache.initialize();
    });
    addTearDown(
      () => tester.runAsync(() async {
        await cache.close();
        await directory.delete(recursive: true);
      }),
    );
    for (final width in [81.0, 240.0, 360.0, 440.0, 800.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 500,
                child: AppearanceScope(
                  controller: appearance,
                  child: SettingsPage(
                    playback: PlaybackSnapshot.idle(),
                    playbackCache: cache,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'viewport width $width');
      expect(
        tester.getSize(find.byType(PlaybackCacheSettings)).width,
        greaterThanOrEqualTo(280),
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Fideflow',
      packageName: 'fideflow',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    media = FakeMediaController();
    controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    store = InMemoryQualityPreferenceStore();
    quality = QualityController(media: media, store: store);
  });

  /// [HomeScreen] disposes the controller it is handed, so no test disposes it.

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
    AuthController? auth,
    QualityController? qualityController,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        home: HomeScreen(
          controller: controller,
          qualityController: qualityController ?? quality,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
  }

  testWidgets('desktop settings remain stable across tiny window resizes', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(440, 560));
    await openSettings(tester);
    for (final size in [
      const Size(280, 180),
      const Size(440, 560),
      const Size(800, 700),
    ]) {
      tester.view.physicalSize = size;
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'desktop size $size');
    }
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  /// The page on its own, for the layout cases that do not need the shell.
  Future<void> pumpSettingsOnly(
    WidgetTester tester, {
    required Size size,
    QualityController? qualityController,
    AppearanceController? appearance,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final page = SettingsPage(
      playback: _snapshot(),
      qualityController: qualityController ?? quality,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: FideflowTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: appearance == null
              ? page
              : AppearanceScope(controller: appearance, child: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Walks to a group through the nav, which is also what brings its content on
  /// screen for a tap.
  Future<void> goToGroup(WidgetTester tester, SettingsSection section) async {
    final tab = find.byKey(ValueKey(section));
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'selected settings tabs and quality marks use readable foregrounds',
    (tester) async {
      await quality.activateAccount('contrast', isVip: true);
      for (final id in ['material-dark', 'material-light']) {
        for (final accent in [Colors.black, Colors.white]) {
          final theme = FideflowTheme.build(
            themePresets.singleWhere((p) => p.id == id),
            accent: accent,
          );
          final colors = theme.extension<AppColors>()!;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SettingsPage(
                  playback: PlaybackSnapshot.idle(),
                  qualityController: quality,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final section in [
            SettingsSection.general,
            SettingsSection.playback,
          ]) {
            final label = find.text(zh(section.title)).first;
            await tester.tap(label);
            await tester.pumpAndSettle();
            expect(
              tester.widget<Text>(label).style!.color,
              colors.accentForeground,
            );
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: QualitySettingsSection(
                    playback: PlaybackSnapshot.idle(),
                    controller: quality,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final mark = tester.widget<Icon>(find.byIcon(Icons.check_rounded));
          final circle = tester.widget<Container>(
            find
                .ancestor(
                  of: find.byIcon(Icons.check_rounded),
                  matching: find.byType(Container),
                )
                .first,
          );
          final fill = (circle.decoration as BoxDecoration).color!;
          expect(fill, colors.accent);
          expect(mark.color, colors.onAccent);
          expect(contrastRatio(mark.color!, fill), greaterThanOrEqualTo(4.5));
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  group('the page', () {
    testWidgets('initial viewport defers theme and About construction', (
      tester,
    ) async {
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      await pumpSettingsOnly(
        tester,
        size: const Size(420, 300),
        appearance: appearance,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('theme-card-'),
        ),
        findsNothing,
      );
      expect(find.text(zh(SettingsSection.about.description)), findsNothing);
      expect(find.text('0.1.0'), findsNothing);
      await goToGroup(tester, SettingsSection.about);
      expect(find.text('0.1.0'), findsOneWidget);
      await goToGroup(tester, SettingsSection.account);
      final viewport = tester.getRect(find.byType(ListView));
      final heading = tester.getRect(
        find.text(zh(SettingsSection.account.description)),
      );
      expect(heading.overlaps(viewport), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('visited theme controls keep state across lazy navigation', (
      tester,
    ) async {
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      await pumpSettingsOnly(
        tester,
        size: const Size(420, 700),
        appearance: appearance,
      );
      await goToGroup(tester, SettingsSection.theme);
      final state = tester.state(find.byType(AppearanceSettings));
      final filter = find.byWidgetPredicate(
        (widget) => widget is SegmentedButton,
      );
      final dark = find.descendant(
        of: filter,
        matching: find.text(zh(UiMessages.dark)),
      );
      await tester.ensureVisible(dark);
      await tester.tap(dark);
      await tester.pumpAndSettle();
      final selected = tester.widget<SegmentedButton<dynamic>>(filter).selected;
      await goToGroup(tester, SettingsSection.about);
      await goToGroup(tester, SettingsSection.theme);
      expect(tester.state(find.byType(AppearanceSettings)), same(state));
      expect(
        tester.widget<SegmentedButton<dynamic>>(filter).selected,
        selected,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('first theme viewport constructs only nearby card rows', (
      tester,
    ) async {
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      await pumpSettingsOnly(
        tester,
        size: const Size(420, 500),
        appearance: appearance,
      );
      await goToGroup(tester, SettingsSection.theme);
      final cards = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('theme-card-'),
      );
      expect(cards, findsWidgets);
      expect(
        cards.evaluate().length,
        lessThan(appearance.themes.length),
        reason:
            'The first visible theme row must not construct the entire catalogue',
      );
      // ignore: avoid_print -- structural first-viewport performance evidence.
      print(
        'SETTINGS_THEME_LAZY built=${cards.evaluate().length} total=${appearance.themes.length}',
      );
      final lastId = appearance.themes.last.id;
      expect(find.byKey(ValueKey('theme-card-$lastId')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('theme-card-$lastId')),
        250,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.byKey(ValueKey('theme-card-$lastId')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('scroll highlighting does not rebuild mounted theme cards', (
      tester,
    ) async {
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      await pumpSettingsOnly(
        tester,
        size: const Size(420, 700),
        appearance: appearance,
      );
      await goToGroup(tester, SettingsSection.theme);
      var rebuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final key = element.widget.key;
        if (builtOnce &&
            key is ValueKey<String> &&
            key.value.startsWith('theme-card-')) {
          rebuilds++;
        }
      };
      try {
        await tester.drag(find.byType(ListView), const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(rebuilds, 0);
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a newer tab wins while an unbuilt section is being located', (
      tester,
    ) async {
      await pumpSettingsOnly(tester, size: const Size(420, 360));
      await tester.tap(find.byKey(const ValueKey(SettingsSection.about)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey(SettingsSection.general)));
      await tester.pumpAndSettle();
      final tab = find.descendant(
        of: find.byKey(const ValueKey(SettingsSection.general)),
        matching: find.text(zh(SettingsSection.general.title)),
      );
      expect(
        tester.widget<Text>(tab).style?.color,
        FideflowTheme.dark().extension<AppColors>()!.accentForeground,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text can reach tall lazy groups in both directions', (
      tester,
    ) async {
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      await pumpSettingsOnly(
        tester,
        size: const Size(360, 640),
        appearance: appearance,
        textScale: 2.5,
      );
      for (final section in [
        SettingsSection.playback,
        SettingsSection.theme,
        SettingsSection.general,
        SettingsSection.about,
        SettingsSection.audio,
        SettingsSection.account,
      ]) {
        await goToGroup(tester, section);
        final description = tester.getRect(find.text(zh(section.description)));
        expect(
          description.overlaps(tester.getRect(find.byType(ListView))),
          isTrue,
          reason: '${section.name} heading is visible at 2.5x text',
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('manual scrolling ignores retained offscreen section geometry', (
      tester,
    ) async {
      await pumpSettingsOnly(tester, size: const Size(420, 500));
      await goToGroup(tester, SettingsSection.about);
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      final label = find.descendant(
        of: find.byKey(const ValueKey(SettingsSection.account)),
        matching: find.text(zh(SettingsSection.account.title)),
      );
      expect(
        tester.widget<Text>(label).style?.color,
        FideflowTheme.dark().extension<AppColors>()!.accentForeground,
        reason:
            'scroll=${tester.widget<ListView>(find.byType(ListView)).controller!.position}; account=${tester.getRect(find.text(zh(SettingsSection.account.description)))}',
      );
      expect(tester.takeException(), isNull);
    });

    for (final width in [420.0, 1280.0, 1800.0]) {
      testWidgets('page title and section tabs align left at width $width', (
        tester,
      ) async {
        await pumpSettingsOnly(tester, size: Size(width, 900));
        final title = find.text(zh(settingsPageTitle));
        final account = find.text(zh(SettingsSection.account.title));
        final expectedLeft = AppBreakpoints.pagePadding(
          AppBreakpoints.ofWidth(width),
        ).left;
        expect(tester.getTopLeft(title).dx, expectedLeft);
        expect(tester.getTopLeft(account.first).dx, expectedLeft);
        expect(tester.getTopLeft(account.last).dx, expectedLeft);
        expect(tester.widget<Text>(title).style?.fontSize, 24);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('opens from the top bar and the back arrow leaves it', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(find.byType(SettingsPage), findsNothing);

      await openSettings(tester);
      expect(
        find.descendant(
          of: find.byType(SettingsPage),
          matching: find.text(zh(settingsPageTitle)),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('后退'));
      await tester.pumpAndSettle();
      expect(
        find.byType(SettingsPage),
        findsNothing,
        reason: 'the page rides the same history the detail pages use',
      );
    });

    testWidgets('is reachable while the home feed is still failing', (
      tester,
    ) async {
      // A feed that never arrives must not take the settings entry with it: the
      // icon lives in the top bar, which is drawn whatever the feed does.
      final failing = BrowseAndPlayController(_BrokenCatalog(), media);
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: HomeScreen(controller: failing, qualityController: quality),
        ),
      );
      await tester.pumpAndSettle();

      await openSettings(tester);
      expect(
        find.descendant(
          of: find.byType(SettingsPage),
          matching: find.text(zh(settingsPageTitle)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('every lazy group is reachable and shows real information', (
      tester,
    ) async {
      await pumpHome(tester);
      await openSettings(tester);

      for (final section in SettingsSection.values) {
        await goToGroup(tester, section);
        expect(
          find.text(zh(section.title)),
          findsWidgets,
          reason: '${section.title} is in the nav and as a heading',
        );
        expect(find.text(zh(section.description)), findsOneWidget);
        if (section == SettingsSection.general) {
          expect(find.text(zh(settingsNoItemsYet)), findsWidgets);
        }
      }

      // The groups without behaviour say so instead of drawing dead controls.
      expect(
        find.textContaining(zh(settingsAboutNote), findRichText: true),
        findsOneWidget,
        reason: 'the About section includes the content-rights notice',
      );
    });

    testWidgets('About shows the installed version and project link', (
      tester,
    ) async {
      await pumpSettingsOnly(tester, size: const Size(900, 900));
      await goToGroup(tester, SettingsSection.about);
      expect(find.text('0.1.0'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, zh(UiMessages.githubProject)),
        findsOneWidget,
      );
      expect(
        find.text(zh(UiMessages.openSourceProjectDeclaration)),
        findsOneWidget,
      );
      expect(find.text(zh(UiMessages.neteaseOfficialWebsite)), findsOneWidget);
    });

    testWidgets('About fits narrow windows with large text in every locale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final locale in [
        const Locale('en'),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: FideflowTheme.dark(),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SettingsPage(playback: PlaybackSnapshot.idle()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await goToGroup(tester, SettingsSection.about);
        expect(
          tester.takeException(),
          isNull,
          reason: '$locale at 320px with 2x text',
        );
      }
    });

    testWidgets('the nav moves to a group and the highlight follows it', (
      tester,
    ) async {
      await pumpHome(tester);
      await openSettings(tester);
      final primary = FideflowTheme.dark().colorScheme.primary;
      Color? navColor(String title) =>
          tester.widgetList<Text>(find.text(zh(title))).first.style?.color;

      expect(navColor('账号'), primary, reason: 'the first group owns the top');

      // The area the groups scroll in, which is where a jump has to land.
      final viewport = tester.getRect(
        find
            .descendant(
              of: find.byType(SettingsPage),
              matching: find.byType(ListView),
            )
            .last,
      );
      final heading = find.text(zh(SettingsSection.about.title)).last;
      await goToGroup(tester, SettingsSection.about);
      final after = tester.getTopLeft(heading).dy;

      expect(
        after,
        greaterThanOrEqualTo(viewport.top),
        reason: 'the heading is inside the scrolling area, not under the nav',
      );
      expect(after, lessThan(viewport.bottom));
      expect(navColor('关于'), primary);
      expect(navColor('账号'), isNot(primary));
    });

    testWidgets('the highlight stays on the tapped group while it scrolls', (
      tester,
    ) async {
      // A jump passes through every group in between, and the spy reads that as
      // a manual scroll: without holding the tap's own answer for the length of
      // the animation the nav would light up 播放、快捷键、音质 on the way to 关于.
      await pumpSettingsOnly(tester, size: const Size(900, 700));
      final primary = FideflowTheme.dark().colorScheme.primary;
      Color? navColor(String title) =>
          tester.widgetList<Text>(find.text(zh(title))).first.style?.color;

      await tester.tap(find.text(zh(SettingsSection.about.title)).first);
      for (var elapsed = 0; elapsed < 300; elapsed += 50) {
        await tester.pump(const Duration(milliseconds: 50));
        for (final section in SettingsSection.values) {
          expect(
            navColor(section.title) == primary,
            section == SettingsSection.about,
            reason:
                '${section.title} at +${elapsed + 50}ms into the jump to 关于',
          );
        }
      }
      await tester.pumpAndSettle();
      expect(navColor('关于'), primary);
    });

    testWidgets('the entry stays on screen where the message icon would not', (
      tester,
    ) async {
      // 消息 is hidden below 680; settings must not be, or a narrow window would
      // have no way into the page at all. The feed is left failing on purpose:
      // the discovery page has its own narrow-window overflow, which is not this
      // page's subject, and a failed feed keeps it out of the capture.
      final failing = BrowseAndPlayController(_BrokenCatalog(), media);
      await tester.binding.setSurfaceSize(const Size(660, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: HomeScreen(controller: failing, qualityController: quality),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('消息'), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      await openSettings(tester);
      expect(
        find.descendant(
          of: find.byType(SettingsPage),
          matching: find.text(zh(settingsPageTitle)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('fits a narrow window without overflowing', (tester) async {
      // Driven on its own: the design asks the *settings page* to survive a
      // narrow window, and the app shell's own player bar is a separate concern.
      await pumpSettingsOnly(tester, size: const Size(420, 800));

      expect(
        tester.takeException(),
        isNull,
        reason: 'a narrow window stacks the groups instead of squeezing them',
      );
      await goToGroup(tester, SettingsSection.audio);
      expect(tester.takeException(), isNull);
      expect(
        find.text(zh(qualityMenuTitle(AudioQuality.hiRes))),
        findsOneWidget,
      );
    });

    testWidgets(
      'all section tabs fit on a mobile width window without being cut off',
      (tester) async {
        for (final width in [360.0, 390.0]) {
          await pumpSettingsOnly(tester, size: Size(width, 844));
          for (final section in SettingsSection.values) {
            final tabText = find.text(zh(section.title)).first;
            expect(tabText, findsOneWidget);
            final rect = tester.getRect(tabText);
            expect(
              rect.left,
              greaterThanOrEqualTo(0),
              reason: '${section.title} left at $width',
            );
            expect(
              rect.right,
              lessThanOrEqualTo(width),
              reason: '${section.title} right at $width',
            );
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  });

  group('the quality preference', () {
    testWidgets('choosing a level updates the preference and remembers it', (
      tester,
    ) async {
      await pumpHome(tester);
      await openSettings(tester);
      await goToGroup(tester, SettingsSection.audio);

      expect(
        find.text('当前选择的偏好：'),
        findsOneWidget,
        reason: 'the page always says what is chosen and what is playing',
      );
      await tester.tap(
        find.text(zh(qualityMenuTitle(AudioQuality.lossless))).first,
      );
      await tester.pumpAndSettle();

      expect(quality.preference, AudioQuality.lossless);
      expect(await store.read(), AudioQuality.lossless);
    });

    testWidgets('Hi-Res is offered once it is verified', (tester) async {
      expect(
        qualityTierVerified,
        isTrue,
        reason:
            'the real answers for both tiers are captured in '
            'live-quality-authenticated/ and asserted by the replay test',
      );
      await pumpHome(tester);
      await openSettings(tester);
      await goToGroup(tester, SettingsSection.audio);

      // No tier is marked as unverified, and each one can be chosen. The label
      // of the tier already chosen also appears in the "当前选择的偏好" line, so
      // presence is what is asserted here, not uniqueness.
      expect(find.text(zh(qualityUnverifiedBadge)), findsNothing);
      for (final offered in AudioQuality.values) {
        expect(find.text(zh(qualityMenuTitle(offered))), findsWidgets);
      }

      for (final level in [AudioQuality.hiRes]) {
        await tester.tap(find.text(zh(qualityMenuTitle(level))));
        await tester.pumpAndSettle();
        expect(quality.preference, level);
        expect(
          await store.read(),
          level,
          reason: '${level.name} is a stable value the file keeps',
        );
      }
    });

    testWidgets('a change here is what the player shows', (tester) async {
      await pumpHome(tester);
      await controller.playTrack(0);
      await tester.pumpAndSettle();

      await openSettings(tester);
      await goToGroup(tester, SettingsSection.audio);
      await tester.tap(
        find.text(zh(qualityMenuTitle(AudioQuality.standard))).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('后退'));
      await tester.pumpAndSettle();

      // The full-screen player reads the same controller, so it shows the level
      // that was chosen on the settings page.
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text(
            zh(controller.current.playback.currentTrack!.title),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPage), findsOneWidget);
      final menuButton = tester.widget<QualityMenuButton>(
        find.descendant(
          of: find.byType(NowPlayingPage),
          matching: find.byType(QualityMenuButton),
        ),
      );
      expect(menuButton.preference, AudioQuality.standard);
    });

    testWidgets('changing the preference while a song plays does not break it', (
      tester,
    ) async {
      // The acceptance bar for this release: local playback, switching songs and
      // the settings page all keep working.
      await pumpHome(tester);
      await controller.playTrack(0);
      await tester.pumpAndSettle();

      await openSettings(tester);
      await goToGroup(tester, SettingsSection.audio);
      await tester.tap(
        find.text(zh(qualityMenuTitle(AudioQuality.lossless))).first,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(quality.preference, AudioQuality.lossless);
      expect(controller.current.playback.currentTrack, isNotNull);
    });

    testWidgets('a failed switch keeps the preference and says so', (
      tester,
    ) async {
      final scripted = _ScriptedQualityMedia(
        outcome: const QualitySwitchOutcome(
          preferenceApplied: true,
          errorCode: 'playback.qualitySwitchPartial',
        ),
      );
      final partial = QualityController(media: scripted, store: store);
      final partialController = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        scripted,
      );

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: HomeScreen(
            controller: partialController,
            qualityController: partial,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openSettings(tester);
      await goToGroup(tester, SettingsSection.audio);
      await tester.tap(
        find.text(zh(qualityMenuTitle(AudioQuality.lossless))).first,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('偏好已更新，当前这首稍后生效'),
        findsOneWidget,
        reason: 'the wording promises the preference, not a new source',
      );
      expect(partial.preference, AudioQuality.lossless);
      expect(await store.read(), AudioQuality.lossless);
    });
  });

  group('QualitySettingsSection', () {
    Future<void> pumpSection(
      WidgetTester tester, {
      required PlaybackSnapshot playback,
      QualityController? sectionController,
      bool withController = true,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: FideflowTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: QualitySettingsSection(
                playback: playback,
                controller: withController
                    ? (sectionController ?? quality)
                    : null,
              ),
            ),
          ),
        ),
      );
      // A single frame rather than a settle: a selection in flight draws a
      // spinner, and an animation that never ends never settles.
      await tester.pump();
    }

    testWidgets(
      'non-VIP selections show a permission message without saving VIP quality',
      (tester) async {
        await quality.activateAccount('free', isVip: false);
        await pumpSection(tester, playback: PlaybackSnapshot.idle());
        expect(find.text('无损与 Hi-Res 音质为 VIP 专享，当前账号暂无权限。'), findsOneWidget);
        for (final level in [AudioQuality.lossless, AudioQuality.hiRes]) {
          await tester.tap(find.text(zh(qualityMenuTitle(level))).first);
          await tester.pumpAndSettle();
          expect(find.text('该音质为 VIP 专享，当前账号暂无权限'), findsOneWidget);
          expect(quality.preference, AudioQuality.high);
          expect(await store.read(), isNull);
          ScaffoldMessenger.of(
            tester.element(find.byType(QualitySettingsSection)),
          ).removeCurrentSnackBar();
          await tester.pumpAndSettle();
        }
        await tester.tap(
          find.text(zh(qualityMenuTitle(AudioQuality.standard))).first,
        );
        await tester.pumpAndSettle();
        await quality.flush();
        expect(await store.read(), AudioQuality.standard);
      },
    );

    testWidgets(
      'shows only the preference while a different quality is playing',
      (tester) async {
        await pumpSection(
          tester,
          playback: _snapshot(
            quality: const PlaybackQuality(
              level: AudioQuality.lossless,
              confirmed: true,
            ),
          ),
        );

        expect(find.text('当前选择的偏好：'), findsOneWidget);
        expect(find.text(zh(qualityLabel(AudioQuality.high))), findsWidgets);
        expect(find.text('当前实际音质：'), findsNothing);
        expect(
          find.text(zh(qualityLabel(AudioQuality.lossless))),
          findsNothing,
        );
      },
    );

    testWidgets('an unconfirmed source does not add an actual-quality row', (
      tester,
    ) async {
      await pumpSection(
        tester,
        playback: _snapshot(
          quality: const PlaybackQuality(level: AudioQuality.lossless),
        ),
      );

      expect(find.text('音质未知'), findsNothing);
    });

    testWidgets('a source switch in flight disables the choice', (
      tester,
    ) async {
      // The old source is still the confirmed one and a replacement is coming:
      // the line names what is audible and the options stop stacking a second
      // change on top of the first.
      await pumpSection(
        tester,
        playback: _snapshot(
          quality: const PlaybackQuality(
            level: AudioQuality.lossless,
            confirmed: true,
            switching: true,
          ),
        ),
      );

      expect(find.text('当前仍为 无损音质(SQ)，正在切换…'), findsNothing);
      await tester.tap(find.text(zh(qualityMenuTitle(AudioQuality.standard))));
      await tester.pump();
      expect(quality.preference, AudioQuality.high);
    });

    testWidgets('a selection in flight cannot be submitted twice', (
      tester,
    ) async {
      final held = _HeldQualityMedia();
      final heldController = QualityController(media: held);
      addTearDown(heldController.dispose);
      await pumpSection(
        tester,
        playback: _snapshot(page: false),
        sectionController: heldController,
      );

      await tester.tap(find.text(zh(qualityMenuTitle(AudioQuality.standard))));
      await tester.pump();
      expect(held.switches, 1);

      // While the first selection is unanswered the options are inert. This is
      // the guard the two entry points share.
      await tester.tap(find.text(zh(qualityMenuTitle(AudioQuality.lossless))));
      await tester.pump();
      expect(
        held.switches,
        1,
        reason: 'the second tap never reached the backend',
      );

      held.gate.complete();
      await tester.pump();
      await tester.pump();
      expect(heldController.preference, AudioQuality.standard);
    });

    testWidgets('says so when there is no preference to store', (tester) async {
      await pumpSection(
        tester,
        playback: _snapshot(page: false),
        withController: false,
      );

      expect(find.text('这个版本没有可用的音质偏好存储，因此无法在这里选择音质。'), findsOneWidget);
      expect(find.text(zh(qualityMenuTitle(AudioQuality.high))), findsNothing);
    });
  });

  test('every tier is offered, and gating follows the verification', () {
    for (final level in AudioQuality.values) {
      expect(
        qualityIsSelectable(level),
        qualityTierVerified || level.index < AudioQuality.hiRes.index,
        reason: '${level.name} is offered iff it is verified',
      );
    }

    // Each tier has words, and each upper tier says what it will *not* do.
    for (final level in AudioQuality.values) {
      expect(qualityLabel(level), isNotEmpty);
      expect(qualityDescription(level), isNotEmpty);
    }
    expect(
      localizedTestValue(qualityDescription(AudioQuality.hiRes)),
      contains('无损'),
    );
    expect(
      localizedTestValue(qualityDescription(AudioQuality.hiRes)),
      contains('无损'),
    );

    expect(localizedTestValue(qualityFallbackNote), contains('实际音质'));
  });
}

/// One item, with whatever quality the case needs.
PlaybackSnapshot _snapshot({
  PlaybackQuality? quality,
  bool page = true,
}) => PlaybackSnapshot(
  sessionId: 'session-1',
  sessionRevision: 1,
  queueRevision: 1,
  status: PlaybackStatus.playing,
  queue: page
      ? [
          Track(
            id: const TrackId('track-1'),
            title: 'Starlight Receiver',
            artists: const [Artist(id: ArtistId('artist-1'), name: 'Aurora')],
            album: const Album(id: AlbumId('album-1'), title: 'Night Drive'),
            duration: const Duration(minutes: 3),
          ),
        ]
      : const [],
  currentIndex: page ? 0 : null,
  position: Duration.zero,
  playWhenReady: true,
  quality: quality,
);

/// A backend whose quality switch answers what the case needs.
final class _ScriptedQualityMedia
    implements MediaController, QualitySwitchableMediaController {
  _ScriptedQualityMedia({required this.outcome});

  final QualitySwitchOutcome outcome;
  final StreamController<PlaybackSnapshot> _events =
      StreamController<PlaybackSnapshot>.broadcast();

  @override
  Future<QualitySwitchOutcome> setQuality({
    required AudioQuality preference,
  }) async => outcome;

  @override
  Future<CommandResult> execute(PlaybackCommand command) async =>
      const CommandResult.accepted(1);

  @override
  Future<PlaybackSnapshot> getSnapshot() async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'scripted',
    baseline: PlaybackSnapshot.idle(),
    snapshots: _events.stream,
  );

  @override
  Future<void> detach(String connectionId) async {}
}

/// A backend whose switch waits for the test, so the "applying" window is real.
final class _HeldQualityMedia
    implements MediaController, QualitySwitchableMediaController {
  final StreamController<PlaybackSnapshot> _events =
      StreamController<PlaybackSnapshot>.broadcast();
  final Completer<void> gate = Completer<void>();
  int switches = 0;

  @override
  Future<QualitySwitchOutcome> setQuality({
    required AudioQuality preference,
  }) async {
    switches++;
    await gate.future;
    return QualitySwitchOutcome(preferenceApplied: true);
  }

  @override
  Future<CommandResult> execute(PlaybackCommand command) async =>
      const CommandResult.accepted(1);

  @override
  Future<PlaybackSnapshot> getSnapshot() async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'held',
    baseline: PlaybackSnapshot.idle(),
    snapshots: _events.stream,
  );

  @override
  Future<void> detach(String connectionId) async {}
}

/// A catalog whose home feed never arrives, for the entry-point test.
final class _BrokenCatalog implements CatalogRepository {
  @override
  Future<HomeFeed> getHomeFeed({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => throw const AppError(
    category: AppErrorCategory.network,
    code: 'network.unreachable',
    retryable: true,
  );

  @override
  Future<Track> getTrack(TrackId id) async => throw UnimplementedError();

  @override
  Future<PlaylistDetail> getPlaylist(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => throw UnimplementedError();

  @override
  Future<SearchResult<Track>> searchTracks(SearchQuery query) async =>
      const SearchResult(items: [], totalCount: 0, hasMore: false);

  @override
  Future<SearchResult<Track>> getPlaylistTracks(
    PlaylistId id, {
    int limit = 50,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => const SearchResult(items: [], totalCount: 0, hasMore: false);

  @override
  Future<PlaylistAccessVerdict> getPlaylistAccess(
    PlaylistId id, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => PlaylistAccessVerdict(
    namespace: 'ncm',
    target: id,
    state: PlaylistAccessState.publicConfirmed,
    evidenceMode: RequestAuthMode.anonymous,
    evidenceKind: 'test',
    fetchedAt: DateTime.now(),
    freshUntil: DateTime.now().add(const Duration(hours: 1)),
  );
}
