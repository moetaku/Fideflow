import 'dart:async';

import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/app/macos_playback_lifecycle.dart';
import 'package:fideflow/app/macos_player_controls.dart';
import 'package:fideflow/app/shortcut_config.dart';
import 'package:fideflow/app/windows_desktop.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fideflow/desktop');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<bool> quit() async {
    final result = Completer<bool>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('quit')),
      (bytes) {
        result.complete(codec.decodeEnvelope(bytes!) as bool);
      },
    );
    return result.future;
  }

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });
  test(
    'native quit waits for cleanup and coalesces repeated requests',
    () async {
      var calls = 0;
      final cleanup = Completer<void>();
      final desktop = WindowsDesktop(() {
        calls++;
        return cleanup.future;
      });
      await desktop.initialize();
      var completed = false;
      final first = quit().then((value) {
        completed = true;
        return value;
      });
      final second = quit();
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      expect(calls, 1);
      cleanup.complete();
      expect(await first, true);
      expect(await second, true);
    },
  );
  test(
    'cleanup failure rejects native destruction and permits retry',
    () async {
      var fail = true;
      final desktop = WindowsDesktop(() async {
        if (fail) throw StateError('synthetic cleanup failure');
      });
      await desktop.initialize();
      expect(await quit(), false);
      fail = false;
      expect(await quit(), true);
    },
  );
  test('missing notification area does not prevent startup', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'trayUnavailable');
    });
    await WindowsDesktop(() async {}).initialize();
  });
  test(
    'real dependency shutdown completes after multiple cleanup failures',
    () async {
      final store = _FailingRecentStore();
      final dependencies = AppDependencies.forTesting(
        homeController: BrowseAndPlayController(
          FakeCatalogRepository(),
          FakeMediaController(),
          recentPlayback: RecentPlaybackController(store),
        ),
      );
      final lifecycle = MacosPlaybackLifecycle(dependencies.homeController);
      dependencies.playbackLifecycle = lifecycle;
      messenger.setMockMethodCallHandler(MacosPlaybackLifecycle.channel, (
        call,
      ) async {
        if (call.method == 'dispose') {
          throw PlatformException(code: 'cleanupFailure');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          MacosPlaybackLifecycle.channel,
          null,
        ),
      );
      await lifecycle.initialize();
      final authClosed = Completer<void>();
      dependencies.authController.states.listen(
        (_) {},
        onDone: authClosed.complete,
      );
      await WindowsDesktop(dependencies.dispose).initialize();
      final results = await Future.wait([quit(), quit()]);
      expect(results, [true, true]);
      await authClosed.future;
      expect(store.closeCalls, 1);
      expect(await quit(), true);
      await dependencies.dispose();
      expect(store.closeCalls, 1);
    },
  );
  test('Windows defaults use Ctrl and Alt without claiming Win shortcuts', () {
    final config = ShortcutConfig.defaults(windows: true);
    expect(config.validationError(), isNull);
    expect(config.globalEnabled, false);
    expect(config.local[PlayerAction.next]!.control, true);
    expect(config.local[PlayerAction.next]!.meta, false);
    expect(config.global[PlayerAction.toggle]!.control, true);
    expect(config.global[PlayerAction.toggle]!.alt, true);
  });
  test(
    'native layout errors and recovery reach the controls callback',
    () async {
      const controlsChannel = ChannelPlayerPlatformBridge.channel;
      final errors = <String?>[];
      var actions = 0;
      await ChannelPlayerPlatformBridge().initialize((_, _) async {
        actions++;
        return true;
      }, onHotkeyError: errors.add);
      addTearDown(() => controlsChannel.setMethodCallHandler(null));
      for (final message in <String?>['controls.layoutChanged', null]) {
        final reply = Completer<void>();
        await messenger.handlePlatformMessage(
          controlsChannel.name,
          codec.encodeMethodCall(MethodCall('hotkeyError', message)),
          (bytes) {
            codec.decodeEnvelope(bytes!);
            reply.complete();
          },
        );
        await reply.future;
      }
      expect(errors, [UiMessages.hotkeyLayoutChanged, null]);
      expect(actions, 0);
    },
  );
}

final class _FailingRecentStore implements RecentPlaybackStore {
  final _store = MemoryRecentPlaybackStore();
  int closeCalls = 0;
  @override
  Future<void> close() async {
    closeCalls++;
    throw StateError('synthetic checkpoint close failure');
  }

  @override
  Future<void> record(List<RecentPlaybackEntry> entries) =>
      _store.record(entries);
  @override
  Future<List<RecentPlaybackEntry>> read(
    RecentKind kind, {
    int limit = 1000,
    int offset = 0,
  }) => _store.read(kind, limit: limit, offset: offset);
  @override
  Future<void> delete(RecentKind kind, List<String> ids) =>
      _store.delete(kind, ids);
  @override
  Future<void> clear(RecentKind kind) => _store.clear(kind);
}
