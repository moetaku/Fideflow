import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late List<Uri> requests;
  late Set<String> revoked;
  Completer<void>? responseGate;
  late Completer<void> received;
  setUp(() async {
    requests = [];
    revoked = {};
    responseGate = null;
    received = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      if (!received.isCompleted) received.complete();
      await responseGate?.future;
      final cookie = request.uri.queryParameters['cookie'] ?? '';
      final token = cookie.split(';').first;
      if (request.uri.path == '/logout') revoked.add(token);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/logout'
              ? {'code': 200}
              : {
                  'code': 200,
                  'profile': revoked.contains(token)
                      ? null
                      : {
                          'userId': token == 'MUSIC_U=A' ? 1 : 2,
                          'nickname': token,
                        },
                },
        ),
      );
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
  });
  RemoteNcmProvider provider({Future<String> Function()? device}) {
    final value = RemoteNcmProvider(
      config: RemoteProviderConfig(baseUrl: 'http://127.0.0.1:${server.port}'),
      deviceIdProvider: device,
    );
    addTearDown(value.dispose);
    return value;
  }

  final stale = throwsA(
    isA<AppError>().having((e) => e.code, 'code', 'auth.epochMismatch'),
  );
  test('credential is captured before device identity await', () async {
    final device = Completer<String>();
    final remote = provider(device: () => device.future)
      ..setCookie('MUSIC_U=A');
    final result = remote.getUserAccount();
    final refused = expectLater(result, stale);
    remote.setCookie('MUSIC_U=B');
    device.complete('device');
    await refused;
    expect(
      requests.single.queryParameters['cookie'],
      'MUSIC_U=A; deviceId=device',
    );
  });
  test('old account response is refused after active cookie changes', () async {
    responseGate = Completer<void>();
    final remote = provider()..setCookie('MUSIC_U=A');
    final refused = expectLater(remote.getUserAccount(), stale);
    await received.future;
    remote.setCookie('MUSIC_U=B');
    responseGate!.complete();
    await refused;
    expect(requests.single.queryParameters['cookie'], 'MUSIC_U=A');
  });
  test(
    'explicit inactive logout leaves active account authenticated',
    () async {
      final remote = provider()..setCookie('MUSIC_U=B');
      await remote.logout(cookie: 'MUSIC_U=A');
      final active = await remote.getUserAccount();
      expect(active.userId, const UserId('ncm-user-2'));
      expect(requests.map((e) => e.queryParameters['cookie']), [
        'MUSIC_U=A',
        'MUSIC_U=A',
        'MUSIC_U=B',
      ]);
    },
  );
  test(
    'commit gate blocks active requests and permits target validation',
    () async {
      final remote = provider()..setCookie('MUSIC_U=A');
      remote.beginAccountTransition();
      await expectLater(
        remote.getUserAccount(),
        throwsA(
          isA<AppError>().having(
            (e) => e.code,
            'code',
            'auth.transitionInProgress',
          ),
        ),
      );
      expect(requests, isEmpty);
      expect(
        (await remote.getUserAccount(cookie: 'MUSIC_U=B')).userId,
        const UserId('ncm-user-2'),
      );
      remote.setCookie('MUSIC_U=B');
      expect(
        (await remote.getUserAccount()).userId,
        const UserId('ncm-user-2'),
      );
    },
  );
}
