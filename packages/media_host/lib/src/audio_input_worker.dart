part of 'media_core_ffi.dart';

/// The main isolate admits sources and owns persistence. Only this worker
/// touches compressed bytes and the native input callback during playback.
final class _InputWorkerHost {
  _InputWorkerHost(this.api, this.provider) {
    _messages.listen(_onMessage);
    _ready.future.ignore();
    unawaited(_start());
  }
  final FfiMediaCoreApi api;
  final AudioInputWorkerProvider provider;
  final _messages = ReceivePort();
  final _ready = Completer<void>();
  final _stopped = Completer<void>();
  final _released = Completer<void>();
  final Map<int, (AudioInputWorkerSource, ReceivePort, Completer<void>)>
  _sources = {};
  final Set<int> _opening = {};
  final Set<int> _cancelled = {};
  final Set<int> _retiring = {};
  SendPort? _commands;
  bool _closing = false;
  Future<void> get ready => _ready.future;

  Future<void> _start() async {
    try {
      await Isolate.spawn(_runInputWorker, [
        _messages.sendPort,
        api._libraryPath,
        api._player.address,
      ], debugName: 'fideflow-audio-input');
    } catch (error, stack) {
      _ready.completeError(error, stack);
      _stopped.complete();
      _released.complete();
      _messages.close();
    }
  }

  void _onMessage(dynamic message) {
    final data = message as List;
    switch (data[0]) {
      case 'ready':
        _commands = data[1] as SendPort;
        if (!_closing) {
          final code = api._inputBindings.setSink(
            api._player,
            Pointer<NativeFunction<_InputSinkNative>>.fromAddress(
              data[2] as int,
            ),
            nullptr,
          );
          if (code != MediaCoreCode.ok) {
            _ready.completeError(
              MediaCoreException(code, detail: 'input worker sink'),
            );
            return;
          }
        }
        _ready.complete();
      case 'startupError':
        _ready.completeError(StateError(data[1] as String));
        _stopped.complete();
        _released.complete();
      case 'open':
        unawaited(_open(data[1] as int, data[2] as int, data[3] as SendPort));
      case 'cancelOpen':
        final id = data[1] as int;
        if (_opening.contains(id)) {
          _cancelled.add(id);
        } else {
          unawaited(_closeSource(id));
        }
      case 'metrics':
        api.inputReadRequests += data[1] as int;
        api.inputBytesWritten += data[2] as int;
      case 'stopped':
        _stopped.complete();
      case 'released':
        _released.complete();
    }
  }

  Future<void> _open(int reader, int sourceId, SendPort response) async {
    _opening.add(reader);
    AudioInputWorkerSource? source;
    try {
      if (_closing) throw StateError('playback.cancelled');
      source = await provider.prepareAudioInputWorker(sourceId);
      if (_closing || _cancelled.contains(reader)) {
        throw StateError('playback.cancelled');
      }
      final events = ReceivePort();
      final admitted = source;
      events.listen((event) {
        if (event == null) {
          unawaited(_closeSource(reader));
        } else {
          admitted.onEvent(event);
        }
      });
      _sources[reader] = (source, events, Completer<void>());
      // Do not send the callbacks retaining the UI/cache owner to the worker.
      response.send([
        source.createReader,
        source.configuration,
        events.sendPort,
      ]);
    } catch (_) {
      if (_sources.containsKey(reader)) {
        await _closeSource(reader);
      } else if (source != null) {
        await source.onClose();
      }
      response.send(null);
    } finally {
      _opening.remove(reader);
      _cancelled.remove(reader);
    }
  }

  Future<void> _closeSource(int reader) async {
    final source = _sources[reader];
    if (source == null || !_retiring.add(reader)) return;
    source.$2.close();
    try {
      await source.$1.onClose();
    } finally {
      _sources.remove(reader);
      _retiring.remove(reader);
      source.$3.complete();
    }
  }

  Future<void> stop() async {
    _closing = true;
    try {
      await ready;
    } catch (_) {}
    _commands?.send('stop');
    await _stopped.future;
    await Future.wait(
      _sources.values.map((source) => source.$3.future).toList(),
    );
  }

