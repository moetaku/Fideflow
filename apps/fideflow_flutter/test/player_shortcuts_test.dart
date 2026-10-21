import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/macos_player_controls.dart';
import 'package:fideflow/app/shortcut_config.dart';
import 'package:fideflow/features/settings/shortcut_settings_section.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';
import '../../../tooling/test_localization.dart';

class _Bridge implements PlayerPlatformBridge {
  ShortcutConfig? config;
  final published = <Map<String, Object?>>[];
  final suspended = <bool>[];
  Map<String, String> failures = {};
  bool closed = false;
  final covers = <(String, Uint8List)>[];
  Future<bool> Function(String, double?)? action;
  @override
  Future<void> initialize(
    Future<bool> Function(String, double?) onAction, {
    void Function(String?)? onHotkeyError,
  }) async {
    action = onAction;
  }

  @override
  Future<Map<String, String>> configure(ShortcutConfig value) async {
    if (failures.isEmpty) config = value;
    return failures;
  }

  @override
  Future<void> suspend(bool value) async {
    suspended.add(value);
  }

  @override
  Future<void> publish(Map<String, Object?> state) async {
    published.add(state);
  }

  @override
  Future<void> artwork(String token, Uint8List bytes) async {
    covers.add((token, bytes));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _PendingBridge extends _Bridge {
  final permission = Completer<Map<String, String>>();
  bool waiting = false;
  @override
  Future<Map<String, String>> configure(ShortcutConfig value) async {
    if (value.globalEnabled) {
      waiting = true;
      return permission.future;
    }
    return super.configure(value);
  }

  @override
  Future<void> close() async {
    await super.close();
    if (!permission.isCompleted) permission.complete({});
  }
}

class _PartialBridge extends _Bridge {
  @override
  Future<Map<String, String>> configure(ShortcutConfig value) async {
    config = value;
    return value.globalEnabled ? {'toggle': UiMessages.hotkeyOccupied} : {};
  }
}

class _FailStore extends MemoryShortcutStore {
  @override
  Future<void> write(ShortcutConfig config) async {
    throw const FileSystemException('read only');
  }
}

Track _track(String id) => Track(
  id: TrackId(id),
  title: id,
  artists: const [],
  album: const Album(id: AlbumId('a'), title: 'Album'),
  duration: const Duration(minutes: 3),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BrowseAndPlayController playback;
  late PlayerControls controls;
  late _Bridge bridge;
  var widgetClosed = false;
  setUp(() async {
    widgetClosed = false;
    playback = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      FakeMediaController(),
    );
    await playback.initialize(prefetchPlaylist: false);
    bridge = _Bridge();
    controls = PlayerControls(
      playback: playback,
      store: MemoryShortcutStore(),
      bridge: bridge,
    );
    await controls.initialize();
  });
  tearDown(() async {
    if (!widgetClosed) await controls.close();
    await playback.dispose();
  });
  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) =>
      tester.sendKeyEvent(key);
  Future<void> widgetClose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var done = false;
    final closing = controls.close().then((_) => done = true);
    // Native keyboard callbacks and the test frame clock use separate zones.
    // Drain both while awaiting lifecycle shutdown.
    for (var i = 0; i < 20 && !done; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(
      done,
      isTrue,
      reason: 'Controls should release all subscriptions and commands',
    );
    await closing;
    widgetClosed = true;
  }

