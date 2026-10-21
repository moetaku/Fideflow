import 'dart:async';
import 'dart:convert';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

void main() {
  const artist = Artist(id: ArtistId('artist'), name: 'Aurora');
  const album = Album(id: AlbumId('album'), title: 'Night');
  const track = Track(
    id: TrackId('track'),
    title: 'Starlight',
    artists: [artist],
    album: album,
    duration: Duration(minutes: 3),
  );
  const secondTrack = Track(
    id: TrackId('second-track'),
    title: 'Afterglow',
    artists: [artist],
    album: album,
    duration: Duration(minutes: 4),
  );

  NativeMediaController controllerFor(_FakeApi api) =>
      NativeMediaController(api: api, sourceResolver: _FakeResolver());

  for (final reject in [false, true]) {
    test(
      'failed speculative source is not retried by progress (reject=$reject)',
      () async {
        final api = _FakeApi();
        final resolver = _HeldResolver();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: resolver,
        );
        await controller.attach();
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
        );
        await controller.execute(
          const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
        );
        await pumpEventQueue();
        expect(resolver.pending, hasLength(1));
        if (reject) {
          api.reply = const {
            'status': 'rejected',
            'errorCode': 'conflict.generation',
          };
          resolver.pending.single.complete(
            await _FakeResolver().resolve(
              secondTrack.id,
              AudioQuality.standard,
              NetworkPolicy.preferCache,
            ),
          );
        } else {
          resolver.pending.single.completeError(
            StateError('unavailable next song'),
          );
        }
        await pumpEventQueue();
        for (var revision = 3; revision < 9; revision++) {
          api.push(
            _snapshot(
              sessionRevision: revision,
              queueRevision: 1,
              generation: 1,
              phase: 'ready',
              currentQueueItemId: 'qi-1',
              positionMs: revision * 250,
            ),
          );
          await pumpEventQueue();
        }
        expect(resolver.pending, hasLength(1));
        // An authoritative request remains able to retry despite speculation.
        api.pushEvent({
          'schemaVersion': 1,
          'kind': 'sourceRequest',
          'sessionId': 'session-1',
          'sessionRevision': '8',
          'generation': '1',
          'queueItemId': 'qi-2',
          'trackId': 'second-track',
          'requestId': 'jit-next',
          'reason': 'retry',
        });
        await pumpEventQueue();
        expect(resolver.pending, hasLength(2));
        resolver.pending.last.completeError(StateError('still unavailable'));
        await pumpEventQueue();
        await controller.close();
      },
    );
  }

  test(
    'late pause synchronization observes a newer pending activation',
    () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      final focus = Completer<bool>();
      final pending = <bool>[];
      controller.activatePlatformAudio = () => focus.future;
      controller.platformAudioCommandFinished = () async {
        pending.add(controller.platformAudioActivationPending);
      };
      final play = controller.execute(const Play(commandId: 'pending-sync'));
      await controller.execute(const Pause(commandId: 'pause-sync'));
      expect(pending, [true]);
      focus.complete(true);
      await play;
      expect(pending, [true, false]);
      await controller.close();
    },
  );

  test(
    'platform activation exceptions remain typed playback failures',
    () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      controller.activatePlatformAudio = () async =>
          throw StateError('platform unavailable');
      final result = await controller.execute(
        const Play(commandId: 'activation-error'),
      );
      expect(result.errorCode, 'audio.activationFailed');
      expect(api.commands, isEmpty);
      await controller.close();
    },
  );

  test('a lifecycle limit fences a play still awaiting focus', () async {
    final api = _FakeApi();
    final controller = controllerFor(api);
    await controller.attach();
    final focus = Completer<bool>();
    controller.activatePlatformAudio = () => focus.future;
    final play = controller.execute(const Play(commandId: 'pending-limit'));
    await controller.execute(
      const SetInterruption(
        commandId: 'call',
        interruptionId: 'phone',
        active: true,
      ),
    );
    focus.complete(true);
    expect((await play).errorCode, 'cancelled');
    expect(api.commands.where((command) => command['kind'] == 'play'), isEmpty);
    await controller.close();
  });

  test('mobile audio focus refusal never submits a play intent', () async {
    final api = _FakeApi();
    final controller = controllerFor(api);
    await controller.attach();
    controller.activatePlatformAudio = () async => false;
    final result = await controller.execute(
      const Play(commandId: 'focus-denied'),
    );
    expect(result.isAccepted, isFalse);
    expect(api.commands.where((command) => command['kind'] == 'play'), isEmpty);
    await controller.close();
  });

  test('pause fences a play waiting for mobile activation', () async {
    final api = _FakeApi();
    final controller = controllerFor(api);
    await controller.attach();
    final focus = Completer<bool>();
    controller.activatePlatformAudio = () => focus.future;
    final play = controller.execute(const Play(commandId: 'pending-play'));
    await controller.execute(const Pause(commandId: 'user-pause'));
    focus.complete(true);
    expect((await play).isAccepted, isFalse);
    expect(api.commands.where((command) => command['kind'] == 'play'), isEmpty);
    await controller.close();
  });

  test('ducking is a host command and never requests focus', () async {
    final api = _FakeApi();
    final controller = controllerFor(api);
    controller.activatePlatformAudio = () async =>
        throw StateError('must not activate');
    controller.accountTransitionInProgress = true;
    expect(
      (await controller.execute(
        const SetTransientGain(commandId: 'duck', permille: 200),
      )).isAccepted,
      isTrue,
    );
    expect(api.commands.single['payload'], {'volume': 200});
    await controller.close();
  });

  test(
    'non-resuming interruption end clears suppression without focus',
    () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      controller.activatePlatformAudio = () async =>
          throw StateError('must not activate');
      expect(
        (await controller.execute(
          const SetInterruption(
            commandId: 'end',
            interruptionId: 'phone',
            active: false,
            allowResume: false,
          ),
        )).isAccepted,
        isTrue,
      );
      expect(api.commands.single['payload'], {
        'interruptionId': 'phone',
        'active': false,
        'allowResume': false,
      });
      await controller.close();
    },
  );

  test(
    'lifecycle events remain available during account transitions without UI attachment',
    () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      controller.accountTransitionInProgress = true;
      expect(
        (await controller.execute(const Pause(commandId: 'pause'))).isAccepted,
        isFalse,
      );
      expect(
        (await controller.execute(
          const SetInterruption(
            commandId: 'sleep',
            interruptionId: 'cycle',
            active: true,
          ),
        )).isAccepted,
        isTrue,
      );
      expect(
        (await controller.execute(
          const SetInterruption(
            commandId: 'wake',
            interruptionId: 'cycle',
            active: false,
          ),
        )).isAccepted,
        isTrue,
      );
      expect(api.commands.map((c) => c['kind']), [
        'setInterruption',
        'setInterruption',
      ]);
      await controller.close();
    },
  );

  test(
    'interruption commands carry token and host publishes suppression',
    () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      await controller.execute(
        const SetInterruption(
          commandId: 'sleep',
          interruptionId: 'cycle',
          active: true,
        ),
      );
      expect(api.commands.last['kind'], 'setInterruption');
      expect(api.commands.last['payload'], {
        'interruptionId': 'cycle',
        'active': true,
        'allowResume': true,
      });
      api.push({
        ..._snapshot(sessionRevision: 2, phase: 'ready', playWhenReady: true),
        'suppressionReasons': ['interruption'],
      });
      await pumpEventQueue();
      final state = await controller.getSnapshot();
      expect(state.suppressionReasons, ['interruption']);
      expect(state.playWhenReady, isTrue);
      expect(state.status, PlaybackStatus.paused);
      expect(state.isActuallyPlaying, isFalse);
      await controller.execute(
        const SetInterruption(
          commandId: 'wake',
          interruptionId: 'cycle',
          active: false,
        ),
      );
      expect(api.commands.last['payload'], {
        'interruptionId': 'cycle',
        'active': false,
        'allowResume': true,
      });
      await controller.close();
    },
  );

  test(
    'effects preferences restore, serialize writes, and report persistence failure',
    () async {
      final api = _FakeApi();
      final writes = <(bool, bool)>[];
      final gate = Completer<void>();
      var failing = false;
      final controller = NativeMediaController(
        api: api,
        readEffectsPreferences: () async =>
            (fadeEnabled: true, volumeNormalizationEnabled: false),
        writeEffectsPreferences: (fade, normalization) async {
          writes.add((fade, normalization));
          if (writes.length == 1) await gate.future;
          if (failing) throw StateError('disk full');
        },
      );
      await controller.attach();
      await controller.loadEffectsPreferences();
      expect(api.commands.last['kind'], 'setPlaybackEffects');
      expect(api.commands.last['payload'], {
        'fadeEnabled': true,
        'volumeNormalizationEnabled': false,
      });
      expect(writes, isEmpty);
      final first = controller.execute(
        const SetPlaybackEffects(
          commandId: 'effects-1',
          fadeEnabled: true,
          volumeNormalizationEnabled: true,
        ),
      );
      await pumpEventQueue();
      final second = controller.execute(
        const SetPlaybackEffects(
          commandId: 'effects-2',
          fadeEnabled: false,
          volumeNormalizationEnabled: true,
        ),
      );
      await pumpEventQueue();
      expect(writes, [(true, true)]);
      gate.complete();
      expect((await first).isAccepted, isTrue);
      expect((await second).isAccepted, isTrue);
      expect(writes, [(true, true), (false, true)]);
      failing = true;
      final failed = await controller.execute(
        const SetPlaybackEffects(
          commandId: 'effects-3',
          fadeEnabled: true,
          volumeNormalizationEnabled: true,
        ),
      );
      expect(failed.errorCode, 'settings.persistFailed');
      expect((api.commands.last['payload'] as Map)['fadeEnabled'], isFalse);
      await controller.close();
    },
  );

  test(
    'song gain reaches initial queue sources and source replacements',
    () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: _FakeResolver(gain: 3.0815, peak: 0.6215),
      );
      await controller.attach();
      await controller.execute(
        const LoadQueue(commandId: 'gain-load', tracks: [track]),
      );
      final item =
          ((api.commands.first['payload'] as Map)['items'] as List).first
              as Map;
      expect(item['normalizationGainDb'], 3.0815);
      expect(item['normalizationPeak'], 0.6215);
      await controller.execute(
        ProvideSource(
          commandId: 'gain-replace',
          targetQueueItemId: 'item',
          sourceUri: Uri.parse('https://cdn.test/song'),
          normalizationGainDb: 0,
          normalizationPeak: 0,
        ),
      );
      final payload = api.commands.last['payload'] as Map;
      expect(payload['normalizationGainDb'], 0);
      expect(payload.containsKey('normalizationPeak'), isFalse);
      await controller.execute(
        const ProvideSource(
          commandId: 'gain-revoke',
          targetQueueItemId: 'item',
          sourceUri: null,
          normalizationGainDb: 3,
        ),
      );
      expect(
        (api.commands.last['payload'] as Map).containsKey(
          'normalizationGainDb',
        ),
        isFalse,
      );
      await controller.close();
    },
  );

  test(
    'output commands and snapshots preserve stable device identity',
    () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      api.value = _snapshot(sessionRevision: 2)
        ..['outputSettings'] = {
          'supported': true,
          'deviceUid': 'uid-a',
          'exclusive': true,
          'exclusiveActive': false,
          'resamplingEnabled': true,
          'targetSampleRate': 96000,
          'activeDeviceUid': null,
          'busy': false,
          'errorCode': 'outputExclusiveUnavailable',
          'refreshPending': true,
          'devices': [
            {
              'uid': 'uid-a',
              'name': '同名设备',
              'isDefault': true,
              'exclusiveSupported': true,
            },
            {
              'uid': 'uid-b',
              'name': '同名设备',
              'isDefault': false,
              'exclusiveSupported': false,
            },
          ],
        };
      await controller.execute(
        const SetOutputConfiguration(
          commandId: 'output-1',
          deviceUid: 'uid-a',
          exclusive: true,
          resamplingEnabled: true,
          targetSampleRate: 96000,
        ),
      );
      expect(api.commands.last['kind'], 'setOutputConfiguration');
      expect(api.commands.last['payload'], {
        'deviceUid': 'uid-a',
        'exclusive': true,
        'resamplingEnabled': true,
        'targetSampleRate': 96000,
      });
      final output = (await controller.getSnapshot()).outputSettings;
      expect(output.deviceUid, 'uid-a');
      expect(output.devices.map((d) => d.uid), ['uid-a', 'uid-b']);
      expect(output.exclusive, isTrue);
      expect(output.resamplingEnabled, isTrue);
      expect(output.targetSampleRate, 96000);
      expect(output.exclusiveActive, isFalse);
      expect(output.refreshPending, isTrue);
      expect(output.errorCode, 'outputExclusiveUnavailable');
      await controller.execute(
        const RefreshOutputDevices(commandId: 'refresh-1'),
      );
      expect(api.commands.last['kind'], 'refreshOutputDevices');
      await controller.close();
    },
  );

  test(
    'output preferences persist successful configurations and device fallback',
    () async {
      final api = _FakeApi();
      final writes =
          <({String? uid, bool exclusive, bool enabled, int rate})>[];
      final controller = NativeMediaController(
        api: api,
        readOutputPreferences: () async => null,
        writeOutputPreferences:
            (
              uid,
              exclusive, {
              bool resamplingEnabled = false,
              int targetSampleRate = 48000,
            }) async {
              writes.add((
                uid: uid,
                exclusive: exclusive,
                enabled: resamplingEnabled,
                rate: targetSampleRate,
              ));
            },
      );
      controller.startHostControl();
      await controller.loadOutputPreferences();
      Map<String, Object?> output(
        int revision, {
        required String? uid,
        bool exclusive = true,
        bool busy = false,
        bool enabled = false,
        int rate = 48000,
        String? error,
      }) => _snapshot(sessionRevision: revision)
        ..['outputSettings'] = {
          'supported': true,
          'deviceUid': uid,
          'exclusive': exclusive,
          'busy': busy,
          'resamplingEnabled': enabled,
          'targetSampleRate': rate,
          'errorCode': error,
          'devices': [],
        };
      api.push(output(2, uid: 'a', busy: true));
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
      api.push(output(3, uid: 'a'));
      await Future<void>.delayed(Duration.zero);
      api.push(output(4, uid: 'b', error: 'outputExclusiveUnavailable'));
      await Future<void>.delayed(Duration.zero);
      expect(writes, [
        (uid: 'a', exclusive: true, enabled: false, rate: 48000),
      ]);
      api.push(output(5, uid: 'b'));
      await Future<void>.delayed(Duration.zero);
      api.push(
        output(
          6,
          uid: null,
          exclusive: false,
          error: 'outputDeviceUnavailable',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      api.push(
        output(7, uid: null, exclusive: false, enabled: true, rate: 96000),
      );
      await Future<void>.delayed(Duration.zero);
      api.push(
        output(8, uid: null, exclusive: false, enabled: true, rate: 192000),
      );
      await Future<void>.delayed(Duration.zero);
      // Identical snapshots do not save twice.
      api.push(
        output(9, uid: null, exclusive: false, enabled: true, rate: 192000),
      );
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      expect(writes, [
        (uid: 'a', exclusive: true, enabled: false, rate: 48000),
        (uid: 'b', exclusive: true, enabled: false, rate: 48000),
        (uid: null, exclusive: false, enabled: false, rate: 48000),
        (uid: null, exclusive: false, enabled: true, rate: 96000),
        (uid: null, exclusive: false, enabled: true, rate: 192000),
      ]);
    },
  );

  test(
    'output preferences restore resampling together with exclusive intent',
    () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        readOutputPreferences: () async => (
          deviceUid: 'dac',
          exclusive: true,
          resamplingEnabled: true,
          targetSampleRate: 88200,
        ),
      );
      await controller.loadOutputPreferences();
      expect(api.commands.last['payload'], {
        'deviceUid': 'dac',
        'exclusive': true,
        'resamplingEnabled': true,
        'targetSampleRate': 88200,
      });
      await controller.close();
    },
  );

  test(
    'sample-rate logs reach the console callback without UI attachment',
    () async {
      final api = _FakeApi();
      final lines = <String>[];
      final controller = NativeMediaController(
        api: api,
        onSampleRateLog: lines.add,
      );
      final event = <String, Object?>{
        'schemaVersion': 1,
        'kind': 'outputSampleRates',
        'event': 'devicesRefreshed',
        'systemRateHz': 48000,
        'sourceRateHz': 44100,
        'pcmRateHz': 96000,
        'targetRateHz': 96000,
        'resamplingEnabled': true,
        'exclusive': false,
        'untrustedExtra': 'secret-url-and-path',
      };
      api.pushEvent(event);
      api.pushEvent(event);
      expect(lines, hasLength(2));
      expect(
        lines.first,
        'Fideflow audio event=devicesRefreshed system_rate_hz=48000 '
        'source_rate_hz=44100 pcm_rate_hz=96000 target_rate_hz=96000 '
        'resampling_enabled=true exclusive=false',
      );
      expect(lines.join(), isNot(contains('secret-url-and-path')));
      for (final bad in [
        {...event, 'event': 'secret-url-and-path'},
        {...event, 'sourceRateHz': 'secret-url-and-path'},
        {...event, 'pcmRateHz': -1},
        {...event, 'resamplingEnabled': 'true'},
        {...event, 'schemaVersion': 2},
      ]) {
        api.pushEvent(bad);
      }
      expect(lines, hasLength(2));
      api.pushEvent({
        ...event,
        'systemRateHz': null,
        'sourceRateHz': null,
        'pcmRateHz': null,
      });
      expect(
        lines.last,
        contains(
          'system_rate_hz=unknown source_rate_hz=unknown pcm_rate_hz=unknown',
        ),
      );
      await controller.close();
      api.pushEvent(event);
      expect(lines, hasLength(3));
    },
  );

  test(
    'console callback failures do not escape the native event handler',
    () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        onSampleRateLog: (_) => throw StateError('console unavailable'),
      );
      api.pushEvent({
        'schemaVersion': 1,
        'kind': 'outputSampleRates',
        'event': 'outputReady',
        'systemRateHz': 48000,
        'sourceRateHz': 44100,
        'pcmRateHz': 48000,
        'targetRateHz': 96000,
        'resamplingEnabled': false,
        'exclusive': false,
      });
      expect(controller.diagnostics.events.last.code, 'audio.logSinkFailed');
      await controller.close();
    },
  );

  group('envelopes', () {
    test('heart start, refill and exit use guarded atomic envelopes', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      final connection = await controller.attach();
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      api.value =
          _snapshot(
              sessionRevision: 2,
              queueRevision: 1,
              generation: 1,
              phase: 'ready',
              currentQueueItemId: 'qi-1',
              playWhenReady: true,
            )
            ..['mode'] = 'sequential'
            ..['intelligenceSessionId'] = 'heart-test';
      await controller.execute(
        const LoadQueue(
          commandId: 'heart-load',
          tracks: [track],
          intelligenceSessionId: 'heart-test',
          autoplay: true,
        ),
      );
      final start = api.commands.first;
      expect(start['kind'], 'intelligence');
      final payload = start['payload'] as Map;
      expect(payload['operation'], 'start');
      expect(payload['sessionId'], 'heart-test');
      expect(payload.containsKey('startItemId'), isFalse);
      expect((await controller.getSnapshot()).isIntelligenceMode, isTrue);
      await controller.execute(
        const RefillIntelligence(
          commandId: 'heart-refill',
          sessionId: 'heart-test',
          tracks: [secondTrack],
          evictCount: 0,
          advance: true,
          autoplay: false,
          expectedQueueRevision: 1,
          expectedSessionRevision: 2,
        ),
      );
      final refill = api.commands.last['payload'] as Map;
      expect(refill['operation'], 'refill');
      expect(refill['advance'], isTrue);
      expect(refill['autoplay'], isFalse);
      expect(refill['expectedSessionRevision'], '2');
      await controller.execute(
        const ExitIntelligence(
          commandId: 'heart-exit',
          sessionId: 'heart-test',
          expectedQueueRevision: 1,
        ),
      );
      expect((api.commands.last['payload'] as Map)['operation'], 'exit');
      await controller.detach(connection.id);
      await controller.close();
    });

    test(
      'heart JIT source failures are reported with current identity and generation',
      () async {
        final api = _FakeApi();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _FailingResolver(),
        );
        await controller.attach();
        api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
        api.value =
            _snapshot(
                sessionRevision: 2,
                queueRevision: 1,
                generation: 1,
                phase: 'resolving',
                currentQueueItemId: 'qi-1',
                playWhenReady: true,
              )
              ..['mode'] = 'sequential'
              ..['intelligenceSessionId'] = 'heart-test';
        final result = await controller.execute(
          const LoadQueue(
            commandId: 'heart-jit',
            tracks: [track],
            intelligenceSessionId: 'heart-test',
            autoplay: true,
          ),
        );
        expect(result.isAccepted, isTrue);
        api.commands.clear();
        api.pushEvent({
          'schemaVersion': 1,
          'kind': 'sourceRequest',
          'sessionId': 'session-1',
          'sessionRevision': '2',
          'generation': '1',
          'queueItemId': 'qi-1',
          'trackId': 'track',
          'requestId': 'heart-jit-1',
        });
        await pumpEventQueue();
        final failure = api.commands.singleWhere(
          (c) => c['kind'] == 'sourceFailed',
        );
        expect(failure['targetQueueItemId'], 'qi-1');
        expect(failure['expectedGeneration'], '1');
        expect(failure['payload'], {'errorCode': 'ncm.upstreamError'});
        await controller.close();
      },
    );

    test('refuses a command until a connection is attached', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);

      final result = await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );

      expect(result.isAccepted, isFalse);
      expect(result.errorCode, 'media.notAttached');
      expect(api.commands, isEmpty);
      expect(controller.diagnostics.events.single.code, 'media.notAttached');
    });

    test('sends a local source per item and the revision it was written '
        'against', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      final connection = await controller.attach();

      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        playWhenReady: true,
        durationMs: 185000,
      );
      final result = await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track, secondTrack],
          autoplay: true,
        ),
      );

      expect(result.isAccepted, isTrue);
      expect(result.sessionRevision, 2);
      final envelope = api.commands.first;
      expect(envelope['schemaVersion'], 1);
      expect(envelope['kind'], 'loadQueue');
      expect(envelope['clientId'], 'flutter-main');
      expect(envelope['commandId'], startsWith('flutter-'));
      expect(envelope['targetSessionId'], connection.baseline.sessionId);
      expect(envelope['expectedQueueRevision'], '0');
      expect(envelope['payload'], {
        'items': [
          {
            'queueItemId': 'qi-1',
            'trackId': 'track',
            'sourceUri': 'file:///tmp/starlight.mp3',
          },
          {'queueItemId': 'qi-2', 'trackId': 'second-track'},
        ],
        'startItemId': 'qi-1',
        'autoplay': true,
      });

      // The second track is prefetched and provided in the background.
      await pumpEventQueue();
      expect(api.commands.length, 2);
      final prefetchEnvelope = api.commands[1];
      expect(prefetchEnvelope['kind'], 'provideSource');
      expect(prefetchEnvelope['targetQueueItemId'], 'qi-2');
      expect(prefetchEnvelope['payload'], {
        'sourceUri': 'file:///tmp/afterglow.mp3',
      });

      // The projection comes from the session's own snapshot, not from the load.
      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue, [track, secondTrack]);
      expect(snapshot.currentTrack, track);
      expect(snapshot.queueRevision, 1);
      expect(snapshot.duration, const Duration(milliseconds: 185000));
      expect(snapshot.status, PlaybackStatus.ready);
    });

    test(
      'addresses the current item and generation for seek and skip',
      () async {
        final api = _FakeApi();
        final controller = controllerFor(api);
        await controller.attach();
        // What the session will answer with once the queue is loaded: the load's
        // own refresh is what binds the projection to queueRevision 1.
        api.value = _snapshot(
          sessionRevision: 3,
          queueRevision: 1,
          generation: 4,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
          positionMs: 12000,
        );
        await controller.execute(
          const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
        );

        api.reply = const {'status': 'accepted', 'sessionRevision': '4'};
        await controller.execute(
          const Seek(commandId: 'seek', position: Duration(seconds: 30)),
        );
        final seek = api.commands.last;
        expect(seek['kind'], 'seek');
        expect(seek['targetQueueItemId'], 'qi-1');
        expect(seek['expectedGeneration'], '4');
        expect(seek['payload'], {'positionMs': '30000'});

        await controller.execute(
          const SkipNext(commandId: 'next', expectedQueueRevision: 1),
        );
        final skip = api.commands.last;
        expect(skip['kind'], 'skipNext');
        expect(skip['expectedQueueRevision'], '1');
        expect(skip['targetQueueItemId'], 'qi-1');
        expect(skip['expectedGeneration'], '4');
        expect(skip['payload'], isEmpty);

        await controller.execute(
          const SkipPrevious(commandId: 'previous', expectedQueueRevision: 1),
        );
        expect(api.commands.last['kind'], 'skipPrevious');
      },
    );

    test('does not send a command the session would refuse outright', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();

      final emptyQueue = await controller.execute(
        const LoadQueue(commandId: 'load', tracks: []),
      );
      expect(emptyQueue.errorCode, 'queue.invalid');

      final skipped = await controller.execute(
        const SkipNext(commandId: 'next'),
      );
      expect(skipped.errorCode, 'playback.queueEmpty');
      expect(api.commands, isEmpty);
    });
  });

  group('results and events', () {
    test('passes a rejection through and adopts the session revision it '
        'reports', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.reply = const {
        'status': 'rejected',
        'errorCode': 'staleQueueRevision',
        'currentQueueRevision': '7',
      };

      final result = await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );

      expect(result.isAccepted, isFalse);
      expect(result.errorCode, 'staleQueueRevision');
      expect(controller.diagnostics.events.single.code, 'staleQueueRevision');

      // The next attempt is written against the revision the session reported.
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      await controller.execute(
        const LoadQueue(commandId: 'load-again', tracks: [track]),
      );
      expect(api.commands.last['expectedQueueRevision'], '7');
    });

    test('a refused load leaves the labels describing the live queue', () async {
      // This is the failure mode the commit-on-accept rule exists to prevent: a
      // queue the session never took must not become the UI's labels.
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        playWhenReady: true,
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      expect((await controller.getSnapshot()).queue, [track, secondTrack]);

      // The session refuses the next load, so its queue is still the first one.
      api.reply = const {
        'status': 'rejected',
        'errorCode': 'staleQueueRevision',
        'currentQueueRevision': '1',
      };
      final refused = await controller.execute(
        const LoadQueue(commandId: 'load-again', tracks: [secondTrack]),
      );

      expect(refused.errorCode, 'staleQueueRevision');
      // A newer snapshot of the *same* queue: it maps ids through the labels the
      // controller holds, which must still be the accepted queue's.
      api.push(
        _snapshot(
          sessionRevision: 3,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-2',
          positionMs: 5000,
          playWhenReady: true,
        ),
      );
      await pumpEventQueue();
      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue, [track, secondTrack]);
      expect(snapshot.currentTrack, secondTrack);
      expect(snapshot.position, const Duration(seconds: 5));

      // The refused load must not have rebound the projection either: a queue
      // change this controller did not make still drops the labels.
      api.push(
        _snapshot(
          sessionRevision: 4,
          queueRevision: 4,
          generation: 9,
          currentQueueItemId: 'qi-9',
        ),
      );
      await pumpEventQueue();
      expect(
        controller.diagnostics.events.map((event) => event.code),
        contains('queue.resyncRequired'),
      );
      expect((await controller.getSnapshot()).queue, isEmpty);
    });

    test('a second accepted load binds its own revision, not a resync', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        playWhenReady: true,
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );

      // Replacing the queue while one is already bound: the new revision is this
      // load's own, so the labels must survive it.
      api.value = _snapshot(
        sessionRevision: 3,
        queueRevision: 2,
        generation: 2,
        phase: 'loading',
        currentQueueItemId: 'qi-3',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load-again', tracks: [secondTrack]),
      );

      final snapshot = await controller.getSnapshot();
      expect(snapshot.queueRevision, 2);
      expect(snapshot.queue, [secondTrack]);
      expect(snapshot.currentTrack, secondTrack);
      expect(
        controller.diagnostics.events.map((event) => event.code),
        isNot(contains('queue.resyncRequired')),
      );

      // The binding is still live, so a change we did not make is still caught.
      api.push(
        _snapshot(
          sessionRevision: 4,
          queueRevision: 5,
          generation: 3,
          currentQueueItemId: 'qi-3',
        ),
      );
      await pumpEventQueue();
      expect(
        controller.diagnostics.events.map((event) => event.code),
        contains('queue.resyncRequired'),
      );
      expect((await controller.getSnapshot()).queue, isEmpty);
    });

    test(
      'reads a snapshot before any connection without inventing one',
      () async {
        final api = _FakeApi();
        final controller = controllerFor(api);

        final snapshot = await controller.getSnapshot();

        expect(snapshot.sessionId, 'session-1');
        expect(snapshot.queue, isEmpty);
        expect(snapshot.currentIndex, isNull);
        expect(api.commands, isEmpty);
      },
    );

    test('delivers pushed snapshots in order and only once', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      final connection = await controller.attach();
      final received = <PlaybackSnapshot>[];
      connection.snapshots.listen(received.add);
      await pumpEventQueue();

      api.push(_snapshot(sessionRevision: 2, phase: 'loading'));
      api.push(
        _snapshot(sessionRevision: 3, phase: 'ready', playWhenReady: true),
      );
      // Older than the last one: a delayed event must not move the UI back.
      api.push(_snapshot(sessionRevision: 2, phase: 'loading'));
      await pumpEventQueue();

      expect(received.map((s) => s.sessionRevision), [2, 3]);
      expect(received.last.status, PlaybackStatus.ready);

      // Loaded with no play intent is paused; ready means prepared *and* asked to
      // play, which is why the two flags are separate in the snapshot.
      api.push(_snapshot(sessionRevision: 4, phase: 'ready'));
      await pumpEventQueue();
      expect(received.last.status, PlaybackStatus.paused);
    });

    test('an old push cannot change the target of the next command', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        currentQueueItemId: 'qi-1',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );

      api.push(
        _snapshot(
          sessionRevision: 4,
          queueRevision: 1,
          generation: 4,
          currentQueueItemId: 'qi-2',
        ),
      );
      api.push(
        _snapshot(
          sessionRevision: 3,
          queueRevision: 9,
          generation: 9,
          currentQueueItemId: 'qi-1',
        ),
      );
      await controller.execute(
        const Seek(commandId: 'seek', position: Duration(seconds: 5)),
      );

      final seek = api.commands.last;
      expect(seek['targetQueueItemId'], 'qi-2');
      expect(seek['expectedGeneration'], '4');
      await controller.execute(const SkipNext(commandId: 'next'));
      expect(api.commands.last['expectedQueueRevision'], '1');
      expect(
        controller.diagnostics.events.map((event) => event.code),
        isNot(contains('queue.resyncRequired')),
      );
    });

    test('drops its labels when the queue changes behind it', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      final connection = await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        currentQueueItemId: 'qi-1',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );
      expect((await controller.getSnapshot()).currentTrack, track);

      // Another client replaced the queue: `qi-1` means something else now.
      api.push(
        _snapshot(
          sessionRevision: 5,
          queueRevision: 3,
          generation: 9,
          currentQueueItemId: 'qi-1',
        ),
      );
      await pumpEventQueue();

      // The attach baseline predates the queue; only the projection is labelled.
      expect(connection.baseline.queue, isEmpty);
      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue, isEmpty);
      expect(snapshot.currentIndex, isNull);
      expect(
        controller.diagnostics.events.map((event) => event.code),
        contains('queue.resyncRequired'),
      );
    });

    test(
      'detaching closes the stream and keeps the native sink installed',
      () async {
        final api = _FakeApi();
        final controller = controllerFor(api);
        final connection = await controller.attach();
        var closed = false;
        connection.snapshots.listen((_) {}, onDone: () => closed = true);

        await controller.detach(connection.id);

        expect(closed, isTrue);
        expect(api.detached, [connection.id]);
        // The sink is the host's, registered for the controller's lifetime: a
        // page leaving removes a subscriber, not playback's ability to resolve
        // (architecture §5.1). Only `close` releases it.
        expect(api.sinkRegistrations, [true]);
      },
    );

    test('closing releases the handle and answers no further calls', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();

      await controller.close();

      expect(api.closed, isTrue);
      expect(api.sinkRegistrations.last, isFalse);
      await expectLater(
        controller.getSnapshot(),
        throwsA(
          isA<MediaCoreException>().having(
            (error) => error.diagnosticCode,
            'diagnosticCode',
            'media.nullHandle',
          ),
        ),
      );
    });
  });

  group('modes and the queue order', () {
    /// A loaded, playing queue whose labels the controller holds.
    Future<(NativeMediaController, _FakeApi)> loaded(
      Map<String, Object?> Function() next,
    ) async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        effectiveOrder: const ['qi-1', 'qi-2'],
        playWhenReady: true,
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      await pumpEventQueue();
      expect((await controller.getSnapshot()).queue, [track, secondTrack]);
      api.value = next();
      return (controller, api);
    }

    test('a mode change keeps the labels and adopts the new order', () async {
      final (controller, api) = await loaded(
        () => _snapshot(
          sessionRevision: 3,
          queueRevision: 2,
          generation: 1,
          phase: 'ready',
          mode: 'shuffle',
          currentQueueItemId: 'qi-2',
          effectiveOrder: const ['qi-2', 'qi-1'],
          playWhenReady: true,
        ),
      );
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};

      final result = await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.shuffle,
          seed: 7,
          expectedQueueRevision: 1,
        ),
      );

      expect(result.isAccepted, isTrue);
      final envelope = api.commands.last;
      expect(envelope['kind'], 'setMode');
      expect(envelope['expectedQueueRevision'], '1');
      expect(envelope['payload'], {'mode': 'shuffle', 'seed': '7'});

      final snapshot = await controller.getSnapshot();
      expect(snapshot.mode, PlaybackMode.shuffle);
      expect(snapshot.queue, [
        secondTrack,
        track,
      ], reason: 'the UI renders the session order, not the load order');
      expect(snapshot.currentTrack, secondTrack);
      expect(snapshot.currentIndex, 0);
      expect(
        controller.diagnostics.events.map((event) => event.code),
        isNot(contains('queue.resyncRequired')),
        reason: 'a mode change this controller made is not a foreign queue',
      );
    });

    test('names the mode with its schema code, never an enum index', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.reply = const {
        'status': 'rejected',
        'errorCode': 'staleQueueRevision',
        'currentQueueRevision': '4',
      };
      final sent = api.commands.length;

      final result = await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.repeatOne,
          expectedQueueRevision: 4,
        ),
      );

      // The revision check belongs to the session, so the command goes out and the
      // refusal comes back with the revision to write against next time.
      expect(result.isAccepted, isFalse);
      expect(result.errorCode, 'staleQueueRevision');
      expect(api.commands.length, sent + 1);
      expect(api.commands.last['expectedQueueRevision'], '4');
      expect(api.commands.last['payload'], {'mode': 'repeatOne'});
    });

    test('sends a load seed and reads back the order it produced', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      // The session built this order from the seed: qi-2 first, not the row the
      // payload listed first.
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        mode: 'shuffle',
        currentQueueItemId: 'qi-2',
        effectiveOrder: const ['qi-2', 'qi-1'],
        shuffleSeed: 4242,
        playWhenReady: true,
      );
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};

      await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track, secondTrack],
          seed: 4242,
          autoplay: true,
          expectedQueueRevision: 0,
        ),
      );

      final payload = api.commands.first['payload'] as Map<String, Object?>;
      expect(
        payload['seed'],
        '4242',
        reason: 'a seed crosses as a decimal string',
      );
      expect(
        payload['startItemId'],
        'qi-1',
        reason: 'the field stays well-formed even when the seed picks the head',
      );

      final snapshot = await controller.getSnapshot();
      expect(snapshot.shuffleSeed, 4242);
      expect(snapshot.queue, [
        secondTrack,
        track,
      ], reason: 'the UI renders the session order the seed produced');
      expect(snapshot.currentTrack, secondTrack);
    });

    test('omits a seed the caller did not pin', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();

      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );

      final payload = api.commands.first['payload'] as Map<String, Object?>;
      expect(
        payload.containsKey('seed'),
        isFalse,
        reason:
            'the wire rule is a decimal string, so a null would be malformed',
      );
      expect(payload['autoplay'], isFalse);
      expect((await controller.getSnapshot()).shuffleSeed, isNull);
    });

    test('a jump names the item at that row of the published order', () async {
      final (controller, api) = await loaded(
        () => _snapshot(
          sessionRevision: 3,
          queueRevision: 2,
          generation: 1,
          phase: 'ready',
          mode: 'shuffle',
          currentQueueItemId: 'qi-2',
          effectiveOrder: const ['qi-2', 'qi-1'],
          playWhenReady: true,
        ),
      );
      await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.shuffle,
          seed: 7,
          expectedQueueRevision: 1,
        ),
      );

      await controller.execute(
        const PlayItem(commandId: 'jump', index: 1, expectedQueueRevision: 2),
      );
      final jump = api.commands.last;
      expect(jump['kind'], 'playItem');
      expect(jump['targetQueueItemId'], 'qi-1');
      expect(jump['expectedQueueRevision'], '2');
      expect(jump.containsKey('expectedGeneration'), isFalse);
      expect(jump['payload'], isEmpty);

      final sent = api.commands.length;
      final invalid = await controller.execute(
        const PlayItem(commandId: 'bad', index: 9, expectedQueueRevision: 2),
      );
      expect(invalid.errorCode, 'queue.invalid');
      expect(
        api.commands.length,
        sent,
        reason: 'a page bug is not the session’s',
      );
    });

    test('a queue that changed behind the controller still resyncs', () async {
      final (controller, api) = await loaded(
        () => _snapshot(
          sessionRevision: 3,
          queueRevision: 2,
          generation: 1,
          phase: 'ready',
          mode: 'shuffle',
          currentQueueItemId: 'qi-2',
          effectiveOrder: const ['qi-2', 'qi-1'],
          playWhenReady: true,
        ),
      );
      await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.shuffle,
          seed: 7,
          expectedQueueRevision: 1,
        ),
      );

      api.push(
        _snapshot(
          sessionRevision: 4,
          queueRevision: 9,
          generation: 9,
          currentQueueItemId: 'qi-9',
        ),
      );
      await pumpEventQueue();

      expect(
        controller.diagnostics.events.map((event) => event.code),
        contains('queue.resyncRequired'),
      );
      expect((await controller.getSnapshot()).queue, isEmpty);
    });

    test(
      'projects optional seek state with an older-library default',
      () async {
        final api = _FakeApi();
        final controller = controllerFor(api);
        await controller.attach();
        expect((await controller.getSnapshot()).isSeeking, isFalse);
        api.push(
          _snapshot(sessionRevision: 2, phase: 'resolving')
            ..['isSeeking'] = true,
        );
        await pumpEventQueue();
        expect((await controller.getSnapshot()).isSeeking, isTrue);
        api.push(_snapshot(sessionRevision: 3, phase: 'ready'));
        await pumpEventQueue();
        expect((await controller.getSnapshot()).isSeeking, isFalse);
      },
    );

    test('projects the phase so a page tells preparing from ready', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();

      api.push(
        _snapshot(
          sessionRevision: 2,
          phase: 'loading',
          playWhenReady: true,
          currentQueueItemId: 'qi-1',
        ),
      );
      await pumpEventQueue();
      final loading = await controller.getSnapshot();
      expect(loading.phase, WirePhase.loading);
      expect(loading.isPreparing, isTrue);
      expect(loading.status, PlaybackStatus.ready);

      api.push(
        _snapshot(
          sessionRevision: 3,
          phase: 'ready',
          buffering: true,
          playWhenReady: true,
          currentQueueItemId: 'qi-1',
        ),
      );
      await pumpEventQueue();
      final buffering = await controller.getSnapshot();
      expect(buffering.phase, WirePhase.ready);
      expect(buffering.buffering, isTrue);
      expect(buffering.status, PlaybackStatus.buffering);
      expect(buffering.isPreparing, isFalse);
    });
  });

  group('resolved sources', () {
    test(
      'resolves each item once, with the quality the load asked for',
      () async {
        final api = _FakeApi();
        final resolver = _CountingResolver();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: resolver,
        );
        await controller.attach();
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
        );

        final result = await controller.execute(
          const LoadQueue(
            commandId: 'load',
            tracks: [track, secondTrack],
            quality: AudioQuality.lossless,
          ),
        );

        expect(result.isAccepted, isTrue);
        // Start item is resolved immediately upfront; second item is prefetched in background.
        await pumpEventQueue();
        expect(
          [for (final call in resolver.calls) call.$1.value],
          ['track', 'second-track'],
          reason: 'one resolve per item, in queue order',
        );
        expect(
          [for (final call in resolver.calls) call.$2],
          [AudioQuality.lossless, AudioQuality.lossless],
          reason: 'the caller’s preference reaches the resolver',
        );
      },
    );

    test('keeps the source of a queue the session accepted', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
      );

      final result = await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );

      expect(result.isAccepted, isTrue);
      final source = controller.resolvedSourceFor(const TrackId('track'));
      expect(source, isNotNull);
      expect(source!.uri.path, '/tmp/starlight.mp3');
      expect(source.actualQuality, AudioQuality.standard);

      // Background prefetch resolves the second item.
      await pumpEventQueue();
      expect(
        controller.resolvedSourceFor(const TrackId('second-track'))!.uri.path,
        '/tmp/afterglow.mp3',
      );
      // A track that is not in the queue the controller labels has no source.
      expect(controller.resolvedSourceFor(const TrackId('elsewhere')), isNull);
    });

    test('a refused load leaves no source behind', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.reply = const {
        'status': 'rejected',
        'errorCode': 'queue.invalid',
        'currentQueueRevision': '0',
      };

      final result = await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );

      expect(result.isAccepted, isFalse);
      expect(
        controller.resolvedSourceFor(const TrackId('track')),
        isNull,
        reason: 'a queue the session never installed is not labeled',
      );
    });

    test(
      'a resolver failure is a rejected command, not an exception',
      () async {
        final api = _FakeApi();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _FailingResolver(),
        );
        await controller.attach();

        final result = await controller.execute(
          const LoadQueue(commandId: 'load', tracks: [track]),
        );

        expect(result.isAccepted, isFalse);
        expect(result.errorCode, 'ncm.upstreamError');
        expect(
          controller.diagnostics.events.map((event) => event.code),
          contains('ncm.upstreamError'),
        );
        expect(api.commands, isEmpty, reason: 'nothing reached the session');
      },
    );
  });

  group('on-demand JIT source resolution (M2 / docs/design/provider.md)', () {
    test(
      'loads 100-track queue with only start item resolved upfront',
      () async {
        final api = _FakeApi();
        final resolver = _CountingResolver();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: resolver,
        );
        await controller.attach();
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
        );

        final tracks = List.generate(
          100,
          (i) => Track(
            id: TrackId('track-$i'),
            title: 'Track $i',
            artists: const [artist],
            album: album,
            duration: const Duration(minutes: 3),
          ),
        );

        final result = await controller.execute(
          LoadQueue(commandId: 'load-100', tracks: tracks, startIndex: 0),
        );

        expect(result.isAccepted, isTrue);
        final envelope = api.commands.first;
        expect(envelope['kind'], 'loadQueue');
        final payload = envelope['payload'] as Map<String, Object?>;
        final items = payload['items'] as List;
        expect(items.length, 100);
        final firstItem = items[0] as Map;
        expect(firstItem['sourceUri'], isNotNull);
        expect(firstItem['trackId'], 'track-0');
        // Tracks 1 through 99 have NO sourceUri upfront in the loadQueue payload
        for (var i = 1; i < 100; i++) {
          final item = items[i] as Map;
          expect(item['sourceUri'], isNull);
          expect(item['trackId'], 'track-$i');
        }

        // Upfront resolution only resolved track-0
        expect(resolver.calls.first.$1.value, 'track-0');
      },
    );

    test('fulfills sourceRequest event with provideSource command', () async {
      final api = _FakeApi();
      final resolver = _CountingResolver();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
      );

      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      await pumpEventQueue();
      api.commands.clear();

      // Session encounters an unresolved item (e.g. user jumped to a distant track)
      api.pushEvent({
        'schemaVersion': 1,
        'kind': 'sourceRequest',
        'sessionId': 'session-1',
        'sessionRevision': '2',
        'generation': '1',
        'queueItemId': 'qi-2',
        'trackId': 'second-track',
        'requestId': 'sr-1-qi-2',
      });
      await pumpEventQueue();

      final provideCommand = api.commands.lastWhere(
        (cmd) => cmd['kind'] == 'provideSource',
      );
      expect(provideCommand['targetQueueItemId'], 'qi-2');
      expect(provideCommand['expectedGeneration'], '1');
      final providePayload = provideCommand['payload'] as Map<String, Object?>;
      expect(providePayload['sourceUri'], 'file:///tmp/afterglow.mp3');
      expect(providePayload['requestId'], 'sr-1-qi-2');
    });
  });

  group('host ownership', () {
    test('answers a source request with no page attached', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      final connection = await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      await pumpEventQueue();

      // The last page goes away; the session carries on and still needs a source
      // for the item it just reached.
      await controller.detach(connection.id);
      api.commands.clear();
      api.pushEvent({
        'schemaVersion': 1,
        'kind': 'sourceRequest',
        'sessionId': 'session-1',
        'sessionRevision': '2',
        'generation': '1',
        'queueItemId': 'qi-2',
        'trackId': 'second-track',
        'requestId': 'sr-1-qi-2',
        'reason': 'missing',
      });
      await pumpEventQueue();

      final provide = api.commands.lastWhere(
        (command) => command['kind'] == 'provideSource',
      );
      expect(provide['targetQueueItemId'], 'qi-2');
      // The host's own client id, so a page can never collide with it.
      expect(provide['clientId'], 'flutter-main:host');
      expect(
        ((provide['payload'] as Map)['sourceUri'] as String),
        'file:///tmp/afterglow.mp3',
      );

      // A *page* command is a different matter: with no shell to render it, it is
      // still refused.
      final pageCommand = await controller.execute(
        const Play(commandId: 'play-from-nowhere'),
      );
      expect(pageCommand.isAccepted, isFalse);
      expect(pageCommand.errorCode, 'media.notAttached');
    });

    test('startHostControl seeds the session before any page attaches', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);

      controller.startHostControl();

      // No attachment happened, yet the session facts are known: a revocation at
      // sign-out can address the session before the first frame.
      final result = await controller.executeHostCommand(
        const ClearQueue(commandId: 'revoke-early'),
      );
      expect(result.isAccepted, isTrue);
      expect(api.commands.single['kind'], 'clearQueue');
      expect(api.commands.single['clientId'], 'flutter-main:host');
      expect(api.sinkRegistrations, [true]);
    });

    test('sends stop and clearQueue without a payload or a queue', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.commands.clear();

      final stopped = await controller.execute(const Stop(commandId: 'stop-1'));
      final cleared = await controller.execute(
        const ClearQueue(commandId: 'clear-1'),
      );

      expect(stopped.isAccepted, isTrue);
      expect(cleared.isAccepted, isTrue);
      expect(api.commands.map((command) => command['kind']), [
        'stop',
        'clearQueue',
      ]);
      expect(api.commands.first['payload'], isEmpty);
      // A page's stop carries the page's client id: only the host's own commands
      // are filed under the host's.
      expect(api.commands.first['clientId'], 'flutter-main');
    });

    test('close releases the sink and the handle', () async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();

      await controller.close();

      expect(api.closed, isTrue);
      expect(api.sinkRegistrations, [true, false]);
    });
  });

  group('account revocation', () {
    test('drops the queue and a resolution that was already in flight', () async {
      final api = _FakeApi();
      final resolver = _HeldResolver();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      await pumpEventQueue();
      // The next item is being resolved for the account that is about to leave.
      expect(resolver.pending, isNotEmpty);
      final inFlight = resolver.pending.first;
      api.commands.clear();

      await controller.onAccountRevoked(2);

      final clear = api.commands.firstWhere(
        (command) => command['kind'] == 'clearQueue',
      );
      expect(
        clear['clientId'],
        'flutter-main:host',
        reason: 'a revocation is the host acting, not a page',
      );

      // The answer arrives after the revocation: it belongs to credentials the
      // session no longer holds, so it must never reach it (docs/design/accounts.md).
      inFlight.complete(
        ResolvedMediaSource(
          trackId: const TrackId('second-track'),
          uri: Uri.parse('https://cdn.test/account-a.mp3'),
          actualQuality: AudioQuality.standard,
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );
      await pumpEventQueue();

      expect(
        api.commands.where((command) => command['kind'] == 'provideSource'),
        isEmpty,
        reason: 'the old account\'s URL must not be handed to the session',
      );
    });
  });

  group('source expiry', () {
    test('carries the expiry of the source it resolved upfront', () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: _HttpResolver(),
      );
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );

      final items = ((api.commands.first['payload'] as Map)['items'] as List);
      final item = items.first as Map<String, Object?>;
      expect(item['sourceUri'], startsWith('https://cdn.test/'));
      expect(
        item['expiresAtMs'],
        '${_httpExpiry.millisecondsSinceEpoch}',
        reason: 'a provider URL carries the instant it lapses',
      );
    });

    test('re-resolves and replaces a source the session revoked', () async {
      final api = _FakeApi();
      final resolver = _HttpResolver();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      await pumpEventQueue();
      final prefetched = resolver.calls;
      api.commands.clear();

      // The session dropped the URL it held because its lifetime had run out.
      api.pushEvent({
        'schemaVersion': 1,
        'kind': 'sourceRequest',
        'sessionId': 'session-1',
        'sessionRevision': '2',
        'generation': '1',
        'queueItemId': 'qi-2',
        'trackId': 'second-track',
        'requestId': 'sr-1-qi-2',
        'reason': 'expired',
      });
      await pumpEventQueue();

      final provide = api.commands.lastWhere(
        (command) => command['kind'] == 'provideSource',
      );
      final payload = provide['payload'] as Map<String, Object?>;
      expect(payload['requestId'], 'sr-1-qi-2');
      expect(payload['expiresAtMs'], isNotNull);
      expect(
        resolver.calls,
        greaterThan(prefetched),
        reason: 'a lapsed source is resolved again, not read from the cache',
      );
      expect(
        payload['sourceUri'],
        endsWith('?n=${resolver.calls}'),
        reason: 'the URL handed over is the fresh resolution',
      );
    });
  });

  group('queue edits', () {
    const thirdTrack = Track(
      id: TrackId('third-track'),
      title: 'Meridian',
      artists: [artist],
      album: album,
      duration: Duration(minutes: 5),
    );

    /// A loaded, playing queue whose labels the controller holds, ready for the
    /// snapshot the next edit will produce.
    Future<(NativeMediaController, _FakeApi)> loaded(
      Map<String, Object?> Function() next,
    ) async {
      final api = _FakeApi();
      final controller = controllerFor(api);
      await controller.attach();
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        effectiveOrder: const ['qi-1', 'qi-2'],
        playWhenReady: true,
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track, secondTrack]),
      );
      await pumpEventQueue();
      api.commands.clear();
      api.value = next();
      return (controller, api);
    }

    test(
      'playNext inserts after the current item and merges its label',
      () async {
        final (controller, api) = await loaded(
          () => _snapshot(
            sessionRevision: 3,
            queueRevision: 2,
            generation: 1,
            phase: 'ready',
            currentQueueItemId: 'qi-1',
            effectiveOrder: const ['qi-1', 'qi-3', 'qi-2'],
            playWhenReady: true,
          ),
        );
        api.reply = const {'status': 'accepted', 'sessionRevision': '3'};

        final result = await controller.execute(
          const PlayNext(
            commandId: 'next',
            tracks: [thirdTrack],
            expectedQueueRevision: 1,
          ),
        );

        expect(result.isAccepted, isTrue);
        final envelope = api.commands.first;
        expect(envelope['kind'], 'editQueue');
        expect(envelope['expectedQueueRevision'], '1');
        expect(envelope['payload'], {
          'operation': 'playNext',
          'items': [
            {'queueItemId': 'qi-3', 'trackId': 'third-track'},
          ],
        });

        final snapshot = await controller.getSnapshot();
        expect(snapshot.queue, [track, thirdTrack, secondTrack]);
        expect(snapshot.currentTrack, track);
        expect(
          controller.diagnostics.events.map((event) => event.code),
          isNot(contains('queue.resyncRequired')),
          reason: 'an edit this controller made is not a foreign queue',
        );
      },
    );

    test('addToQueue appends at the end', () async {
      final (controller, api) = await loaded(
        () => _snapshot(
          sessionRevision: 3,
          queueRevision: 2,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
          effectiveOrder: const ['qi-1', 'qi-2', 'qi-3'],
          playWhenReady: true,
        ),
      );
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};

      await controller.execute(
        const AddToQueue(
          commandId: 'append',
          tracks: [thirdTrack],
          expectedQueueRevision: 1,
        ),
      );

      final envelope = api.commands.first;
      expect(envelope['kind'], 'editQueue');
      expect(envelope['payload'], {
        'operation': 'append',
        'items': [
          {'queueItemId': 'qi-3', 'trackId': 'third-track'},
        ],
      });
      expect((await controller.getSnapshot()).queue, [
        track,
        secondTrack,
        thirdTrack,
      ]);
    });

    test(
      'removeFromQueue names the entry at that row and drops its label',
      () async {
        final (controller, api) = await loaded(
          () => _snapshot(
            sessionRevision: 3,
            queueRevision: 2,
            generation: 1,
            phase: 'ready',
            currentQueueItemId: 'qi-1',
            effectiveOrder: const ['qi-1'],
            playWhenReady: true,
          ),
        );
        api.reply = const {'status': 'accepted', 'sessionRevision': '3'};

        final result = await controller.execute(
          const RemoveFromQueue(
            commandId: 'remove',
            index: 1,
            expectedQueueRevision: 1,
          ),
        );

        expect(result.isAccepted, isTrue);
        final envelope = api.commands.first;
        expect(envelope['kind'], 'editQueue');
        expect(envelope['targetQueueItemId'], 'qi-2');
        expect(envelope['payload'], {'operation': 'remove'});

        final snapshot = await controller.getSnapshot();
        expect(snapshot.queue, [track]);
        expect(
          controller.diagnostics.events.map((event) => event.code),
          isNot(contains('queue.resyncRequired')),
        );

        final sent = api.commands.length;
        final invalid = await controller.execute(
          const RemoveFromQueue(
            commandId: 'bad',
            index: 9,
            expectedQueueRevision: 2,
          ),
        );
        expect(invalid.errorCode, 'queue.invalid');
        expect(
          api.commands.length,
          sent,
          reason: 'a page bug is not the session’s',
        );
      },
    );
  });

  group('session-side restore record', () {
    test('hands the directory and account to the session', () {
      final api = _FakeApi();
      final controller = controllerFor(api);

      controller.configureCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'ncm-user-1',
      );

      expect(
        api.checkpointDirectory,
        '/tmp/ff-playback',
        reason: 'the session, not this controller, writes the record',
      );
      expect(api.checkpointAccount, 'ncm-user-1');
    });

    test(
      'reports a closed session rather than silently dropping the call',
      () async {
        final api = _FakeApi();
        final controller = controllerFor(api);
        await controller.close();

        expect(
          () => controller.configureCheckpoint(directory: '/tmp', account: 'a'),
          throwsA(
            isA<MediaCoreException>().having(
              (error) => error.diagnosticCode,
              'diagnosticCode',
              'media.nullHandle',
            ),
          ),
        );
      },
    );

    test('labels the queue the session restored', () async {
      final api = _FakeApi();
      final lookedUp = <String>[];
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async {
          lookedUp.add(id.value);
          return _labelled(id);
        },
      );
      // A queue this controller never loaded: the session rebuilt it from its own
      // record, so the wire carries identities and no titles.
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        mode: 'shuffle',
        effectiveOrder: const ['restored-1', 'restored-0'],
        queueItems: const [
          {'queueItemId': 'restored-1', 'trackId': 'track-b'},
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
        ],
        currentQueueItemId: 'restored-1',
        shuffleSeed: 42,
      );

      final restored = await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );

      expect(restored, isTrue);
      expect(api.restoredDirectory, '/tmp/ff-playback');
      expect(api.restoredAccount, 'guest');
      // The structure is published before any label exists (design §6), so the
      // labels land behind the caller and are awaited here.
      await pumpEventQueue();
      expect(lookedUp, unorderedEquals(['track-a', 'track-b']));
      final snapshot = await controller.getSnapshot();
      expect(
        snapshot.queue.map((track) => track.id.value),
        ['track-b', 'track-a'],
        reason: 'the queue renders in the session order, not the record order',
      );
      expect(snapshot.currentIndex, 0);
      expect(snapshot.currentTrack?.id, const TrackId('track-b'));
      expect(snapshot.mode, PlaybackMode.shuffle);
      expect(snapshot.shuffleSeed, 42);
      expect(snapshot.playWhenReady, isFalse, reason: 'a restore waits');
    });

    test('keeps the rest of a restored queue when a track is gone', () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async {
          if (id.value == 'gone') {
            throw const AppError(
              category: AppErrorCategory.provider,
              code: 'provider.notFound',
              retryable: false,
            );
          }
          return _labelled(id);
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-1', 'restored-0'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'gone'},
          {'queueItemId': 'restored-1', 'trackId': 'track-b'},
        ],
        currentQueueItemId: 'restored-1',
      );

      final restored = await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );

      expect(restored, isTrue);
      await pumpEventQueue();
      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue.map((track) => track.id.value), [
        'track-b',
        'gone',
      ], reason: 'one missing track keeps its row as a placeholder');
      expect(snapshot.queue.last.title, NativeMediaController.placeholderTitle);
      expect(snapshot.queue.last.id, const TrackId('gone'));
      expect(snapshot.currentTrack?.id, const TrackId('track-b'));
    });

    test('a restored queue never hands out an id it already holds', () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async => _labelled(id),
      );
      // These ids came from the process that wrote the record, so this one starts
      // its own counter at zero and would otherwise mint `qi-1` again (issue 2).
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'ready',
        effectiveOrder: const ['qi-1', 'qi-2'],
        queueItems: const [
          {'queueItemId': 'qi-1', 'trackId': 'track-a'},
          {'queueItemId': 'qi-2', 'trackId': 'track-b'},
        ],
        currentQueueItemId: 'qi-1',
      );
      expect(
        await controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        ),
        isTrue,
      );

      api.commands.clear();
      await controller.executeHostCommand(
        const PlayNext(
          commandId: 'next',
          tracks: [track],
          expectedQueueRevision: 1,
        ),
      );

      final items = ((api.commands.single['payload'] as Map)['items'] as List);
      final minted = [for (final item in items) (item as Map)['queueItemId']];
      expect(minted, [
        'qi-3',
      ], reason: 'the allocator resumes past the restored ids, not from zero');
    });

    test('a permanently missing track is not looked up again', () async {
      final api = _FakeApi();
      var attempts = 0;
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async {
          attempts++;
          throw const AppError(
            category: AppErrorCategory.provider,
            code: 'provider.notFound',
            retryable: false,
          );
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['qi-1'],
        queueItems: const [
          {'queueItemId': 'qi-1', 'trackId': 'gone'},
        ],
        currentQueueItemId: 'qi-1',
      );

      await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      expect(attempts, 1);
      // Past the first retry backoff: a condition a retry cannot clear must not
      // be polled again (issue 6).
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(attempts, 1, reason: 'a track the library lacks is not retried');
      // The entry keeps its row, as a placeholder carrying its stable id, so a
      // track the library no longer has cannot cost the queue its structure
      // (design §6).
      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue, hasLength(1));
      expect(snapshot.queue.single.id, const TrackId('gone'));
      expect(
        snapshot.queue.single.title,
        NativeMediaController.placeholderTitle,
      );
    });

    test('publishes the restored structure before the labels arrive', () async {
      final api = _FakeApi();
      final gate = Completer<void>();
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async {
          await gate.future;
          return _labelled(id);
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-0', 'restored-1'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
          {'queueItemId': 'restored-1', 'trackId': 'track-b'},
        ],
        currentQueueItemId: 'restored-1',
      );

      final restored = await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );

      // Every lookup is still blocked, and yet the queue, its current entry and
      // the saved progress are already published: the first frame does not wait
      // on the catalog (design §6).
      expect(restored, isTrue);
      final early = await controller.getSnapshot();
      expect(early.queue.map((track) => track.id.value), [
        'track-a',
        'track-b',
      ]);
      expect(early.queue.first.title, NativeMediaController.placeholderTitle);
      expect(early.queue.first.id, const TrackId('track-a'));
      expect(early.currentIndex, 1);
      expect(early.currentTrack?.id, const TrackId('track-b'));

      gate.complete();
      await pumpEventQueue();
      final labelled = await controller.getSnapshot();
      expect(
        labelled.queue.map((track) => track.title),
        isNot(contains(NativeMediaController.placeholderTitle)),
        reason: 'the labels land behind the caller',
      );
    });

    test('labels a restored queue with one batch lookup', () async {
      final api = _FakeApi();
      final singles = <String>[];
      final batches = <List<String>>[];
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async {
          singles.add(id.value);
          return _labelled(id);
        },
        trackLookupMany: (ids) async {
          batches.add([for (final id in ids) id.value]);
          return {for (final id in ids) id: _labelled(id)};
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-0', 'restored-1', 'restored-2'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
          {'queueItemId': 'restored-1', 'trackId': 'track-b'},
          {'queueItemId': 'restored-2', 'trackId': 'track-b'},
        ],
        currentQueueItemId: 'restored-1',
      );

      await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      await pumpEventQueue();

      // The current entry is resolved on its own for the first frame; the rest
      // go out as one call, with a repeated track asked for once (design §6, §7).
      expect(singles, ['track-b']);
      expect(batches, hasLength(1));
      expect(batches.single, hasLength(2));
      expect(batches.single.toSet(), {'track-a', 'track-b'});

      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue.map((track) => track.id.value), [
        'track-a',
        'track-b',
        'track-b',
      ]);
      expect(snapshot.queue[1].id, snapshot.queue[2].id);
    });

    test('an id a batch did not answer stays pending rather than gone', () async {
      final api = _FakeApi();
      var batchCalls = 0;
      final controller = NativeMediaController(
        api: api,
        trackLookupMany: (ids) async {
          batchCalls++;
          if (batchCalls == 1) {
            // The service answered nothing about the ids it was asked for. That
            // is not proof they are gone (design §9).
            return const {};
          }
          return {for (final id in ids) id: _labelled(id)};
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-0', 'restored-1'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
          {'queueItemId': 'restored-1', 'trackId': 'track-b'},
        ],
        currentQueueItemId: 'restored-0',
      );

      await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      await pumpEventQueue();

      expect(batchCalls, 1, reason: 'the batch is what labels the queue');
      final early = await controller.getSnapshot();
      expect(early.queue.map((track) => track.id.value), [
        'track-a',
        'track-b',
      ]);
      expect(
        early.queue.every(
          (track) => track.title == NativeMediaController.placeholderTitle,
        ),
        isTrue,
        reason: 'an unanswered id keeps its placeholder, not its neighbours',
      );

      // Past the first retry backoff: the unanswered id is asked again instead
      // of being remembered as gone.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(batchCalls, greaterThan(1));
      final retried = await controller.getSnapshot();
      expect(
        retried.queue.map((track) => track.title),
        isNot(contains(NativeMediaController.placeholderTitle)),
      );
    });

    test(
      'an attach during a restore sees the restored queue, not an empty one',
      () async {
        final api = _FakeApi();
        final gate = Completer<void>();
        final controller = NativeMediaController(
          api: api,
          trackLookup: (id) async {
            // The lookup the restore is waiting on: an attach that raced it must
            // not install the projection built before it answers (issue 1).
            await gate.future;
            return _labelled(id);
          },
        );
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          phase: 'resolving',
          effectiveOrder: const ['restored-0'],
          queueItems: const [
            {'queueItemId': 'restored-0', 'trackId': 'track-a'},
          ],
          currentQueueItemId: 'restored-0',
        );

        final restoring = controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        );
        await pumpEventQueue();
        // A page mounts while the restore's lookup is still in flight.
        final attachment = controller.attach();
        gate.complete();
        final connection = await attachment;
        expect(await restoring, isTrue);

        expect(
          connection.baseline.queue.map((track) => track.id.value),
          ['track-a'],
          reason:
              'the baseline is the restored queue, not the empty one a '
              'read that raced the record would have installed',
        );
        expect(connection.baseline.currentTrack?.id, const TrackId('track-a'));
        expect((await controller.getSnapshot()).currentTrack, isNotNull);
      },
    );

    test(
      'a page that mounts mid-restore is handed the labels when they land',
      () async {
        final api = _FakeApi();
        final gate = Completer<void>();
        final controller = NativeMediaController(
          api: api,
          trackLookup: (id) async {
            await gate.future;
            return _labelled(id);
          },
        );
        // The session holds nothing until the record is read *inside*
        // `restoreCheckpoint`, which is what the session really does — and what
        // makes a baseline read that beats the restore see an empty queue.
        api.value = _snapshot(sessionRevision: 1);
        api.duringRestore = () {
          api.value = _snapshot(
            sessionRevision: 2,
            queueRevision: 1,
            phase: 'paused',
            effectiveOrder: const ['restored-0', 'restored-1'],
            queueItems: const [
              {'queueItemId': 'restored-0', 'trackId': 'track-a'},
              {'queueItemId': 'restored-1', 'trackId': 'track-b'},
            ],
            currentQueueItemId: 'restored-0',
          );
        };

        final restoring = controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        );
        // A page mounts while the labels are still on their way.
        final connection = await controller.attach();
        final seen = <PlaybackSnapshot>[];
        final subscription = connection.snapshots.listen(seen.add);
        expect(await restoring, isTrue);

        // The structure is on screen at once — the session's rows with their
        // stable identities and the entry it is holding — rather than an empty
        // queue waiting for a catalog (design §6).
        expect(connection.baseline.queue.map((track) => track.id.value), [
          'track-a',
          'track-b',
        ]);
        expect(connection.baseline.currentTrack?.id, const TrackId('track-a'));
        expect(
          connection.baseline.queue.map((track) => track.title),
          everyElement(NativeMediaController.placeholderTitle),
          reason: 'the labels are deliberately not awaited by the restore',
        );

        gate.complete();
        await pumpEventQueue();

        // A label completion publishes no new session revision, so a page that
        // mounted before it only sees the finished queue if the projection is
        // the thing that decides whether a snapshot is new (issue 1).
        expect(
          seen,
          isNotEmpty,
          reason: 'the attached page is refreshed when the labels land',
        );
        expect(seen.last.queue.map((track) => track.title), [
          'Restored track-a',
          'Restored track-b',
        ], reason: 'the placeholders are replaced, not left on screen');
        expect(
          seen.last.sessionRevision,
          connection.baseline.sessionRevision,
          reason: 'the refresh carries no new session revision of its own',
        );
        expect(
          (await controller.getSnapshot()).queue.map((track) => track.title),
          ['Restored track-a', 'Restored track-b'],
          reason: 'and a pull agrees with what the page was pushed',
        );
        await subscription.cancel();
      },
    );

    test(
      'a missing row before the current one keeps the visible index aligned',
      () async {
        final api = _FakeApi();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _FakeResolver(),
          trackLookup: (id) async {
            if (id.value == 'gone') {
              throw const AppError(
                category: AppErrorCategory.provider,
                code: 'provider.notFound',
                retryable: false,
              );
            }
            return _labelled(id);
          },
        );
        // The missing entry sits *before* the current one, which is the case the
        // old full-queue addressing got wrong (issue 3).
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          phase: 'ready',
          generation: 1,
          effectiveOrder: const ['restored-0', 'restored-1'],
          queueItems: const [
            {'queueItemId': 'restored-0', 'trackId': 'gone'},
            {'queueItemId': 'restored-1', 'trackId': 'track-b'},
          ],
          currentQueueItemId: 'restored-1',
        );
        await controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        );
        await controller.attach();
        final snapshot = await controller.getSnapshot();

        // The unlabelled entry keeps its row, so the visible order *is* the
        // session's order and an index always names the entry it appears to
        // (design §6, issue 3).
        expect(snapshot.queue.map((track) => track.id.value), [
          'gone',
          'track-b',
        ]);
        expect(snapshot.currentIndex, 1);
        expect(snapshot.currentTrack?.id, const TrackId('track-b'));

        // Row 0 is restored-0 — the placeholder — never restored-1.
        api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
        await controller.execute(
          const RemoveFromQueue(commandId: 'rm0', index: 0),
        );
        expect(api.commands.last['targetQueueItemId'], 'restored-0');

        await controller.execute(
          const RemoveFromQueue(commandId: 'rm1', index: 1),
        );
        expect(api.commands.last['targetQueueItemId'], 'restored-1');
      },
    );

    test('a restored queue is paused rather than preparing', () async {
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        trackLookup: (id) async => _labelled(id),
      );
      // A restore asks for no source, so the session reports the entry as
      // selected-and-holding rather than as a resolution in flight
      // (docs/design/restore.md §7).
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'paused',
        effectiveOrder: const ['restored-0'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
        ],
        currentQueueItemId: 'restored-0',
      );

      await controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      final snapshot = await controller.getSnapshot();

      expect(snapshot.phase, WirePhase.paused);
      expect(snapshot.status, PlaybackStatus.paused);
      expect(snapshot.playWhenReady, isFalse);
      expect(snapshot.currentTrack?.id, const TrackId('track-a'));
    });

    test('a queue loaded during a restore is not overwritten by it', () async {
      final api = _FakeApi();
      final gate = Completer<void>();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: _FakeResolver(),
        trackLookup: (id) async {
          // The lookup the restore is waiting on; a load that lands while it is
          // in flight must win, not be overwritten by the restore (issue 7).
          await gate.future;
          return _labelled(id);
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-0'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
        ],
        currentQueueItemId: 'restored-0',
      );
      // The page is already attached when the restore begins.
      await controller.attach();

      final restoring = controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      await pumpEventQueue();

      // While the restore waits on its label, the page starts a new queue.
      api.value = _snapshot(
        sessionRevision: 3,
        queueRevision: 2,
        generation: 1,
        phase: 'ready',
        effectiveOrder: const ['qi-1'],
        currentQueueItemId: 'qi-1',
        playWhenReady: true,
      );
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [secondTrack]),
      );

      gate.complete();
      await restoring;

      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue, [
        secondTrack,
      ], reason: 'the restore must not install its order over the new load');
      expect(snapshot.currentTrack, secondTrack);
      expect(
        controller.diagnostics.events.map((event) => event.code),
        isNot(contains('queue.resyncRequired')),
      );
    });

    test(
      'a restore publishes the newest state, not the one it read first',
      () async {
        final api = _FakeApi();
        final gate = Completer<void>();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _FakeResolver(),
          trackLookup: (id) async {
            await gate.future;
            return _labelled(id);
          },
        );
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          phase: 'ready',
          effectiveOrder: const ['restored-0', 'restored-1'],
          queueItems: const [
            {'queueItemId': 'restored-0', 'trackId': 'track-a'},
            {'queueItemId': 'restored-1', 'trackId': 'track-b'},
          ],
          currentQueueItemId: 'restored-0',
        );

        final restoring = controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        );
        await pumpEventQueue();

        // The session moves on while the labels are still being fetched: shuffle
        // entered, the order reversed, the revision advanced. The restore must
        // publish *this* state, not the one it read before the lookups (issue 8).
        api.push(
          _snapshot(
            sessionRevision: 3,
            queueRevision: 1,
            phase: 'ready',
            mode: 'shuffle',
            effectiveOrder: const ['restored-1', 'restored-0'],
            queueItems: const [
              {'queueItemId': 'restored-0', 'trackId': 'track-a'},
              {'queueItemId': 'restored-1', 'trackId': 'track-b'},
            ],
            currentQueueItemId: 'restored-1',
          ),
        );
        await pumpEventQueue();

        gate.complete();
        expect(await restoring, isTrue);

        final snapshot = await controller.getSnapshot();
        expect(snapshot.mode, PlaybackMode.shuffle);
        expect(snapshot.sessionRevision, 3);
        expect(snapshot.queue.map((track) => track.id.value), [
          'track-b',
          'track-a',
        ], reason: 'the projection uses the newest effectiveOrder');
        expect(snapshot.currentTrack?.id, const TrackId('track-b'));

        final connection = await controller.attach();
        expect(connection.baseline.mode, PlaybackMode.shuffle);
        expect(connection.baseline.sessionRevision, 3);
      },
    );

    test('a clearQueue during a restore keeps the queue empty', () async {
      final api = _FakeApi();
      final gate = Completer<void>();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: _FakeResolver(),
        trackLookup: (id) async {
          await gate.future;
          return _labelled(id);
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-0'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
        ],
        currentQueueItemId: 'restored-0',
      );
      final connection = await controller.attach();
      final seen = <PlaybackSnapshot>[];
      final subscription = connection.snapshots.listen(seen.add);

      final restoring = controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      await pumpEventQueue();

      // The page clears the queue while the restore still waits on its label.
      api.value = _snapshot(sessionRevision: 3, queueRevision: 2);
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      await controller.execute(const ClearQueue(commandId: 'clear'));

      gate.complete();
      await restoring;
      await pumpEventQueue();

      expect(
        (await controller.getSnapshot()).queue,
        isEmpty,
        reason: 'the restore must not resurrect a queue the page cleared',
      );

      // The suppression window the restore installed is gone: a push the session
      // makes now reaches the subscriber (issue 7).
      api.push(_snapshot(sessionRevision: 4, queueRevision: 2));
      await pumpEventQueue();
      expect(seen.last.sessionRevision, 4);
      await subscription.cancel();
    });

    test(
      'a close during a restore still finishes it and releases the session',
      () async {
        final api = _FakeApi();
        final gate = Completer<void>();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _FakeResolver(),
          trackLookup: (id) async {
            await gate.future;
            return _labelled(id);
          },
        );
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          phase: 'resolving',
          effectiveOrder: const ['restored-0'],
          queueItems: const [
            {'queueItemId': 'restored-0', 'trackId': 'track-a'},
          ],
          currentQueueItemId: 'restored-0',
        );
        await controller.attach();

        final restoring = controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        );
        await pumpEventQueue();

        // The session is released while the labelling is still in flight.
        await controller.close();
        gate.complete();

        // The structure was already published before the close, so the restore
        // reports what it did; the labelling in flight is abandoned rather than
        // committing into a released controller (design §6).
        expect(await restoring, isTrue);
        expect(api.closed, isTrue);
        expect(api.sinkRegistrations.last, isFalse);
        await expectLater(
          controller.getSnapshot(),
          throwsA(
            isA<MediaCoreException>().having(
              (error) => error.diagnosticCode,
              'diagnosticCode',
              'media.nullHandle',
            ),
          ),
        );
      },
    );

    test('an account revocation during a restore leaves no queue', () async {
      final api = _FakeApi();
      final gate = Completer<void>();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: _FakeResolver(),
        trackLookup: (id) async {
          await gate.future;
          return _labelled(id);
        },
      );
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        phase: 'resolving',
        effectiveOrder: const ['restored-0'],
        queueItems: const [
          {'queueItemId': 'restored-0', 'trackId': 'track-a'},
        ],
        currentQueueItemId: 'restored-0',
      );
      final connection = await controller.attach();
      final seen = <PlaybackSnapshot>[];
      final subscription = connection.snapshots.listen(seen.add);

      final restoring = controller.restoreCheckpoint(
        directory: '/tmp/ff-playback',
        account: 'guest',
      );
      await pumpEventQueue();

      // The account is revoked while the restore still waits on its label.
      api.value = _snapshot(sessionRevision: 3, queueRevision: 2);
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      await controller.onAccountRevoked(1);

      gate.complete();
      await restoring;
      await pumpEventQueue();

      expect(
        api.flushes,
        greaterThan(0),
        reason: 'the outgoing record is saved',
      );
      expect(api.checkpointDirectory, isEmpty);
      expect(
        (await controller.getSnapshot()).queue,
        isEmpty,
        reason: 'a revoked account must not have its queue restored back',
      );

      // The suppression window is released even on this path.
      api.push(_snapshot(sessionRevision: 4, queueRevision: 2));
      await pumpEventQueue();
      expect(seen.last.sessionRevision, 4);
      await subscription.cancel();
    });

    test(
      'holds a source request until the restored queue is labelled',
      () async {
        final api = _FakeApi();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _FakeResolver(),
          trackLookup: (id) async => _labelled(id),
        );
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          phase: 'resolving',
          effectiveOrder: const ['restored-0'],
          queueItems: const [
            {'queueItemId': 'restored-0', 'trackId': 'track-a'},
          ],
          currentQueueItemId: 'restored-0',
        );
        // The session asks for the source of the item it just restored while the
        // restore is still turning identities into labels.
        api.duringRestore = () => api.pushEvent({
          'kind': 'sourceRequest',
          'sessionId': 'session-1',
          'sessionRevision': '2',
          'generation': '1',
          'queueItemId': 'restored-0',
          'trackId': 'track-a',
          'reason': 'missing',
        });

        final restored = await controller.restoreCheckpoint(
          directory: '/tmp/ff-playback',
          account: 'guest',
        );
        await pumpEventQueue();

        expect(restored, isTrue);
        expect(
          (await controller.getSnapshot()).queue.map((track) => track.id.value),
          ['track-a'],
          reason: 'answering the request must not publish an unlabelled queue',
        );
        final provided = api.commands
            .where((command) => command['kind'] == 'provideSource')
            .toList();
        expect(provided, hasLength(1));
        expect(provided.single['targetQueueItemId'], 'restored-0');
      },
    );
  });

  group('quality', () {
    /// Loads [track] and leaves the session on `qi-1` at `positionMs`, resolving
    /// at [level].
    Future<(NativeMediaController, _FakeApi, _QualityResolver)> playing(
      AudioQuality level, {
      int positionMs = 42000,
      int generation = 1,
    }) async {
      final api = _FakeApi();
      final resolver = _QualityResolver();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      await controller.attach();
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: generation,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        positionMs: positionMs,
        playWhenReady: true,
        isActuallyPlaying: true,
        queueItems: const [
          {'queueItemId': 'qi-1', 'trackId': 'track'},
        ],
      );
      await controller.execute(
        LoadQueue(commandId: 'load', tracks: const [track], quality: level),
      );
      return (controller, api, resolver);
    }

    /// The snapshot document a session answers a reopen with.
    Map<String, Object?> resolvingAt(int sessionRevision, int generation) =>
        _snapshot(
          sessionRevision: sessionRevision,
          queueRevision: 1,
          generation: generation,
          phase: 'resolving',
          currentQueueItemId: 'qi-1',
          positionMs: 42000,
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
          ],
        );

    test('swaps the source and reopens the entry where it was', () async {
      final (controller, api, _) = await playing(AudioQuality.standard);

      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      api.value = resolvingAt(3, 2);
      final outcome = await controller.setQuality(
        preference: AudioQuality.lossless,
      );

      expect(outcome.preferenceApplied, isTrue);
      expect(outcome.currentSwitchStarted, isTrue);
      expect(outcome.hasError, isFalse);
      // Provide then seek: the provide alone only stores the URI on an entry
      // that is already playing, so the seek is what opens it.
      expect(api.commands.map((command) => command['kind']), [
        'loadQueue',
        'provideSource',
        'seek',
      ]);
      final provide = api.commands[1];
      expect(provide['targetQueueItemId'], 'qi-1');
      expect(
        (provide['payload'] as Map)['sourceUri'],
        contains('q=lossless'),
        reason: 'the switch resolves at the level it was asked for',
      );
      final seek = api.commands[2];
      expect(seek['targetQueueItemId'], 'qi-1');
      expect(seek['payload'], {'positionMs': '42000'});
    });

    test('switching the preference of a local file keeps playing', () async {
      // The acceptance bar for the four-tier change: local playback, changing
      // songs and the settings page all keep working. A `file:` source has no
      // streaming tier, so the switch reopens the same file and the level stays
      // unnamed instead of being reported as whatever the user asked for.
      final api = _FakeApi();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: _LocalFileResolver(),
      );
      await controller.attach();
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        positionMs: 42000,
        playWhenReady: true,
        isActuallyPlaying: true,
        queueItems: const [
          {'queueItemId': 'qi-1', 'trackId': 'track'},
        ],
      );
      await controller.execute(
        LoadQueue(
          commandId: 'load',
          tracks: const [track],
          quality: AudioQuality.high,
        ),
      );
      expect(
        controller.resolvedSourceFor(const TrackId('track'))?.actualQuality,
        isNull,
        reason: 'a local file has no online tier to name',
      );

      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      api.value = resolvingAt(3, 2);
      final outcome = await controller.setQuality(
        preference: AudioQuality.hiRes,
      );

      expect(outcome.preferenceApplied, isTrue);
      expect(outcome.hasError, isFalse);
      final snapshot = await controller.getSnapshot();
      expect(snapshot.quality?.confirmed, isTrue);
      expect(
        snapshot.quality?.level,
        isNull,
        reason: 'nothing here may claim the level the preference asked for',
      );
    });

    test(
      'does not claim the new level until the entry is ready again',
      () async {
        final (controller, api, _) = await playing(AudioQuality.standard);
        expect((await controller.getSnapshot()).quality?.confirmed, isTrue);

        api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
        api.value = resolvingAt(3, 2);
        await controller.setQuality(preference: AudioQuality.lossless);

        // Reopening is not playing: until the session primes the new source, the
        // words stay the ones for the audio that is (or was) really there.
        final pending = await controller.getSnapshot();
        expect(pending.quality?.level, AudioQuality.standard);
        expect(pending.quality?.confirmed, isTrue);
        expect(pending.quality?.switching, isTrue);

        api.push(
          _snapshot(
            sessionRevision: 4,
            queueRevision: 1,
            generation: 2,
            phase: 'ready',
            currentQueueItemId: 'qi-1',
            positionMs: 43000,
            playWhenReady: true,
            isActuallyPlaying: true,
            queueItems: const [
              {'queueItemId': 'qi-1', 'trackId': 'track'},
            ],
          ),
        );
        await pumpEventQueue();

        final settled = await controller.getSnapshot();
        expect(settled.quality?.level, AudioQuality.lossless);
        expect(settled.quality?.confirmed, isTrue);
        expect(settled.quality?.switching, isFalse);
        expect(settled.quality?.bitrateKbps, 1411);
        expect(settled.quality?.sampleRateHz, 44100);
        expect(settled.quality?.codec, 'flac');
      },
    );

    test('a phase on the way to ready never fails the switch', () async {
      final (controller, api, _) = await playing(AudioQuality.standard);
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      api.value = resolvingAt(3, 2);
      await controller.setQuality(preference: AudioQuality.lossless);

      // Loading is the middle of a switch, not the end of it: treating it as
      // failure would make every switch report one.
      api.push(
        _snapshot(
          sessionRevision: 4,
          queueRevision: 1,
          generation: 2,
          phase: 'loading',
          currentQueueItemId: 'qi-1',
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
          ],
        ),
      );
      await pumpEventQueue();
      final loading = await controller.getSnapshot();
      expect(loading.quality?.switching, isTrue);
      expect(loading.quality?.confirmed, isTrue);
      expect(loading.quality?.level, AudioQuality.standard);
    });

    test('a refused reopen is reported as partial, not as a change', () async {
      final (controller, api, _) = await playing(AudioQuality.standard);
      // The provide is accepted; the reopen is refused (a delayed command, or a
      // session that moved on between the two).
      api.replyQueue = [
        const {'status': 'accepted', 'sessionRevision': '3'},
        const {'status': 'rejected', 'errorCode': 'staleGeneration'},
      ];
      api.value = resolvingAt(3, 2);

      final outcome = await controller.setQuality(
        preference: AudioQuality.lossless,
      );

      expect(outcome.currentSwitchStarted, isFalse);
      expect(outcome.errorCode, 'playback.qualitySwitchPartial');
      expect(
        controller.diagnostics.events.map((event) => event.code),
        contains('playback.qualitySwitchPartial'),
      );
      // The session holds the new URI, so it is what `provided` means; the audio
      // in effect is still the old source, and nothing pretends otherwise.
      final snapshot = await controller.getSnapshot();
      expect(
        controller.resolvedSourceFor(const TrackId('track'))?.actualQuality,
        AudioQuality.lossless,
      );
      expect(snapshot.quality?.level, AudioQuality.standard);
      expect(snapshot.quality?.confirmed, isTrue);
      expect(snapshot.quality?.switching, isFalse);
    });

    test(
      'a failing resolution reports its own code and keeps the old source',
      () async {
        final (controller, api, resolver) = await playing(
          AudioQuality.standard,
        );
        resolver.failNext = true;

        final outcome = await controller.setQuality(
          preference: AudioQuality.lossless,
        );

        expect(outcome.preferenceApplied, isTrue);
        expect(outcome.currentSwitchStarted, isFalse);
        expect(outcome.errorCode, 'ncm.upstreamError');
        expect(
          api.commands.map((command) => command['kind']),
          ['loadQueue'],
          reason: 'nothing is handed over for a source that was never resolved',
        );
        final snapshot = await controller.getSnapshot();
        expect(snapshot.quality?.level, AudioQuality.standard);
        expect(snapshot.quality?.switching, isFalse);
      },
    );

    Future<void> pauseCurrent(
      NativeMediaController controller,
      _FakeApi api,
    ) async {
      api.value = _snapshot(
        sessionRevision: 3,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        positionMs: 42000,
        playWhenReady: false,
        queueItems: const [
          {'queueItemId': 'qi-1', 'trackId': 'track'},
        ],
      );
      await controller.getSnapshot();
    }

    test(
      'paused selections defer resolution and resume at the latest quality',
      () async {
        final (controller, api, resolver) = await playing(
          AudioQuality.standard,
        );
        await pauseCurrent(controller, api);
        final commandsBefore = api.commands.length;
        await controller.setQuality(preference: AudioQuality.lossless);
        await controller.setQuality(preference: AudioQuality.high);
        final snapshot = await controller.getSnapshot();
        expect(snapshot.status, PlaybackStatus.paused);
        expect(snapshot.position, const Duration(seconds: 42));
        expect(snapshot.quality?.level, AudioQuality.standard);
        expect(snapshot.quality?.confirmed, isTrue);
        expect(snapshot.quality?.bitrateKbps, 128);
        expect(snapshot.quality?.sampleRateHz, 44100);
        expect(snapshot.quality?.codec, 'flac');
        expect(snapshot.quality?.switching, isFalse);
        expect(resolver.levels, [AudioQuality.standard]);
        expect(api.commands.length, commandsBefore);

        api.reply = const {'status': 'accepted', 'sessionRevision': '4'};
        final result = await controller.execute(
          const Play(commandId: 'resume'),
        );
        expect(result.isAccepted, isTrue);
        expect(resolver.levels, [AudioQuality.standard, AudioQuality.high]);
        expect(api.commands.skip(commandsBefore).map((c) => c['kind']), [
          'provideSource',
          'seek',
          'play',
        ]);
        expect(
          (api.commands[commandsBefore + 1]['payload'] as Map)['positionMs'],
          '42000',
        );
      },
    );

    test(
      'a failed deferred resolution stays paused and can be retried',
      () async {
        final (controller, api, resolver) = await playing(
          AudioQuality.standard,
        );
        await pauseCurrent(controller, api);
        await controller.setQuality(preference: AudioQuality.lossless);
        resolver.failNext = true;
        final result = await controller.execute(
          const Play(commandId: 'resume'),
        );
        expect(result.isAccepted, isFalse);
        expect(result.errorCode, 'ncm.upstreamError');
        final snapshot = await controller.getSnapshot();
        expect(snapshot.status, PlaybackStatus.paused);
        expect(snapshot.quality?.level, AudioQuality.standard);
        expect(snapshot.quality?.confirmed, isTrue);
        expect(snapshot.quality?.switching, isFalse);
        expect(api.commands.map((c) => c['kind']), ['loadQueue']);
        api.reply = const {'status': 'accepted', 'sessionRevision': '4'};
        expect(
          (await controller.execute(const Play(commandId: 'retry'))).isAccepted,
          isTrue,
        );
        expect(resolver.levels.last, AudioQuality.lossless);
      },
    );

    test(
      'paused local files never acquire the requested streaming tier',
      () async {
        final api = _FakeApi();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: _LocalFileResolver(),
        );
        await controller.attach();
        api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
          ],
        );
        await controller.execute(
          const LoadQueue(commandId: 'load', tracks: [track]),
        );
        await pauseCurrent(controller, api);
        final before = (await controller.getSnapshot()).quality!;
        final commandCount = api.commands.length;
        await controller.setQuality(preference: AudioQuality.hiRes);
        final snapshot = await controller.getSnapshot();
        expect(snapshot.status, PlaybackStatus.paused);
        expect(snapshot.quality?.level, isNull);
        expect(snapshot.quality?.confirmed, before.confirmed);
        expect(snapshot.quality?.codec, before.codec);
        expect(snapshot.quality?.switching, isFalse);
        expect(api.commands.length, commandCount);
      },
    );

    test('clearing a paused queue discards its deferred switch', () async {
      final (controller, api, resolver) = await playing(AudioQuality.standard);
      await pauseCurrent(controller, api);
      await controller.setQuality(preference: AudioQuality.lossless);
      api.reply = const {'status': 'accepted', 'sessionRevision': '4'};
      api.value = _snapshot(
        sessionRevision: 4,
        queueRevision: 2,
        generation: 2,
      );
      await controller.execute(const ClearQueue(commandId: 'clear'));
      await controller.execute(const Play(commandId: 'resume'));
      expect(resolver.levels, [AudioQuality.standard]);
      expect(
        api.commands.map((c) => c['kind']),
        isNot(contains('provideSource')),
      );
      expect((await controller.getSnapshot()).quality, isNull);
    });

    test(
      'a quality change revokes the next cached source before skipping',
      () async {
        final api = _FakeApi();
        final resolver = _QualityResolver();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: resolver,
        );
        await controller.attach();
        api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
            {'queueItemId': 'qi-2', 'trackId': 'second-track'},
          ],
        );
        await controller.execute(
          const LoadQueue(
            commandId: 'load',
            tracks: [track, secondTrack],
            quality: AudioQuality.standard,
          ),
        );
        await pumpEventQueue();
        expect(
          controller.resolvedSourceFor(secondTrack.id)?.actualQuality,
          AudioQuality.standard,
        );
        final before = api.commands.length;
        await controller.setQuality(preference: AudioQuality.lossless);
        await pumpEventQueue();
        final nextCommands = api.commands
            .skip(before)
            .where((c) => c['targetQueueItemId'] == 'qi-2')
            .toList();
        expect(nextCommands, isNotEmpty);
        expect((nextCommands.first['payload'] as Map)['sourceUri'], isNull);
        expect(
          controller.resolvedSourceFor(secondTrack.id)?.actualQuality,
          AudioQuality.lossless,
        );
        final source = nextCommands.last['payload'] as Map;
        expect(source['sourceUri'], contains('q=lossless'));

        api.value = _snapshot(
          sessionRevision: 9,
          queueRevision: 1,
          generation: 2,
          phase: 'ready',
          currentQueueItemId: 'qi-2',
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
            {'queueItemId': 'qi-2', 'trackId': 'second-track'},
          ],
        );
        final next = await controller.getSnapshot();
        expect(next.quality?.level, AudioQuality.lossless);
      },
    );

    test(
      'an old prefetch cannot restore standard after choosing lossless',
      () async {
        final api = _FakeApi();
        final gate = Completer<void>();
        final resolver = _QualityResolver()..secondGate = gate.future;
        final controller = NativeMediaController(
          api: api,
          sourceResolver: resolver,
        );
        await controller.attach();
        api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
            {'queueItemId': 'qi-2', 'trackId': 'second-track'},
          ],
        );
        await controller.execute(
          const LoadQueue(
            commandId: 'load',
            tracks: [track, secondTrack],
            quality: AudioQuality.standard,
          ),
        );
        await pumpEventQueue();
        expect(resolver.levels, [AudioQuality.standard, AudioQuality.standard]);
        resolver.secondGate = null;
        await controller.setQuality(preference: AudioQuality.lossless);
        gate.complete();
        await pumpEventQueue();
        final provided = api.commands.where(
          (c) =>
              c['kind'] == 'provideSource' && c['targetQueueItemId'] == 'qi-2',
        );
        expect(provided, isNotEmpty);
        expect(
          provided.every(
            (c) => (c['payload'] as Map)['sourceUri'].toString().contains(
              'q=lossless',
            ),
          ),
          isTrue,
        );
        expect(
          controller.resolvedSourceFor(secondTrack.id)?.actualQuality,
          AudioQuality.lossless,
        );
      },
    );

    test(
      'a newer selection supersedes switches still revoking sources',
      () async {
        final api = _FakeApi();
        final resolver = _QualityResolver();
        final controller = NativeMediaController(
          api: api,
          sourceResolver: resolver,
        );
        await controller.attach();
        api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
        api.value = _snapshot(
          sessionRevision: 2,
          queueRevision: 1,
          generation: 1,
          phase: 'ready',
          currentQueueItemId: 'qi-1',
          playWhenReady: true,
          queueItems: const [
            {'queueItemId': 'qi-1', 'trackId': 'track'},
            {'queueItemId': 'qi-2', 'trackId': 'second-track'},
          ],
        );
        await controller.execute(
          const LoadQueue(
            commandId: 'load',
            tracks: [track, secondTrack],
            quality: AudioQuality.standard,
          ),
        );
        await pumpEventQueue();
        expect(controller.resolvedSourceFor(secondTrack.id), isNotNull);
        resolver.levels.clear();
        api.commands.clear();

        // Both changed preferences yield during revocation. Reapplying the
        // newest preference skips revocation and reaches the switch queue first.
        final first = controller.setQuality(preference: AudioQuality.lossless);
        final second = controller.setQuality(preference: AudioQuality.high);
        final latest = controller.setQuality(preference: AudioQuality.high);
        final outcomes = await Future.wait([first, second, latest]);
        await pumpEventQueue();

        expect(outcomes.every((outcome) => outcome.preferenceApplied), isTrue);
        expect(outcomes[0].currentSwitchStarted, isFalse);
        expect(outcomes[1].currentSwitchStarted, isFalse);
        expect(outcomes[2].currentSwitchStarted, isTrue);
        expect(resolver.levels, isNot(contains(AudioQuality.lossless)));
        final currentSources = api.commands.where(
          (command) =>
              command['kind'] == 'provideSource' &&
              command['targetQueueItemId'] == 'qi-1',
        );
        expect(currentSources, hasLength(1));
        expect(
          (currentSources.single['payload'] as Map)['sourceUri'],
          contains('q=high'),
        );
        await controller.close();
      },
    );

    test('the preference applies on its own when nothing is playing', () async {
      final api = _FakeApi();
      final resolver = _QualityResolver();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      await controller.attach();

      final outcome = await controller.setQuality(
        preference: AudioQuality.lossless,
      );

      expect(outcome.preferenceApplied, isTrue);
      expect(outcome.currentSwitchStarted, isFalse);
      expect(outcome.hasError, isFalse);
      expect(api.commands, isEmpty);
    });

    test('a current-entry change also updates the preference', () async {
      final (controller, api, resolver) = await playing(AudioQuality.standard);
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      api.value = resolvingAt(3, 2);

      final outcome = await controller.setQuality(
        preference: AudioQuality.lossless,
      );

      expect(outcome.preferenceApplied, isTrue);
      expect(outcome.currentSwitchStarted, isTrue);
      expect(resolver.levels, [
        AudioQuality.standard,
        AudioQuality.lossless,
      ], reason: 'the entry is re-resolved at the requested level');
    });

    test('two switches on one entry never interleave their commands', () async {
      final api = _FakeApi();
      final gate = Completer<void>();
      final resolver = _QualityResolver();
      final controller = NativeMediaController(
        api: api,
        sourceResolver: resolver,
      );
      await controller.attach();
      api.reply = const {'status': 'accepted', 'sessionRevision': '2'};
      api.value = _snapshot(
        sessionRevision: 2,
        queueRevision: 1,
        generation: 1,
        phase: 'ready',
        currentQueueItemId: 'qi-1',
        positionMs: 1000,
        playWhenReady: true,
        queueItems: const [
          {'queueItemId': 'qi-1', 'trackId': 'track'},
        ],
      );
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );
      // Only the switches wait from here: the load's own resolution is done.
      resolver.gate = gate.future;

      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      api.value = resolvingAt(3, 2);
      final first = controller.setQuality(preference: AudioQuality.lossless);
      await pumpEventQueue();
      // Asked while the first is still resolving: the second waits its turn, so
      // the last ask is the one the user ends up hearing.
      final second = controller.setQuality(preference: AudioQuality.standard);
      gate.complete();
      await first;
      await second;

      expect(api.commands.map((command) => command['kind']), [
        'loadQueue',
        'provideSource',
        'seek',
        'provideSource',
        'seek',
      ]);
      final uris = api.commands
          .where((command) => command['kind'] == 'provideSource')
          .map((command) => (command['payload'] as Map)['sourceUri'])
          .toList();
      expect(uris[0], contains('q=lossless'));
      expect(uris[1], contains('q=standard'));
    });

    test(
      'a switch whose entry the session left is dropped, not credited',
      () async {
        final (controller, api, _) = await playing(AudioQuality.standard);
        api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
        api.value = resolvingAt(3, 2);
        await controller.setQuality(preference: AudioQuality.lossless);
        expect((await controller.getSnapshot()).quality?.switching, isTrue);

        // The session is told to stop: nothing is playing, so no swap is on its
        // way, and the old entry's switch is not left hanging over the new state.
        api.push(
          _snapshot(
            sessionRevision: 4,
            queueRevision: 1,
            generation: 3,
            phase: 'idle',
            positionMs: 0,
          ),
        );
        await pumpEventQueue();

        final stopped = await controller.getSnapshot();
        expect(stopped.quality, isNull);
        expect(stopped.currentIndex, isNull);
      },
    );

    test('a new queue starts with no proof about its sources', () async {
      final (controller, api, _) = await playing(AudioQuality.lossless);
      expect(
        (await controller.getSnapshot()).quality?.level,
        AudioQuality.lossless,
      );

      // A second load: the item ids are new, so the previous queue's proof
      // describes entries that do not exist any more.
      api.reply = const {'status': 'accepted', 'sessionRevision': '3'};
      api.value = _snapshot(
        sessionRevision: 3,
        queueRevision: 2,
        generation: 2,
        phase: 'loading',
        currentQueueItemId: 'qi-2',
        playWhenReady: true,
        queueItems: const [
          {'queueItemId': 'qi-2', 'trackId': 'second-track'},
        ],
      );
      await controller.execute(
        const LoadQueue(
          commandId: 'load-2',
          tracks: [secondTrack],
          quality: AudioQuality.standard,
        ),
      );

      final snapshot = await controller.getSnapshot();
      expect(snapshot.currentTrack, secondTrack);
      expect(snapshot.quality?.level, AudioQuality.standard);
      expect(
        snapshot.quality?.confirmed,
        isFalse,
        reason: 'nothing has opened this entry yet, so nothing is proven',
      );
    });
  });
}

