import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../shared/artwork_service.dart';
import 'shortcut_config.dart';

abstract interface class PlayerPlatformBridge {
  Future<void> initialize(
    Future<bool> Function(String, double?) onAction, {
    void Function(String?)? onHotkeyError,
  });
  Future<Map<String, String>> configure(ShortcutConfig config);
  Future<void> suspend(bool value);
  Future<void> publish(Map<String, Object?> state);
  Future<void> artwork(String token, Uint8List bytes);
  Future<void> close();
}

final class ChannelPlayerPlatformBridge implements PlayerPlatformBridge {
  static const channel = MethodChannel('fideflow/player_controls');
  static String _nativeMessage(String value) => switch (value) {
    'controls.occupied' => UiMessages.hotkeyOccupied,
    'controls.layoutChanged' => UiMessages.hotkeyLayoutChanged,
    'controls.registration' => UiMessages.hotkeyRegistrationFailed,
    'controls.unsupportedAction' => UiMessages.unsupportedAction,
    'controls.unsupportedBinding' => UiMessages.unsupportedGlobalShortcut,
    'controls.duplicate' => UiMessages.duplicateShortcut,
    _ => UiMessages.hotkeyRegistrationFailed,
  };
  @override
  Future<void> initialize(
    Future<bool> Function(String, double?) onAction, {
    void Function(String?)? onHotkeyError,
  }) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'hotkeyError') {
        final value = call.arguments as String?;
        onHotkeyError?.call(value == null ? null : _nativeMessage(value));
        return null;
      }
      if (call.method != 'action') throw MissingPluginException();
      final args = Map<String, dynamic>.from(call.arguments as Map);
      return onAction(
        args['action'] as String,
        (args['position'] as num?)?.toDouble(),
      );
    });
  }

  @override
  Future<Map<String, String>> configure(ShortcutConfig config) async {
    final result = await channel.invokeMapMethod<String, String>(
      'configure',
      config.toJson(),
    );
    return {
      for (final entry in (result ?? <String, String>{}).entries)
        entry.key: _nativeMessage(entry.value),
    };
  }

  @override
  Future<void> suspend(bool value) => channel.invokeMethod('suspend', value);
  @override
  Future<void> publish(Map<String, Object?> state) =>
      channel.invokeMethod('publish', state);
  @override
  Future<void> artwork(String token, Uint8List bytes) =>
      channel.invokeMethod('artwork', {'token': token, 'bytes': bytes});
  @override
  Future<void> close() async {
    channel.setMethodCallHandler(null);
    await channel.invokeMethod<void>('dispose');
  }
}

final class PlayerControls extends ChangeNotifier {
  PlayerControls({
    required this.playback,
    required this.store,
    required this.bridge,
    this.music,
    this.auth,
    this.artworkService,
    this.artworkLoader,
    this.translate = _identity,
  });
  final BrowseAndPlayController playback;
  final ShortcutStore store;
  final PlayerPlatformBridge bridge;
  final AccountMusicController? music;
  final AuthController? auth;
  final ArtworkService? artworkService;
  final Future<Uint8List?> Function(Track)? artworkLoader;
  final String Function(String) translate;
  static String _identity(String value) => value;
  void refreshLocalization() => _publish();
  ShortcutConfig config = ShortcutConfig.defaults();
  String? error;
  bool recording = false,
      available = true,
      _closed = false,
      _favoriteBusy = false;
  Future<bool>? _writes, _commands;
  StreamSubscription<HomeState>? _playbackSub;
  StreamSubscription<AuthState>? _authSub;
  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;
  String? _coverKey;
  int _coverGeneration = 0;
  String get _owner =>
      '${auth?.current.session?.user.userId.value}:${auth?.current.session?.authEpoch}';

  Future<void> initialize() async {
    config = await store.read();
    if (_closed) return;
    try {
      await bridge.initialize(
        dispatch,
        onHotkeyError: (message) {
          if (_closed) return;
          error = message;
          notifyListeners();
        },
      );
      if (_closed) return;
      final failures = await bridge.configure(config);
      if (_closed) return;
      if (failures.isNotEmpty) {
        error = _registrationMessage(failures);
        config = config.copyWith(globalEnabled: false);
        await bridge.configure(config);
      }
    } on MissingPluginException {
      available = false;
    } catch (_) {
      available = false;
      error = UiMessages.couldNotInitializeSystemMediaControls;
    }
    if (_closed) return;
    _playbackSub = playback.states.listen((_) => _publish());
    _authSub = auth?.states.listen((_) => _publish());
    _publish();
    notifyListeners();
  }

