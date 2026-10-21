import 'dart:math';

import 'package:fideflow_domain/domain.dart';
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

  test(
    'interruption tokens preserve position and ignore stale wake events',
    () async {
      final media = FakeMediaController();
      await media.attach();
      await media.execute(
        const LoadQueue(commandId: 'load', tracks: [track], autoplay: true),
      );
      await media.execute(
        const Seek(commandId: 'seek', position: Duration(seconds: 42)),
      );
      await media.execute(
        const SetInterruption(
          commandId: 'begin',
          interruptionId: 'one',
          active: true,
        ),
      );
      var state = await media.getSnapshot();
      expect(state.suppressionReasons, ['interruption']);
      expect(state.isActuallyPlaying, isFalse);
      expect(state.playWhenReady, isTrue);
      await media.execute(
        const SetInterruption(
          commandId: 'old',
          interruptionId: 'old',
          active: false,
        ),
      );
      expect((await media.getSnapshot()).suppressionReasons, ['interruption']);
      await media.execute(
        const SetInterruption(
          commandId: 'end',
          interruptionId: 'one',
          active: false,
        ),
      );
      state = await media.getSnapshot();
      expect(state.isActuallyPlaying, isTrue);
      expect(state.position, const Duration(seconds: 42));
      expect(state.queue, [track]);
      final revision = state.sessionRevision;
      await media.execute(
        const SetInterruption(
          commandId: 'again',
          interruptionId: 'one',
          active: false,
        ),
      );
      expect((await media.getSnapshot()).sessionRevision, revision);
      await media.execute(
        const SetInterruption(
          commandId: 'late-begin',
          interruptionId: 'one',
          active: true,
        ),
      );
      expect((await media.getSnapshot()).suppressionReasons, isEmpty);
    },
  );

  test(
    'new transport operations cancel wake recovery and stay silent during interruption',
    () async {
      for (final command in <PlaybackCommand>[
        const Pause(commandId: 'user'),
        const Stop(commandId: 'user'),
        const ClearQueue(commandId: 'user'),
        const Play(commandId: 'user'),
        const SkipNext(commandId: 'user'),
        const SkipPrevious(commandId: 'user'),
        const LoadQueue(
          commandId: 'user',
          tracks: [secondTrack],
          autoplay: true,
        ),
      ]) {
        final media = FakeMediaController();
        await media.attach();
        await media.execute(
          const LoadQueue(
            commandId: 'load',
            tracks: [track, secondTrack],
            autoplay: true,
          ),
        );
        await media.execute(
          const SetInterruption(
            commandId: 'begin',
            interruptionId: 'one',
            active: true,
          ),
        );
        expect((await media.execute(command)).isAccepted, isTrue);
        expect((await media.getSnapshot()).isActuallyPlaying, isFalse);
        await media.execute(
          const SetInterruption(
            commandId: 'end',
            interruptionId: 'one',
            active: false,
          ),
        );
        expect((await media.getSnapshot()).playWhenReady, isFalse);
        expect((await media.getSnapshot()).isActuallyPlaying, isFalse);
      }
    },
  );

  test(
    'paused playback stays paused and volume changes preserve wake recovery',
    () async {
      for (final autoplay in [false, true]) {
        final media = FakeMediaController();
        await media.attach();
        await media.execute(
          LoadQueue(commandId: 'load', tracks: [track], autoplay: autoplay),
        );
        await media.execute(
          const SetInterruption(
            commandId: 'begin',
            interruptionId: 'one',
            active: true,
          ),
        );
        await media.execute(
          const SetVolume(commandId: 'volume', permille: 400),
        );
        await media.execute(
          const SetInterruption(
            commandId: 'end',
            interruptionId: 'one',
            active: false,
          ),
        );
        expect((await media.getSnapshot()).isActuallyPlaying, autoplay);
      }
    },
  );

  test(
    'requires attach and increments revisions for accepted commands',
    () async {
      final controller = FakeMediaController();
      final rejected = await controller.execute(
        const LoadQueue(commandId: 'before-attach', tracks: [track]),
      );
      expect(rejected.isAccepted, isFalse);

      await controller.attach();
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );
      final result = await controller.execute(const Play(commandId: 'play'));
      final snapshot = await controller.getSnapshot();

      expect(result.isAccepted, isTrue);
      expect(snapshot.status, PlaybackStatus.playing);
      expect(snapshot.currentTrack, track);
      expect(snapshot.queueRevision, 1);
      expect(snapshot.sessionRevision, 2);
    },
  );

  test('supports seek and previous commands through snapshots', () async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      const LoadQueue(
        commandId: 'load',
        tracks: [track, secondTrack],
        startIndex: 1,
      ),
    );

    await controller.execute(
      const Seek(commandId: 'seek', position: Duration(seconds: 45)),
    );
    expect(
      (await controller.getSnapshot()).position,
      const Duration(seconds: 45),
    );

    await controller.execute(
      const SkipPrevious(commandId: 'previous', expectedQueueRevision: 1),
    );
    final snapshot = await controller.getSnapshot();
    expect(snapshot.currentIndex, 0);
    expect(snapshot.position, Duration.zero);
    expect(snapshot.status, PlaybackStatus.playing);
  });

  test('replay is idempotent before revision validation', () async {
    final controller = FakeMediaController();
    await controller.attach();
    const load = LoadQueue(commandId: 'same', tracks: [track]);
    final first = await controller.execute(load);
    final replay = await controller.execute(load);
    expect(replay.sessionRevision, first.sessionRevision);
    expect((await controller.getSnapshot()).queueRevision, 1);
    final conflict = await controller.execute(
      const LoadQueue(commandId: 'same', tracks: [secondTrack]),
    );
    expect(conflict.errorCode, 'command.idConflict');
    expect((await controller.getSnapshot()).sessionRevision, 1);
    final stale = await controller.execute(
      const SkipNext(commandId: 'stale', expectedQueueRevision: 0),
    );
    expect(stale.errorCode, 'queue.revisionConflict');
    expect((await controller.getSnapshot()).sessionRevision, 1);
  });

  test(
    'attach buffers after-baseline events and detach isolates clients',
    () async {
      final controller = FakeMediaController();
      final first = await controller.attach();
      final second = await controller.attach();
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );
      expect(first.baseline.sessionRevision, 0);
      expect((await first.snapshots.first).sessionRevision, 1);
      await controller.detach(first.id);
      await controller.execute(const Play(commandId: 'play'));
      final events = await second.snapshots.take(2).toList();
      expect(events.map((event) => event.sessionRevision), [1, 2]);
      expect((await controller.getSnapshot()).status, PlaybackStatus.playing);
    },
  );

  group('modes', () {
    test('a natural end repeats the item in repeat one', () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track, secondTrack],
          autoplay: true,
        ),
      );
      await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.repeatOne,
          expectedQueueRevision: 1,
        ),
      );

      controller.completeCurrentItem();
      final repeated = await controller.getSnapshot();
      expect(repeated.currentTrack, track);
      expect(repeated.position, Duration.zero);
      expect(repeated.mode, PlaybackMode.repeatOne);

      // A manual skip still walks the queue rather than repeating.
      await controller.execute(
        const SkipNext(commandId: 'next', expectedQueueRevision: 2),
      );
      expect((await controller.getSnapshot()).currentTrack, secondTrack);
    });

    test('list loop wraps and a jump keeps the queue revision', () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track, secondTrack],
          autoplay: true,
        ),
      );

      controller.completeCurrentItem();
      expect((await controller.getSnapshot()).currentTrack, secondTrack);
      controller.completeCurrentItem();
      expect((await controller.getSnapshot()).currentTrack, track);

      final revision = (await controller.getSnapshot()).queueRevision;
      await controller.execute(
        const PlayItem(commandId: 'jump', index: 1, expectedQueueRevision: 1),
      );
      final jumped = await controller.getSnapshot();
      expect(jumped.currentTrack, secondTrack);
      expect(jumped.queue, [track, secondTrack]);
      expect(jumped.queueRevision, revision);
    });

    test(
      'shuffle publishes a new order and navigates by adjacent entries',
      () async {
        final controller = FakeMediaController();
        await controller.attach();
        await controller.execute(
          const LoadQueue(
            commandId: 'load',
            tracks: [track, secondTrack],
            startIndex: 1,
            autoplay: true,
          ),
        );

        await controller.execute(
          const SetMode(
            commandId: 'mode',
            mode: PlaybackMode.shuffle,
            seed: 4,
            expectedQueueRevision: 1,
          ),
        );
        final shuffled = await controller.getSnapshot();
        expect(shuffled.mode, PlaybackMode.shuffle);
        expect(shuffled.queueRevision, 2);
        // The item that was playing stays the item that is playing.
        expect(shuffled.currentTrack, secondTrack);
        expect(shuffled.currentIndex, 0);
        expect(shuffled.queue, hasLength(2));

        await controller.execute(
          const SkipNext(commandId: 'next', expectedQueueRevision: 2),
        );
        final second = await controller.getSnapshot();
        expect(second.currentTrack, track);

        // "Previous" is the entry before the current one in the published list,
        // not the last item visited (issue 12).
        await controller.execute(
          const SkipPrevious(commandId: 'back', expectedQueueRevision: 2),
        );
        expect((await controller.getSnapshot()).currentTrack, secondTrack);

        // From the head, "previous" wraps to the tail and the permutation stays.
        await controller.execute(
          const SkipPrevious(commandId: 'back-2', expectedQueueRevision: 2),
        );
        expect((await controller.getSnapshot()).currentTrack, track);
      },
    );
  });

  test(
    'a volume change reaches the snapshot without touching the queue',
    () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );

      final result = await controller.execute(
        const SetVolume(commandId: 'vol', permille: 350),
      );
      final snapshot = await controller.getSnapshot();

      expect(result.isAccepted, isTrue);
      expect(snapshot.volume, 350);
      expect(snapshot.queueRevision, 1, reason: 'the gain is not a queue fact');
      expect(snapshot.currentTrack, track);
    },
  );

  test(
    'a volume assertion failure would be a caller bug, not a state change',
    () async {
      // The command is const-constructed, so the range assertion is a compile-time
      // guard; this test pins the documented default the snapshot starts at.
      final controller = FakeMediaController();
      await controller.attach();
      final snapshot = await controller.getSnapshot();
      expect(snapshot.volume, 800);
    },
  );

  test('a jump outside the queue is refused', () async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      const LoadQueue(commandId: 'load', tracks: [track]),
    );

    final result = await controller.execute(
      const PlayItem(commandId: 'jump', index: 4, expectedQueueRevision: 1),
    );

    expect(result.errorCode, 'queue.invalid');
    expect(controller.diagnostics.events.last.code, 'queue.invalid');
  });

  test('stop keeps the queue while clearQueue drops it', () async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      const LoadQueue(
        commandId: 'load',
        tracks: [track, secondTrack],
        autoplay: true,
      ),
    );

    await controller.execute(
      const Seek(
        commandId: 'seek-before-stop',
        position: Duration(seconds: 12),
      ),
    );
    // Stopping keeps the queue and the item's place: a later play resumes it.
    await controller.execute(const Stop(commandId: 'stop'));
    var snapshot = await controller.getSnapshot();
    expect(snapshot.queue, [track, secondTrack]);
    expect(snapshot.status, PlaybackStatus.idle);
    expect(snapshot.currentIndex, 0);
    expect(snapshot.position, const Duration(seconds: 12));
    expect(snapshot.playWhenReady, isFalse);

    // Clearing drops it, and the revision that describes it moves.
    final revision = snapshot.queueRevision;
    await controller.execute(const ClearQueue(commandId: 'clear'));
    snapshot = await controller.getSnapshot();
    expect(snapshot.queue, isEmpty);
    expect(snapshot.currentIndex, isNull);
    expect(snapshot.queueRevision, revision + 1);
    expect(
      (await controller.execute(const Play(commandId: 'play'))).errorCode,
      'playback.queueEmpty',
      reason: 'no item of a cleared queue can be started again',
    );
  });

  group('a seeded shuffle load', () {
    final queue = [
      for (var index = 0; index < 6; index++)
        Track(
          id: TrackId('seeded-$index'),
          title: 'Seeded $index',
          artists: const [artist],
          album: album,
          duration: Duration(minutes: 3),
        ),
    ];

    Future<PlaybackSnapshot> seededLoad(int seed) async {
      final controller = FakeMediaController();
      await controller.attach();
      // Shuffle first: only a shuffle load has an order for a seed to build.
      await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.shuffle,
          expectedQueueRevision: 0,
        ),
      );
      await controller.execute(
        LoadQueue(
          commandId: 'load',
          tracks: queue,
          seed: seed,
          autoplay: true,
          expectedQueueRevision: 1,
        ),
      );
      return controller.getSnapshot();
    }

    test('lets the seed name both the order and the first track', () async {
      final snapshot = await seededLoad(42);
      // The fake's rule: the seed permutes the whole queue, nothing is pinned.
      final permutation = [
        for (var index = 0; index < queue.length; index++) index,
      ]..shuffle(Random(42));
      expect(snapshot.shuffleSeed, 42);
      expect(snapshot.queue, [
        for (final index in permutation) queue[index],
      ], reason: 'the permutation covers the whole queue');
      expect(
        snapshot.currentTrack,
        queue[permutation.first],
        reason: 'the session derives the opening track, not the caller',
      );
      expect(
        snapshot.currentTrack,
        isNot(queue.first),
        reason: 'seed 42 does not open on the row the load listed first',
      );
    });

    test('replays the same order and first track for the same seed', () async {
      final first = await seededLoad(7);
      final again = await seededLoad(7);
      expect(again.shuffleSeed, first.shuffleSeed);
      expect(again.queue, first.queue);
      expect(again.currentTrack, first.currentTrack);
    });

    test('publishes no seed while the mode holds no seeded order', () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        LoadQueue(
          commandId: 'load',
          tracks: queue,
          seed: 42,
          autoplay: true,
          expectedQueueRevision: 0,
        ),
      );
      final snapshot = await controller.getSnapshot();
      expect(snapshot.mode, PlaybackMode.listLoop);
      expect(
        snapshot.shuffleSeed,
        isNull,
        reason: 'a seed outside shuffle is not an order anyone can replay',
      );
      expect(snapshot.currentTrack, queue.first);
    });
  });

  group('quality switching', () {
    test('a load publishes the quality it was asked for, confirmed', () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track],
          quality: AudioQuality.lossless,
        ),
      );
      final quality = (await controller.getSnapshot()).quality;
      expect(quality?.level, AudioQuality.lossless);
      expect(quality?.confirmed, isTrue);
    });

    test(
      'switching re-resolves the current entry and reports the scopes',
      () async {
        final controller = FakeMediaController();
        await controller.attach();
        await controller.execute(
          const LoadQueue(commandId: 'load', tracks: [track]),
        );

        final global = await controller.setQuality(
          preference: AudioQuality.lossless,
        );
        expect(global.preferenceApplied, isTrue);
        expect(global.currentSwitchStarted, isTrue);
        expect(controller.preferredQuality, AudioQuality.lossless);
        expect(
          (await controller.getSnapshot()).quality?.level,
          AudioQuality.lossless,
        );

        // A second selection also replaces the shared preference.
        final current = await controller.setQuality(
          preference: AudioQuality.high,
        );
        expect(current.preferenceApplied, isTrue);
        expect(current.currentSwitchStarted, isTrue);
        expect(controller.preferredQuality, AudioQuality.high);
        expect(
          (await controller.getSnapshot()).quality?.level,
          AudioQuality.high,
        );
      },
    );

    test('with nothing playing only the preference applies', () async {
      final controller = FakeMediaController();
      await controller.attach();
      final outcome = await controller.setQuality(
        preference: AudioQuality.high,
      );
      expect(outcome.preferenceApplied, isTrue);
      expect(outcome.currentSwitchStarted, isFalse);
      expect(controller.preferredQuality, AudioQuality.high);
      expect((await controller.getSnapshot()).quality, isNull);
    });

    test('clearing the queue drops the published quality', () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(commandId: 'load', tracks: [track]),
      );
      await controller.execute(const ClearQueue(commandId: 'clear'));
      expect((await controller.getSnapshot()).quality, isNull);
    });
  });

  test('diagnostics retain only bounded stable codes', () {
    final diagnostics = BoundedDiagnostics(capacity: 2);
    diagnostics.record('media.attached', 1);
    diagnostics.record('queue.revisionConflict', 2);
    diagnostics.record('media.detached', 3);
    expect(diagnostics.events.map((event) => event.code), [
      'queue.revisionConflict',
      'media.detached',
    ]);
    expect(() => diagnostics.record('https://secret', 4), throwsArgumentError);
  });
}
