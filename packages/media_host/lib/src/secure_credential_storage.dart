import 'dart:io';

import 'package:fideflow_domain/domain.dart';

/// In-memory implementation of [SecureCredentialStorage] for testing or fallback.
final class InMemoryCredentialStorage implements SecureCredentialStorage {
  final Map<String, String> _storage = {};

  @override
  Future<String?> read(String key) async => _storage[key];

  @override
  Future<void> write(String key, String value) async {
    _storage[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _storage.remove(key);
  }
}

/// macOS Keychain implementation of [SecureCredentialStorage] using `/usr/bin/security`.
final class MacOsKeychainCredentialStorage implements SecureCredentialStorage {
  MacOsKeychainCredentialStorage({
    this.service = 'com.moetaku.fideflow.desktop.auth',
    this.securityExecutable = '/usr/bin/security',
  });

  /// The service name used in the Keychain.
  final String service;

  /// The path to the macOS `security` executable.
  final String securityExecutable;

  @override
  Future<String?> read(String key) async {
    try {
      final result = await Process.run(securityExecutable, [
        'find-generic-password',
        '-a',
        key,
        '-s',
        service,
        '-w',
      ]);
      if (result.exitCode == 0) {
        final out = (result.stdout as String).trim();
        return out.isNotEmpty ? out : null;
      }
      if (result.exitCode == 44) return null;
      throw StateError('Keychain read failed with code ${result.exitCode}');
    } catch (error) {
      if (error is StateError) rethrow;
      throw StateError('Failed to access macOS Keychain');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final result = await Process.run(securityExecutable, [
        'add-generic-password',
        '-a',
        key,
        '-s',
        service,
        '-w',
        value,
        '-U',
      ]);
      if (result.exitCode != 0) {
        throw StateError('Keychain write failed with code ${result.exitCode}');
      }
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('Failed to access macOS Keychain');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await Process.run(securityExecutable, [
        'delete-generic-password',
        '-a',
        key,
        '-s',
        service,
      ]);
    } catch (_) {
      // Ignore if not present or cannot delete.
    }
  }
}
