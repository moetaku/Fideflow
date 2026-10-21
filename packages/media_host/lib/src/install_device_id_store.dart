import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fideflow_domain/domain.dart';

import 'platform_paths.dart';

/// A Netease device identity owned by this installation's application data.
///
/// Uses the SDK-compatible 52-character uppercase hexadecimal format and
/// persists it across app restarts and account changes.
final class InstallDeviceIdStore {
  InstallDeviceIdStore({String? homeDirectory, PlatformPaths? paths})
    : _dataDirectory =
          (paths ??
                  PlatformPaths.resolve(
                    environment: homeDirectory == null
                        ? null
                        : {'HOME': homeDirectory},
                    platform: homeDirectory == null
                        ? null
                        : DesktopPlatform.macos,
                  ))
              .dataDirectory;

  final String? _dataDirectory;
  String? _cached;
  Future<String>? _pending;

  // POSIX advisory file locks coordinate separate app processes, but do not
  // serialize multiple handles in the same process.
  static final Map<String, Future<String>> _processLoads = {};

  static final _validId = RegExp(r'^[0-9A-F]{52}$');

  /// Reads or creates the ID. Concurrent callers share one operation, while a
  /// file lock also coordinates separate app processes using the same data.
  Future<String> loadOrCreate() {
    if (_cached case final id?) return Future.value(id);
    return _pending ??= _sharedLoad()
        .then((id) {
          _cached = id;
          return id;
        })
        .whenComplete(() => _pending = null);
  }

  Future<String> _sharedLoad() {
    final key = _dataDirectory ?? '';
    if (_processLoads[key] case final existing?) return existing;
    final task = _loadOrCreate();
    _processLoads[key] = task;
    unawaited(
      task.then<void>(
        (_) {
          _processLoads.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _processLoads.remove(key);
        },
      ),
    );
    return task;
  }

  Future<String> _loadOrCreate() async {
    final data = _dataDirectory;
    if (data == null || data.isEmpty) {
      throw _unavailable();
    }

    final directory = Directory(data);
    final file = File('${directory.path}/device-id');
    final lockFile = File('${directory.path}/device-id.lock');
    RandomAccessFile? lock;
    try {
      await directory.create(recursive: true);
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);

      String? existing;
      try {
        existing = await file.readAsString();
      } on FileSystemException catch (error) {
        // Only an absent file is first use. A permission or I/O error must not
        // silently rotate the identity of an already signed-in installation.
        if (error.osError?.errorCode != 2) rethrow;
      }
      if (existing != null) {
        if (!_validId.hasMatch(existing)) throw _invalid();
        return existing;
      }

      final random = Random.secure();
      final id = List<int>.generate(26, (_) => random.nextInt(256))
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      final temp = File(
        '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await temp.writeAsString(id, flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      return id;
    } on AppError {
      rethrow;
    } catch (_) {
      throw _unavailable();
    } finally {
      if (lock != null) {
        await lock.unlock();
        await lock.close();
      }
    }
  }

  static AppError _invalid() => const AppError(
    category: AppErrorCategory.provider,
    code: 'provider.deviceIdInvalid',
    retryable: false,
  );

  static AppError _unavailable() => const AppError(
    category: AppErrorCategory.provider,
    code: 'provider.deviceIdUnavailable',
    retryable: true,
  );
}