/// A track built from an id alone, which is all a restore's identity carries.
Track _labelled(TrackId id) => Track(
  id: id,
  title: 'Restored ${id.value}',
  artists: const [Artist(id: ArtistId('artist'), name: 'Aurora')],
  album: const Album(id: AlbumId('album'), title: 'Night'),
  duration: const Duration(minutes: 2),
);

/// A snapshot document as the native session writes it: counters and identities
/// only, every `uint64` a decimal string.
Map<String, Object?> _snapshot({
  required int sessionRevision,
  int queueRevision = 0,
  int generation = 0,
  String phase = 'idle',
  String? currentQueueItemId,
  int positionMs = 0,
  int? durationMs,
  bool playWhenReady = false,
  bool buffering = false,
  bool isActuallyPlaying = false,
  String? errorCode,
  String mode = 'listLoop',
  List<String>? effectiveOrder,
  List<Map<String, Object?>>? queueItems,
  int? shuffleSeed,
}) {
  final duration = durationMs == null ? null : '$durationMs';
  final seed = shuffleSeed == null ? null : '$shuffleSeed';
  return {
    'schemaVersion': 1,
    'kind': 'snapshot',
    'sessionId': 'session-1',
    'sessionRevision': '$sessionRevision',
    'queueRevision': '$queueRevision',
    'queueItems': queueItems,
    'generation': '$generation',
    'phase': phase,
    'mode': mode,
    'playWhenReady': playWhenReady,
    'buffering': buffering,
    'suppressionReasons': const <String>[],
    'isActuallyPlaying': isActuallyPlaying,
    'currentQueueItemId': currentQueueItemId,
    'effectiveOrder': ?effectiveOrder,
    'positionMs': '$positionMs',
    'durationMs': ?duration,
    'errorCode': ?errorCode,
    'shuffleSeed': seed,
  };
}

