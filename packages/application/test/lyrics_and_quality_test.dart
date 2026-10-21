import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  const artist = Artist(id: ArtistId('artist'), name: 'Aurora');
  const album = Album(id: AlbumId('album'), title: 'Night');
  Track track(String id) => Track(
    id: TrackId(id),
    title: id,
    artists: const [artist],
    album: album,
    duration: const Duration(minutes: 3),
  );

  group('LyricsController', () {
    test('reads the sheet of the song that is playing', () async {
      final media = FakeMediaController();
      final controller = LyricsController(
        media: media,
        lyrics: FakeCatalogRepository(latency: Duration.zero),
      );
      await controller.initialize();
      expect(controller.current.status, LyricsStatus.unavailable);

      await media.execute(
        LoadQueue(
          commandId: 'load',
          tracks: [track('track-starlight')],
          autoplay: true,
        ),
      );
      await pumpEventQueue();

      expect(controller.current.trackId, const TrackId('track-starlight'));
      expect(controller.current.loading, isFalse);
      expect(controller.current.status, LyricsStatus.synchronized);
      expect(controller.current.isWordLevel, isTrue);
      expect(controller.current.hasTimedLines, isTrue);
      expect(
        controller.current.timeline!.hasTranslation,
        isTrue,
        reason: 'the translation travels with the sheet, not as a second read',
      );
      await controller.dispose();
    });

    test('a track with no sheet is an empty state, not a failure', () async {
      final media = FakeMediaController();
      final controller = LyricsController(
        media: media,
        lyrics: FakeCatalogRepository(latency: Duration.zero),
      );
      await controller.initialize();

      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track-polaris')]),
      );
      await pumpEventQueue();

      expect(controller.current.status, LyricsStatus.instrumental);
      expect(controller.current.isEmpty, isTrue);
      await controller.dispose();
    });

    test('a slow read for the song the user left never lands', () async {
      final media = FakeMediaController();
      final lyrics = _HeldLyrics();
      final controller = LyricsController(media: media, lyrics: lyrics);
      await controller.initialize();

      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track-first')]),
      );
      await pumpEventQueue();
      // The user moves on before the first sheet answers.
      await media.execute(
        LoadQueue(commandId: 'load-2', tracks: [track('track-second')]),
      );
      await pumpEventQueue();

      lyrics.answer('track-second', const LyricTimeline.instrumental());
      await pumpEventQueue();
      expect(controller.current.trackId, const TrackId('track-second'));
      expect(controller.current.status, LyricsStatus.instrumental);

      // The answer for the song that was left arrives last, and is dropped.
      lyrics.answer(
        'track-first',
        parseLrcSheet('[00:01.00]stale line\n[00:03.00]another\n'),
      );
      await pumpEventQueue();
      expect(
        controller.current.status,
        LyricsStatus.instrumental,
        reason: 'the sheet of the song that was left must not be shown',
      );
      expect(
        LyricsStatus.instrumental,
        controller.current.status,
        reason: 'the placeholder decision is not re-derived from a late read',
      );
      await controller.dispose();
    });

    test('a failing read is an absent sheet rather than an error', () async {
      final media = FakeMediaController();
      final controller = LyricsController(
        media: media,
        lyrics: _BrokenLyrics(),
      );
      await controller.initialize();

      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track-anything')]),
      );
      await pumpEventQueue();

      expect(controller.current.status, LyricsStatus.unavailable);
      expect(controller.current.loading, isFalse);
      await controller.dispose();
    });
  });

  // The catalogue-ceiling mapping itself is covered where it lives, in
  // `packages/domain`; what matters here is that nothing in this package decides
  // a request from it.
  group('QualityState', () {
    test(
      'publishes the choice as applying until the backend answers',
      () async {
        final media = _HeldQualityMedia();
        final controller = QualityController(media: media);
        final seen = <QualityState>[];
        final subscription = controller.states.listen(seen.add);
        addTearDown(subscription.cancel);

        final pending = controller.select(AudioQuality.hiRes);
        await pumpEventQueue();

        expect(seen, isNotEmpty);
        expect(seen.last.preference, AudioQuality.hiRes);
        expect(
          seen.last.applying,
          isTrue,
          reason: 'the backend has not answered yet',
        );
        expect(controller.current.applying, isTrue);

        media.gate.complete();
        await pending;
        await pumpEventQueue();

        expect(seen.last.applying, isFalse);
        expect(seen.last.preference, AudioQuality.hiRes);
        await controller.dispose();
      },
    );

    test('an empty queue still publishes the choice', () async {
      final controller = QualityController(media: FakeMediaController());
      final seen = <QualityState>[];
      final subscription = controller.states.listen(seen.add);
      addTearDown(subscription.cancel);

      final decision = await controller.select(AudioQuality.hiRes);
      await pumpEventQueue();

      expect(decision.outcome.currentSwitchStarted, isFalse);
      expect(
        seen.map((state) => state.preference),
        contains(AudioQuality.hiRes),
        reason:
            'both entry points must show the new choice with nothing playing',
      );
      expect(seen.last.applying, isFalse);
      await controller.dispose();
    });

    test('load publishes the stored preference', () async {
      final controller = QualityController(
        media: FakeMediaController(),
        store: InMemoryQualityPreferenceStore(AudioQuality.hiRes),
        initial: AudioQuality.high,
      );
      final seen = <QualityState>[];
      final subscription = controller.states.listen(seen.add);
      addTearDown(subscription.cancel);

      expect(await controller.load(), AudioQuality.hiRes);
      await pumpEventQueue();

      expect(seen.last.preference, AudioQuality.hiRes);
      await controller.dispose();
    });

    test('the stream closes with the controller', () async {
      final controller = QualityController(media: FakeMediaController());
      final done = expectLater(
        controller.states,
        emitsThrough(isA<QualityState>()),
      );
      final pending = controller.select(AudioQuality.standard);
      await controller.dispose();
      await pending;
      await done;
    });
  });

  group('QualityController', () {
    test('applies the preference and re-resolves the song playing', () async {
      final media = FakeMediaController();
      final store = InMemoryQualityPreferenceStore();
      final controller = QualityController(media: media, store: store);
      // The fake mirrors the host's rule that a page command needs a connection.
      await media.attach();
      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track')], autoplay: true),
      );

      final decision = await controller.select(AudioQuality.lossless);
      await controller.flush();

      expect(decision.preference, AudioQuality.lossless);
      expect(decision.requested, AudioQuality.lossless);
      expect(decision.outcome.preferenceApplied, isTrue);
      expect(decision.outcome.currentSwitchStarted, isTrue);
      expect(await store.read(), AudioQuality.lossless);
      expect((await media.getSnapshot()).quality?.level, AudioQuality.lossless);
      await controller.dispose();
    });

    test('every selection updates the remembered preference', () async {
      final media = FakeMediaController();
      final store = InMemoryQualityPreferenceStore();
      final controller = QualityController(
        media: media,
        store: store,
        initial: AudioQuality.high,
      );
      await media.attach();
      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track')], autoplay: true),
      );

      final decision = await controller.select(AudioQuality.lossless);

      expect(decision.preference, AudioQuality.lossless);
      expect(decision.outcome.preferenceApplied, isTrue);
      expect(decision.outcome.currentSwitchStarted, isTrue);
      await controller.flush();
      expect(await store.read(), AudioQuality.lossless);
      await controller.dispose();
    });

    test(
      'higher lower and identical selections always persist globally',
      () async {
        final media = FakeMediaController();
        final store = InMemoryQualityPreferenceStore();
        final controller = QualityController(media: media, store: store);
        await media.attach();
        await media.execute(
          LoadQueue(
            commandId: 'load',
            tracks: [track('track')],
            autoplay: true,
          ),
        );
        for (final level in [
          AudioQuality.lossless,
          AudioQuality.standard,
          AudioQuality.standard,
        ]) {
          final decision = await controller.select(level);
          await controller.flush();
          expect(controller.preference, level);
          expect(media.preferredQuality, level);
          expect(await store.read(), level);
          expect(decision.outcome.preferenceApplied, isTrue);
        }
        await controller.dispose();
      },
    );

    test('paused selection persists without publishing applying', () async {
      final media = FakeMediaController();
      final store = InMemoryQualityPreferenceStore();
      final controller = QualityController(media: media, store: store);
      await media.attach();
      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track')], autoplay: true),
      );
      await media.execute(const Pause(commandId: 'pause'));
      final seen = <QualityState>[];
      final subscription = controller.states.listen(seen.add);
      await controller.select(AudioQuality.lossless);
      await controller.flush();
      await pumpEventQueue();
      expect(seen.every((state) => !state.applying), isTrue);
      expect(await store.read(), AudioQuality.lossless);
      expect((await media.getSnapshot()).status, PlaybackStatus.paused);
      expect((await media.getSnapshot()).quality?.level, AudioQuality.standard);
      await media.execute(const Play(commandId: 'resume'));
      expect((await media.getSnapshot()).quality?.level, AudioQuality.lossless);
      await subscription.cancel();
      await controller.dispose();
    });

    test(
      'boot synchronizes stored and default preferences with the media host',
      () async {
        for (final stored in [AudioQuality.lossless, null]) {
          final media = FakeMediaController();
          final controller = QualityController(
            media: media,
            store: InMemoryQualityPreferenceStore(stored),
            initial: AudioQuality.high,
          );
          await controller.load();
          expect(media.preferredQuality, stored ?? AudioQuality.high);
          await controller.dispose();
        }
      },
    );

    test('loads the stored preference for the next launch', () async {
      final controller = QualityController(
        media: FakeMediaController(),
        store: InMemoryQualityPreferenceStore(AudioQuality.lossless),
        initial: AudioQuality.high,
      );

      expect(await controller.load(), AudioQuality.lossless);
      expect(controller.preference, AudioQuality.lossless);
      await controller.dispose();
    });

    test('the last preference is the one that reaches the store', () async {
      final store = _SlowStore();
      final media = FakeMediaController();
      final controller = QualityController(media: media, store: store);
      await media.attach();
      await media.execute(
        LoadQueue(commandId: 'load', tracks: [track('track')], autoplay: true),
      );

      final slow = controller.select(AudioQuality.standard);
      // A second choice while the first write is still in flight: the store must
      // end up holding the newer one, whatever order the writes finish in.
      final quick = controller.select(AudioQuality.lossless);
      store.release();
      await slow;
      await quick;
      await controller.flush();

      expect(store.writes, isNotEmpty);
      expect(store.value, AudioQuality.lossless);
      expect(
        store.writes.last,
        AudioQuality.lossless,
        reason: 'the newest preference is the last one written',
      );
      await controller.dispose();
    });

    test('a backend that cannot switch still takes the preference', () async {
      final media = _PlainMedia();
      final store = InMemoryQualityPreferenceStore();
      final controller = QualityController(media: media, store: store);

      final decision = await controller.select(AudioQuality.lossless);
      await controller.flush();

      expect(controller.canSwitchCurrent, isFalse);
      expect(decision.outcome.preferenceApplied, isTrue);
      expect(decision.outcome.currentSwitchStarted, isFalse);
      expect(await store.read(), AudioQuality.lossless);
      await controller.dispose();
    });
  });
}

