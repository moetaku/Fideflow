import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'audio_input.dart';
import 'library_locator.dart';
import 'media_core_api.dart';
import 'ncm_host_transport.dart';

part 'audio_input_worker.dart';

/// Owned UTF-8 bytes, the layout of `ff_owned_bytes_t` in `schemas/media_core.h`.
final class FfOwnedBytes extends Struct {
  /// Buffer base, or null when empty.
  external Pointer<Uint8> data;

  /// Buffer length in bytes.
  @IntPtr()
  external int len;
}

/// The opaque session handle (`ff_player_t`).
final class FfPlayer extends Opaque {}

/// Independent in-process NCM Host handle.
final class FfNcmHost extends Opaque {}

/// The C event sink signature: `void (*)(uint8_t *, size_t, void *)`.
typedef _EventSinkNative = Void Function(Pointer<Uint8>, IntPtr, Pointer<Void>);

typedef _AbiVersionNative = Uint32 Function();
typedef _PlayerNewNative = Pointer<FfPlayer> Function();
typedef _PlayerFreeNative = Void Function(Pointer<FfPlayer>);
typedef _SetEventSinkNative =
    Uint32 Function(
      Pointer<FfPlayer>,
      Pointer<NativeFunction<_EventSinkNative>>,
      Pointer<Void>,
    );
typedef _InBytesOutNative =
    Uint32 Function(
      Pointer<FfPlayer>,
      Pointer<Uint8>,
      IntPtr,
      Pointer<FfOwnedBytes>,
    );
typedef _InIdNative =
    Uint32 Function(Pointer<FfPlayer>, Pointer<Uint8>, IntPtr);
typedef _SnapshotNative =
    Uint32 Function(Pointer<FfPlayer>, Pointer<FfOwnedBytes>);
typedef _ExecuteNative =
    Uint32 Function(
      Pointer<FfPlayer>,
      Pointer<Uint8>,
      IntPtr,
      Uint32,
      Pointer<FfOwnedBytes>,
    );
typedef _BytesFreeNative = Void Function(FfOwnedBytes);
typedef _ConfigureCheckpointNative =
    Uint32 Function(
      Pointer<FfPlayer>,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
    );
typedef _RestoreCheckpointNative =
    Uint32 Function(
      Pointer<FfPlayer>,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint32>,
    );
typedef _PlayerCommandNative = Uint32 Function(Pointer<FfPlayer>);
typedef _CapabilitiesJsonNative = FfOwnedBytes Function();

/// ABI version this Dart host speaks. A library that reports anything else is
/// refused instead of guessed at (docs/design/boundaries.md). It must track the header's
/// `FF_MEDIA_CORE_ABI_VERSION` and the Rust `ABI_VERSION`, which the contract
/// check enforces for all three (issue 1).
const supportedAbiVersion = 3;