/// The expiry `_HttpResolver` names: a provider URL with a known lifetime.
final DateTime _httpExpiry = DateTime.utc(2030);

/// Resolves everything to a provider URL, counting the calls so a test can tell a
/// fresh resolution from a cached one. The URL is different every time, which is
/// what makes that visible on the wire.
final class _HttpResolver implements PlaybackSourceResolver {
  int calls = 0;

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async {
    calls += 1;
    return ResolvedMediaSource(
      trackId: id,
      uri: Uri.parse('https://cdn.test/${id.value}?n=$calls'),
      actualQuality: AudioQuality.standard,
      expiresAt: _httpExpiry,
    );
  }
}

/// A resolver whose answers a test completes itself, so it can make one arrive
/// *after* an account revocation.
final class _HeldResolver implements PlaybackSourceResolver {
  final List<Completer<ResolvedMediaSource>> pending = [];
  int _calls = 0;

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) {
    _calls += 1;
    // The first call is the upfront resolution the load itself waits for; every
    // later one is the host prefetching, and the test decides when it answers.
    if (_calls == 1) {
      return _FakeResolver().resolve(id, preferredQuality, networkPolicy);
    }
    final completer = Completer<ResolvedMediaSource>();
    pending.add(completer);
    return completer.future;
  }
}

