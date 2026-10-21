import 'dart:convert';
import 'dart:io';

import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  group('Cookie masking', () {
    test('masks long MUSIC_U while retaining prefix, suffix and length', () {
      const cookie =
          'deviceId=A1B2C3D4E5F6G7H8; MUSIC_U=02a9b3c4d5e6f7a8b9c0d1e2f3a4b5c67c1f; __csrf=123456789';
      final masked = ProviderRequestExecutor.maskCookieString(cookie);
      expect(masked, contains('MUSIC_U=02a9b3***7c1f (len: 36)'));
      expect(masked, contains('deviceId=A1B2C3D4...'));
      expect(masked, contains('__csrf=1234***'));
    });

    test('marks cleared MUSIC_U explicitly', () {
      const cookie = 'deviceId=A1B2C3D4; MUSIC_U=';
      final masked = ProviderRequestExecutor.maskCookieString(cookie);
      expect(masked, contains('MUSIC_U= (cleared)'));
    });

    test('masks Set-Cookie header while preserving attributes', () {
      const header =
          'MUSIC_U=02a9b3c4d5e6f7a8b9c0d1e2f3a4b5c67c1f; Path=/; Max-Age=1296000; HttpOnly';
      final masked = ProviderRequestExecutor.maskSetCookieHeader(header);
      expect(masked, startsWith('MUSIC_U=02a9b3***7c1f (len: 36);'));
      expect(masked, contains('Path=/; Max-Age=1296000; HttpOnly'));
    });

    test('masks Set-Cookie header clearing session', () {
      const header = 'MUSIC_U=; Max-Age=0; Path=/';
      final masked = ProviderRequestExecutor.maskSetCookieHeader(header);
      expect(masked, equals('MUSIC_U= (cleared); Max-Age=0; Path=/'));
    });

    test('handles empty or unrecognized cookie strings safely', () {
      expect(ProviderRequestExecutor.maskCookieString(''), isEmpty);
      expect(
        ProviderRequestExecutor.maskCookieString('other_key=simple_value'),
        equals('other_key=[redacted]'),
      );
    });
  });

  group('ProviderRequestExecutor HTTP logging', () {
    late HttpServer server;
    late HttpClient client;
    final logs = <String>[];

    setUp(() async {
      logs.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    ProviderRequestExecutor createExecutor({
      bool enableLogging = false,
      Set<String> responseWhitelist = const {},
    }) {
      return ProviderRequestExecutor(
        client: client,
        enableLogging: enableLogging,
        responseWhitelist: responseWhitelist,
        logger: logs.add,
      );
    }

    test('does not log when enableLogging is false', () async {
      server.listen((request) {
        request.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({'code': 200, 'data': 'ok'}))
          ..close();
      });

      final executor = createExecutor(enableLogging: false);
      final response = await executor.getJson(
        baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
        path: '/song/detail',
        query: {'id': '123'},
      );

      expect(response['code'], equals(200));
      expect(logs, isEmpty);
    });

    test(
      'logs request and status for all requests, but logs cookies and response body only when in respective whitelists',
      () async {
        server.listen((request) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.add(
              HttpHeaders.setCookieHeader,
              'MUSIC_U=abcdef1234567890; Path=/',
            )
            ..write(jsonEncode({'code': 200, 'title': 'Test Response'}))
            ..close();
        });

        final executor = createExecutor(
          enableLogging: true,
          responseWhitelist: {'/song/detail', '/user/account'},
          // cookieWhitelist uses default: /login/*, /user/account, /logout
        );

        final baseUri = Uri.parse(
          'http://${server.address.host}:${server.port}',
        );

        // 1. Auth route in cookieWhitelist AND responseWhitelist (/user/account):
        // should print cookies AND response body.
        await executor.getJson(
          baseUri: baseUri,
          path: '/user/account',
          query: {
            'timestamp': '123456',
            'cookie': 'deviceId=123456789012; MUSIC_U=abcdef1234567890',
          },
        );

        expect(
          logs.any((l) => l.contains('[NCM] --> GET /user/account')),
          isTrue,
        );
        expect(
          logs.any((l) => l.contains('[NCM Cookies] Request Cookie:')),
          isTrue,
        );
        expect(
          logs.any((l) => l.contains('MUSIC_U=abcdef***7890 (len: 16)')),
          isTrue,
        );
        expect(
          logs.any((l) => l.contains('[NCM] <-- 200 /user/account')),
          isTrue,
        );
        expect(
          logs.any(
            (l) => l.contains(
              '[NCM Cookies] Set-Cookie: MUSIC_U=abcdef***7890 (len: 16); Path=/',
            ),
          ),
          isTrue,
        );
        expect(
          logs.any((l) => l.contains('[NCM Response Body] /user/account:')),
          isTrue,
        );

        logs.clear();

        // 2. Normal media route in responseWhitelist but NOT in cookieWhitelist (/song/detail):
        // should print response body, but should NOT print cookies.
        await executor.getJson(
          baseUri: baseUri,
          path: '/song/detail',
          query: {
            'id': '123',
            'cookie': 'deviceId=123456789012; MUSIC_U=abcdef1234567890',
          },
        );

        expect(
          logs.any((l) => l.contains('[NCM] --> GET /song/detail')),
          isTrue,
        );
        expect(logs.any((l) => l.contains('[NCM Cookies]')), isFalse);
        expect(
          logs.any((l) => l.contains('[NCM] <-- 200 /song/detail')),
          isTrue,
        );
        expect(
          logs.any((l) => l.contains('[NCM Response Body] /song/detail:')),
          isTrue,
        );

        logs.clear();

        // 3. Non-whitelisted route (/personalized):
        // should print request and status, but neither cookies nor response body.
        await executor.getJson(
          baseUri: baseUri,
          path: '/personalized',
          query: {
            'limit': '10',
            'cookie': 'deviceId=123456789012; MUSIC_U=abcdef1234567890',
          },
        );

        expect(
          logs.any((l) => l.contains('[NCM] --> GET /personalized')),
          isTrue,
        );
        expect(logs.any((l) => l.contains('[NCM Cookies]')), isFalse);
        expect(
          logs.any((l) => l.contains('[NCM] <-- 200 /personalized')),
          isTrue,
        );
        expect(logs.any((l) => l.contains('[NCM Response Body]')), isFalse);
      },
    );

    test('always logs error response body on non-200 status', () async {
      server.listen((request) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write(jsonEncode({'code': 404, 'message': 'Not Found'}))
          ..close();
      });

      final executor = createExecutor(
        enableLogging: true,
        responseWhitelist: {}, // Empty whitelist
      );

      final baseUri = Uri.parse('http://${server.address.host}:${server.port}');

      try {
        await executor.getJson(baseUri: baseUri, path: '/unknown', query: {});
      } catch (_) {
        // Expected AppError
      }

      expect(logs.any((l) => l.contains('[NCM] --> GET /unknown')), isTrue);
      expect(logs.any((l) => l.contains('[NCM] <-- 404 /unknown')), isTrue);
      expect(logs.any((l) => l.contains('"code": 404')), isTrue);
      expect(logs.any((l) => l.contains('"message": "[redacted]"')), isTrue);
    });
  });
}
