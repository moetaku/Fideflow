import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('fideflow-device-id-');
  });

  tearDown(() async {
    await home.delete(recursive: true);
  });

  File identityFile() =>
      File('${home.path}/Library/Application Support/Fideflow/device-id');

  test(
    'creates 52 uppercase hex digits and reuses them after restart',
    () async {
      final first = await InstallDeviceIdStore(
        homeDirectory: home.path,
      ).loadOrCreate();
      expect(first, matches(RegExp(r'^[0-9A-F]{52}$')));
      expect(await identityFile().readAsString(), first);

      final restarted = InstallDeviceIdStore(homeDirectory: home.path);
      expect(await restarted.loadOrCreate(), first);
      expect(await restarted.loadOrCreate(), first);
    },
  );

  test('concurrent callers and app instances share one identity', () async {
    final first = InstallDeviceIdStore(homeDirectory: home.path);
    final second = InstallDeviceIdStore(homeDirectory: home.path);
    final values = await Future.wait([
      first.loadOrCreate(),
      first.loadOrCreate(),
      second.loadOrCreate(),
    ]);

    expect(values.toSet(), hasLength(1));
    expect(await identityFile().readAsString(), values.first);
  });

  test('invalid existing identity is reported without rotation', () async {
    await identityFile().parent.create(recursive: true);
    final invalid = '${List.filled(52, 'A').join()}\n';
    await identityFile().writeAsString(invalid);

    await expectLater(
      InstallDeviceIdStore(homeDirectory: home.path).loadOrCreate(),
      throwsA(
        isA<AppError>().having(
          (error) => error.code,
          'code',
          'provider.deviceIdInvalid',
        ),
      ),
    );
    expect(await identityFile().readAsString(), invalid);
  });

  test('I/O failure is reported without inventing a new identity', () async {
    final blockedHome = File('${home.path}/blocked');
    await blockedHome.writeAsString('not a directory');

    await expectLater(
      InstallDeviceIdStore(homeDirectory: blockedHome.path).loadOrCreate(),
      throwsA(
        isA<AppError>().having(
          (error) => error.code,
          'code',
          'provider.deviceIdUnavailable',
        ),
      ),
    );
    expect(await blockedHome.readAsString(), 'not a directory');
  });
}