/// Resolves every track to a URL that names the level it was asked for, so a
/// test can read which level a command carries, and reports a bitrate and a
/// sample rate per level, so "what the provider said" has something to say.
final class _QualityResolver implements PlaybackSourceResolver {
  Future<void>? secondGate;

  /// When set, every resolution waits for it: a test can hold one switch in
  /// flight while it asks for another.
  Future<void>? gate;

  final List<AudioQuality> levels = [];

  /// Fails the next resolution, the shape a provider failure has here.
  bool failNext = false;

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async {
    levels.add(preferredQuality);
    final hold = id.value == 'second-track' ? secondGate ?? gate : gate;
    if (hold != null) await hold;
    if (failNext) {
      failNext = false;
      throw const AppError(
        category: AppErrorCategory.provider,
        code: 'ncm.upstreamError',
        retryable: true,
      );
    }
    return ResolvedMediaSource(
      trackId: id,
      uri: Uri.parse('https://cdn.test/${id.value}?q=${preferredQuality.name}'),
      actualQuality: preferredQuality,
      expiresAt: _httpExpiry,
      bitrateKbps: switch (preferredQuality) {
        AudioQuality.standard => 128,
        AudioQuality.high => 320,
        AudioQuality.lossless => 1411,
        // The two independent tiers are not this fake's business: it only has to
        // name a bitrate for whatever it was asked for.
        AudioQuality.hiRes => 4608,
      },
      sampleRateHz: 44100,
      codec: 'flac',
    );
  }
}

