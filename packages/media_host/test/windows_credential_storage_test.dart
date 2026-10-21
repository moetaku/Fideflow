import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

import 'credential_coordinator_test.dart' show FakeRemoteAuthClient;

void main() {
  group('Windows current-user DPAPI', () {
    late Directory directory;
    late WindowsDpapiCredentialStorage storage;
    WindowsDpapiCredentialStorage open() => WindowsDpapiCredentialStorage(
      paths: PlatformPaths(dataDirectory: directory.path),
    );
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('ff-dpapi-中文 ');
      storage = open();
    });
    tearDown(() async => directory.delete(recursive: true));

    test('persists encrypted Unicode values, overwrites and deletes', () async {
      const key = 'account_token:ncm:user:123';
      expect(await storage.read(key), isNull);
      await storage.write(key, 'test-cookie-中文');
      expect(await open().read(key), 'test-cookie-中文');
      final files = await Directory(
        '${directory.path}/credentials',
      ).list().toList();
      expect(files, hasLength(1));
      final bytes = await (files.single as File).readAsBytes();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('test-cookie')),
      );
      await storage.write(key, 'replacement');
      expect(await open().read(key), 'replacement');
      await storage.write(key, '');
      expect(await open().read(key), '');
      await storage.delete(key);
      await storage.delete(key);
      expect(await open().read(key), isNull);
    });

    test('restores and removes from a separate process', () async {
      await storage.write('account_token:ncm:user:123', 'test-cookie-中文');
      final source =
          File('test/support/windows_credential_child.dart').existsSync()
          ? File('test/support/windows_credential_child.dart')
          : File(
              'packages/media_host/test/support/windows_credential_child.dart',
            );
      final result = await Process.run(Platform.resolvedExecutable, [
        source.absolute.path,
        directory.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(await storage.read('account_token:ncm:user:123'), isNull);
    });

    test(
      'rejects corrupted data and ciphertext moved to a different key',
      () async {
        await storage.write('first', 'secret');
        await storage.write('second', 'other');
        File file(String key) => File(
          '${directory.path}/credentials/${utf8.encode(key).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}.dpapi',
        );
        await file('second').writeAsBytes(await file('first').readAsBytes());
        await expectLater(storage.read('second'), throwsStateError);
        await file('first').writeAsBytes([1, 2, 3]);
        await expectLater(storage.read('first'), throwsStateError);
        // A failed operation must not poison the serialization queue.
        await storage.write('first', 'recovered');
        expect(await storage.read('first'), 'recovered');
      },
    );

    test('serializes updates and isolates account keys', () async {
      await Future.wait([
        storage.write('../first', 'one'),
        storage.write('second', 'two'),
        storage.write('../first', 'updated'),
      ]);
      expect(await storage.read('../first'), 'updated');
      expect(await storage.read('second'), 'two');
      await storage.delete('../first');
      expect(await storage.read('second'), 'two');
      expect(await directory.list().length, 1);
    });

    test('keys differing only by filename case remain distinct', () async {
      // Base64 of these keys is AQ and aQ, a collision on Windows.
      await storage.write('\u0001', 'upper');
      await storage.write('B', 'other');
      await storage.write('i', 'lower');
      expect(await open().read('\u0001'), 'upper');
      expect(await open().read('B'), 'other');
      expect(await open().read('i'), 'lower');
    });

    test('storage errors do not fall back to memory or plaintext', () async {
      final unavailable = WindowsDpapiCredentialStorage(
        paths: const PlatformPaths(),
      );
      await expectLater(unavailable.write('key', 'secret'), throwsStateError);
      await expectLater(unavailable.read('key'), throwsStateError);
      final blocked = File('${directory.path}/credentials');
      await blocked.writeAsString('not a directory');
      await expectLater(storage.write('key', 'secret'), throwsStateError);
      expect(await blocked.readAsString(), 'not a directory');
      await blocked.delete();
      await storage.write('key', 'recovered');
      expect(await storage.read('key'), 'recovered');
    });

    test('coordinator restores login and revokes it after sign out', () async {
      final client = FakeRemoteAuthClient()
        ..nextStatus = QrCodeScanStatus.authorized
        ..nextCookie = 'test-cookie';
      final first = CredentialCoordinator(storage: storage, authClient: client);
      await first.checkQrCodeStatus('test-qr');
      await first.completeLogin('test-qr');
      first.dispose();
      final restored = CredentialCoordinator(
        storage: open(),
        authClient: FakeRemoteAuthClient(),
      );
      expect(await restored.restoreSession(), isNotNull);
      await restored.signOut();
      restored.dispose();
      final signedOut = CredentialCoordinator(
        storage: open(),
        authClient: FakeRemoteAuthClient(),
      );
      expect(await signedOut.restoreSession(), isNull);
      expect(await open().read('account_token:ncm-user-123'), isNull);
      signedOut.dispose();
    });
  }, skip: !Platform.isWindows);
}
