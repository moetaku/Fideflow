// Test-only entrypoint for tooling/native/linux/desktop_smoke.py. It exercises
// the real Linux native channel without constructing the production app graph.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('fideflow/player_controls');
const _desktopChannel = MethodChannel('fideflow/desktop');
const _trackToken = 'fixture/token:track-#1';
const _duration = 240.75;

final _state = <String, Object?>{
  'token': _trackToken,
  'hasTrack': true,
  'trayHasTrack': true,
  'title': 'Harness: punctuation / title',
  'artist': 'Fideflow Fixture',
  'album': 'MPRIS Test Suite',
  'duration': _duration,
  'position': 12.5,
  'playing': true,
  'status': 'playing',
  'canSeek': true,
  'volume': 0.4,
  'shuffle': false,
  'loopStatus': 'None',
};

// A valid 1x1 PNG. Native writes these bytes to its private artwork cache.
final _artwork = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  207,
  192,
  240,
  31,
  0,
  5,
  0,
  1,
  255,
  137,
  153,
  61,
  29,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mediaEnabled =
      Platform.environment['FIDEFLOW_TEST_MEDIA_DISABLED'] != '1';
  _desktopChannel.setMethodCallHandler((call) async {
    if (call.method == 'quit') return true;
    if (call.method == 'closeRequested') return 'quit';
    throw MissingPluginException();
  });
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'hotkeyError') return null;
    if (call.method != 'action') throw MissingPluginException();
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final action = args['action'] as String;
    switch (action) {
      case 'toggle':
        _state['playing'] = !(_state['playing'] as bool);
        _state['status'] = (_state['playing'] as bool) ? 'playing' : 'paused';
        break;
      case 'play':
        _state['playing'] = true;
        _state['status'] = 'playing';
        break;
      case 'pause':
        _state['playing'] = false;
        _state['status'] = 'paused';
        break;
      case 'stop':
        _state['playing'] = false;
        _state['status'] = 'stopped';
        break;
      case 'seek':
        final position = (args['position'] as num?)?.toDouble();
        if (position == null || !position.isFinite || position < 0) {
          return false;
        }
        _state['position'] = position.clamp(0, _duration);
        break;
      case 'setVolume':
        final value = (args['position'] as num?)?.toDouble();
        if (value == null || !value.isFinite || value < 0 || value > 1) {
          return false;
        }
        _state['volume'] = value;
        break;
      case 'setShuffle':
        _state['shuffle'] = args['position'] == 1;
        break;
      case 'setLoopStatus':
        const values = ['None', 'Track', 'Playlist'];
        final index = (args['position'] as num?)?.toInt();
        if (index == null || index < 0 || index >= values.length) return false;
        _state['loopStatus'] = values[index];
        break;
      case 'next':
      case 'previous':
        _state['position'] = 0.0;
        break;
      default:
        return false;
    }
    await _channel.invokeMethod<void>('publish', _state);
    return true;
  });

  await _channel.invokeMethod<Map<Object?, Object?>>('configure', {
    'version': 1,
    'globalEnabled': false,
    'mediaEnabled': mediaEnabled,
    'local': <String, Object?>{},
    'global': <String, Object?>{},
  });
  await _channel.invokeMethod<void>('publish', _state);
  await _channel.invokeMethod<void>('artwork', {
    'token': _trackToken,
    'bytes': _artwork,
  });
  await _desktopChannel.invokeMethod<bool>('initialize');
  runApp(const SizedBox.shrink());
}
