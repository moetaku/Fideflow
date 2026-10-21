import 'dart:async';

import 'package:fideflow/app/macos_playback_lifecycle.dart';
import 'package:fideflow/features/player/playback_controls.dart';
import 'package:fideflow/features/player/playback_labels.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MacosPlaybackLifecycle.channel;
  const codec = StandardMethodCodec();
  const track = Track(
    id: TrackId('one'),
    title: 'One',
    artists: [],
    album: Album(id: AlbumId('a'), title: 'A'),
    duration: Duration(minutes: 3),
  );
  late FakeMediaController media;
  late BrowseAndPlayController playback;
  late MacosPlaybackLifecycle lifecycle;
  final calls = <String>[];
  Future<void> deliver(String id, bool active) async {
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(
            MethodCall('interruption', {
              'interruptionId': id,
              'active': active,
            }),
          ),
          (ByteData? reply) {
            if (reply != null) codec.decodeEnvelope(reply);
            done.complete();
          },
        );
    await done.future;
  }

  setUp(() async {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    media = FakeMediaController();
    playback = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      media,
    );
    await playback.initialize(prefetchPlaylist: false);
    await media.execute(
      const LoadQueue(commandId: 'load', tracks: [track], autoplay: true),
    );
    lifecycle = MacosPlaybackLifecycle(playback);
    await lifecycle.initialize();
  });
  tearDown(() async {
    await lifecycle.close();
    await playback.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'sleep and wake update authoritative state without media controls',
    () async {
      await deliver('one', true);
      expect(playback.current.playback.suppressionReasons, ['interruption']);
      expect(
        localizedTestValue(playbackStatusText(playback.current.playback)),
        '系统中断，播放已暂停',
      );
      expect(playback.current.playback.isActuallyPlaying, isFalse);
      await deliver('old', false);
      expect(playback.current.playback.suppressionReasons, ['interruption']);
      await deliver('one', false);
      expect(playback.current.playback.isActuallyPlaying, isTrue);
      expect(calls, ['initialize']);
    },
  );

  test('back to back lifecycle events preserve their delivery order', () async {
    await Future.wait([deliver('one', true), deliver('one', false)]);
    expect(playback.current.playback.suppressionReasons, isEmpty);
    expect(playback.current.playback.isActuallyPlaying, isTrue);
  });

  test('pause between sleep and wake cancels recovery', () async {
    await deliver('one', true);
    await media.execute(const Pause(commandId: 'pause'));
    await deliver('one', false);
    expect(playback.current.playback.playWhenReady, isFalse);
  });

  testWidgets(
    'output interruption displays an actionable retry outside item error phase',
    (tester) async {
      var retried = false;
      final snapshot = PlaybackSnapshot(
        sessionId: 'one',
        sessionRevision: 1,
        queueRevision: 1,
        status: PlaybackStatus.paused,
        queue: const [track],
        currentIndex: 0,
        position: const Duration(seconds: 42),
        playWhenReady: false,
        phase: WirePhase.ready,
        outputSettings: const PlaybackOutputSettings(
          supported: true,
          errorCode: 'outputStopped',
        ),
      );
      expect(localizedTestValue(playbackStatusText(snapshot)), '音频输出中断，点击播放重试');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackErrorStrip(
              snapshot: snapshot,
              onRetry: () async {
                retried = true;
              },
              onNext: () async {},
            ),
          ),
        ),
      );
      expect(find.text('音频输出已中断，请检查设备后点击播放重试。'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
      final refreshFailure = PlaybackSnapshot(
        sessionId: 'one',
        sessionRevision: 2,
        queueRevision: 1,
        status: PlaybackStatus.playing,
        queue: const [track],
        currentIndex: 0,
        position: const Duration(seconds: 42),
        playWhenReady: true,
        isActuallyPlaying: true,
        outputSettings: const PlaybackOutputSettings(
          supported: true,
          errorCode: 'outputEnumerationFailed',
        ),
      );
      expect(playbackStatusText(refreshFailure), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackErrorStrip(
              snapshot: refreshFailure,
              onRetry: () async {},
              onNext: () async {},
            ),
          ),
        ),
      );
      expect(find.text('重试'), findsNothing);
    },
  );

  test(
    'close removes method handler and disposes native notifications',
    () async {
      await lifecycle.close();
      expect(calls, ['initialize', 'dispose']);
    },
  );
}