  String _registrationMessage(Map<String, String> errors) => errors.entries
      .map((e) {
        final action = PlayerAction.values
            .where((a) => a.name == e.key)
            .firstOrNull;
        return '${action?.label ?? e.key}：${e.value}';
      })
      .join('；');

  /// Applies each edit to the latest successfully saved configuration.
  Future<bool> update(ShortcutConfig Function(ShortcutConfig) edit) {
    final result = (_writes ?? Future<bool>.value(true)).then<bool>((_) async {
      if (_closed) {
        return false;
      }
      final next = edit(config);
      error = next.validationError();
      if (error != null) {
        notifyListeners();
        return false;
      }
      final before = config;
      try {
        if (available) {
          final errors = await bridge.configure(next);
          if (_closed) return false;
          if (errors.isNotEmpty) {
            // A platform may have registered only a subset; restore intent.
            await bridge.configure(before);
            if (_closed) return false;
            error = _registrationMessage(errors);
            notifyListeners();
            return false;
          }
        } else if (next.globalEnabled) {
          error = UiMessages.globalShortcutsAreAvailableOnlyInSupportedNative;
          notifyListeners();
          return false;
        }
        try {
          await store.write(next);
        } catch (_) {
          if (available && !_closed) {
            await bridge.configure(before);
            // Re-enabling media controls cannot restore the native artwork
            // that disabling them cleared. Retire pending cover loads too.
            if (before.mediaEnabled != next.mediaEnabled) _coverKey = null;
            _publish();
          }
          rethrow;
        }
        if (_closed) return false;
        config = next;
        error = null;
        _publish();
        notifyListeners();
        return true;
      } catch (_) {
        if (_closed) return false;
        error = UiMessages.couldNotSaveShortcutsPleaseTryAgain;
        notifyListeners();
        return false;
      }
    });
    _writes = result;
    return result;
  }

  Future<void> setRecording(bool value) async {
    if (_closed) return;
    recording = value;
    notifyListeners();
    if (available) {
      try {
        await bridge.suspend(value);
      } catch (_) {
        error = UiMessages.couldNotRestoreGlobalShortcutsEnableThemAgain;
        notifyListeners();
      }
    }
  }

  void _message(String text) {
    if (!_closed) _messages.add(text);
  }

  Future<bool> dispatch(String action, double? position) {
    if (_closed || recording) return Future.value(false);
    if (action == 'favorite') return _favorite();
    final result = (_commands ?? Future<bool>.value(true)).then<bool>((
      _,
    ) async {
      if (_closed || recording) {
        return false;
      }
      final s = playback.current.playback;
      if (s.currentTrack == null &&
          ![
            'volumeUp',
            'volumeDown',
            'setVolume',
            'setLoopStatus',
            'setShuffle',
            'stop',
          ].contains(action)) {
        return false;
      }
      try {
        switch (action) {
          case 'toggle':
            await playback.togglePlayback();
          case 'play':
            await playback.play();
          case 'pause':
            await playback.pause();
          case 'stop':
            await playback.stop();
          case 'previous':
            await playback.skipPrevious();
          case 'next':
            await playback.skipNext();
          case 'volumeUp':
            await playback.setVolume(s.volume + 50);
          case 'volumeDown':
            await playback.setVolume(s.volume - 50);
          case 'setVolume':
            if (position == null || !position.isFinite) return false;
            await playback.setVolume((position.clamp(0.0, 1.0) * 1000).round());
          case 'setLoopStatus':
            final mode = switch (position) {
              0.0 => PlaybackMode.sequential,
              1.0 => PlaybackMode.repeatOne,
              2.0 => PlaybackMode.listLoop,
              _ => null,
            };
            if (mode == null) return false;
            await playback.setPlayMode(mode);
          case 'setShuffle':
            if (position != 0.0 && position != 1.0) return false;
            if (position == 1.0 && s.mode != PlaybackMode.shuffle) {
              await playback.setPlayMode(PlaybackMode.shuffle);
            } else if (position == 0.0 && s.mode == PlaybackMode.shuffle) {
              await playback.setPlayMode(PlaybackMode.listLoop);
            }
          case 'seek':
            final duration = s.duration ?? s.currentTrack!.duration;
            if (position == null ||
                !position.isFinite ||
                position < 0 ||
                duration <= Duration.zero) {
              return false;
            }
            await playback.seek(
              Duration(
                milliseconds: (position * 1000).round().clamp(
                  0,
                  duration.inMilliseconds,
                ),
              ),
            );
          default:
            return false;
        }
        return true;
      } catch (_) {
        _message(UiMessages.playbackFailedPleaseTryAgain);
        return false;
      }
    });
    _commands = result;
    return result;
  }

