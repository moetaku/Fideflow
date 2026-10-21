import 'package:audio_session/audio_session.dart';
import 'package:fideflow/app/dependencies.dart';
import 'package:fideflow/app/mobile_platform.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends Fake implements AudioSession {
  bool allowed = true;
  final activations = <bool>[];
  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration? fallbackConfiguration,
  }) async {
    activations.add(active);
    return !active || allowed;
  }
}

class _EndGate implements MediaController {
  _EndGate(this.delegate);
  final MediaController delegate;
  bool denyResume = false;
  @override
  Future<CommandResult> execute(PlaybackCommand command) async {
    if (denyResume &&
        command is SetInterruption &&
        !command.active &&
        command.allowResume) {
      return const CommandResult.rejected('cancelled');
    }
    return delegate.execute(command);
  }

  @override
  Future<PlaybackSnapshot> getSnapshot() => delegate.getSnapshot();
  @override
  Future<PlaybackConnection> attach() => delegate.attach();
  @override
  Future<void> detach(String connectionId) => delegate.detach(connectionId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(
    id: TrackId('one'),
    title: 'One',
    artists: [],
    album: Album(id: AlbumId('a'), title: 'A'),
    duration: Duration(minutes: 3),
  );
  late FakeMediaController media;
  late _EndGate gate;
  late AppDependencies dependencies;
  late MobilePlaybackHost host;
  late _Session session;
  late List<PlaybackCommand> commands;
  setUp(() async {
    media = FakeMediaController();
    gate = _EndGate(media);
    final playback = BrowseAndPlayController(
      FakeCatalogRepository(latency: Duration.zero),
      gate,
    );
    await playback.initialize(prefetchPlaylist: false);
    await media.execute(
      const LoadQueue(commandId: 'load', tracks: [track], autoplay: true),
    );
    dependencies = AppDependencies.forTesting(homeController: playback);
    session = _Session();
    commands = [];
    host = MobilePlaybackHost(
      dependencies,
      session,
      android: false,
      executePlatformCommand: (command) {
        commands.add(command);
        return media.execute(command);
      },
    );
  });
  tearDown(() async {
    await host.close();
    await dependencies.dispose();
  });
  test(
    'progress updates preserve metadata and queue while position advances',
    () async {
      final items = <String?>[];
      final queues = <List<String>>[];
      final positions = <Duration>[];
      final itemSubscription = host.mediaItem.listen(
        (item) => items.add(item?.id),
      );
      final queueSubscription = host.queue.listen(
        (queue) => queues.add(queue.map((item) => item.id).toList()),
      );
      final stateSubscription = host.playbackState.listen(
        (state) => positions.add(state.updatePosition),
      );
      addTearDown(itemSubscription.cancel);
      addTearDown(queueSubscription.cancel);
      addTearDown(stateSubscription.cancel);
      await Future<void>.delayed(Duration.zero);
      final originalItem = host.mediaItem.value;
      final originalQueue = host.queue.value;
      final itemCount = items.length;
      final queueCount = queues.length;
      final stateCount = positions.length;

      for (var i = 1; i <= 20; i++) {
        await host.seek(Duration(milliseconds: i * 500));
      }
      await Future<void>.delayed(Duration.zero);

      expect(items.length, itemCount);
      expect(queues.length, queueCount);
      expect(identical(host.mediaItem.value, originalItem), isTrue);
      expect(identical(host.queue.value, originalQueue), isTrue);
      expect(positions.length, greaterThan(stateCount));
      expect(positions.last, const Duration(seconds: 10));
      await host.pause();
      await Future<void>.delayed(Duration.zero);
      expect(host.playbackState.value.playing, isFalse);
      expect(items.length, itemCount);
      expect(queues.length, queueCount);
    },
  );

  test(
    'metadata changes for the same track refresh the system media item',
    () async {
      const updated = Track(
        id: TrackId('one'),
        title: 'Updated title',
        artists: [Artist(id: ArtistId('artist'), name: 'Artist')],
        album: Album(id: AlbumId('a'), title: 'Updated album'),
        duration: Duration(minutes: 4),
      );
      await media.execute(
        const LoadQueue(
          commandId: 'metadata',
          tracks: [updated],
          autoplay: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(host.mediaItem.value?.title, 'Updated title');
      expect(host.mediaItem.value?.artist, 'Artist');
      expect(host.mediaItem.value?.album, 'Updated album');
      expect(host.mediaItem.value?.duration, const Duration(minutes: 4));
      expect(host.queue.value.single.title, 'Updated title');
      expect(host.queue.value.single.artist, 'Artist');
    },
  );

  test(
    'switching duplicate queue entries updates the index without resending metadata',
    () async {
      await media.execute(
        const LoadQueue(
          commandId: 'duplicates',
          tracks: [track, track],
          autoplay: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final originalItem = host.mediaItem.value;
      final originalQueue = host.queue.value;
      expect(originalQueue.length, 2);
      await host.skipToQueueItem(1);
      await Future<void>.delayed(Duration.zero);
      expect(host.playbackState.value.queueIndex, 1);
      expect(identical(host.mediaItem.value, originalItem), isTrue);
      expect(identical(host.queue.value, originalQueue), isTrue);
    },
  );
  test(
    'system-approved interruption restores the same playback intent',
    () async {
      await host.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      expect((await media.getSnapshot()).isActuallyPlaying, isFalse);
      await host.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect((await media.getSnapshot()).isActuallyPlaying, isTrue);
    },
  );
  test(
    'album artwork updates refresh metadata without resending the queue',
    () async {
      final originalQueue = host.queue.value;
      final artwork = Uri.parse('https://example.com/updated.jpg');
      final updated = Track(
        id: track.id,
        title: track.title,
        artists: track.artists,
        album: Album(
          id: track.album.id,
          title: 'New album',
          artworkUri: artwork,
        ),
        duration: track.duration,
      );
      await media.execute(
        LoadQueue(commandId: 'artwork', tracks: [updated], autoplay: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(host.mediaItem.value?.album, 'New album');
      expect(host.mediaItem.value?.artUri, artwork);
      expect(identical(host.queue.value, originalQueue), isTrue);
    },
  );

  test('clearing the queue removes stale system metadata', () async {
    expect(host.mediaItem.value, isNotNull);
    await media.execute(const ClearQueue(commandId: 'clear'));
    await Future<void>.delayed(Duration.zero);
    expect(host.mediaItem.value, isNull);
    expect(host.queue.value, isEmpty);
    expect(host.playbackState.value.queueIndex, isNull);
    expect(host.playbackState.value.playing, isFalse);
  });

  test('system refusing resume clears the limit but stays paused', () async {
    await host.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.unknown),
    );
    await host.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.unknown),
    );
    final snapshot = await media.getSnapshot();
    expect(snapshot.playWhenReady, isFalse);
    expect(snapshot.suppressionReasons, isEmpty);
  });
  test('user pause during interruption prevents automatic playback', () async {
    await host.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await host.pause();
    await host.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect((await media.getSnapshot()).playWhenReady, isFalse);
    expect(session.activations.where((active) => active), isEmpty);
  });
  test('denied focus ends suppression without resuming', () async {
    await host.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.allowed = false;
    await host.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    final snapshot = await media.getSnapshot();
    expect(snapshot.playWhenReady, isFalse);
    expect(snapshot.suppressionReasons, isEmpty);
  });
  test(
    'permanent Android loss stays paused but permits a later explicit play',
    () async {
      final execute = host.executePlatformCommand;
      await host.close();
      host = MobilePlaybackHost(
        dependencies,
        session,
        android: true,
        executePlatformCommand: execute,
      );
      await host.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await host.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      var snapshot = await media.getSnapshot();
      expect(snapshot.playWhenReady, isFalse);
      expect(snapshot.suppressionReasons, isEmpty);
      await host.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect((await media.getSnapshot()).playWhenReady, isFalse);
      await host.play();
      snapshot = await media.getSnapshot();
      expect(snapshot.isActuallyPlaying, isTrue);
    },
  );

  test(
    'a rejected automatic recovery still clears the old native limit',
    () async {
      await host.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      gate.denyResume = true;
      await host.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      final snapshot = await media.getSnapshot();
      expect(snapshot.playWhenReady, isFalse);
      expect(snapshot.suppressionReasons, isEmpty);
      await host.play();
      expect((await media.getSnapshot()).isActuallyPlaying, isTrue);
    },
  );

  test(
    'closed host ignores late media actions and interruption events',
    () async {
      await host.pause();
      await host.close();
      final count = commands.length;
      final position = (await media.getSnapshot()).position;
      await host.play();
      await host.seek(const Duration(seconds: 40));
      await host.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(commands.length, count);
      final snapshot = await media.getSnapshot();
      expect(snapshot.playWhenReady, isFalse);
      expect(snapshot.position, position);
    },
  );

  test('ducking is transient and leaves user volume intact', () async {
    final volume = (await media.getSnapshot()).volume;
    await host.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await host.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    expect(
      commands.whereType<SetTransientGain>().map((command) => command.permille),
      [200, 1000],
    );
    expect((await media.getSnapshot()).volume, volume);
  });
  test('duplicate begin and end events are idempotent', () async {
    for (var i = 0; i < 2; i++) {
      await host.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
    }
    for (var i = 0; i < 2; i++) {
      await host.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
    }
    expect((await media.getSnapshot()).isActuallyPlaying, isTrue);
    await host.close();
    await host.close();
  });
}