  Future<void> release() async {
    _commands?.send('release');
    await _released.future;
    _messages.close();
  }
}

void _runInputWorker(List<Object> args) {
  final host = args[0] as SendPort;
  try {
    _InputWorker(host, args[1] as String, args[2] as int).start();
  } catch (error) {
    host.send(['startupError', '$error']);
  }
}

final class _InputWorker {
  _InputWorker(this.host, String library, int address)
    : bindings = _InputBindings(DynamicLibrary.open(library)),
      player = Pointer<FfPlayer>.fromAddress(address);
  final SendPort host;
  final _InputBindings bindings;
  final Pointer<FfPlayer> player;
  final commands = ReceivePort();
  final Map<int, Future<_InputReaderLease>> readers = {};
  int nextLease = 0;
  final Set<Future<void>> fills = {};
  late final NativeCallable<_InputSinkNative> callable;
  bool stopped = false;

  void start() {
    callable = NativeCallable<_InputSinkNative>.listener(_onInput);
    commands.listen((message) {
      if (message == 'stop') unawaited(_stop());
      if (message == 'release') {
        callable.close();
        commands.close();
        host.send(['released']);
      }
    });
    host.send(['ready', commands.sendPort, callable.nativeFunction.address]);
  }

  Future<_InputReaderLease> _open(int source) async {
    final reply = ReceivePort();
    final leaseId = ++nextLease;
    try {
      host.send(['open', leaseId, source, reply.sendPort]);
      final data =
          await reply.first.timeout(const Duration(seconds: 15)) as List?;
      if (data == null) throw StateError('playback.cancelled');
      final factory = data[0] as AudioInputReader Function(Object?, SendPort);
      final events = data[2] as SendPort;
      try {
        return _InputReaderLease(factory(data[1], events), events);
      } catch (_) {
        events.send(null);
        rethrow;
      }
    } catch (_) {
      host.send(['cancelOpen', leaseId]);
      rethrow;
    } finally {
      reply.close();
    }
  }

  void _onInput(
    int request,
    int source,
    int reader,
    int offset,
    Pointer<Void> user,
  ) {
    if (stopped) return;
    if (offset == -2 || offset == -3) {
      unawaited(_closeReader(reader));
      return;
    }
    final fill = _fill(request, source, reader, offset);
    fills.add(fill);
    unawaited(fill.whenComplete(() => fills.remove(fill)));
  }

  Future<void> _fill(int request, int source, int id, int offset) async {
    final output = calloc<_InputBuffer>();
    Pointer<Void> lease = nullptr;
    try {
      if (bindings.acquire(player, request, output) != MediaCoreCode.ok) return;
      lease = output.ref.lease;
      final reader = (await (readers[id] ??= _open(source))).reader;
      if (stopped) return;
      final count = offset < 0
          ? (await reader.length(), 0).$2
          : await reader.read(
              offset,
              output.ref.data.asTypedList(output.ref.capacity),
            );
      bindings.commit(
        lease,
        count,
        reader.totalBytes ?? -1,
        offset >= 0 && count == 0 ? 1 : 0,
      );
      lease = nullptr;
      host.send(['metrics', 1, count]);
    } catch (error) {
      if (lease != nullptr) {
        bindings.commit(lease, 0, -1, error is TimeoutException ? 4 : 3);
        lease = nullptr;
      }
    } finally {
      if (lease != nullptr) bindings.release(lease);
      calloc.free(output);
    }
  }

  Future<void> _closeReader(int id) async {
    final pending = readers.remove(id);
    if (pending == null) return;
    try {
      final lease = await pending;
      try {
        await lease.reader.close();
      } finally {
        lease.events.send(null);
      }
    } catch (_) {}
  }

  Future<void> _stop() async {
    stopped = true;
    for (final id in readers.keys.toList()) {
      await _closeReader(id);
    }
    await Future.wait(fills.toList());
    host.send(['stopped']);
  }
}

final class _InputReaderLease {
  const _InputReaderLease(this.reader, this.events);
  final AudioInputReader reader;
  final SendPort events;
}
