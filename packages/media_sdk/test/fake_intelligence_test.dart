import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:test/test.dart';

Track song(int id) => Track(
  id: TrackId('ncm-$id'),
  title: '$id',
  artists: const [],
  album: const Album(id: AlbumId('album'), title: 'Album'),
  duration: const Duration(seconds: 1),
);

void main() {
  late FakeMediaController media;
  setUp(() async {
    media = FakeMediaController();
    await media.attach();
    await media.execute(
      LoadQueue(
        commandId: 'heart',
        tracks: [song(1), song(2)],
        autoplay: true,
        intelligenceSessionId: 'heart-test',
      ),
    );
  });

  test('heart mode rejects shuffle, loop and unconfirmed insertion', () async {
    for (final mode in [PlaybackMode.shuffle, PlaybackMode.listLoop]) {
      expect(
        (await media.execute(
          SetMode(commandId: mode.name, mode: mode),
        )).isAccepted,
        isFalse,
      );
    }
    expect(
      (await media.execute(
        AddToQueue(commandId: 'add', tracks: [song(3)]),
      )).isAccepted,
      isFalse,
    );
    expect((await media.getSnapshot()).isIntelligenceMode, isTrue);
    await media.execute(
      AddToQueue(
        commandId: 'confirmed',
        tracks: [song(3)],
        exitIntelligence: true,
      ),
    );
    expect((await media.getSnapshot()).isIntelligenceMode, isFalse);
  });

  test(
    'sequential natural end and repeatOne manual next do not wrap',
    () async {
      await media.execute(
        const SetMode(commandId: 'repeat', mode: PlaybackMode.repeatOne),
      );
      media.completeCurrentItem();
      expect((await media.getSnapshot()).currentIndex, 0);
      await media.execute(const SkipNext(commandId: 'next'));
      await media.execute(const SkipNext(commandId: 'tail-next'));
      expect((await media.getSnapshot()).currentIndex, 1);
      await media.execute(
        const SetMode(commandId: 'sequence', mode: PlaybackMode.sequential),
      );
      media.completeCurrentItem();
      expect((await media.getSnapshot()).phase, WirePhase.ended);
      expect((await media.getSnapshot()).currentIndex, 1);
    },
  );

  test('remove-last keeps paused intent and clear drops context', () async {
    await media.execute(const Pause(commandId: 'pause'));
    await media.execute(const RemoveFromQueue(commandId: 'remove2', index: 1));
    await media.execute(const RemoveFromQueue(commandId: 'remove1', index: 0));
    expect((await media.getSnapshot()).isIntelligenceMode, isTrue);
    await media.execute(
      RefillIntelligence(
        commandId: 'supply',
        sessionId: 'heart-test',
        tracks: [song(3)],
      ),
    );
    expect((await media.getSnapshot()).playWhenReady, isFalse);
    await media.execute(const ClearQueue(commandId: 'clear'));
    expect((await media.getSnapshot()).isIntelligenceMode, isFalse);
  });

  test(
    'window rejects oversized and unsafe mutations without changing the queue',
    () async {
      final before = await media.getSnapshot();
      expect(
        (await media.execute(
          RefillIntelligence(
            commandId: 'unsafe',
            sessionId: 'heart-test',
            tracks: [song(3)],
            evictCount: 1,
          ),
        )).isAccepted,
        isFalse,
      );
      expect(
        (await media.execute(
          RefillIntelligence(
            commandId: 'oversize',
            sessionId: 'heart-test',
            tracks: List.generate(50, (i) => song(i + 3)),
          ),
        )).isAccepted,
        isFalse,
      );
      expect((await media.getSnapshot()).queue, before.queue);
    },
  );
}
