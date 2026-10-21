/// Seeded-shuffle end-to-end regression at the SDK boundary (docs/design/playback.md).
///
/// The mirror of the native `session_seed` wire tests: a seed drawn for a
/// whole-playlist start travels in a `loadQueue`, decides the fake session's
/// permutation and opener, is published back in the snapshot, and — fed back in —
/// replays the exact order it described. The suite covers the three modes and the
/// empty-queue boundary a restore starts from.
library;

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

void main() {
  const artist = Artist(id: ArtistId('artist'), name: 'Aurora');
  const album = Album(id: AlbumId('album'), title: 'Night');
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

  /// A session in [mode] whose queue was installed by a seeded load, so the seed
  /// owns both the permutation and the item that is playing.
  Future<PlaybackSnapshot> seededSession(String mode, int seed) async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      SetMode(commandId: 'mode', mode: _mode(mode), expectedQueueRevision: 0),
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

  test('only shuffle lets a seed order the queue', () async {
    for (final mode in ['listLoop', 'repeatOne']) {
      final snapshot = await seededSession(mode, 7);
      expect(snapshot.mode, _mode(mode));
      expect(
        snapshot.shuffleSeed,
        isNull,
        reason: 'a seed outside shuffle is not an order anyone can replay',
      );
      expect(
        snapshot.queue,
        queue,
        reason: 'the queue plays in the order it was loaded',
      );
      expect(
        snapshot.currentTrack,
        queue.first,
        reason: 'only shuffle derives its opener from the seed ($mode)',
      );
    }
  });

  test(
    'a seeded shuffle load publishes the seed that owns the order',
    () async {
      final snapshot = await seededSession('shuffle', 7);
      expect(snapshot.mode, PlaybackMode.shuffle);
      expect(
        snapshot.shuffleSeed,
        7,
        reason: 'a client can only persist an order it was told the seed of',
      );
      expect(snapshot.queue, hasLength(queue.length));
      expect(
        snapshot.queue.toSet(),
        queue.toSet(),
        reason: 'the permutation covers the whole queue and repeats nothing',
      );
      expect(
        snapshot.currentTrack,
        snapshot.queue.first,
        reason: 'the seed names the opener, not the row the load listed',
      );
    },
  );

  test('the published seed replays the same order and opener', () async {
    // What the session heard: an order and the seed that describes it.
    final heard = await seededSession('shuffle', 7);
    final seed = heard.shuffleSeed!;

    // What a restore does: start a fresh session and hand it back the seed that
    // was persisted, not the one the original caller happened to draw.
    final replayed = await seededSession('shuffle', seed);

    expect(replayed.shuffleSeed, seed);
    expect(replayed.queue, heard.queue);
    expect(
      replayed.currentTrack,
      heard.currentTrack,
      reason: 'a restore resumes on the opener the seed derived',
    );
  });

  test('shuffle without a seed still starts on the named item', () async {
    final controller = FakeMediaController();
    await controller.attach();
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
        startIndex: 2,
        autoplay: true,
        expectedQueueRevision: 1,
      ),
    );
    final snapshot = await controller.getSnapshot();
    expect(
      snapshot.currentTrack,
      queue[2],
      reason: 'a caller that named a row keeps that row',
    );
    expect(
      snapshot.shuffleSeed,
      isNotNull,
      reason: 'the session derives a seed even when the caller did not pin one',
    );
  });

  test('an empty session publishes no seed', () async {
    final controller = FakeMediaController();
    await controller.attach();
    final snapshot = await controller.getSnapshot();
    expect(snapshot.queue, isEmpty);
    expect(snapshot.shuffleSeed, isNull);
  });

  test('a seeded load on an empty queue is refused', () async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      const SetMode(
        commandId: 'mode',
        mode: PlaybackMode.shuffle,
        expectedQueueRevision: 0,
      ),
    );

    final result = await controller.execute(
      const LoadQueue(
        commandId: 'load',
        tracks: [],
        seed: 7,
        autoplay: true,
        expectedQueueRevision: 1,
      ),
    );
    expect(result.errorCode, 'queue.invalid');

    // The refusal is a queue fact, not partial state: nothing was installed.
    final snapshot = await controller.getSnapshot();
    expect(snapshot.queue, isEmpty);
    expect(snapshot.queueRevision, 1, reason: 'only the mode change moved it');
  });

  test('clearing the queue drops the seed with it', () async {
    final controller = FakeMediaController();
    await controller.attach();
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
        seed: 7,
        autoplay: true,
        expectedQueueRevision: 1,
      ),
    );
    expect((await controller.getSnapshot()).shuffleSeed, isNotNull);

    await controller.execute(const ClearQueue(commandId: 'clear'));
    final snapshot = await controller.getSnapshot();
    expect(snapshot.queue, isEmpty);
    expect(
      snapshot.shuffleSeed,
      isNull,
      reason: 'no item is left for a permutation to describe',
    );
  });
}

PlaybackMode _mode(String wire) => switch (wire) {
  'shuffle' => PlaybackMode.shuffle,
  'repeatOne' => PlaybackMode.repeatOne,
  _ => PlaybackMode.listLoop,
};