/// The real host: `dart:ffi` over the packaged Rust dynamic library.
///
/// Threading: the library serialises commands itself, so every call here may run
/// on any isolate. Events arrive on the session's publisher thread and are
/// delivered to this isolate through a `NativeCallable.listener`, which is why
/// the ABI transfers ownership of each event buffer instead of lending it: the
/// listener's body runs on the isolate's event loop, after the library's call has
/// already returned.
final class FfiMediaCoreApi
    implements
        MediaCoreApi,
        AudioInputApi,
        AudioInputWorkerTransport,
        AsyncMediaCoreApi,
        NcmHostApi {
  FfiMediaCoreApi._();

  /// Opens the packaged library and creates a session.
  ///
  /// Throws [MediaCoreException] when the library is missing, does not export the
  /// documented symbols, reports a different ABI version, or cannot create a
  /// session.
  factory FfiMediaCoreApi.open({String? libraryPath}) {
    final path = libraryPath ?? resolveMediaCoreLibraryPath();
    if (path == null) {
      throw const MediaCoreException(
        MediaCoreCode.unsupported,
        detail: 'no native media host for this platform',
      );
    }
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(path);
    } on ArgumentError catch (error) {
      throw MediaCoreException(
        MediaCoreCode.unsupported,
        detail: 'cannot load $path: $error',
      );
    }
    return FfiMediaCoreApi._().._start(library, path);
  }

  late final DynamicLibrary _library;
  _NcmBindings? _ncmBindings;
  Pointer<FfNcmHost>? _ncmHost;
  NativeCallable<_EventSinkNative>? _ncmCallable;
  void Function(String)? _ncmSink;
  int _ncmDelivered = 0;
  int? _ncmExpected;

  @override
  bool get supportsNcmHost {
    final capability = capabilities()['ncmHost'];
    return capability is Map && capability['schemaVersion'] == 1;
  }

  @override
  void openNcmHost(void Function(String) onEvent) {
    _ensureOpen();
    if (_ncmHost != null || _ncmCallable != null) {
      throw const MediaCoreException(MediaCoreCode.invalidArgument);
    }
    if (!supportsNcmHost) {
      throw const MediaCoreException(MediaCoreCode.unsupported);
    }
    final _NcmBindings bindings;
    try {
      bindings = _ncmBindings ??= _NcmBindings(_library);
    } on ArgumentError {
      throw const MediaCoreException(MediaCoreCode.unsupported);
    }
    final out = calloc<Pointer<FfNcmHost>>();
    try {
      _throwOnFailure(bindings.create(out), 'ncmHost.new');
      _ncmHost = out.value;
      _ncmSink = onEvent;
      _ncmDelivered = 0;
      _ncmExpected = null;
      _ncmCallable = NativeCallable<_EventSinkNative>.listener((
        Pointer<Uint8> json,
        int length,
        Pointer<Void> user,
      ) {
        final descriptor = calloc<FfOwnedBytes>();
        try {
          descriptor.ref
            ..data = json
            ..len = length;
          if (_ncmSink != null && json != nullptr && length > 0) {
            _ncmSink!(utf8.decode(json.asTypedList(length)));
          }
        } finally {
          _bindings.bytesFree(descriptor.ref);
          calloc.free(descriptor);
          _ncmDelivered++;
          _closeNcmListenerWhenDrained();
        }
      });
      _throwOnFailure(
        bindings.sink(_ncmHost!, _ncmCallable!.nativeFunction, nullptr),
        'ncmHost.sink',
      );
    } on Object {
      closeNcmHost();
      rethrow;
    } finally {
      calloc.free(out);
    }
  }

  void _ncmCall(String text, bool cancel) {
    _ensureOpen();
    final host = _ncmHost;
    if (host == null) throw const MediaCoreException(MediaCoreCode.nullHandle);
    final bytes = utf8.encode(text);
    final pointer = calloc<Uint8>(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      final bindings = _ncmBindings!;
      _throwOnFailure(
        (cancel ? bindings.cancel : bindings.submit)(
          host,
          pointer,
          bytes.length,
        ),
        'ncmHost.request',
      );
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  void submitNcmHost(String document) => _ncmCall(document, false);
  @override
  void cancelNcmHost(String requestId) => _ncmCall(requestId, true);
  @override
  void closeNcmHost() {
    final host = _ncmHost;
    if (host == null) return;
    _ncmHost = null;
    _ncmSink = null;
    _ncmBindings!.sink(host, nullptr, nullptr);
    _ncmExpected = _ncmBindings!.deliveries(host);
    _ncmBindings!.free(host);
    _closeNcmListenerWhenDrained();
  }

  void _closeNcmListenerWhenDrained() {
    if (_ncmExpected == null || _ncmDelivered != _ncmExpected) return;
    _ncmCallable?.close();
    _ncmCallable = null;
  }

  late final _Bindings _bindings;
  late final _InputBindings _inputBindings;
  AudioInputProvider? _inputProvider;
  Zone _inputZone = Zone.current;
  NativeCallable<_InputSinkNative>? _inputCallable;
  final Map<int, Future<AudioInputReader>> _inputReaders = {};
  int inputReadRequests = 0;
  int inputBytesWritten = 0;
  _InputWorkerHost? _inputWorker;
  late String _libraryPath;
  Future<void>? _closeFuture;

  @override
  Future<void> get audioInputReady => _inputWorker?.ready ?? Future.value();

  @override
  void bindAudioInputProvider(AudioInputProvider provider) {
    _ensureOpen();
    if (identical(_inputProvider, provider)) return;
    if (_inputProvider != null) throw StateError('audio.providerAlreadyBound');
    _inputProvider = provider;
    _inputZone = Zone.current;
    if (provider is AudioInputWorkerProvider) {
      _inputWorker = _InputWorkerHost(this, provider);
      provider.bindAudioInputTransport(this);
      return;
    }
    _inputCallable ??= NativeCallable<_InputSinkNative>.listener(_onInput);
    _throwOnFailure(
      _inputBindings.setSink(_player, _inputCallable!.nativeFunction, nullptr),
      'inputSetSink',
    );
    provider.bindAudioInputTransport(this);
  }

  @override
  void registerAudioInput(int sourceId) {
    _ensureOpen();
    _throwOnFailure(
      _inputBindings.register(_player, sourceId),
      'inputRegister',
    );
  }

  @override
  void revokeAudioInput(int sourceId) {
    if (!_closed) {
      _throwOnFailure(_inputBindings.revoke(_player, sourceId), 'inputRevoke');
    }
  }

  void _onInput(
    int request,
    int source,
    int reader,
    int offset,
    Pointer<Void> user,
  ) {
    if (_closed) return;
    if (!identical(Zone.current, _inputZone)) {
      _inputZone.run(() => _onInput(request, source, reader, offset, user));
      return;
    }
    if (offset == -2 || offset == -3) {
      final pending = _inputReaders.remove(reader);
      if (pending != null) {
        unawaited(pending.then((r) => r.close(), onError: (Object _) {}));
      }
      return;
    }
    unawaited(_fillInput(request, source, reader, offset));
  }

  Future<void> _fillInput(
    int request,
    int source,
    int readerId,
    int offset,
  ) async {
    final provider = _inputProvider;
    if (_closed || provider == null) return;
    final output = calloc<_InputBuffer>();
    Pointer<Void> lease = nullptr;
    try {
      if (_inputBindings.acquire(_player, request, output) !=
          MediaCoreCode.ok) {
        return;
      }
      lease = output.ref.lease;
      final reader = await (_inputReaders[readerId] ??= provider.openAudioInput(
        source,
      ));
      if (_closed) return;
      int count;
      if (offset < 0) {
        await reader.length();
        count = 0;
      } else {
        count = await reader.read(
          offset,
          output.ref.data.asTypedList(output.ref.capacity),
        );
      }
      inputReadRequests++;
      inputBytesWritten += count;
      // commit consumes the independent lease, even if the player was freed.
      _inputBindings.commit(
        lease,
        count,
        reader.totalBytes ?? -1,
        offset >= 0 && count == 0 ? 1 : 0,
      );
      lease = nullptr;
    } catch (error) {
      if (lease != nullptr) {
        _inputBindings.commit(lease, 0, -1, error is TimeoutException ? 4 : 3);
        lease = nullptr;
      }
    } finally {
      if (lease != nullptr) _inputBindings.release(lease);
      calloc.free(output);
    }
  }

  late final Pointer<FfPlayer> _player;
  NativeCallable<_EventSinkNative>? _callable;
  void Function(String message)? _sink;
  bool _closed = false;

  void _start(DynamicLibrary library, String path) {
    _libraryPath = path;
    _library = library;
    _bindings = _Bindings(library);
    _inputBindings = _InputBindings(library);
    final version = _bindings.abiVersion();
    if (version != supportedAbiVersion) {
      throw MediaCoreException(
        MediaCoreCode.unsupported,
        detail:
            '$path speaks ABI $version, this host speaks $supportedAbiVersion',
      );
    }
    final player = _bindings.playerNew();
    if (player == nullptr) {
      throw const MediaCoreException(
        MediaCoreCode.internal,
        detail: 'the library could not create a session',
      );
    }
    _player = player;
    _callable = NativeCallable<_EventSinkNative>.listener(_onEvent);
  }

  @override
  int get abiVersion => _bindings.abiVersion();

  @override
  Map<String, Object?> capabilities() =>
      _decodeJson(_takeOwned(_bindings.capabilities()));

  @override
  void setEventSink(void Function(String message)? sink) {
    _ensureOpen();
    _sink = sink;
    final callable = _callable;
    final code = sink == null || callable == null
        ? _bindings.setEventSink(_player, nullptr, nullptr)
        : _bindings.setEventSink(_player, callable.nativeFunction, nullptr);
    _throwOnFailure(code, 'setEventSink');
  }

  @override
  String attach(String clientId) {
    _ensureOpen();
    final id = clientId.toNativeUtf8();
    final out = calloc<FfOwnedBytes>();
    try {
      final code = _bindings.attach(_player, id.cast<Uint8>(), id.length, out);
      _throwOnFailure(code, 'attach');
      return _takeOwned(out.ref);
    } finally {
      calloc.free(id);
      calloc.free(out);
    }
  }

  @override
  void detach(String connectionId) {
    _ensureOpen();
    final id = connectionId.toNativeUtf8();
    try {
      _throwOnFailure(
        _bindings.detach(_player, id.cast<Uint8>(), id.length),
        'detach',
      );
    } finally {
      calloc.free(id);
    }
  }

  @override
  String snapshot() {
    _ensureOpen();
    final out = calloc<FfOwnedBytes>();
    try {
      _throwOnFailure(_bindings.snapshot(_player, out), 'snapshot');
      return _takeOwned(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  @override
  String diagnostics() {
    _ensureOpen();
    final out = calloc<FfOwnedBytes>();
    try {
      _throwOnFailure(_bindings.diagnostics(_player, out), 'diagnostics');
      return _takeOwned(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  @override
  String execute(String command, {int timeoutMs = 2000}) {
    _ensureOpen();
    final bytes = utf8.encode(command);
    final request = calloc<Uint8>(bytes.length);
    final out = calloc<FfOwnedBytes>();
    try {
      request.asTypedList(bytes.length).setAll(0, bytes);
      _throwOnFailure(
        _bindings.execute(_player, request, bytes.length, timeoutMs, out),
        'execute',
      );
      return _takeOwned(out.ref);
    } finally {
      calloc.free(request);
      calloc.free(out);
    }
  }

  @override
  void configureCheckpoint({
    required String directory,
    required String account,
  }) {
    _ensureOpen();
    _callCheckpointCommand(
      _bindings.configureCheckpoint,
      'configureCheckpoint',
      directory,
      account,
    );
  }

  @override
  RestoreStatus restoreCheckpoint({
    required String directory,
    required String account,
  }) {
    _ensureOpen();
    final directoryBytes = utf8.encode(directory);
    final accountBytes = utf8.encode(account);
    final directoryPtr = calloc<Uint8>(
      directoryBytes.isEmpty ? 1 : directoryBytes.length,
    );
    final accountPtr = calloc<Uint8>(
      accountBytes.isEmpty ? 1 : accountBytes.length,
    );
    final outStatus = calloc<Uint32>();
    try {
      directoryPtr.asTypedList(directoryBytes.length).setAll(0, directoryBytes);
      accountPtr.asTypedList(accountBytes.length).setAll(0, accountBytes);
      _throwOnFailure(
        _bindings.restoreCheckpoint(
          _player,
          directoryPtr,
          directoryBytes.length,
          accountPtr,
          accountBytes.length,
          outStatus,
        ),
        'restoreCheckpoint',
      );
      return RestoreStatus.fromCode(outStatus.value);
    } finally {
      calloc.free(directoryPtr);
      calloc.free(accountPtr);
      calloc.free(outStatus);
    }
  }

  @override
  void deleteCheckpoint({required String directory, required String account}) {
    _ensureOpen();
    _callCheckpointCommand(
      _bindings.deleteCheckpoint,
      'deleteCheckpoint',
      directory,
      account,
    );
  }

  @override
  void flushCheckpoint() {
    _ensureOpen();
    _throwOnFailure(_bindings.flushCheckpoint(_player), 'flushCheckpoint');
  }

  /// Calls one of the checkpoint entry points, which share a signature: the
  /// directory and account cross as borrowed UTF-8, and an empty argument is a
  /// valid value (an empty directory turns the writer off).
  void _callCheckpointCommand(
    int Function(Pointer<FfPlayer>, Pointer<Uint8>, int, Pointer<Uint8>, int)
    call,
    String name,
    String directory,
    String account,
  ) {
    final directoryBytes = utf8.encode(directory);
    final accountBytes = utf8.encode(account);
    // A zero-length argument is valid here, so a null pointer with length 0 is
    // what the ABI expects; the buffers are still allocated so both are freed the
    // same way.
    final directoryPtr = calloc<Uint8>(
      directoryBytes.isEmpty ? 1 : directoryBytes.length,
    );
    final accountPtr = calloc<Uint8>(
      accountBytes.isEmpty ? 1 : accountBytes.length,
    );
    try {
      directoryPtr.asTypedList(directoryBytes.length).setAll(0, directoryBytes);
      accountPtr.asTypedList(accountBytes.length).setAll(0, accountBytes);
      _throwOnFailure(
        call(
          _player,
          directoryPtr,
          directoryBytes.length,
          accountPtr,
          accountBytes.length,
        ),
        name,
      );
    } finally {
      calloc.free(directoryPtr);
      calloc.free(accountPtr);
    }
  }

  @override
  void close() {
    unawaited(closeAsync());
  }

  @override
  Future<void> closeAsync() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _inputBindings.setSink(_player, nullptr, nullptr);
    final worker = _inputWorker;
    if (worker != null) await worker.stop();
    for (final pending in _inputReaders.values) {
      unawaited(
        pending.then((reader) => reader.close(), onError: (Object _) {}),
      );
    }
    _inputReaders.clear();
    _inputProvider = null;
    // Order matters: stop delivery, then stop playback and join the session's
    // threads (which is what makes "no callback after free" true), and only then
    // release the native callables. Events already queued on this isolate find the
    // sink gone and are dropped.
    closeNcmHost();
    _bindings.setEventSink(_player, nullptr, nullptr);
    _bindings.playerFree(_player);
    if (worker != null) await worker.release();
    _inputCallable?.close();
    _inputCallable = null;
    _sink = null;
    _callable?.close();
    _callable = null;
  }

  /// Runs on the isolate's event loop, after the library's publish call returned.
  ///
  /// The buffer was transferred with its ownership: it is released here, however
  /// long delivery waited and whether or not a sink is still registered.
  void _onEvent(Pointer<Uint8> json, int length, Pointer<Void> user) {
    // A struct cannot be built in Dart; the descriptor is assembled in native
    // memory around the buffer the library handed over.
    final descriptor = calloc<FfOwnedBytes>();
    try {
      descriptor.ref
        ..data = json
        ..len = length;
      final sink = _sink;
      if (sink != null && json != nullptr && length > 0) {
        sink(utf8.decode(json.asTypedList(length)));
      }
    } finally {
      _bindings.bytesFree(descriptor.ref);
      calloc.free(descriptor);
    }
  }

  /// Reads an owned buffer into a Dart string and releases it exactly once.
  String _takeOwned(FfOwnedBytes bytes) {
    if (bytes.data == nullptr || bytes.len == 0) {
      _bindings.bytesFree(bytes);
      return '';
    }
    final text = utf8.decode(bytes.data.asTypedList(bytes.len));
    _bindings.bytesFree(bytes);
    return text;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const MediaCoreException(
        MediaCoreCode.nullHandle,
        detail: 'the session was closed',
      );
    }
  }

  void _throwOnFailure(int code, String what) {
    if (code == MediaCoreCode.ok) return;
    throw MediaCoreException(code, detail: 'while calling $what');
  }

  static Map<String, Object?> _decodeJson(String text) {
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : const {};
  }

  @override
  String toString() => 'FfiMediaCoreApi(abi $abiVersion)';
}

/// The library's exported functions, resolved once.
final class _Bindings {
  _Bindings(DynamicLibrary library)
    : abiVersion = library.lookupFunction<_AbiVersionNative, int Function()>(
        'ff_media_core_abi_version',
      ),
      capabilities = library
          .lookupFunction<_CapabilitiesJsonNative, FfOwnedBytes Function()>(
            'ff_media_core_capabilities_json',
          ),
      bytesFree = library
          .lookupFunction<_BytesFreeNative, void Function(FfOwnedBytes)>(
            'ff_owned_bytes_free',
          ),
      playerNew = library
          .lookupFunction<_PlayerNewNative, Pointer<FfPlayer> Function()>(
            'ff_player_new',
          ),
      playerFree = library
          .lookupFunction<_PlayerFreeNative, void Function(Pointer<FfPlayer>)>(
            'ff_player_free',
          ),
      setEventSink = library
          .lookupFunction<
            _SetEventSinkNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<NativeFunction<_EventSinkNative>>,
              Pointer<Void>,
            )
          >('ff_player_set_event_sink'),
      attach = library
          .lookupFunction<
            _InBytesOutNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<Uint8>,
              int,
              Pointer<FfOwnedBytes>,
            )
          >('ff_player_attach'),
      detach = library
          .lookupFunction<
            _InIdNative,
            int Function(Pointer<FfPlayer>, Pointer<Uint8>, int)
          >('ff_player_detach'),
      snapshot = library
          .lookupFunction<
            _SnapshotNative,
            int Function(Pointer<FfPlayer>, Pointer<FfOwnedBytes>)
          >('ff_player_snapshot'),
      diagnostics = library
          .lookupFunction<
            _SnapshotNative,
            int Function(Pointer<FfPlayer>, Pointer<FfOwnedBytes>)
          >('ff_player_diagnostics'),
      execute = library
          .lookupFunction<
            _ExecuteNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<Uint8>,
              int,
              int,
              Pointer<FfOwnedBytes>,
            )
          >('ff_player_execute'),
      configureCheckpoint = library
          .lookupFunction<
            _ConfigureCheckpointNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              int,
            )
          >('ff_player_configure_checkpoint'),
      restoreCheckpoint = library
          .lookupFunction<
            _RestoreCheckpointNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              int,
              Pointer<Uint32>,
            )
          >('ff_player_restore_checkpoint'),
      deleteCheckpoint = library
          .lookupFunction<
            _ConfigureCheckpointNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              int,
            )
          >('ff_player_delete_checkpoint'),
      flushCheckpoint = library
          .lookupFunction<
            _PlayerCommandNative,
            int Function(Pointer<FfPlayer>)
          >('ff_player_flush_checkpoint');

  final int Function() abiVersion;
  final FfOwnedBytes Function() capabilities;
  final void Function(FfOwnedBytes bytes) bytesFree;
  final Pointer<FfPlayer> Function() playerNew;
  final void Function(Pointer<FfPlayer> player) playerFree;
  final int Function(
    Pointer<FfPlayer> player,
    Pointer<NativeFunction<_EventSinkNative>> sink,
    Pointer<Void> user,
  )
  setEventSink;
  final int Function(
    Pointer<FfPlayer> player,
    Pointer<Uint8> id,
    int length,
    Pointer<FfOwnedBytes> out,
  )
  attach;
  final int Function(Pointer<FfPlayer> player, Pointer<Uint8> id, int length)
  detach;
  final int Function(Pointer<FfPlayer> player, Pointer<FfOwnedBytes> out)
  snapshot;
  final int Function(Pointer<FfPlayer> player, Pointer<FfOwnedBytes> out)
  diagnostics;
  final int Function(
    Pointer<FfPlayer> player,
    Pointer<Uint8> json,
    int length,
    int timeoutMs,
    Pointer<FfOwnedBytes> out,
  )
  execute;
  final int Function(
    Pointer<FfPlayer> player,
    Pointer<Uint8> directory,
    int directoryLength,
    Pointer<Uint8> account,
    int accountLength,
  )
  configureCheckpoint;
  final int Function(
    Pointer<FfPlayer> player,
    Pointer<Uint8> directory,
    int directoryLength,
    Pointer<Uint8> account,
    int accountLength,
  )
  deleteCheckpoint;
  final int Function(Pointer<FfPlayer> player) flushCheckpoint;
  final int Function(
    Pointer<FfPlayer> player,
    Pointer<Uint8> directory,
    int directoryLength,
    Pointer<Uint8> account,
    int accountLength,
    Pointer<Uint32> outStatus,
  )
  restoreCheckpoint;
}

