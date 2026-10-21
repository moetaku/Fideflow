import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fideflow_domain/domain.dart';

import 'platform_paths.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptNative =
    Int32 Function(
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_Blob>,
    );
typedef _CryptDart =
    int Function(
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_Blob>,
    );

/// Current-user DPAPI storage. Only encrypted blobs are written to disk.
/// No subprocess, plaintext fallback, or machine-wide DPAPI keys are used.
final class WindowsDpapiCredentialStorage implements SecureCredentialStorage {
  WindowsDpapiCredentialStorage({PlatformPaths? paths})
    : _directory = (paths ?? PlatformPaths.resolve()).credentialsDirectory;

  final String? _directory;
  final _random = Random.secure();
  Future<void> _tail = Future<void>.value();
  late final _Dpapi _api = _Dpapi();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  File _file(String key) {
    if (!Platform.isWindows) throw UnsupportedError('DPAPI requires Windows');
    if (_directory == null) {
      throw StateError('Windows credential directory is unavailable');
    }
    final bytes = utf8.encode(key);
    if (bytes.isEmpty || bytes.length > 120) {
      throw ArgumentError('Credential key must contain 1 to 120 UTF-8 bytes');
    }
    // Lowercase hex avoids collisions on Windows case-insensitive filesystems.
    final name = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return File('$_directory/$name.dpapi');
  }

  @override
  Future<String?> read(String key) => _serial(() async {
    final file = _file(key);
    Uint8List encrypted;
    try {
      encrypted = await file.readAsBytes();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2 || error.osError?.errorCode == 3) {
        return null;
      }
      throw StateError('Windows credential read failed');
    }
    final plaintext = _api.transform(encrypted, key, protect: false);
    try {
      return utf8.decode(plaintext);
    } on FormatException {
      throw StateError('Windows credential encoding is invalid');
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  });

  @override
  Future<void> write(String key, String value) => _serial(() async {
    final file = _file(key);
    final plaintext = utf8.encode(value);
    late final Uint8List encrypted;
    try {
      encrypted = _api.transform(plaintext, key, protect: true);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
    final suffix = List.generate(16, (_) => _random.nextInt(256));
    final temporary = File('${file.path}.${base64Url.encode(suffix)}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temporary.writeAsBytes(encrypted, flush: true);
      _api.replace(temporary.absolute.path, file.absolute.path);
    } on FileSystemException {
      throw StateError('Windows credential write failed');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });

  @override
  Future<void> delete(String key) => _serial(() async {
    try {
      await _file(key).delete();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 2 && error.osError?.errorCode != 3) {
        throw StateError('Windows credential delete failed');
      }
    }
  });
}

final class _Dpapi {
  _Dpapi() {
    final crypt = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    _protect = crypt.lookupFunction<_CryptNative, _CryptDart>(
      'CryptProtectData',
    );
    _unprotect = crypt.lookupFunction<_CryptNative, _CryptDart>(
      'CryptUnprotectData',
    );
    _free = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    _error = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    _move = kernel
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
  }

  late final _CryptDart _protect;
  late final _CryptDart _unprotect;
  late final Pointer<Void> Function(Pointer<Void>) _free;
  late final int Function() _error;
  late final int Function(Pointer<Utf16>, Pointer<Utf16>, int) _move;

  Uint8List transform(List<int> bytes, String key, {required bool protect}) {
    if (bytes.length > 16 * 1024 * 1024) {
      throw StateError('Windows credential exceeds size limit');
    }
    final entropyBytes = utf8.encode(
      'com.moetaku.fideflow.desktop.auth.v1:$key',
    );
    final input = calloc<_Blob>();
    final entropy = calloc<_Blob>();
    final output = calloc<_Blob>();
    final inputData = calloc<Uint8>(max(1, bytes.length));
    final entropyData = calloc<Uint8>(entropyBytes.length);
    input.ref
      ..length = bytes.length
      ..data = inputData;
    entropy.ref
      ..length = entropyBytes.length
      ..data = entropyData;
    inputData.asTypedList(bytes.length).setAll(0, bytes);
    entropyData.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
    try {
      final call = protect ? _protect : _unprotect;
      // CRYPTPROTECT_UI_FORBIDDEN, without CRYPTPROTECT_LOCAL_MACHINE.
      if (call(input, nullptr, entropy, nullptr, nullptr, 1, output) == 0) {
        throw StateError('Windows credential protection failed (${_error()})');
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      inputData.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        _free(output.ref.data.cast());
      }
      calloc.free(inputData);
      calloc.free(entropyData);
      calloc.free(input);
      calloc.free(entropy);
      calloc.free(output);
    }
  }

  void replace(String source, String destination) {
    final from = source.toNativeUtf16();
    final to = destination.toNativeUtf16();
    try {
      // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH, same directory.
      if (_move(from, to, 0x1 | 0x8) == 0) {
        throw StateError('Windows credential replacement failed (${_error()})');
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }
}
