import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

final class LoginTransport implements NcmRequestTransport {
  final calls =
      <
        ({
          String path,
          Map<String, String> params,
          String? cookie,
          String device,
        })
      >[];
  Map<String, Object?> body = {'code': 200};
  List<String> setCookie = [];
  @override
  ProviderEndpointState get state => const ProviderHostReady();
  @override
  Future<NcmTransportResponse> request({
    required String path,
    required Map<String, String> params,
    required String? cookie,
    required String deviceId,
    required int accountEpoch,
    required Duration budget,
    required int maxResponseBytes,
  }) async {
    calls.add((path: path, params: params, cookie: cookie, device: deviceId));
    return NcmTransportResponse(status: 200, body: body, setCookie: setCookie);
  }

  @override
  void cancelBeforeEpoch(int epoch) {}
  @override
  void dispose() {}
}

void main() {
  const device = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  late LoginTransport transport;
  late RemoteNcmProvider provider;
  setUp(() {
    transport = LoginTransport();
    provider = RemoteNcmProvider(
      config: const RemoteProviderConfig(baseUrl: 'http://127.0.0.1:1'),
      transport: transport,
      deviceIdProvider: () async => device,
    );
    provider.setCookie('MUSIC_U=outgoing');
  });
  tearDown(() => provider.dispose());

  test(
    'SMS uses anonymous credentials and ctcode, login never sends password',
    () async {
      await provider.sendLoginCode(phone: '2025550123', countryCode: '1');
      expect(transport.calls.single.params['ctcode'], '1');
      expect(transport.calls.single.cookie, isNull);
      transport.setCookie = ['MUSIC_U=incoming; HttpOnly'];
      expect(
        await provider.loginWithCode(
          phone: '2025550123',
          countryCode: '1',
          code: '123456',
        ),
        'MUSIC_U=incoming',
      );
      final login = transport.calls.last;
      expect(login.params['countrycode'], '1');
      expect(login.params['captcha'], '123456');
      expect(login.params.containsKey('password'), isFalse);
      expect(login.cookie, isNull);
      expect(login.device, device);
      await provider.uploadDeviceName(
        '我的 Mac & PC',
        cookie: 'MUSIC_U=incoming',
      );
      expect(transport.calls.last.cookie, 'MUSIC_U=incoming');
      expect(transport.calls.last.params['deviceName'], '我的 Mac & PC');
    },
  );

  test('body cookie takes priority and missing cookie is rejected', () async {
    transport.body = {'code': 200, 'cookie': 'MUSIC_U=body'};
    transport.setCookie = ['MUSIC_U=header; HttpOnly'];
    expect(
      await provider.loginWithCode(
        phone: '13800138000',
        countryCode: '86',
        code: '123456',
      ),
      'MUSIC_U=body',
    );
    transport.body = {'code': 200};
    transport.setCookie = [];
    await expectLater(
      provider.loginWithCode(
        phone: '13800138000',
        countryCode: '86',
        code: '123456',
      ),
      throwsA(
        isA<AppError>().having((e) => e.code, 'code', 'provider.schemaChanged'),
      ),
    );
  });

  test(
    'classifies error categories and never retries authentication writes',
    () async {
      for (final item in [
        (503, '验证码错误', 'auth.codeInvalid'),
        (400, '验证码已过期', 'auth.codeExpired'),
        (509, '操作过于频繁', 'network.rateLimited'),
        (415, '安全验证', 'auth.verificationRequired'),
      ]) {
        transport.body = {'code': item.$1, 'message': item.$2};
        final count = transport.calls.length;
        await expectLater(
          provider.loginWithCode(
            phone: '13800138000',
            countryCode: '86',
            code: '123456',
          ),
          throwsA(isA<AppError>().having((e) => e.code, 'code', item.$3)),
        );
        expect(transport.calls.length, count + 1);
      }
    },
  );

  test(
    'HTTP preserves device name encoding and private routes ignore logging whitelists',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final logs = <String>[];
      final queries = <Uri>[];
      server.listen((request) async {
        queries.add(request.uri);
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json',
        );
        request.response.headers.add(
          HttpHeaders.setCookieHeader,
          'MUSIC_U=private-token; HttpOnly',
        );
        request.response.write(
          jsonEncode({
            'code': 200,
            'cookie': 'MUSIC_U=private-token',
            'phone': '13800138000',
            'captcha': '987654',
          }),
        );
        await request.response.close();
      });
      final http = HttpClient();
      final executor = ProviderRequestExecutor(
        client: http,
        enableLogging: true,
        logger: logs.add,
        responseWhitelist: {
          '/captcha/sent',
          '/login/cellphone',
          '/deviceinfo/center/upload',
        },
        cookieWhitelist: {
          '/captcha/sent',
          '/login/cellphone',
          '/deviceinfo/center/upload',
        },
      );
      try {
        for (final path in [
          '/captcha/sent',
          '/login/cellphone',
          '/deviceinfo/center/upload',
        ]) {
          await executor.getJsonResponse(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
            path: path,
            query: {
              'phone': '13800138000',
              'captcha': '987654',
              'cookie': 'MUSIC_U=private-token',
              'deviceName': '我的 Mac & PC',
            },
          );
        }
        expect(queries.last.queryParameters['deviceName'], '我的 Mac & PC');
        final log = logs.join('\n');
        for (final secret in [
          '13800138000',
          '987654',
          'private-token',
          '我的 Mac',
          'Response Body',
          'Set-Cookie',
        ]) {
          expect(log, isNot(contains(secret)));
        }
        await executor.executeTransport(
          transport,
          path: '/login/cellphone',
          params: {'phone': '13800138000', 'captcha': '987654'},
          cookie: 'MUSIC_U=private-token',
          deviceId: device,
          accountEpoch: 1,
        );
        expect(logs.last, isNot(contains('private-token')));
      } finally {
        http.close(force: true);
        await server.close(force: true);
      }
    },
  );
}