typedef _InputSinkNative =
    Void Function(Uint64, Uint64, Uint64, Int64, Pointer<Void>);
typedef _InputSetSinkNative =
    Uint32 Function(
      Pointer<FfPlayer>,
      Pointer<NativeFunction<_InputSinkNative>>,
      Pointer<Void>,
    );
typedef _InputIdNative = Uint32 Function(Pointer<FfPlayer>, Uint64);
typedef _InputAcquireNative =
    Uint32 Function(Pointer<FfPlayer>, Uint64, Pointer<_InputBuffer>);
typedef _InputCommitNative =
    Uint32 Function(Pointer<Void>, IntPtr, Int64, Uint32);
typedef _InputReleaseNative = Uint32 Function(Pointer<Void>);

final class _InputBuffer extends Struct {
  external Pointer<Void> lease;
  external Pointer<Uint8> data;
  @IntPtr()
  external int capacity;
}

final class _InputBindings {
  _InputBindings(DynamicLibrary library)
    : setSink = library
          .lookupFunction<
            _InputSetSinkNative,
            int Function(
              Pointer<FfPlayer>,
              Pointer<NativeFunction<_InputSinkNative>>,
              Pointer<Void>,
            )
          >('ff_player_input_set_sink'),
      register = library
          .lookupFunction<_InputIdNative, int Function(Pointer<FfPlayer>, int)>(
            'ff_player_input_register',
          ),
      revoke = library
          .lookupFunction<_InputIdNative, int Function(Pointer<FfPlayer>, int)>(
            'ff_player_input_revoke',
          ),
      acquire = library
          .lookupFunction<
            _InputAcquireNative,
            int Function(Pointer<FfPlayer>, int, Pointer<_InputBuffer>)
          >('ff_player_input_acquire'),
      commit = library
          .lookupFunction<
            _InputCommitNative,
            int Function(Pointer<Void>, int, int, int)
          >('ff_input_commit'),
      release = library
          .lookupFunction<_InputReleaseNative, int Function(Pointer<Void>)>(
            'ff_input_release',
          );
  final int Function(
    Pointer<FfPlayer>,
    Pointer<NativeFunction<_InputSinkNative>>,
    Pointer<Void>,
  )
  setSink;
  final int Function(Pointer<FfPlayer>, int) register, revoke;
  final int Function(Pointer<FfPlayer>, int, Pointer<_InputBuffer>) acquire;
  final int Function(Pointer<Void>, int, int, int) commit;
  final int Function(Pointer<Void>) release;
}

