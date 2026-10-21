import 'dart:isolate';
import 'dart:typed_data';

/// Compressed audio only. EOF is read=0; unknown length remains null.
abstract interface class AudioInputReader {
  int? get totalBytes;

  /// May initialize upstream metadata; null is an unknown length.
  Future<int?> length();

  /// Reads at an absolute byte offset. Short reads are valid; zero is EOF.
  /// Do not retain or mutate [destination] after this future completes: it is
  /// a borrowed native buffer. Only one read per reader may be in flight.
  Future<int> read(int offset, Uint8List destination);

  /// Idempotent; cancels pending I/O and completes any outstanding read.
  Future<void> close();
}

abstract interface class AudioInputTransport {
  void registerAudioInput(int sourceId);
  void revokeAudioInput(int sourceId);
}

abstract interface class AudioInputProvider {
  void bindAudioInputTransport(AudioInputTransport transport);
  Future<AudioInputReader> openAudioInput(int sourceId);
}

abstract interface class AudioInputApi implements AudioInputTransport {
  void bindAudioInputProvider(AudioInputProvider provider);
}

/// An admitted, transferable reader configuration. The factory must be a
/// top-level/static function; configuration must contain only sendable data.
/// Events carry optional persistence work back to the owner, never PCM or a
/// request that must finish before the next audio read.
final class AudioInputWorkerSource {
  const AudioInputWorkerSource({
    required this.configuration,
    required this.createReader,
    required this.onEvent,
    required this.onClose,
  });
  final Object? configuration;
  final AudioInputReader Function(Object?, SendPort) createReader;
  final void Function(Object?) onEvent;
  final Future<void> Function() onClose;
}

abstract interface class AudioInputWorkerProvider
    implements AudioInputProvider {
  Future<AudioInputWorkerSource> prepareAudioInputWorker(int sourceId);
}

abstract interface class AudioInputWorkerTransport
    implements AudioInputTransport {
  Future<void> get audioInputReady;
}
