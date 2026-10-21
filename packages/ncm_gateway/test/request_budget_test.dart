import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

import '../../../tooling/test_localization.dart';

/// The gateway's network boundary, against a local HTTP fixture.
///
/// Each case is a thing a real peer does to a client: never finishing a body,
/// answering with something huge, dropping the connection, changing the payload
/// shape, or answering with a failure status. The contract every case has to
/// keep is the same — the call ends, and it ends as a stable [AppError] with the
/// category and `retryable` flag a recovery policy reads.
void main() {
  group('the request budget and the error taxonomy', () {
    final servers = <HttpServer>[];
    final sockets = <ServerSocket>[];
    final clients = <HttpClient>[];

    tearDown(() async {
      for (final client in clients) {
        client.close(force: true);
      }
      clients.clear();
      for (final server in servers) {
        await server.close(force: true);
      }
      servers.clear();
      for (final socket in sockets) {
        await socket.close();
      }
      sockets.clear();
    });

    RemoteNcmProvider providerAt(
      String baseUrl, {
      Duration budget = const Duration(seconds: 5),
      int maxResponseBytes = defaultMaxResponseBytes,
    }) {
      final client = HttpClient();
      clients.add(client);
      return RemoteNcmProvider(
        config: RemoteProviderConfig(baseUrl: baseUrl),
        client: client,
        timeout: budget,
        maxResponseBytes: maxResponseBytes,
      );
    }

    /// A provider whose every request is answered by [handler], on a server of
    /// its own so two providers in one test cannot share a request stream.
    Future<RemoteNcmProvider> providerFor(
      Future<void> Function(HttpRequest request) handler, {
      Duration budget = const Duration(seconds: 5),
      int maxResponseBytes = defaultMaxResponseBytes,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      server.listen((request) => unawaited(handler(request)));
      return providerAt(
        'http://127.0.0.1:${server.port}',
        budget: budget,
        maxResponseBytes: maxResponseBytes,
      );
    }

    /// A provider pointed at a port nothing is listening on.
    Future<RemoteNcmProvider> providerAtADeadPort() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      return providerAt(
        'http://127.0.0.1:$port',
        budget: const Duration(seconds: 3),
      );
    }

    Future<Track> trackFrom(RemoteNcmProvider provider) =>
        provider.getTrack(const TrackId('ncm-3340137263'));

    /// Runs [call], requires it to fail, and returns the stable error.
    Future<AppError> failureOf(Future<Object?> Function() call) async {
      try {
        await call();
      } on AppError catch (error) {
        return error;
      } catch (error) {
        fail('a non-AppError escaped the gateway: $error');
      }
      fail('the call was expected to fail');
    }

    Future<void> answer(
      HttpRequest request, {
      int status = 200,
      required String body,
    }) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    }

    /// A raw socket that answers with [head] and then does whatever the test
    /// wants, which is the only way to produce a truncated or endless body.
    Future<String> rawServer(
      String head,
      Future<void> Function(Socket socket) afterwards,
    ) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sockets.add(server);
      server.listen((socket) {
        socket.listen((_) {}, onError: (_) {});
        unawaited(() async {
          socket.write(head);
          await socket.flush();
          await afterwards(socket);
        }());
      });
      return 'http://127.0.0.1:${server.port}';
    }

    test('a body that never ends still ends the request', () async {
      var calls = 0;
      final provider = await providerFor(
        budget: const Duration(milliseconds: 400),
        (request) async {
          calls++;
          if (calls == 1) {
            request.response.statusCode = 200;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"songs": [');
            await request.response.flush();
            // The body never finishes; only the client's own deadline can end
            // this exchange.
            return;
          }
          await answer(
            request,
            body: jsonEncode({
              'songs': [
                {'id': 3340137263, 'name': '靛青宇宙', 'dt': 1000},
              ],
              'code': 200,
            }),
          );
        },
      );

      final stopwatch = Stopwatch()..start();
      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'network.timeout');
      expect(error.category, AppErrorCategory.network);
      expect(error.retryable, isTrue);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'a hanging body must not outlive the budget',
      );
      expect(error.diagnosticId, contains('/song/detail'));
      expect(
        '${error.diagnosticId}',
        isNot(contains('127.0.0.1')),
        reason: 'a diagnostic names the route, never the endpoint',
      );

      // The cut connection left the client usable: the next request is normal.
      final track = await trackFrom(provider);
      expect(localizedTestValue(track.title), '靛青宇宙');
      expect(calls, 2);
    });

    test('a body past the cap is refused and the socket closed', () async {
      final provider = await providerFor(
        maxResponseBytes: 1024,
        (request) => answer(request, body: '{"songs": ${'x' * 4096}}'),
      );

      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'ncm.responseTooLarge');
      expect(error.category, AppErrorCategory.provider);
      expect(error.retryable, isFalse);
    });

    test('large playlist replies fit their separate bounded cap', () async {
      final padding = 'x' * (defaultMaxResponseBytes + 1024);
      final provider = await providerFor((request) async {
        if (request.uri.path == '/playlist/detail') {
          await answer(
            request,
            body: jsonEncode({
              'code': 200,
              'playlist': {
                'id': 24381616,
                'name': '大型歌单',
                'trackCount': 0,
                'tracks': [],
              },
              'privileges': [padding],
            }),
          );
        } else {
          await answer(
            request,
            body: jsonEncode({'code': 200, 'songs': [], 'padding': padding}),
          );
        }
      });

      final detail = await provider.getPlaylist(
        const PlaylistId('ncm-playlist-24381616'),
      );
      final page = await provider.getPlaylistTracks(
        const PlaylistId('ncm-playlist-24381616'),
      );

      expect(localizedTestValue(detail.summary.title), '大型歌单');
      expect(detail.tracks, isEmpty);
      expect(page.items, isEmpty);
    });

    test('a connection that drops mid-body reads as unreachable', () async {
      final baseUrl = await rawServer(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: application/json\r\n'
        // A length the peer will never finish writing.
        'Content-Length: 4096\r\n\r\n'
        '{"songs": [',
        (socket) async => socket.destroy(),
      );
      final provider = providerAt(baseUrl, budget: const Duration(seconds: 5));

      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'network.unreachable');
      expect(error.category, AppErrorCategory.network);
      expect(error.retryable, isTrue);
    });

    test('a response that never arrives ends within the budget', () async {
      final baseUrl = await rawServer(
        'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n',
        // Headers, then silence: no body, no close ever.
        (socket) => Completer<void>().future,
      );
      final provider = providerAt(
        baseUrl,
        budget: const Duration(milliseconds: 400),
      );

      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'network.timeout');
      expect(error.retryable, isTrue);
    });

    test(
      'an endpoint that is not listening is a retryable network failure',
      () async {
        final provider = await providerAtADeadPort();

        final error = await failureOf(() => trackFrom(provider));

        expect(error.code, 'network.unreachable');
        expect(error.category, AppErrorCategory.network);
        expect(error.retryable, isTrue);
      },
    );

    test('prose where JSON belongs is a schema change, not a crash', () async {
      final provider = await providerFor(
        (request) => answer(request, body: '<html>gateway</html>'),
      );

      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'provider.schemaChanged');
      expect(error.category, AppErrorCategory.provider);
      expect(error.retryable, isFalse);
    });

    test('a JSON body of the wrong shape is a schema change', () async {
      final provider = await providerFor(
        (request) => answer(request, body: '[1, 2, 3]'),
      );

      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'provider.schemaChanged');
      expect(error.retryable, isFalse);
    });

    test(
      'songs of the wrong type is a schema change, an empty list is not',
      () async {
        final wrongType = await providerFor(
          (request) => answer(request, body: jsonEncode({'songs': 'oops'})),
        );
        expect(
          (await failureOf(() => trackFrom(wrongType))).code,
          'provider.schemaChanged',
        );

        final empty = await providerFor(
          (request) => answer(request, body: jsonEncode({'songs': []})),
        );
        expect(
          (await failureOf(() => trackFrom(empty))).code,
          'ncm.trackNotFound',
        );
      },
    );

    test('a field of the wrong type never escapes as a TypeError', () async {
      final provider = await providerFor(
        (request) => answer(
          request,
          body: jsonEncode({
            'songs': [
              {
                'id': 3340137263,
                'name': '靛青宇宙',
                'ar': 'nope',
                'al': 'nope',
                'dt': 'nope',
              },
            ],
            'code': 200,
          }),
        ),
      );

      final mapped = await trackFrom(provider);

      expect(localizedTestValue(mapped.title), '靛青宇宙');
      expect(localizedTestValue(mapped.artists.single.name), '未知艺术家');
      expect(localizedTestValue(mapped.album.title), '单曲');
      expect(mapped.duration, Duration.zero);
    });

    test('each failure status becomes its own stable error', () async {
      Future<AppError> forStatus(int status) async {
        final provider = await providerFor(
          (request) => answer(request, status: status, body: '{}'),
        );
        return failureOf(() => trackFrom(provider));
      }

      // A refused request is the request's problem, not the service's shape:
      // the fixed provider folds an out-of-range upstream code (netease's
      // `-460 cheating`, for one) into this status.
      final badRequest = await forStatus(HttpStatus.badRequest);
      expect(badRequest.code, 'ncm.badRequest');
      expect(badRequest.category, AppErrorCategory.provider);
      expect(badRequest.retryable, isFalse);

      final rateLimited = await forStatus(HttpStatus.tooManyRequests);
      expect(rateLimited.code, 'network.rateLimited');
      expect(rateLimited.category, AppErrorCategory.network);
      expect(rateLimited.retryable, isTrue);

      final upstream = await forStatus(HttpStatus.badGateway);
      expect(upstream.code, 'ncm.upstreamError');
      expect(upstream.category, AppErrorCategory.provider);
      expect(
        upstream.retryable,
        isTrue,
        reason: 'a 5xx is a condition a retry can clear, not a schema change',
      );

      final unauthorized = await forStatus(HttpStatus.unauthorized);
      expect(unauthorized.code, 'ncm.authRequired');
      expect(unauthorized.category, AppErrorCategory.authentication);
      expect(unauthorized.retryable, isFalse);

      final forbidden = await forStatus(HttpStatus.forbidden);
      expect(forbidden.code, 'ncm.permissionDenied');
      expect(forbidden.category, AppErrorCategory.permission);

      final missing = await forStatus(HttpStatus.notFound);
      expect(missing.code, 'ncm.trackNotFound');
    });

    test('a business code inside a 2xx body is classified too', () async {
      // The route map answers an expired session with HTTP 200 and `code: 301`.
      final provider = await providerFor(
        (request) =>
            answer(request, body: jsonEncode({'code': 301, 'msg': '需要登录'})),
      );

      final error = await failureOf(() => trackFrom(provider));

      expect(error.code, 'ncm.authRequired');
      expect(error.category, AppErrorCategory.authentication);
      expect(error.retryable, isFalse);
    });

    test(
      'a 400 business code is a refused request, not a schema change',
      () async {
        // The route map normalises 400 into a 2xx with the original code in the
        // body, so this failure reaches the classifier through the body path.
        final provider = await providerFor(
          (request) =>
              answer(request, body: jsonEncode({'code': 400, 'msg': '参数错误'})),
        );

        final error = await failureOf(() => trackFrom(provider));

        expect(error.code, 'ncm.badRequest');
        expect(error.category, AppErrorCategory.provider);
        expect(error.retryable, isFalse);
      },
    );

    test(
      'a successful answer with code 200 is not mistaken for a failure',
      () async {
        final provider = await providerFor(
          (request) => answer(
            request,
            body: jsonEncode({
              'songs': [
                {'id': 3340137263, 'name': '靛青宇宙', 'dt': 147900},
              ],
              'code': 200,
            }),
          ),
        );

        expect(localizedTestValue((await trackFrom(provider)).title), '靛青宇宙');
      },
    );

    test('an error body that never ends does not strand the caller', () async {
      final provider = await providerFor(
        budget: const Duration(milliseconds: 400),
        (request) async {
          request.response.statusCode = 502;
          request.response.write('{"code":');
          await request.response.flush();
        },
      );

      final error = await failureOf(() => trackFrom(provider));

      expect(
        ['network.timeout', 'ncm.upstreamError'],
        contains(error.code),
        reason: 'an error body is read inside the budget, never past it',
      );
      expect(error.retryable, isTrue);
    });
  });
}
