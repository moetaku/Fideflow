import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:fideflow_ncm_gateway/src/listen_target.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a connection completing after timeout is aborted without sending',
    () async {
      final client = _Client();
      final request = _Request();
      final executor = ProviderRequestExecutor(
        client: client,
        budget: const Duration(milliseconds: 10),
      );
      await expectLater(
        executor.getJson(
          baseUri: Uri.parse('http://localhost'),
          path: '/mutation',
          query: {},
        ),
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', 'network.timeout'),
        ),
      );
      client.pending.complete(request);
      await Future<void>.delayed(Duration.zero);
      expect(request.sent, isFalse);
      expect(request.aborted, isTrue);
    },
  );

  for (final status in [200, 500]) {
    test(
      'all diagnostic paths redact body and query secrets ($status)',
      () async {
        final logs = <String>[];
        final client = _Client()..pending.complete(_Request(status: status));
        final executor = ProviderRequestExecutor(
          client: client,
          enableLogging: true,
          responseWhitelist: {'/login/qr/check'},
          logger: logs.add,
        );
        try {
          await executor.getJson(
            baseUri: Uri.parse('http://localhost'),
            path: '/login/qr/check',
            query: {'key': 'private-qr-key', 'token': 'private-query-token'},
          );
        } on AppError {
          /* Error diagnostics use the same redaction boundary. */
        }
        final text = logs.join('\n');
        for (final secret in [
          'private-qr-key',
          'private-query-token',
          'private-cookie',
          'private-nested',
          'private-url',
        ]) {
          expect(text, isNot(contains(secret)));
        }
        expect(text, contains('[redacted]'));
      },
    );
  }

  test('resource target uses exact type and routes, never URL substrings', () {
    final album = parseListenTarget(
      'ALBUM',
      '123',
      'https://music.163.com/album?id=123&ref=playlist',
    );
    expect(album, isA<AlbumListenTarget>());
    final playlist = parseListenTarget(
      '',
      '',
      'https://music.163.com/#/playlist?id=5678',
    );
    expect(
      (playlist as PlaylistListenTarget).id,
      const PlaylistId('ncm-playlist-5678'),
    );
    expect(
      (parseListenTarget('ALBUM', '0', 'https://music.163.com/album?id=90')
              as AlbumListenTarget)
          .id,
      const AlbumId('ncm-album-90'),
    );
    expect(
      parseListenTarget('ALBUM', '', 'https://music.163.com/playlist/90'),
      isA<UnknownListenTarget>(),
    );
    expect(
      parseListenTarget('', '123', 'https://example.test/page?redirect=album'),
      isA<UnknownListenTarget>(),
    );
    expect(parseListenTarget('ALBUM', '-1', null), isA<UnknownListenTarget>());
  });
}

class _Client implements HttpClient {
  final pending = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> getUrl(Uri url) => pending.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request({this.status = 200});
  final int status;
  bool sent = false, aborted = false;
  @override
  Future<HttpClientResponse> close() async {
    sent = true;
    return _Response(status);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  String? value(String name) => null;
  @override
  List<String>? operator [](String name) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode);
  @override
  final int statusCode;
  @override
  HttpHeaders get headers => _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream.value(
        utf8.encode(
          jsonEncode({
            'code': statusCode,
            'cookie': 'private-cookie',
            'nested': {'token': 'private-nested'},
            'url': 'private-url',
          }),
        ),
      ).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
