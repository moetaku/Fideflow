import 'dart:async';
import 'dart:convert';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_host/media_host.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

final class _Api implements MediaCoreApi, NcmHostApi {
  @override
  bool supportsNcmHost = true;
  void Function(String)? sink;
  final requests = <Map<String, Object?>>[];
  final cancelled = <String>[];
  int opens = 0, closes = 0;
  bool failOpen = false;
  @override
  void openNcmHost(void Function(String) onEvent) {
    if (failOpen) throw const MediaCoreException(MediaCoreCode.internal);
    opens++;
    sink = onEvent;
  }

  @override
  void submitNcmHost(String document) =>
      requests.add(jsonDecode(document) as Map<String, Object?>);
  @override
  void cancelNcmHost(String id) => cancelled.add(id);
  @override
  void closeNcmHost() {
    closes++;
  }

  void answer(
    int index, {
    Object? body = const {'code': 200},
    String? error,
    List<String> cookies = const [],
  }) {
    final request = requests[index];
    sink!(
      jsonEncode({
        'schemaVersion': 1,
        'requestId': request['requestId'],
        'accountEpoch': request['accountEpoch'],
        'status': 200,
        'body': body,
        'setCookie': cookies,
        'error': ?error,
      }),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<NcmTransportResponse> _request(
  NativeNcmTransport transport, {
  int epoch = 0,
  Duration budget = const Duration(seconds: 1),
  String? cookie,
}) => transport.request(
  path: '/user/account',
  params: {},
  cookie: cookie,
  deviceId: 'A' * 52,
  accountEpoch: epoch,
  budget: budget,
  maxResponseBytes: 1024,
);

void main() {
  test(
    'out-of-order completions pair with credential snapshots; duplicate events drop',
    () async {
      final api = _Api();
      final transport = NativeNcmTransport(api);
      addTearDown(transport.dispose);
      final first = _request(transport, cookie: 'MUSIC_U=one');
      final second = _request(transport);
      api.answer(1, body: {'value': 2});
      api.answer(
        0,
        body: {'value': 1},
        cookies: ['MUSIC_U=authorized; HttpOnly'],
      );
      expect((await first).setCookie.single, contains('authorized'));
      expect((await second).body, {'value': 2});
      expect(api.requests[0]['cookie'], 'MUSIC_U=one');
      expect(api.requests[1]['cookie'], isNull);
      api.answer(0);
      expect(api.opens, 1);
    },
  );

  test(
    'epoch cancellation discards late results and allows new account',
    () async {
      final api = _Api();
      final transport = NativeNcmTransport(api);
      addTearDown(transport.dispose);
      final old = _request(transport);
      final rejected = expectLater(
        old,
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', 'auth.epochMismatch'),
        ),
      );
      transport.cancelBeforeEpoch(1);
      await rejected;
      api.answer(0);
      final fresh = _request(transport, epoch: 1);
      api.answer(1);
      await fresh;
      expect(api.cancelled, ['1']);
      await expectLater(_request(transport), throwsA(isA<AppError>()));
    },
  );

  test(
    'deadline cancels native work and disposal completes pending futures',
    () async {
      final api = _Api();
      final transport = NativeNcmTransport(api);
      await expectLater(
        _request(transport, budget: const Duration(milliseconds: 5)),
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', 'network.timeout'),
        ),
      );
      expect(api.cancelled, ['1']);
      final pending = _request(transport);
      final done = expectLater(pending, throwsA(isA<AppError>()));
      transport.dispose();
      await done;
      api.answer(1);
      transport.dispose();
      expect(api.closes, 1);
    },
  );

  test(
    'older ABI and initialization failure remain explicit and never submit',
    () async {
      for (final api in [
        _Api()..supportsNcmHost = false,
        _Api()..failOpen = true,
      ]) {
        final transport = NativeNcmTransport(api);
        await expectLater(
          _request(transport),
          throwsA(
            isA<AppError>().having(
              (e) => e.code,
              'code',
              'provider.unavailable',
            ),
          ),
        );
        expect(api.requests, isEmpty);
        transport.dispose();
      }
    },
  );

  for (final code in [
    'network.timeout',
    'network.unreachable',
    'ncm.responseTooLarge',
    'provider.schemaChanged',
  ]) {
    test('structured native failure $code maps to AppError', () async {
      final api = _Api();
      final transport = NativeNcmTransport(api);
      addTearDown(transport.dispose);
      final request = _request(transport);
      final result = expectLater(
        request,
        throwsA(isA<AppError>().having((e) => e.code, 'code', code)),
      );
      api.answer(0, error: code);
      await result;
    });
  }
}