/// A resolver for local files: a `file:` source with no streaming tier.
final class _LocalFileResolver implements PlaybackSourceResolver {
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async => ResolvedMediaSource(
    trackId: id,
    uri: Uri.parse('file:///tmp/starlight.mp3'),
    actualQuality: null,
    expiresAt: DateTime.utc(9999),
  );
}

final class _FakeResolver implements PlaybackSourceResolver {
  _FakeResolver({this.gain, this.peak});
  final double? gain;
  final double? peak;
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async => ResolvedMediaSource(
    trackId: id,
    uri: Uri.parse(
      'file:///tmp/${id.value == 'track' ? 'starlight.mp3' : 'afterglow.mp3'}',
    ),
    normalizationGainDb: gain,
    normalizationPeak: peak,
    actualQuality: AudioQuality.standard,
    expiresAt: DateTime.utc(9999),
  );
}

/// Records what the controller asked for, so a test can count the resolves
/// instead of inferring them from the wire.
final class _CountingResolver implements PlaybackSourceResolver {
  final List<(TrackId, AudioQuality)> calls = [];

  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async {
    calls.add((id, preferredQuality));
    return _FakeResolver().resolve(id, preferredQuality, networkPolicy);
  }
}

/// A resolver no network can satisfy: the shape a provider failure has at this
/// boundary.
final class _FailingResolver implements PlaybackSourceResolver {
  @override
  Future<ResolvedMediaSource> resolve(
    TrackId id,
    AudioQuality preferredQuality,
    NetworkPolicy networkPolicy,
  ) async => throw const AppError(
    category: AppErrorCategory.provider,
    code: 'ncm.upstreamError',
    retryable: true,
    diagnosticId: 'ncm.http.502./song/url/v1',
  );
}

