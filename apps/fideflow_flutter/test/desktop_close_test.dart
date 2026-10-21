import 'dart:async';
import 'dart:io';

import 'package:fideflow/app/desktop_close.dart';
import 'package:fideflow/app/windows_desktop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'preferences default to ask, persist, and recover damaged files',
    () async {
      final dir = await Directory.systemTemp.createTemp('ff-close-');
      addTearDown(() => dir.delete(recursive: true));
      final controller = DesktopCloseController(directory: dir.path);
      await controller.load();
      expect(controller.behavior, DesktopCloseBehavior.ask);
      for (final value in DesktopCloseBehavior.values) {
        await controller.setBehavior(value);
        final restored = DesktopCloseController(directory: dir.path);
        await restored.load();
        expect(restored.behavior, value);
      }
      await File('${dir.path}/desktop-close.json').writeAsString('{broken');
      final restored = DesktopCloseController(directory: dir.path);
      await restored.load();
      expect(restored.behavior, DesktopCloseBehavior.ask);
    },
  );
  test(
    'close waits for UI and coalesces requests; unavailable tray prompts',
    () async {
      final controller = DesktopCloseController(write: (_) async {});
      var calls = 0;
      final decision = Completer<String>();
      final first = controller.requestClose(true);
      expect(identical(first, controller.requestClose(true)), true);
      controller.attach((available) {
        calls++;
        return decision.future;
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      decision.complete('cancel');
      expect(await first, 'cancel');
      await controller.setBehavior(DesktopCloseBehavior.background);
      expect(await controller.requestClose(true), 'background');
      expect(await controller.requestClose(false), 'cancel');
      expect(calls, 2);
      await controller.setBehavior(DesktopCloseBehavior.quit);
      expect(await controller.requestClose(false), 'quit');
    },
  );

  test(
    'settings only change after a successful write, with save notifications',
    () async {
      final pending = Completer<void>();
      final controller = DesktopCloseController(write: (_) => pending.future);
      var changes = 0;
      controller.addListener(() => changes++);
      final save = controller.setBehavior(DesktopCloseBehavior.background);
      expect(controller.saving, true);
      expect(controller.behavior, DesktopCloseBehavior.ask);
      await expectLater(
        controller.setBehavior(DesktopCloseBehavior.quit),
        throwsStateError,
      );
      pending.complete();
      await save;
      expect(controller.behavior, DesktopCloseBehavior.background);
      expect(controller.saving, false);
      expect(changes, 2);
    },
  );

  for (final action in ['关闭窗口', '退出 Fideflow']) {
    for (final remember in [false, true]) {
      testWidgets('$action remember=$remember synchronizes preference', (
        tester,
      ) async {
        final controller = DesktopCloseController(
          windows: true,
          write: (_) async {},
        );
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDesktopCloseDialog(
                      context,
                      controller,
                      true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        if (remember) {
          await tester.tap(find.text('不再询问'));
          await tester.pump();
        }
        await tester.tap(find.text(zh(action)));
        await tester.pumpAndSettle();
        final value = action == '关闭窗口'
            ? DesktopCloseBehavior.background
            : DesktopCloseBehavior.quit;
        expect(result, value.name);
        expect(
          controller.behavior,
          remember ? value : DesktopCloseBehavior.ask,
        );
      });
    }
  }
  testWidgets(
    'failed save keeps dialog and preference; Esc cancels without saving',
    (tester) async {
      final controller = DesktopCloseController(
        write: (_) async => throw FileSystemException('test'),
      );
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDesktopCloseDialog(
                    context,
                    controller,
                    true,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不再询问'));
      await tester.tap(find.text('退出 Fideflow'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(controller.behavior, DesktopCloseBehavior.ask);
      expect(result, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(result, 'cancel');
    },
  );
  testWidgets(
    'unavailable tray disables background; settings reflect updates',
    (tester) async {
      final controller = DesktopCloseController(
        windows: true,
        write: (_) async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopCloseSettings(controller: controller)),
        ),
      );
      await tester.tap(find.text('最小化到系统托盘'));
      await tester.pumpAndSettle();
      expect(controller.behavior, DesktopCloseBehavior.background);
      final context = tester.element(find.byType(DesktopCloseSettings));
      final result = showDesktopCloseDialog(context, controller, false);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '关闭窗口'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await result, 'cancel');
    },
  );
  test(
    'native close bridge returns action without invoking shutdown',
    () async {
      const channel = MethodChannel('fideflow/desktop');
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        channel.setMethodCallHandler(null);
      });
      var quits = 0;
      final controller = DesktopCloseController(write: (_) async {});
      controller.attach((_) async => 'background');
      await WindowsDesktop(() async {
        quits++;
      }, closeController: controller).initialize();
      final response = Completer<String>();
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          const MethodCall('closeRequested', {'canBackground': true}),
        ),
        (data) => response.complete(codec.decodeEnvelope(data!) as String),
      );
      expect(await response.future, 'background');
      expect(quits, 0);
    },
  );
}
