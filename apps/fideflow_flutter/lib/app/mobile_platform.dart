import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import 'app.dart';
import 'dependencies.dart';

final class MobileCredentialStorage implements SecureCredentialStorage {
  MobileCredentialStorage({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

Future<void> startMobileApplication() async {
  runApp(const _MobileStartup());
}

class _MobileStartup extends StatefulWidget {
  const _MobileStartup();
  @override
  State<_MobileStartup> createState() => _MobileStartupState();
}

class _MobileStartupState extends State<_MobileStartup> {
  AppDependencies? _dependencies;
  Object? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() => _error = null);
    AppDependencies? dependencies;
    try {
      final data = await getApplicationSupportDirectory();
      final cache = await getApplicationCacheDirectory();
      dependencies = AppDependencies.create(
        platformPaths: PlatformPaths(
          dataDirectory: data.path,
          cacheDirectory: cache.path,
        ),
      );
      await dependencies.prepare();
      await MobilePlaybackHost.initialize(dependencies);
      if (!mounted) {
        await dependencies.dispose();
        return;
      }
      setState(() => _dependencies = dependencies);
    } catch (error, stack) {
      debugPrint('Mobile playback startup failed: $error\n$stack');
      await dependencies?.dispose();
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = _dependencies;
    if (dependencies != null) return FideflowApp(dependencies: dependencies);
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          AppLocalizations.of(
                            context,
                          ).mobilePlaybackStartupFailed,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _start,
                          child: Text(AppLocalizations.of(context).retry),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One handler and one native session survive Activity visibility changes.
final class MobilePlaybackHost extends BaseAudioHandler {
  MobilePlaybackHost(
    this.dependencies,
    this.session, {
    this.executePlatformCommand,
    bool? android,
  }) : _android = android ?? Platform.isAndroid {
    _subscriptions.add(playbackStates(dependencies).listen(_publish));
    _publish(dependencies.homeController.current);
  }
  final Future<CommandResult> Function(PlaybackCommand)? executePlatformCommand;
  final bool _android;
  final AppDependencies dependencies;
  final AudioSession session;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _tail = Future.value();
  String? _interruption;
  bool _canResume = true;
  int _sequence = 0;
  bool _closed = false;
  Track? _publishedTrack;
  Duration? _publishedDuration;
  List<Track>? _publishedQueue;
  String get _owner =>
      '${dependencies.authController.current.session?.user.userId.value}:${dependencies.authController.current.session?.authEpoch}';
  String? _interruptedOwner;
  BrowseAndPlayController get playback => dependencies.homeController;

  static Future<MobilePlaybackHost> initialize(
    AppDependencies dependencies,
  ) async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    final handler = await AudioService.init<MobilePlaybackHost>(
      builder: () => MobilePlaybackHost(dependencies, session),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.moetaku.fideflow.playback',
        androidNotificationChannelName: 'Music playback',
        androidStopForegroundOnPause: true,
        androidNotificationOngoing: true,
      ),
    );
    dependencies.nativeController!.activatePlatformAudio = handler.activate;
    dependencies.closeMobilePlayback = handler.close;
    handler._subscriptions.add(
      AudioService.asyncError.listen((error) {
        debugPrint('Mobile media service error: $error');
      }),
    );
    dependencies.nativeController!.platformAudioCommandFinished = () async {
      if (handler._closed ||
          dependencies.nativeController!.platformAudioActivationPending) {
        return;
      }
      final snapshot = await dependencies.nativeController!.getSnapshot();
      if (dependencies.nativeController!.platformAudioActivationPending) return;
      handler._publish(HomeState(status: LoadStatus.ready, playback: snapshot));
      if (!snapshot.playWhenReady && handler._interruption == null) {
        await session.setActive(false);
      }
    };
    handler._subscriptions.add(
      session.interruptionEventStream.listen(
        (event) => handler._enqueue(() => handler.handleInterruption(event)),
      ),
    );
    handler._subscriptions.add(
      session.becomingNoisyEventStream.listen(
        (_) => handler._enqueue(() async {
          handler._canResume = false;
          await handler.pause();
        }),
      ),
    );
    handler._subscriptions.add(
      dependencies.authController.states.listen((_) {
        if (handler._interruptedOwner != handler._owner) {
          handler._canResume = false;
        }
      }),
    );
    handler._publish(dependencies.homeController.current);
    return handler;
  }

  static Stream<HomeState> playbackStates(AppDependencies dependencies) =>
      dependencies.homeController.states;

  Future<bool> activate() async {
    if (_closed) return false;
    // Start the media foreground service before requesting audio focus. Modern
    // Android refuses focus for a background app without an active service.
    playbackState.add(
      playbackState.value.copyWith(
        playing: true,
        processingState: AudioProcessingState.loading,
      ),
    );
    final allowed = await session.setActive(true);
    return !_closed && allowed;
  }

  void _enqueue(Future<void> Function() action) {
    _tail = _tail
        .then((_) async {
          if (!_closed) await action();
        })
        .catchError((Object error, StackTrace stack) {
          debugPrint('Mobile audio lifecycle failed: $error\n$stack');
        });
  }

  Future<void> _gain(int permille) async {
    await (executePlatformCommand ??
        dependencies.nativeController!.executeHostCommand)(
      SetTransientGain(
        commandId: 'mobile-gain-${++_sequence}',
        permille: permille,
      ),
    );
  }

  Future<void> handleInterruption(AudioInterruptionEvent event) async {
    if (_closed) return;
    if (event.type == AudioInterruptionType.duck) {
      await _gain(event.begin ? 200 : 1000);
      return;
    }
    if (event.begin) {
      await _gain(1000);
      if (_android && event.type == AudioInterruptionType.unknown) {
        // Permanent loss has no guaranteed matching gain event. End the native
        // limit paused so a later explicit play can request focus and succeed.
        final id = _interruption ?? 'mobile-${++_sequence}';
        _canResume = false;
        await playback.setInterruption(id, active: true);
        await playback.pause();
        await playback.setInterruption(id, active: false, allowResume: false);
        _interruption = null;
        _interruptedOwner = null;
        await session.setActive(false);
        return;
      }
      if (_interruption != null) return;
      _interruption = 'mobile-${++_sequence}';
      _interruptedOwner = _owner;
      _canResume = true;
      await playback.setInterruption(_interruption!, active: true);
    } else {
      final id = _interruption;
      if (id == null) return;
      final resume =
          _canResume &&
          _owner == _interruptedOwner &&
          playback.current.playback.playWhenReady &&
          event.type == AudioInterruptionType.pause;
      // Clear suppression even if activation is refused; the explicit resume
      // flag keeps that path paused rather than leaving an orphaned limit.
      final allowed = resume && await activate();
      final result = await playback.setInterruption(
        id,
        active: false,
        allowResume: allowed,
      );
      if (!result.isAccepted) {
        // A concurrent account transition may refuse the activation-gated end.
        // The host must still clear its old limit, without requesting playback.
        await playback.setInterruption(id, active: false, allowResume: false);
      }
      _interruption = null;
      _interruptedOwner = null;
      if (!allowed || !playback.current.playback.playWhenReady) {
        await session.setActive(false);
      }
    }
  }

  void _publish(HomeState state) {
    if (_closed ||
        dependencies.nativeController?.platformAudioActivationPending == true) {
      return;
    }
    final snapshot = state.playback;
    final track = snapshot.currentTrack;
    if (track == null) {
      if (_publishedTrack != null) mediaItem.add(null);
      _publishedTrack = null;
      _publishedDuration = null;
    } else if (_publishedTrack == null ||
        !_sameQueueTrack(_publishedTrack!, track) ||
        _publishedTrack!.album.title != track.album.title ||
        _publishedTrack!.album.artworkUri != track.album.artworkUri ||
        _publishedDuration != (snapshot.duration ?? track.duration)) {
      mediaItem.add(
        MediaItem(
          id: track.id.value,
          title: track.title,
          artist: track.artists.map((artist) => artist.name).join(', '),
          album: track.album.title,
          duration: snapshot.duration ?? track.duration,
          artUri: track.album.artworkUri,
        ),
      );
      _publishedTrack = track;
      _publishedDuration = snapshot.duration ?? track.duration;
    }
    // Progress snapshots arrive throughout playback. Only resend metadata and
    // the full queue when their published fields change; Android otherwise
    // rebuilds media-session objects and notifications on every progress tick.
    final previousQueue = _publishedQueue;
    if (previousQueue == null || !_sameQueue(previousQueue, snapshot.queue)) {
      queue.add(
        snapshot.queue
            .map(
              (track) => MediaItem(
                id: track.id.value,
                title: track.title,
                artist: track.artists.map((artist) => artist.name).join(', '),
                duration: track.duration,
              ),
            )
            .toList(),
      );
      _publishedQueue = List.unmodifiable(snapshot.queue);
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          snapshot.playWhenReady && snapshot.errorCode == null
              ? MediaControl.pause
              : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: snapshot.errorCode != null
            ? AudioProcessingState.error
            : track == null || snapshot.phase == WirePhase.idle
            ? AudioProcessingState.idle
            : snapshot.isPreparing
            ? AudioProcessingState.loading
            : snapshot.buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        // Keep the foreground service while fetching, buffering or interrupted.
        playing: snapshot.playWhenReady && snapshot.errorCode == null,
        updatePosition: snapshot.position,
        queueIndex: snapshot.currentIndex,
        speed: snapshot.isActuallyPlaying ? 1 : 0,
        errorMessage: snapshot.errorCode,
      ),
    );
  }

  static bool _sameQueue(List<Track> previous, List<Track> next) {
    if (previous.length != next.length) return false;
    for (var i = 0; i < previous.length; i++) {
      if (!_sameQueueTrack(previous[i], next[i])) return false;
    }
    return true;
  }

  static bool _sameQueueTrack(Track previous, Track next) {
    if (previous.id != next.id ||
        previous.title != next.title ||
        previous.duration != next.duration ||
        previous.artists.length != next.artists.length) {
      return false;
    }
    for (var i = 0; i < previous.artists.length; i++) {
      if (previous.artists[i].name != next.artists[i].name) return false;
    }
    return true;
  }

  Future<void> _dispatch(Future<void> Function() action) async {
    if (!_closed) await action();
  }

  @override
  Future<void> play() => _dispatch(playback.play);
  @override
  Future<void> pause() => _dispatch(playback.pause);
  @override
  Future<void> seek(Duration position) =>
      _dispatch(() => playback.seek(position));
  @override
  Future<void> skipToNext() => _dispatch(playback.skipNext);
  @override
  Future<void> skipToPrevious() => _dispatch(playback.skipPrevious);
  @override
  Future<void> skipToQueueItem(int index) =>
      _dispatch(() => playback.playQueueItem(index));
  @override
  Future<void> stop() async {
    if (_closed) return;
    _canResume = false;
    await playback.stop();
    await _gain(1000);
    await session.setActive(false);
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  @override
  Future<void> onTaskRemoved() async {
    /* Active foreground playback continues. */
  }
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    dependencies.nativeController?.activatePlatformAudio = null;
    dependencies.nativeController?.platformAudioCommandFinished = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _tail;
    await _gain(1000);
    await session.setActive(false);
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }
}