/// A [MediaCoreApi] that records envelopes and replays canned answers, so the
/// controller can be tested without a dynamic library.
final class _FakeApi implements MediaCoreApi {
  final List<Map<String, Object?>> commands = [];
  final List<String> detached = [];

  /// One entry per `setEventSink` call: whether a sink was registered.
  final List<bool> sinkRegistrations = [];

  Map<String, Object?> value = _snapshot(sessionRevision: 1);
  Map<String, Object?> reply = const {
    'status': 'accepted',
    'sessionRevision': '1',
  };
  bool closed = false;
  void Function(String message)? _sink;

  /// The last `configureCheckpoint` the session-side writer received, if any.
  String? checkpointDirectory;
  String? checkpointAccount;

  /// The last `restoreCheckpoint` the session-side reader received, if any.
  String? restoredDirectory;
  String? restoredAccount;
  RestoreStatus restoresWith = RestoreStatus.restored;

  /// The last `deleteCheckpoint`, and how often the record was flushed.
  String? deletedDirectory;
  String? deletedAccount;
  int flushes = 0;

  /// The reply the next command gets. A queue of them when a test needs one
  /// command to be refused and the next to be accepted; the last one repeats.
  List<Map<String, Object?>>? replyQueue;

  /// Runs inside `restoreCheckpoint`, which is how a test plays an event the
  /// session pushes while it is restoring.
  void Function()? duringRestore;