typedef _NcmFreeNative = Void Function(Pointer<FfNcmHost>);
typedef _NcmSinkNative =
    Uint32 Function(
      Pointer<FfNcmHost>,
      Pointer<NativeFunction<_EventSinkNative>>,
      Pointer<Void>,
    );
typedef _NcmDeliveriesNative = Uint64 Function(Pointer<FfNcmHost>);

typedef _NcmNewNative = Uint32 Function(Pointer<Pointer<FfNcmHost>>);
typedef _NcmRequestNative =
    Uint32 Function(Pointer<FfNcmHost>, Pointer<Uint8>, IntPtr);

final class _NcmBindings {
  _NcmBindings(DynamicLibrary library)
    : create = library
          .lookupFunction<
            _NcmNewNative,
            int Function(Pointer<Pointer<FfNcmHost>>)
          >('ff_ncm_host_new'),
      submit = library
          .lookupFunction<
            _NcmRequestNative,
            int Function(Pointer<FfNcmHost>, Pointer<Uint8>, int)
          >('ff_ncm_host_submit'),
      cancel = library
          .lookupFunction<
            _NcmRequestNative,
            int Function(Pointer<FfNcmHost>, Pointer<Uint8>, int)
          >('ff_ncm_host_cancel'),
      sink = library
          .lookupFunction<
            _NcmSinkNative,
            int Function(
              Pointer<FfNcmHost>,
              Pointer<NativeFunction<_EventSinkNative>>,
              Pointer<Void>,
            )
          >('ff_ncm_host_set_event_sink'),
      free = library
          .lookupFunction<_NcmFreeNative, void Function(Pointer<FfNcmHost>)>(
            'ff_ncm_host_free',
          ),
      deliveries = library
          .lookupFunction<
            _NcmDeliveriesNative,
            int Function(Pointer<FfNcmHost>)
          >('ff_ncm_host_deliveries');
  final int Function(Pointer<FfNcmHost>) deliveries;
  final int Function(Pointer<Pointer<FfNcmHost>>) create;
  final int Function(Pointer<FfNcmHost>, Pointer<Uint8>, int) submit, cancel;
  final int Function(
    Pointer<FfNcmHost>,
    Pointer<NativeFunction<_EventSinkNative>>,
    Pointer<Void>,
  )
  sink;
  final void Function(Pointer<FfNcmHost>) free;
}