/// A lyric source a test answers by hand, so a read can finish after the track
/// it belongs to has been left.
final class _HeldLyrics implements LyricsRepository {
  final Map<String, Completer<LyricTimeline>> _pending = {};

  @override
  Future<LyricTimeline> getLyrics(TrackId id) {
    final completer = Completer<LyricTimeline>();
    _pending[id.value] = completer;
    return completer.future;
  }

  void answer(String trackId, LyricTimeline timeline) {
    _pending.remove(trackId)?.complete(timeline);
  }
}

/// A lyric source that always fails, the shape a broken provider has here.
final class _BrokenLyrics implements LyricsRepository {
  @override
  Future<LyricTimeline> getLyrics(TrackId id) async => throw const AppError(
    category: AppErrorCategory.provider,
    code: 'ncm.upstreamError',
    retryable: true,
  );
}

/// A store whose first write waits for the test, so two choices can overlap.
final class _SlowStore implements QualityPreferenceStore {
  final List<AudioQuality> writes = [];
  final Completer<void> _gate = Completer<void>();
  AudioQuality? value;
  bool _held = false;

  void release() => _gate.complete();

  @override
  Future<AudioQuality?> read() async => value;

  @override
  Future<void> write(AudioQuality quality) async {
    // Only the first write waits: what matters is that a write already running
    // does not overwrite the newer value that arrived behind it.
    if (!_held) {
      _held = true;
      await _gate.future;
    }
    writes.add(quality);
    value = quality;
  }
}

