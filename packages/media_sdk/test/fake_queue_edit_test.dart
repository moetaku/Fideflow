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
  const second = Track(
    id: TrackId('second'),
    title: 'Afterglow',
    artists: [artist],
    album: album,
    duration: Duration(minutes: 4),
  );
  const third = Track(
    id: TrackId('third'),
    title: 'Meridian',
    artists: [artist],
    album: album,
    duration: Duration(minutes: 5),
  );

  Future<FakeMediaController> loaded() async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      const LoadQueue(
        commandId: 'load',
        tracks: [track, second],
        autoplay: true,
      ),
    );
    return controller;
  }

  test(
    'playNext inserts after the current item and keeps it playing',
    () async {
      final controller = await loaded();
      final result = await controller.execute(
        const PlayNext(
          commandId: 'next',
          tracks: [third],
          expectedQueueRevision: 1,
        ),
      );
      final snapshot = await controller.getSnapshot();
      expect(result.isAccepted, isTrue);
      expect(snapshot.queue, [track, third, second]);
      expect(snapshot.currentTrack, track);
      expect(snapshot.status, PlaybackStatus.playing);
      expect(snapshot.queueRevision, 2);
    },
  );

  test('addToQueue appends and leaves the current item alone', () async {
    final controller = await loaded();
    await controller.execute(
      const AddToQueue(
        commandId: 'append',
        tracks: [third],
        expectedQueueRevision: 1,
      ),
    );
    final snapshot = await controller.getSnapshot();
    expect(snapshot.queue, [track, second, third]);
    expect(snapshot.currentTrack, track);
    expect(snapshot.queueRevision, 2);
  });

  test('removing a non-current entry keeps the current item', () async {
    final controller = await loaded();
    final result = await controller.execute(
      const RemoveFromQueue(
        commandId: 'remove',
        index: 1,
        expectedQueueRevision: 1,
      ),
    );
    final snapshot = await controller.getSnapshot();
    expect(result.isAccepted, isTrue);
    expect(snapshot.queue, [track]);
    expect(snapshot.currentTrack, track);
    expect(snapshot.queueRevision, 2);
  });

  test('removing the current entry advances and keeps playing', () async {
    final controller = await loaded();
    await controller.execute(
      const RemoveFromQueue(
        commandId: 'remove',
        index: 0,
        expectedQueueRevision: 1,
      ),
    );
    final snapshot = await controller.getSnapshot();
    expect(snapshot.queue, [second]);
    expect(snapshot.currentTrack, second);
    expect(snapshot.status, PlaybackStatus.playing);
  });

  test('removing the only entry stops like clearQueue', () async {
    final controller = FakeMediaController();
    await controller.attach();
    await controller.execute(
      const LoadQueue(commandId: 'load', tracks: [track], autoplay: true),
    );
    await controller.execute(
      const RemoveFromQueue(
        commandId: 'remove',
        index: 0,
        expectedQueueRevision: 1,
      ),
    );
    final snapshot = await controller.getSnapshot();
    expect(snapshot.queue, isEmpty);
    expect(snapshot.currentIndex, isNull);
    expect(snapshot.status, PlaybackStatus.idle);
    expect(snapshot.playWhenReady, isFalse);
    expect(
      (await controller.execute(const Play(commandId: 'play'))).errorCode,
      'playback.queueEmpty',
    );
  });

  test(
    'a duplicated track is two entries that are removed one at a time',
    () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track, second, track],
          autoplay: true,
        ),
      );

      // Remove the duplicate at the end; the first entry of the same track stays.
      await controller.execute(
        const RemoveFromQueue(
          commandId: 'remove-1',
          index: 2,
          expectedQueueRevision: 1,
        ),
      );
      var snapshot = await controller.getSnapshot();
      expect(snapshot.queue, [track, second]);
      expect(snapshot.currentTrack, track);

      // The remaining entry of that track is removed on its own.
      await controller.execute(
        const RemoveFromQueue(
          commandId: 'remove-2',
          index: 0,
          expectedQueueRevision: 2,
        ),
      );
      snapshot = await controller.getSnapshot();
      expect(snapshot.queue, [second]);
      expect(snapshot.currentTrack, second);
    },
  );

  test(
    'editing an empty queue installs the entries and starts playing',
    () async {
      final controller = FakeMediaController();
      await controller.attach();
      final result = await controller.execute(
        const PlayNext(
          commandId: 'next',
          tracks: [track, second],
          expectedQueueRevision: 0,
        ),
      );
      final snapshot = await controller.getSnapshot();
      expect(result.isAccepted, isTrue);
      expect(snapshot.queue, [track, second]);
      expect(snapshot.currentTrack, track);
      expect(snapshot.status, PlaybackStatus.playing);
      expect(snapshot.queueRevision, 1);
    },
  );

  test(
    'playNext under shuffle places the entry next in the effective order',
    () async {
      final controller = FakeMediaController();
      await controller.attach();
      await controller.execute(
        const LoadQueue(
          commandId: 'load',
          tracks: [track, second, third],
          autoplay: true,
        ),
      );
      await controller.execute(
        const SetMode(
          commandId: 'mode',
          mode: PlaybackMode.shuffle,
          seed: 3,
          expectedQueueRevision: 1,
        ),
      );
      const added = Track(
        id: TrackId('added'),
        title: 'Zenith',
        artists: [artist],
        album: album,
        duration: Duration(minutes: 6),
      );
      await controller.execute(
        const PlayNext(
          commandId: 'next',
          tracks: [added],
          expectedQueueRevision: 2,
        ),
      );
      final snapshot = await controller.getSnapshot();
      expect(snapshot.queue, hasLength(4));
      expect(snapshot.queue.first, snapshot.currentTrack);
      expect(snapshot.queue[1], added, reason: 'the new entry plays next');
      expect(snapshot.queueRevision, 3);
    },
  );

  test('removing the current entry under repeatOne advances', () async {
    final controller = await loaded();
    await controller.execute(
      const SetMode(
        commandId: 'mode',
        mode: PlaybackMode.repeatOne,
        expectedQueueRevision: 1,
      ),
    );
    await controller.execute(
      const RemoveFromQueue(
        commandId: 'remove',
        index: 0,
        expectedQueueRevision: 2,
      ),
    );
    final snapshot = await controller.getSnapshot();
    expect(snapshot.currentTrack, second);
    expect(snapshot.status, PlaybackStatus.playing);
  });

  test('an edit written against an old revision is refused', () async {
    final controller = await loaded();
    final result = await controller.execute(
      const AddToQueue(
        commandId: 'append',
        tracks: [third],
        expectedQueueRevision: 0,
      ),
    );
    expect(result.errorCode, 'queue.revisionConflict');
    expect((await controller.getSnapshot()).queue, [track, second]);
  });
}
