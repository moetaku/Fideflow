import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

void main() {
  const config = RemoteProviderConfig(baseUrl: 'http://192.168.55.13:8000');

  group('ProviderEndpoint', () {
    test('a static endpoint is ready with the configured base URL', () async {
      final endpoint = StaticProviderEndpoint(config);

      expect(
        endpoint.state,
        isA<ProviderEndpointReady>().having(
          (state) => state.baseUri,
          'baseUri',
          Uri.parse('http://192.168.55.13:8000'),
        ),
      );
      expect(await endpoint.baseUri(), Uri.parse('http://192.168.55.13:8000'));
      expect(
        await endpoint.watch().first,
        isA<ProviderEndpointReady>(),
        reason: 'a fixed endpoint has exactly one state to announce',
      );
    });

    test('a callback endpoint reports what the seam reports', () async {
      final ready = StreamController<ProviderEndpointState>();
      addTearDown(ready.close);
      final endpoint = CallbackProviderEndpoint(
        resolve: () async => Uri.parse('http://127.0.0.1:53421'),
        current: () => const ProviderEndpointStarting(),
        states: ready.stream,
      );

      expect(endpoint.state, isA<ProviderEndpointStarting>());
      expect(await endpoint.baseUri(), Uri.parse('http://127.0.0.1:53421'));

      ready.add(const ProviderEndpointUnavailable('provider.unavailable'));
      expect(
        await endpoint.watch().skip(1).first,
        isA<ProviderEndpointUnavailable>().having(
          (state) => state.code,
          'code',
          'provider.unavailable',
        ),
      );
    });

    test('a seam that throws something unknown still arrives as AppError', () {
      final endpoint = CallbackProviderEndpoint(
        resolve: () async => throw StateError('no endpoint'),
      );

      expect(
        endpoint.baseUri(),
        throwsA(
          isA<AppError>()
              .having(
                (error) => error.category,
                'category',
                AppErrorCategory.provider,
              )
              .having((error) => error.code, 'code', 'provider.unavailable'),
        ),
      );
    });

    test('a seam that reports a domain error keeps it', () {
      final endpoint = CallbackProviderEndpoint(
        resolve: () async => throw AppError(
          category: AppErrorCategory.provider,
          code: 'provider.starting',
          retryable: true,
        ),
      );

      expect(
        endpoint.baseUri(),
        throwsA(
          isA<AppError>().having(
            (error) => error.code,
            'code',
            'provider.starting',
          ),
        ),
      );
    });
  });

  group('RemoteNcmProvider over a local endpoint', () {
    late HttpServer server;
    late RemoteNcmProvider provider;
    final requests = <Uri>[];
    var baseUri = Uri.parse('http://127.0.0.1:1');

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${server.port}');
      provider = RemoteNcmProvider(
        endpoint: CallbackProviderEndpoint(resolve: () async => baseUri),
      );
    });

    tearDown(() async {
      provider.dispose();
      await server.close(force: true);
    });

    void serve(Object? body) {
      server.listen((request) async {
        requests.add(request.requestedUri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
    }

    test(
      'calls the endpoint it is given, not the configured default',
      () async {
        serve({
          'songs': [
            {
              'name': '靛青宇宙',
              'id': 3340137263,
              'dt': 147900,
              'ar': [
                {'id': 1, 'name': '鸣潮先约电台'},
              ],
              'al': {'id': 2, 'name': '飞行雪绒'},
            },
          ],
          'code': 200,
        });

        final track = await provider.getTrack(const TrackId('ncm-3340137263'));

        expect(localizedTestValue(track.title), '靛青宇宙');
        expect(requests.single.host, '127.0.0.1');
        expect(requests.single.port, server.port);
        expect(requests.single.path, '/song/detail');
      },
    );

    test('follows the endpoint when it moves', () async {
      serve({'songs': [], 'code': 200});

      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => second.close(force: true));
      second.listen((request) async {
        requests.add(request.requestedUri);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'songs': [], 'code': 200}));
        await request.response.close();
      });
      baseUri = Uri.parse('http://127.0.0.1:${second.port}');

      await expectLater(
        provider.getTrack(const TrackId('ncm-1')),
        throwsA(isA<AppError>()),
      );
      expect(
        requests.single.port,
        second.port,
        reason: 'a restarted provider comes back on a different port',
      );
    });

    test('an endpoint that is not serving fails before any socket', () async {
      var asked = false;
      final unavailable = RemoteNcmProvider(
        endpoint: CallbackProviderEndpoint(
          resolve: () async {
            asked = true;
            throw AppError(
              category: AppErrorCategory.provider,
              code: 'provider.starting',
              retryable: true,
            );
          },
        ),
      );
      addTearDown(unavailable.dispose);

      await expectLater(
        unavailable.getTrack(const TrackId('ncm-3340137263')),
        throwsA(
          isA<AppError>()
              .having((error) => error.code, 'code', 'provider.starting')
              .having((error) => error.retryable, 'retryable', true),
        ),
      );
      expect(asked, isTrue);
      expect(requests, isEmpty, reason: 'nothing was sent anywhere');
    });

    test('the default endpoint is still the configured remote service', () {
      final remote = RemoteNcmProvider(config: config);
      addTearDown(remote.dispose);

      expect(
        remote.endpointState,
        isA<ProviderEndpointReady>().having(
          (state) => state.baseUri,
          'baseUri',
          Uri.parse('http://192.168.55.13:8000'),
        ),
      );
    });
  });
}