/// A controller whose quality switch waits for the test, so the window in which
/// the choice is submitted but unanswered can be observed.
final class _HeldQualityMedia
    implements MediaController, QualitySwitchableMediaController {
  final StreamController<PlaybackSnapshot> _snapshots =
      StreamController<PlaybackSnapshot>.broadcast();

  /// Released by the test to let the switch finish.
  final Completer<void> gate = Completer<void>();

  int switches = 0;

  @override
  Future<QualitySwitchOutcome> setQuality({
    required AudioQuality preference,
  }) async {
    switches++;
    await gate.future;
    return QualitySwitchOutcome(
      preferenceApplied: true,
      currentSwitchStarted: true,
    );
  }

  @override
  Future<CommandResult> execute(PlaybackCommand command) async =>
      const CommandResult.accepted(1);

  @override
  Future<PlaybackSnapshot> getSnapshot() async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'held',
    baseline: PlaybackSnapshot.idle(),
    snapshots: _snapshots.stream,
  );

  @override
  Future<void> detach(String connectionId) async {}
}

/// A controller with none of the quality capability: the shape a backend that
/// resolves nothing has.
final class _PlainMedia implements MediaController {
  final _snapshots = StreamController<PlaybackSnapshot>.broadcast();

  @override
  Future<CommandResult> execute(PlaybackCommand command) async =>
      const CommandResult.accepted(1);

  @override
  Future<PlaybackSnapshot> getSnapshot() async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackConnection> attach() async => PlaybackConnection(
    id: 'plain',
    baseline: PlaybackSnapshot.idle(),
    snapshots: _snapshots.stream,
  );

  @override
  Future<void> detach(String connectionId) async {}
}
