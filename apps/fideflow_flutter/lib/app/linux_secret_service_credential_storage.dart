import 'package:fideflow_domain/domain.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Narrow seam around the plugin so storage behavior can be tested without a
/// running Secret Service or touching a developer's keyring.
abstract interface class LinuxSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterSecureStorageLinuxSecretStore implements LinuxSecretStore {
  FlutterSecureStorageLinuxSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Secret Service backed credential storage for the Linux desktop app.
///
/// flutter_secure_storage_linux scopes entries to the application ID in its
/// Secret Service schema. This additional prefix versions and scopes Fideflow's
/// keys so entries cannot collide with another feature in this app.
final class LinuxSecretServiceCredentialStorage
    implements SecureCredentialStorage {
  LinuxSecretServiceCredentialStorage({LinuxSecretStore? store})
    : _store = store ?? FlutterSecureStorageLinuxSecretStore();

  static const keyNamespace = 'com.moetaku.fideflow/auth/v1';
  final LinuxSecretStore _store;

  String _qualifiedKey(String key) => '$keyNamespace/$key';

  @override
  Future<String?> read(String key) async {
    try {
      return await _store.read(_qualifiedKey(key));
    } catch (error) {
      throw _storageError(error);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final qualified = _qualifiedKey(key);
    try {
      await _store.write(qualified, value);
      // The Linux plugin's native layer currently ignores a false libsecret
      // result without a GError. Read-back turns that into an explicit failure.
      if (await _store.read(qualified) != value) {
        throw const AppError(
          category: AppErrorCategory.storage,
          code: 'auth.secureStorageWriteFailed',
          retryable: true,
        );
      }
    } catch (error) {
      if (error is AppError) rethrow;
      throw _storageError(error);
    }
  }

  @override
  Future<void> delete(String key) async {
    final qualified = _qualifiedKey(key);
    try {
      await _store.delete(qualified);
      // The plugin also ignores false from libsecret delete operations.
      if (await _store.read(qualified) != null) {
        throw const AppError(
          category: AppErrorCategory.storage,
          code: 'auth.secureStorageDeleteFailed',
          retryable: true,
        );
      }
    } catch (error) {
      if (error is AppError) rethrow;
      throw _storageError(error);
    }
  }

  AppError _storageError(Object error) => AppError(
    category: AppErrorCategory.storage,
    code: error is PlatformException && error.code == 'KeyringLocked'
        ? 'auth.secretServiceLocked'
        : 'auth.secretServiceUnavailable',
    retryable: true,
  );
}
