import 'dart:collection';

/// Bounded, payload-free control-plane diagnostics.
final class DiagnosticEvent {
  const DiagnosticEvent({
    required this.code,
    required this.elapsed,
    required this.sessionRevision,
  });

  final String code;
  final Duration elapsed;
  final int sessionRevision;
}

final class BoundedDiagnostics {
  BoundedDiagnostics({this.capacity = 512}) : assert(capacity > 0);

  final int capacity;
  final Stopwatch _clock = Stopwatch()..start();
  final Queue<DiagnosticEvent> _events = Queue();

  List<DiagnosticEvent> get events => List.unmodifiable(_events);

  void record(String code, int sessionRevision) {
    if (!RegExp(r'^[a-z][a-zA-Z0-9.]{0,63}$').hasMatch(code)) {
      throw ArgumentError.value(code, 'code', 'Expected a stable event code');
    }
    if (_events.length == capacity) _events.removeFirst();
    _events.add(
      DiagnosticEvent(
        code: code,
        elapsed: _clock.elapsed,
        sessionRevision: sessionRevision,
      ),
    );
  }
}

/// Numeric-only native output diagnostics suitable for a Flutter console.
final class OutputSampleRateLog {
  const OutputSampleRateLog._({
    required this.event,
    required this.systemRateHz,
    required this.sourceRateHz,
    required this.pcmRateHz,
    required this.targetRateHz,
    required this.resamplingEnabled,
    required this.exclusive,
  });

  final String event;
  final int? systemRateHz;
  final int? sourceRateHz;
  final int? pcmRateHz;
  final int targetRateHz;
  final bool resamplingEnabled;
  final bool exclusive;

  static const events = {
    'pcmConfigured',
    'configurationUpdated',
    'devicesRefreshed',
    'systemFormatChanged',
    'outputReady',
  };

  static OutputSampleRateLog? tryParse(Map<String, Object?> value) {
    bool rate(Object? v) => v == null || (v is int && v > 0 && v <= 2147483647);
    if (value['schemaVersion'] != 1 ||
        value['kind'] != 'outputSampleRates' ||
        !events.contains(value['event']) ||
        ![
          'systemRateHz',
          'sourceRateHz',
          'pcmRateHz',
        ].every((key) => value.containsKey(key) && rate(value[key])) ||
        value['targetRateHz'] is! int ||
        !rate(value['targetRateHz']) ||
        value['resamplingEnabled'] is! bool ||
        value['exclusive'] is! bool) {
      return null;
    }
    return OutputSampleRateLog._(
      event: value['event'] as String,
      systemRateHz: value['systemRateHz'] as int?,
      sourceRateHz: value['sourceRateHz'] as int?,
      pcmRateHz: value['pcmRateHz'] as int?,
      targetRateHz: value['targetRateHz'] as int,
      resamplingEnabled: value['resamplingEnabled'] as bool,
      exclusive: value['exclusive'] as bool,
    );
  }

  String toLogLine() =>
      'Fideflow audio event=$event '
      'system_rate_hz=${systemRateHz ?? 'unknown'} '
      'source_rate_hz=${sourceRateHz ?? 'unknown'} '
      'pcm_rate_hz=${pcmRateHz ?? 'unknown'} '
      'target_rate_hz=$targetRateHz '
      'resampling_enabled=$resamplingEnabled exclusive=$exclusive';
}