  @override
  int get abiVersion => 1;

  @override
  Map<String, Object?> capabilities() => {'abiVersion': 1};

  @override
  void setEventSink(void Function(String message)? sink) {
    _sink = sink;
    sinkRegistrations.add(sink != null);
  }

  @override
  String attach(String clientId) =>
      jsonEncode({'connectionId': 'connection-1', 'baseline': value});

  @override
  void detach(String connectionId) => detached.add(connectionId);

  @override
  String snapshot() => jsonEncode(value);

  @override
  String diagnostics() => '{}';

  @override
  String execute(String command, {int timeoutMs = 2000}) {
    commands.add(jsonDecode(command) as Map<String, Object?>);
    final queued = replyQueue;
    if (queued != null && queued.isNotEmpty) {
      return jsonEncode(queued.length == 1 ? queued.first : queued.removeAt(0));
    }
    return jsonEncode(reply);
  }

  @override
  void configureCheckpoint({
    required String directory,
    required String account,
  }) {
    checkpointDirectory = directory;
    checkpointAccount = account;
  }

  @override
  void deleteCheckpoint({required String directory, required String account}) {
    deletedDirectory = directory;
    deletedAccount = account;
  }

  @override
  void flushCheckpoint() {
    flushes += 1;
  }

  @override
  RestoreStatus restoreCheckpoint({
    required String directory,
    required String account,
  }) {
    restoredDirectory = directory;
    restoredAccount = account;
    duringRestore?.call();
    return restoresWith;
  }

  @override
  void close() => closed = true;

  /// Publishes a snapshot the way the session's publisher thread would.
  void push(Map<String, Object?> snapshot) {
    value = snapshot;
    _sink?.call(jsonEncode(snapshot));
  }

  /// Publishes an arbitrary event (such as sourceRequest) to the event sink.
  void pushEvent(Map<String, Object?> event) {
    _sink?.call(jsonEncode(event));
  }
}
