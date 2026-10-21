import 'dart:async';

import 'package:fideflow/app/desktop_close.dart';
import 'package:fideflow/app/desktop_window.dart';
import 'package:fideflow/app/windows_desktop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fideflow/desktop');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test('Linux desktop window controls are enabled', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(DesktopWindow.supported, isTrue);
  });

  test('Linux tray availability is returned by initialize', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'initialize');
      return false;
    });
    final lifecycle = NativeDesktopLifecycle(() async {});
    await lifecycle.initialize();
    expect(lifecycle.trayAvailable, isFalse);
  });

  test(
    'Linux no-tray close always prompts and cannot choose background',
    () async {
      final controller = DesktopCloseController(
        linux: true,
        write: (_) async {},
      );
      var promptedWithTray = true;
      controller.attach((canBackground) async {
        promptedWithTray = canBackground;
        return 'quit';
      });
      await controller.setBehavior(DesktopCloseBehavior.background);

      expect(await controller.requestClose(false), 'quit');
      expect(promptedWithTray, isFalse);
      expect(controller.usesSystemTray, isTrue);
    },
  );

  testWidgets('Linux close setting uses system tray wording', (tester) async {
    final controller = DesktopCloseController(linux: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DesktopCloseSettings(controller: controller)),
      ),
    );
    expect(find.text('最小化到系统托盘'), findsOneWidget);
    expect(find.text('关闭窗口，继续播放'), findsNothing);
  });

  test('Linux quit cleanup coalesces and a failed cleanup can retry', () async {
    var cleanupCalls = 0;
    final pending = Completer<void>();
    final lifecycle = NativeDesktopLifecycle(() {
      cleanupCalls++;
      return cleanupCalls == 1 ? pending.future : Future<void>.value();
    });
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    await lifecycle.initialize();

    Future<bool> quit() async {
      final response = Completer<bool>();
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('quit')),
        (bytes) => response.complete(codec.decodeEnvelope(bytes!) as bool),
      );
      return response.future;
    }

    final first = quit();
    final second = quit();
    await Future<void>.delayed(Duration.zero);
    expect(cleanupCalls, 1);
    pending.completeError(StateError('first shutdown failed'));
    expect(await Future.wait([first, second]), [false, false]);

    // A later request retries cleanup after the failed attempt.
    expect(await quit(), true);
    expect(cleanupCalls, 2);
  });
}