  void widgetTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await widgetClose(tester);
      }
    });
  }

  test(
    'partial shortcut registration is rolled back to the saved configuration',
    () async {
      await controls.close();
      final partial = _PartialBridge();
      controls = PlayerControls(
        playback: playback,
        store: MemoryShortcutStore(),
        bridge: partial,
      );
      await controls.initialize();
      expect(
        await controls.update((value) => value.copyWith(globalEnabled: true)),
        false,
      );
      expect(controls.config.globalEnabled, false);
      expect(partial.config!.globalEnabled, false);
    },
  );

  test(
    'close during restored shortcut permission cannot revive controls',
    () async {
      await controls.close();
      final pending = _PendingBridge();
      final store = MemoryShortcutStore();
      store.value = store.value.copyWith(globalEnabled: true);
      controls = PlayerControls(
        playback: playback,
        store: store,
        bridge: pending,
      );
      final initializing = controls.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(pending.waiting, true);
      await controls.close().timeout(const Duration(seconds: 2));
      await initializing;
      expect(pending.closed, true);
      expect(await controls.dispatch('play', null), false);
    },
  );

  test(
    'close cancels pending native shortcut permission before awaiting writes',
    () async {
      await controls.close();
      final pending = _PendingBridge();
      controls = PlayerControls(
        playback: playback,
        store: MemoryShortcutStore(),
        bridge: pending,
      );
      await controls.initialize();
      final updating = controls.update(
        (value) => value.copyWith(globalEnabled: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(pending.waiting, true);
      await controls.close().timeout(const Duration(seconds: 2));
      expect(await updating, false);
      expect(controls.config.globalEnabled, false);
      expect(pending.closed, true);
    },
  );

  test(
    'MPRIS property actions update shared volume and playback mode',
    () async {
      expect(await controls.dispatch('setVolume', .25), true);
      expect(playback.current.playback.volume, 250);
      expect(await controls.dispatch('setVolume', double.nan), false);
      expect(await controls.dispatch('setLoopStatus', 1), true);
      expect(playback.current.playback.mode, PlaybackMode.repeatOne);
      expect(await controls.dispatch('setLoopStatus', 9), false);
      expect(await controls.dispatch('setShuffle', 0), true);
      expect(playback.current.playback.mode, PlaybackMode.repeatOne);
      expect(await controls.dispatch('setShuffle', 1), true);
      expect(playback.current.playback.mode, PlaybackMode.shuffle);
      expect(await controls.dispatch('setShuffle', 0), true);
      expect(playback.current.playback.mode, PlaybackMode.listLoop);
    },
  );

  test(
    'defaults round trip and reject duplicates, navigation and bare global key',
    () {
      final defaults = ShortcutConfig.defaults();
      expect(defaults.globalEnabled, false);
      expect(defaults.mediaEnabled, true);
      expect(
        localizedTestValue(defaults.local[PlayerAction.toggle]!.label),
        '空格',
      );
      expect(defaults.global[PlayerAction.favorite]!.label, '⌥⌘L');
      expect(
        ShortcutConfig.fromJson(
          jsonDecode(jsonEncode(defaults.toJson())),
        ).validationError(),
        isNull,
      );
      expect(
        localizedTestValue(
          defaults
              .copyWith(
                local: {
                  ...defaults.local,
                  PlayerAction.next: defaults.local[PlayerAction.previous],
                },
              )
              .validationError(),
        ),
        contains('重复'),
      );
      expect(
        localizedTestValue(
          defaults
              .copyWith(
                local: {
                  ...defaults.local,
                  PlayerAction.next: const ShortcutBinding(47, meta: true),
                },
              )
              .validationError(),
        ),
        contains('前进/后退'),
      );
      expect(
        localizedTestValue(
          defaults
              .copyWith(
                global: {
                  ...defaults.global,
                  PlayerAction.next: const ShortcutBinding(7),
                },
              )
              .validationError(),
        ),
        contains('⌘'),
      );
      expect(
        localizedTestValue(
          defaults
              .copyWith(
                local: {
                  ...defaults.local,
                  PlayerAction.next: defaults.global[PlayerAction.next],
                },
              )
              .validationError(),
        ),
        contains('重复'),
      );
    },
  );
  test(
    'file persistence uses defaults for missing/corrupt/future schema',
    () async {
      final directory = await Directory.systemTemp.createTemp('ff-shortcuts-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileShortcutStore(
        '${directory.path}/settings/shortcuts.json',
      );
      expect((await store.read()).mediaEnabled, true);
      await store.write(
        ShortcutConfig.defaults().copyWith(globalEnabled: true),
      );
      expect((await store.read()).globalEnabled, true);
      await File(store.path).writeAsString('{bad json');
      expect((await store.read()).globalEnabled, false);
      await File(store.path).writeAsString(
        jsonEncode({...ShortcutConfig.defaults().toJson(), 'version': 2}),
      );
      expect((await store.read()).mediaEnabled, true);
    },
  );
  test(
    'Linux defaults use Ctrl bindings and retain the shared config schema',
    () {
      final config = ShortcutConfig.defaults(linux: true);
      expect(config.local[PlayerAction.toggle]!.control, false);
      expect(config.local[PlayerAction.toggle]!.meta, false);
      expect(config.local[PlayerAction.next]!.control, true);
      expect(config.local[PlayerAction.next]!.meta, false);
      expect(config.global[PlayerAction.next]!.control, true);
      expect(config.global[PlayerAction.next]!.alt, true);
      expect(config.validationError(), isNull);
      final restored = ShortcutConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())),
      );
      expect(restored.toJson(), config.toJson());
    },
  );
  test(
    'unsupported global registration leaves media controls available',
    () async {
      final platform = _Bridge()..failures = {'next': 'unsupported'};
      final service = PlayerControls(
        playback: playback,
        store: MemoryShortcutStore(),
        bridge: platform,
      );
      await service.initialize();
      addTearDown(service.close);
      expect(service.available, true);
      expect(service.config.globalEnabled, false);
      expect(service.config.mediaEnabled, true);
      expect(localizedTestValue(service.error), contains('下一首'));
    },
  );
  test(
    'registration failure keeps old config; sequential changes persist last value',
    () async {
      bridge.failures = {'next': 'occupied'};
      expect(
        await controls.update((config) => config.copyWith(globalEnabled: true)),
        false,
      );
      expect(controls.config.globalEnabled, false);
      expect(localizedTestValue(controls.error), contains('下一首'));
      bridge.failures = {};
      final first = controls.update(
        (config) => config.copyWith(globalEnabled: true),
      );
      final last = controls.update(
        (config) => config.copyWith(mediaEnabled: false),
      );
      expect(await first, true);
      expect(await last, true);
      expect((await controls.store.read()).globalEnabled, true);
      expect(controls.config.globalEnabled, true);
      expect((await controls.store.read()).mediaEnabled, false);
      expect(controls.config.mediaEnabled, false);
    },
  );
  test('disk failure rolls native configuration back', () async {
    final failing = PlayerControls(
      playback: playback,
      store: _FailStore(),
      bridge: bridge,
    );
    await failing.initialize();
    expect(
      await failing.update((config) => config.copyWith(globalEnabled: true)),
      false,
    );
    expect(bridge.config!.globalEnabled, false);
    expect(localizedTestValue(failing.error), contains('保存失败'));
    await failing.close();
  });
  test('queued edits to the same field use the last requested value', () async {
    final first = controls.update(
      (config) => config.copyWith(globalEnabled: true),
    );
    final last = controls.update(
      (config) => config.copyWith(globalEnabled: false),
    );
    expect(await first, true);
    expect(await last, true);
    expect(controls.config.globalEnabled, false);
    expect((await controls.store.read()).globalEnabled, false);
    expect(bridge.config!.globalEnabled, false);
  });
  test(
    'failed media disable republishes the current cover with a new token',
    () async {
      final platform = _Bridge();
      final failing = PlayerControls(
        playback: playback,
        store: _FailStore(),
        bridge: platform,
        artworkLoader: (_) async => Uint8List.fromList([1]),
      );
      await failing.initialize();
      addTearDown(failing.close);
      await playback.playTracks([_track('one')]);
      await flush();
      expect(platform.covers, hasLength(1));
      final oldToken = platform.covers.single.$1;
      expect(
        await failing.update((config) => config.copyWith(mediaEnabled: false)),
        false,
      );
      await flush();
      expect(failing.config.mediaEnabled, true);
      expect(platform.config!.mediaEnabled, true);
      expect(platform.published.last['hasTrack'], true);
      expect(platform.covers, hasLength(2));
      expect(platform.covers.last.$1, isNot(oldToken));
      expect(platform.covers.last.$1, platform.published.last['token']);
      expect(platform.covers.last.$2, [1]);
    },
  );
  test(
    'explicit play/pause are idempotent, stop keeps queue and position',
    () async {
      await playback.playTracks([_track('one'), _track('two')]);
      await controls.dispatch('play', null);
      await controls.dispatch('play', null);
      expect(playback.current.playback.playWhenReady, true);
      await controls.dispatch('pause', null);
      await controls.dispatch('pause', null);
      expect(playback.current.playback.playWhenReady, false);
      await playback.seek(const Duration(seconds: 12));
      await controls.dispatch('stop', null);
      expect(playback.current.playback.queue, hasLength(2));
      expect(playback.current.playback.position, const Duration(seconds: 12));
      expect(playback.current.playback.status, PlaybackStatus.idle);
      await controls.dispatch('play', null);
      expect(playback.current.playback.playWhenReady, true);
      expect(await controls.dispatch('seek', double.nan), false);
      expect(await controls.dispatch('seek', -1), false);
      await controls.dispatch('seek', 999);
      expect(playback.current.playback.position, const Duration(minutes: 3));
    },
  );
  test(
    'ordered rapid next/previous and volume commands follow session',
    () async {
      await playback.playTracks([
        _track('one'),
        _track('two'),
        _track('three'),
      ]);
      await Future.wait([
        controls.dispatch('next', null),
        controls.dispatch('next', null),
        controls.dispatch('previous', null),
      ]);
      expect(playback.current.playback.currentTrack!.title, 'two');
      await playback.setVolume(900);
      await Future.wait(
        List.generate(4, (_) => controls.dispatch('volumeUp', null)),
      );
      expect(playback.current.playback.volume, 1000);
      await Future.wait(
        List.generate(22, (_) => controls.dispatch('volumeDown', null)),
      );
      expect(playback.current.playback.volume, 0);
      await controls.setRecording(true);
      expect(await controls.dispatch('toggle', null), false);
      await controls.setRecording(false);
      expect(bridge.suspended, [true, false]);
    },
  );
  test(
    'empty queue and media disable clear projection; close releases bridge',
    () async {
      expect(await controls.dispatch('toggle', null), false);
      await playback.playTracks([_track('one')]);
      await flush();
      expect(bridge.published.last['hasTrack'], true);
      await controls.update((config) => config.copyWith(mediaEnabled: false));
      expect(bridge.published.last['hasTrack'], false);
      await controls.update((config) => config.copyWith(mediaEnabled: true));
      await playback.clearQueue();
      await flush();
      expect(bridge.published.last['hasTrack'], false);
      await controls.close();
      expect(bridge.closed, true);
      expect(await controls.dispatch('play', null), false);
    },
  );
  test(
    'favorite loads unknown state, toggles and survives account switch without changing config',
    () async {
      final repo = TestAuth();
      final auth = AuthController(repo);
      final catalog = TestCatalog();
      final music = TestMusic(catalog);
      final account = AccountMusicController(
        repository: music,
        catalog: catalog,
        auth: auth,
      );
      final service = PlayerControls(
        playback: playback,
        store: MemoryShortcutStore(),
        bridge: _Bridge(),
        music: account,
        auth: auth,
      );
      repo.login();
      await flush();
      await service.initialize();
      addTearDown(() async {
        await service.close();
        account.dispose();
        auth.dispose();
        await repo.events.close();
      });
      await playback.playTracks([_track(track1.value)]);
      expect(await service.dispatch('favorite', null), true);
      expect(account.favorite(track1), FavoriteState.liked);
      expect(await service.dispatch('favorite', null), true);
      expect(account.favorite(track1), FavoriteState.unliked);
      await service.update((config) => config.copyWith(globalEnabled: true));
      repo.login(id: '43', epoch: 2);
      await flush();
      expect(service.config.globalEnabled, true);
    },
  );
  test(
    'favorite gives local-track and login feedback without opening dialogs',
    () async {
      final messages = <String>[];
      final sub = controls.messages.listen(messages.add);
      await playback.playTracks([_track('local:one')]);
      expect(await controls.dispatch('favorite', null), false);
      await flush();
      expect(localizedTestValue(messages), contains('仅支持网易云歌曲'));
      await sub.cancel();
      final repo = TestAuth();
      final auth = AuthController(repo);
      final catalog = TestCatalog();
      final account = AccountMusicController(
        repository: TestMusic(catalog),
        catalog: catalog,
        auth: auth,
      );
      final service = PlayerControls(
        playback: playback,
        store: MemoryShortcutStore(),
        bridge: _Bridge(),
        music: account,
        auth: auth,
      );
      final loginMessages = <String>[];
      final loginSub = service.messages.listen(loginMessages.add);
      await service.initialize();
      await playback.playTracks([_track(track1.value)]);
      expect(await service.dispatch('favorite', null), false);
      await flush();
      expect(localizedTestValue(loginMessages.single), contains('登录'));
      await loginSub.cancel();
      await service.close();
      account.dispose();
      auth.dispose();
      await repo.events.close();
    },
  );
  test(
    'late covers are discarded and enabling media again reloads the cover',
    () async {
      final pending = <String, Completer<Uint8List?>>{};
      final platform = _Bridge();
      final service = PlayerControls(
        playback: playback,
        store: MemoryShortcutStore(),
        bridge: platform,
        artworkLoader: (track) =>
            (pending[track.id.value] ??= Completer<Uint8List?>()).future,
      );
      await service.initialize();
      addTearDown(service.close);
      await playback.playTracks([_track('first'), _track('second')]);
      await flush();
      await playback.skipNext();
      await flush();
      pending['first']!.complete(Uint8List.fromList([1]));
      await flush();
      expect(platform.covers, isEmpty);
      pending['second']!.complete(Uint8List.fromList([2]));
      await flush();
      expect(platform.covers.single.$2, [2]);
      await service.update((config) => config.copyWith(mediaEnabled: false));
      await service.update((config) => config.copyWith(mediaEnabled: true));
      await flush();
      expect(platform.covers, hasLength(2));
      expect(platform.covers.last.$1, isNot(platform.covers.first.$1));
      await playback.skipPrevious();
      await flush();
      final third = Completer<Uint8List?>();
      pending['third'] = third;
      await playback.playTracks([_track('third')]);
      await flush();
      await service.close();
      third.complete(Uint8List.fromList([3]));
      await flush();
      expect(platform.covers.last.$2, [1]);
    },
  );
  widgetTest('keyboard works on modal routes and ignores editing text', (
    tester,
  ) async {
    await playback.playTracks([_track('one'), _track('two')]);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PlayerKeyboardListener(controls: controls, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              const TextField(),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(content: Text('Modal')),
                  ),
                  child: const Text('open'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await key(tester, LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.current.playback.playWhenReady, false);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await key(tester, LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.current.playback.playWhenReady, false);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.current.playback.playWhenReady, true);
  });
  widgetTest('record, escape, clear and restore defaults on narrow layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ShortcutSettingsSection(controls: controls),
          ),
        ),
      ),
    );
    final toggle = find.byKey(const ValueKey('shortcut-local-toggle'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(controls.recording, true);
    await key(tester, LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    expect(controls.config.local[PlayerAction.toggle]!.label, 'P');
    expect(controls.recording, false);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controls.config.local[PlayerAction.toggle]!.label, 'P');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除绑定'));
    await tester.pumpAndSettle();
    expect(controls.config.local[PlayerAction.toggle], isNull);
    await tester.ensureVisible(find.text('恢复默认'));
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(
      localizedTestValue(controls.config.local[PlayerAction.toggle]!.label),
      '空格',
    );
    expect(tester.takeException(), isNull);
  });
  widgetTest('recording reports duplicate and does not execute player action', (
    tester,
  ) async {
    await playback.playTracks([_track('one')]);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PlayerKeyboardListener(controls: controls, child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ShortcutSettingsSection(controls: controls),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('shortcut-local-favorite')));
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.current.playback.playWhenReady, true);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('快捷键重复'),
      ),
      findsOneWidget,
    );
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });
}
