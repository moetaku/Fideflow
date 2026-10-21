import 'dart:async';

import 'package:fideflow/features/settings/output_settings_section.dart';
import 'package:fideflow/features/settings/settings_page.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow/presentation/playback/browse_projection.dart';
import 'package:fideflow/presentation/settings/settings_capabilities.dart';
import 'package:fideflow/shared/settings_capabilities_scope.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

const devices = [
  PlaybackOutputDevice(
    uid: 'a',
    name: '同名 DAC',
    isDefault: true,
    exclusiveSupported: true,
  ),
  PlaybackOutputDevice(uid: 'b', name: '同名 DAC', exclusiveSupported: true),
];

String? _menuLabel(WidgetTester tester, MenuItemButton item) => tester
    .widget<Text>(
      find
          .descendant(of: find.byWidget(item), matching: find.byType(Text))
          .first,
    )
    .data;

final class _Media implements MediaController {
  final commands = <PlaybackCommand>[];
  final events = StreamController<PlaybackSnapshot>.broadcast();
  PlaybackOutputSettings output = const PlaybackOutputSettings(
    supported: true,
    devices: devices,
  );
  int revision = 0;
  CommandResult? configureResult;
  PlaybackOutputSettings? refreshedOutput;
  PlaybackSnapshot get current => PlaybackSnapshot(
    sessionId: 'output-test',
    sessionRevision: revision,
    queueRevision: 0,
    status: PlaybackStatus.idle,
    queue: const [],
    currentIndex: null,
    position: Duration.zero,
    playWhenReady: false,
    outputSettings: output,
  );
  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    commands.add(command);
    if (command is SetOutputConfiguration && configureResult != null) {
      return configureResult!;
    }
    if (command is RefreshOutputDevices && refreshedOutput != null) {
      output = refreshedOutput!;
    }
    if (command case SetOutputConfiguration(
      :final deviceUid,
      :final exclusive,
      :final resamplingEnabled,
      :final targetSampleRate,
    )) {
      output = PlaybackOutputSettings(
        supported: true,
        deviceUid: deviceUid,
        exclusive: exclusive,
        resamplingEnabled: resamplingEnabled,
        targetSampleRate: targetSampleRate,
        devices: output.devices,
      );
    }
    revision++;
    events.add(current);
    return CommandResult.accepted(revision);
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() async => current;
  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'output-test',
    baseline: current,
    snapshots: events.stream,
  );
  @override
  Future<void> detach(String connectionId) async {}
}

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      'resampling in Playback preserves device and remembered target (mobile=$mobile)',
      (tester) async {
        final media = _Media()
          ..output = const PlaybackOutputSettings(
            supported: true,
            deviceUid: 'b',
            exclusive: true,
            devices: devices,
          );
        final controller = BrowseAndPlayController(
          FakeCatalogRepository(latency: Duration.zero),
          media,
        );
        await tester.runAsync(
          () => controller.initialize(prefetchPlaylist: false),
        );
        addTearDown(() async {
          unawaited(controller.dispose());
          await media.events.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsCapabilitiesScope(
              capabilities: SettingsCapabilities(
                shortcuts: false,
                windowClose: false,
                outputDevices: !mobile,
              ),
              child: Scaffold(
                body: StreamBuilder<HomeState>(
                  stream: browseStates(controller),
                  initialData: controller.current,
                  builder: (context, state) => SettingsPage(
                    playback: (state.data ?? controller.current).playback,
                    playbackController: controller,
                  ),
                ),
              ),
            ),
          ),
        );
        final section = find.byType(OutputSettingsSection);
        expect(
          tester.widget<OutputSettingsSection>(section).showDevicePicker,
          !mobile,
        );
        final toggle = find.descendant(
          of: section,
          matching: find.byType(SwitchListTile),
        );
        final dropdown = find.descendant(
          of: section,
          matching: find.byType(DropdownButton<int>),
        );
        expect(tester.widget<DropdownButton<int>>(dropdown).value, 48000);
        expect(tester.widget<DropdownButton<int>>(dropdown).onChanged, isNull);
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        // The media subscription was initialized in the real async zone.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        var command = media.commands.whereType<SetOutputConfiguration>().last;
        expect(command.deviceUid, 'b');
        expect(command.exclusive, isTrue);
        expect(command.resamplingEnabled, isTrue);
        expect(media.output.resamplingEnabled, isTrue, reason: 'media state');
        expect(
          controller.current.playback.outputSettings.resamplingEnabled,
          isTrue,
          reason: 'controller state',
        );
        expect(
          tester
              .widget<SettingsPage>(find.byType(SettingsPage))
              .playback
              .outputSettings
              .resamplingEnabled,
          isTrue,
          reason: 'settings page state',
        );
        expect(
          tester
              .widget<OutputSettingsSection>(section)
              .settings
              .resamplingEnabled,
          isTrue,
          reason: 'section state',
        );
        expect(
          tester.widget<DropdownButton<int>>(dropdown).onChanged,
          isNotNull,
        );
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('96.0 kHz').last);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(tester.widget<DropdownButton<int>>(dropdown).value, 96000);
        // A rejected selection must not leave an unsaved value in the dropdown.
        media.configureResult = const CommandResult.rejected(
          'outputOpenFailed',
        );
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('192.0 kHz').last);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(tester.widget<DropdownButton<int>>(dropdown).value, 96000);
        expect(find.byType(SnackBar), findsOneWidget);
        media.configureResult = null;
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        command = media.commands.whereType<SetOutputConfiguration>().last;
        expect(command.exclusive, isTrue);
        expect(command.resamplingEnabled, isFalse);
        expect(command.targetSampleRate, 96000);
        expect(tester.widget<DropdownButton<int>>(dropdown).onChanged, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final locale in [
    const Locale('en'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  ]) {
    testWidgets('resampling fits 320px at 2x text in $locale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final media = _Media();
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      addTearDown(() async {
        unawaited(controller.dispose());
        await media.events.close();
      });
      await tester.pumpWidget(
        MaterialApp(
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
            body: SingleChildScrollView(
              child: OutputSettingsSection(
                controller: controller,
                settings: const PlaybackOutputSettings(
                  supported: true,
                  resamplingEnabled: true,
                  targetSampleRate: 192000,
                ),
                showDevicePicker: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Linux default sink remains selectable as a fixed shared device',
    (tester) async {
      const output = PlaybackOutputSettings(
        supported: true,
        devices: [
          PlaybackOutputDevice(
            uid: 'alsa:pulse:DEVICE=speaker',
            name: 'Speaker',
            isDefault: true,
          ),
          PlaybackOutputDevice(
            uid: 'alsa:dmix:CARD=USB,DEV=0',
            name: 'USB DAC',
          ),
        ],
      );
      final media = _Media()..output = output;
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      await tester.runAsync(
        () => controller.initialize(prefetchPlaylist: false),
      );
      addTearDown(() async {
        unawaited(controller.dispose());
        await media.events.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutputSettingsSection(
              settings: output,
              controller: controller,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      final items = tester
          .widgetList<MenuItemButton>(find.byType(MenuItemButton))
          .toList();
      expect(items, hasLength(3));
      expect(find.text('Speaker'), findsOneWidget);
      expect(find.text('USB DAC'), findsOneWidget);
      await tester.tap(find.widgetWithText(MenuItemButton, 'Speaker'));
      await tester.pumpAndSettle();
      final fixed = media.commands.whereType<SetOutputConfiguration>().last;
      expect(fixed.deviceUid, 'alsa:pulse:DEVICE=speaker');
      expect(fixed.exclusive, isFalse);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MenuItemButton).first);
      await tester.pumpAndSettle();
      final followDefault = media.commands
          .whereType<SetOutputConfiguration>()
          .last;
      expect(followDefault.deviceUid, isNull);
      expect(followDefault.exclusive, isFalse);
    },
  );

  testWidgets('hardware appears only as an exclusive device', (tester) async {
    final media = _Media()
      ..output = const PlaybackOutputSettings(
        supported: true,
        devices: [
          PlaybackOutputDevice(
            uid: 'alsa:hw:CARD=USB,DEV=0,SUBDEV=0',
            name: 'USB DAC',
            sharedSupported: false,
            exclusiveSupported: true,
          ),
        ],
      );
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await tester.runAsync(() => controller.initialize(prefetchPlaylist: false));
    addTearDown(() async {
      unawaited(controller.dispose());
      await media.events.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutputSettingsSection(
            settings: media.output,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<MenuItemButton>(find.byType(MenuItemButton))
        .toList();
    expect(items, hasLength(2));
    expect(find.textContaining('暂无可用设备'), findsNothing);
    expect(find.text('USB DAC'), findsNothing);
    expect(items.last.onPressed, isNotNull);
    await tester.tap(find.byWidget(items.last));
    await tester.pumpAndSettle();
    final command = media.commands.whereType<SetOutputConfiguration>().last;
    expect(command.deviceUid, 'alsa:hw:CARD=USB,DEV=0,SUBDEV=0');
    expect(command.exclusive, isTrue);
  });

  testWidgets(
    'open menu retains shared devices and hides unsupported exclusive entries',
    (tester) async {
      final media = _Media()
        ..refreshedOutput = const PlaybackOutputSettings(
          supported: true,
          devices: [
            PlaybackOutputDevice(uid: 'new', name: '外接设备', isDefault: true),
          ],
        );
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      await tester.runAsync(
        () => controller.initialize(prefetchPlaylist: false),
      );
      addTearDown(() async {
        unawaited(controller.dispose());
        await media.events.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamBuilder<HomeState>(
              stream: controller.states,
              initialData: controller.current,
              builder: (context, snapshot) => OutputSettingsSection(
                settings: (snapshot.data ?? controller.current)
                    .playback
                    .outputSettings,
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      final items = tester
          .widgetList<MenuItemButton>(find.byType(MenuItemButton))
          .toList();
      expect(
        localizedTestValue(items.map((item) => _menuLabel(tester, item))),
        ['默认输出设备（外接设备）', '外接设备'],
      );
      expect(items[1].onPressed, isNotNull);
      expect(items, hasLength(2));
      expect(find.text('外接设备（独占模式）'), findsNothing);
      expect(find.text('同名 DAC'), findsNothing);
    },
  );
  testWidgets(
    'dropdown lists default, all shared devices and all exclusive devices',
    (tester) async {
      final media = _Media();
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      await tester.runAsync(
        () => controller.initialize(prefetchPlaylist: false),
      );
      addTearDown(() async {
        unawaited(controller.dispose());
        await media.events.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamBuilder<HomeState>(
              stream: controller.states,
              initialData: controller.current,
              builder: (context, snapshot) => OutputSettingsSection(
                settings: (snapshot.data ?? controller.current)
                    .playback
                    .outputSettings,
                controller: controller,
              ),
            ),
          ),
        ),
      );
      expect(find.text('播放设备'), findsOneWidget);
      expect(find.textContaining('bit-perfect'), findsNothing);
      expect(find.textContaining('硬件音量'), findsNothing);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(media.commands.whereType<RefreshOutputDevices>(), hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
      final items = tester
          .widgetList<MenuItemButton>(find.byType(MenuItemButton))
          .toList();
      expect(
        localizedTestValue(items.map((item) => _menuLabel(tester, item))),
        ['默认输出设备（同名 DAC）', '同名 DAC', '同名 DAC', '同名 DAC（独占模式）', '同名 DAC（独占模式）'],
      );
      await tester.tap(find.text('同名 DAC').last);
      await tester.pumpAndSettle();
      expect(
        media.commands.whereType<SetOutputConfiguration>().last.deviceUid,
        'b',
      );
      expect(
        media.commands.whereType<SetOutputConfiguration>().last.exclusive,
        isFalse,
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同名 DAC（独占模式）').last);
      await tester.pumpAndSettle();
      expect(
        media.commands.whereType<SetOutputConfiguration>().last.exclusive,
        isTrue,
      );
      expect(
        media.commands.whereType<SetOutputConfiguration>().last.deviceUid,
        'b',
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '默认输出设备（同名 DAC）'));
      await tester.pumpAndSettle();
      final defaultSelection = media.commands
          .whereType<SetOutputConfiguration>()
          .last;
      expect(defaultSelection.deviceUid, isNull);
      expect(defaultSelection.exclusive, isFalse);
    },
  );
  testWidgets(
    'busy settings disable actions and a missing device keeps its selection',
    (tester) async {
      final media = _Media();
      final controller = BrowseAndPlayController(
        FakeCatalogRepository(latency: Duration.zero),
        media,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutputSettingsSection(
              controller: controller,
              settings: const PlaybackOutputSettings(
                supported: true,
                deviceUid: 'removed',
                exclusive: true,
                busy: true,
                errorCode: 'outputDeviceRemoved',
                devices: devices,
              ),
            ),
          ),
        ),
      );
      expect(find.text('所选设备不可用（独占模式）'), findsOneWidget);
      expect(find.textContaining('已停止播放'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(find.byType(Switch), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await media.events.close();
    },
  );

  testWidgets('exclusive mode heading wraps within narrow settings card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final media = _Media();
    final controller = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutputSettingsSection(
              controller: controller,
              settings: const PlaybackOutputSettings(
                supported: true,
                exclusive: true,
                devices: devices,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final heading = find.text(
      'Acquire exclusive access during playback and release it when paused.',
    );
    expect(heading, findsOneWidget);
    expect(tester.getSize(heading).height, greaterThan(14));
    expect(tester.takeException(), isNull);
  });
}