  Future<bool> _favorite() async {
    final track = playback.current.playback.currentTrack;
    final c = music;
    if (track == null || _favoriteBusy) return false;
    if (c == null || !c.isRemoteTrack(track.id)) {
      _message(UiMessages.onlyNeteaseCloudMusicTracksAreSupported);
      return false;
    }
    if (!c.authenticated) {
      _message(UiMessages.signInThroughAccountSettingsFirst);
      return false;
    }
    if (c.busy('likes')) return false;
    final owner = _owner;
    _favoriteBusy = true;
    try {
      if (c.favorite(track.id) == FavoriteState.unknown) {
        await c.loadFavorites();
      }
      if (_closed ||
          owner != _owner ||
          playback.current.playback.currentTrack?.id != track.id) {
        return false;
      }
      if (c.favorite(track.id) == FavoriteState.unknown) {
        _message(
          c.favoriteError ?? UiMessages.couldNotLoadFavoritesPleaseTryAgain,
        );
        return false;
      }
      final result = await c.setLiked(
        track.id,
        c.favorite(track.id) != FavoriteState.liked,
      );
      if (owner == _owner) _message(result.message);
      return result.success;
    } catch (_) {
      _message(UiMessages.couldNotUpdateFavoritesPleaseTryAgain);
      return false;
    } finally {
      _favoriteBusy = false;
    }
  }

  void _publish() {
    if (_closed || !available) return;
    final s = playback.current.playback;
    final switching =
        auth?.current.isSwitching == true || auth?.current.isSigningOut == true;
    final t = config.mediaEnabled && !switching ? s.currentTrack : null;
    final coverKey = t == null
        ? null
        : '$_owner:${s.sessionId}:${t.id.value}:${t.album.artworkUri}';
    final coverChanged = coverKey != _coverKey;
    if (coverChanged) {
      _coverKey = coverKey;
      ++_coverGeneration;
    }
    final token = '$_coverGeneration';
    final payload = <String, Object?>{
      'token': token,
      'hasTrack': t != null,
      'trayHasTrack': !switching && s.currentTrack != null,
      'title': t == null ? null : translate(t.title),
      'artist': t == null ? null : translate(t.artistLabel),
      'album': t == null ? null : translate(t.album.title),
      'duration':
          ((s.duration ?? t?.duration ?? Duration.zero).inMilliseconds / 1000),
      'position': s.position.inMilliseconds / 1000,
      'playing': s.isActuallyPlaying && !s.buffering,
      'status': s.status.name,
      'canSeek': t != null && (s.duration ?? t.duration) > Duration.zero,
      'volume': s.volume / 1000,
      'loopStatus': switch (s.mode) {
        PlaybackMode.repeatOne => 'Track',
        PlaybackMode.listLoop => 'Playlist',
        PlaybackMode.shuffle || PlaybackMode.sequential => 'None',
      },
      'shuffle': s.mode == PlaybackMode.shuffle,
    };
    unawaited(
      bridge.publish(payload).catchError((Object _) {
        _message(UiMessages.couldNotSyncSystemMediaInformation);
      }),
    );
    if (t != null && coverChanged) {
      unawaited(_loadCover(t, token, _coverGeneration));
    }
  }

  Future<void> _loadCover(Track track, String token, int generation) async {
    try {
      Uint8List? bytes;
      final loader = artworkLoader;
      if (loader != null) {
        bytes = await loader(track);
      } else {
        final service = artworkService, uri = track.album.artworkUri;
        if (service == null || uri == null) return;
        final data = await service.load(
          service.publicRequest(uri, ArtworkSizeBucket.px512),
        );
        if (data != null) bytes = Uint8List.fromList(data.bytes);
      }
      if (!_closed &&
          config.mediaEnabled &&
          generation == _coverGeneration &&
          bytes != null) {
        await bridge.artwork(token, bytes);
      }
    } catch (_) {
      /* A missing cover never interrupts audio. */
    }
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    ++_coverGeneration;
    await _playbackSub?.cancel();
    await _authSub?.cancel();
    // Cancel pending native permission requests before waiting for updates.
    if (available) {
      try {
        await bridge.close();
      } catch (_) {}
    }
    await _writes;
    await _commands;
    await _messages.close();
    super.dispose();
  }
}
