import 'dart:io';
import 'dart:ui' as ui;

import 'package:fideflow/app/app.dart';
import 'package:fideflow/app/appearance.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/app/language.dart';
import 'package:fideflow/features/discovery/widgets/daily_recommend_card.dart';
import 'package:fideflow/features/discovery/widgets/heartbeat_recommend_card.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final previews = Platform.environment['FF_L10N_PREVIEWS'] == '1';
  setUpAll(() async {
    // Optional local QA uses an installed font rather than Flutter's Ahem font.
    // CI layout tests keep the default test font and need no external assets.
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (previews && font.existsSync()) {
      await (FontLoader(
        'Roboto',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      final icons = File(
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
      }
      final mono = File('C:/Windows/Fonts/consola.ttf');
      if (mono.existsSync()) {
        await (FontLoader(
          'monospace',
        )..addFont(mono.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!previews) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = await Directory(
          'build/l10n_previews',
        ).create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets(
    'switching app language retains detail route, queue, playback and search input',
    (tester) async {
      for (final name in ['fideflow/player_controls']) {
        final channel = MethodChannel(name);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => null);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
      }
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dependencies = AppDependencies.create(environment: const {});
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: FideflowApp(dependencies: dependencies),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('极光夜航').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放全部'));
      await tester.pumpAndSettle();
      final track =
          dependencies.homeController.current.playback.currentTrack!.id;
      final queue = dependencies.homeController.current.playback.queue
          .map((item) => item.id)
          .toList();
      for (final mode in [LanguageMode.english, LanguageMode.simplified]) {
        await dependencies.language.select(mode);
        await tester.pumpAndSettle();
        expect(
          dependencies.homeController.current.playback.currentTrack!.id,
          track,
        );
        expect(
          dependencies.homeController.current.playback.queue
              .map((item) => item.id)
              .toList(),
          queue,
        );
        expect(find.text('极光夜航'), findsWidgets);
        expect(
          find.byTooltip(dependencies.language.copy.pause),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, boundary, 'detail_${mode.id}');
      }
      await tester.enterText(find.byType(TextField).first, '用户输入 / draft');
      for (final mode in [LanguageMode.english, LanguageMode.simplified]) {
        await dependencies.language.select(mode);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).first)
              .controller
              .text,
          '用户输入 / draft',
        );
        expect(
          dependencies.homeController.current.playback.currentTrack!.id,
          track,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      final disposing = dependencies.dispose();
      await tester.pump();
      await disposing;
    },
  );

  for (final mode in [LanguageMode.english, LanguageMode.simplified]) {
    testWidgets('recommendation cards fit narrow layouts in ${mode.id}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final language = LanguageController(platformSync: (_, _) async {});
      addTearDown(language.dispose);
      await language.select(mode);
      await tester.pumpWidget(
        MaterialApp(
          locale: language.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DailyRecommendCard(onTap: () {}, onPlay: () {}),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: HeartbeatRecommendCard(onTap: () {})),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
    for (final width in [400.0, 1280.0]) {
      testWidgets('settings layout ${mode.id} at width $width', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final language = LanguageController(platformSync: (_, _) async {});
        final appearance = AppearanceController();
        final media = FakeMediaController();
        final quality = QualityController(
          media: media,
          store: InMemoryQualityPreferenceStore(),
        );
        addTearDown(language.dispose);
        addTearDown(appearance.dispose);
        addTearDown(quality.dispose);
        await language.select(mode);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: LanguageScope(
              controller: language,
              child: AppearanceScope(
                controller: appearance,
                child: MaterialApp(
                  locale: language.locale,
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: appearance.theme,
                  home: Scaffold(
                    body: SettingsPage(
                      playback: PlaybackSnapshot.idle(),
                      qualityController: quality,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dropdown = find.byKey(const ValueKey('language-selection'));
        await tester.ensureVisible(dropdown);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        expect(find.text('English'), findsWidgets);
        expect(find.text('简体中文'), findsWidgets);
        expect(find.text('繁體中文'), findsNothing);
        expect(find.text(language.copy.languageFollowSystem), findsWidgets);
        await tester.tap(find.text('English').last);
        await tester.pumpAndSettle();
        expect(language.mode, LanguageMode.english);
        await language.select(mode);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, boundary, 'settings_${mode.id}_${width.toInt()}');
      });
    }
  }
}
