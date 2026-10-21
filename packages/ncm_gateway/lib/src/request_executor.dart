import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fideflow_domain/domain.dart';

import 'ncm_error.dart';
import 'request_transport.dart';

/// How long one provider request may take **in total**: connecting, answering
/// and reading the body. It is deliberately one budget rather than a per-phase
/// one, because a slow body is as able to strand the UI as a slow connect.
const defaultRequestBudget = Duration(seconds: 15);

/// One answered request: the decoded body, plus the `Set-Cookie` values a login
/// route needs (see [ProviderRequestExecutor.getJsonResponse]).
typedef ProviderResponse = ({
  Map<String, Object?> body,
  List<String> setCookie,
});

/// The largest response body this gateway will hold in memory.
///
/// Most catalog and source answers are kilobytes. Playlist routes use an
/// explicit larger bound because their replies contain large unused arrays.
const defaultMaxResponseBytes = 2 * 1024 * 1024;

/// How much of an *error* response is read before the socket is closed.
const _errorBodyLimit = 8 * 1024;

/// Runs the provider's HTTP calls inside one budget, with the provider's error
/// taxonomy applied in the same place.
///
/// Two guarantees make the rest of the app's error handling possible:
///
/// * **every request ends** — within [budget], by aborting the socket, whatever
///   the peer does (a body that never finishes, one that never ends, a slow
///   connect);
/// * **every failure is an [AppError]** with a stable code and a category — a
///   socket error, a TLS failure, invalid JSON and a field of the wrong type all
///   become the same vocabulary the UI already maps, so a caller that catches
///   [AppError] catches everything.
///
/// Diagnostics stay bounded and sanitized: they name the route, never the full
/// URL, the query string or a credential.
final class ProviderRequestExecutor {
  const ProviderRequestExecutor({
    required this.client,
    this.budget = defaultRequestBudget,
    this.maxResponseBytes = defaultMaxResponseBytes,
    this.enableLogging = false,
    this.responseWhitelist = const {},
    this.cookieWhitelist = defaultCookieWhitelist,
    this.logger,
    this.onServerTime,
  });

  /// Default routes where request cookies and response Set-Cookie headers are logged.
  static const defaultCookieWhitelist = <String>{
    '/login/qr/key',
    '/login/qr/create',
    '/login/qr/check',
    '/user/account',
    '/logout',
  };

  /// The HTTP client every request goes through.
  final void Function(DateTime)? onServerTime;
  final HttpClient client;

  /// The total time one request may take.
  final Duration budget;

  /// The largest body this executor will read.
  final int maxResponseBytes;

  /// Whether HTTP request and response logging is enabled.
  final bool enableLogging;

  /// Routes whose response bodies are printed when [enableLogging] is true.
  final Set<String> responseWhitelist;

  /// Routes whose cookies (Request Cookie and Set-Cookie) are printed when [enableLogging] is true.
  final Set<String> cookieWhitelist;

  /// Custom logger output callback (defaults to `print`).
  final void Function(String message)? logger;

  void _log(String message) {
    if (logger != null) {
      logger!(message);
    } else {
      // ignore: avoid_print
      print(message);
    }
  }

  /// Runs one `GET` and decodes its JSON-object body.
  ///
  /// [baseUri] is already resolved: an endpoint that is not serving throws its
  /// own `provider.*` error before this is called, and waiting for a local
  /// service to come up is not something this budget should cut short.
  Future<Map<String, Object?>> getJson({
    required Uri baseUri,
    required String path,
    required Map<String, String> query,
  }) async =>
      (await getJsonResponse(baseUri: baseUri, path: path, query: query)).body;

  /// Runs one `GET` and returns its body *and* the `Set-Cookie` values.
  ///
  /// Most routes only need [ProviderResponse.body]; the login route also needs
  /// the cookies, because the two deployments of this API disagree about where
  /// they put them: the Node wrapper copies them into the body, while the pinned
  /// provider forwards Netease's answer untouched and hands them back as response
  /// headers. Reading only the body therefore works against one deployment and
  /// silently fails against the other.
  Future<ProviderResponse> getJsonResponse({
    required Uri baseUri,
    required String path,
    required Map<String, String> query,
    int? responseLimitBytes,
  }) async {
    final timedOut = networkFailure(
      'network.timeout',
      'ncm.request.timeout.$path',
    );
    final uri = baseUri.replace(path: path, queryParameters: query);
    HttpClientRequest? request;
    var cancelled = false;

    Future<ProviderResponse> exchange() async {
      final stopwatch = enableLogging ? (Stopwatch()..start()) : null;
      if (enableLogging) {
        _logRequest(path: path, uri: uri, query: query);
      }
      final opened = await client.getUrl(uri);
      request = opened;
      if (cancelled) {
        opened.abort();
        throw timedOut;
      }
      final response = await opened.close();
      if (cancelled) throw timedOut;
      final date = response.headers.value(HttpHeaders.dateHeader);
      if (date != null) {
        try {
          onServerTime?.call(HttpDate.parse(date));
        } catch (_) {}
      }
      final setCookie = _setCookieValues(response);

      if (response.statusCode != HttpStatus.ok) {
        final body = await _readErrorBody(response, opened);
        if (cancelled) throw timedOut;
        if (enableLogging) {
          _logResponse(
            path: path,
            status: response.statusCode,
            elapsed: stopwatch?.elapsed,
            setCookie: setCookie,
            body: body,
          );
        }
        throw _statusError(response.statusCode, body, path);
      }
      // Headers first: they are complete as soon as the response arrives, while
      // reading the body is what can abort the socket.
      final decoded = _decode(
        await _readBody(
          response,
          opened,
          path,
          responseLimitBytes ?? maxResponseBytes,
        ),
        path,
      );
      if (cancelled) throw timedOut;

      if (enableLogging) {
        final shouldLogBody = responseWhitelist.contains(path);
        _logResponse(
          path: path,
          status: response.statusCode,
          elapsed: stopwatch?.elapsed,
          setCookie: setCookie,
          body: shouldLogBody ? decoded : null,
        );
      }

      return (body: _classified(decoded, path), setCookie: setCookie);
    }

    try {
      // One deadline over the *whole* exchange — connecting, answering and
      // reading the body — because a peer that trickles a body can strand a
      // caller exactly as well as one that never answers. The socket is cut
      // rather than merely abandoned: a body nobody will read must not keep the
      // connection, or the busy state that owns it, alive behind us.
      return await exchange().timeout(
        budget,
        onTimeout: () {
          cancelled = true;
          request?.abort();
          throw timedOut;
        },
      );
    } on AppError {
      rethrow;
    } on HandshakeException {
      // TLS: an untrusted or unreachable endpoint, not a data problem.
      throw networkFailure('network.unreachable', 'ncm.tls.$path');
    } on SocketException {
      throw networkFailure('network.unreachable', 'ncm.socket.$path');
    } on HttpException {
      // An aborted or truncated exchange, and whatever the abort surfaces.
      throw networkFailure('network.unreachable', 'ncm.transport.$path');
    } on FormatException {
      throw providerFailure('provider.schemaChanged', 'ncm.json.$path');
    } on TimeoutException {
      throw timedOut;
    }
  }

  /// Classifies an in-process exchange with the existing HTTP business rules.
  Future<ProviderResponse> executeTransport(
    NcmRequestTransport transport, {
    required String path,
    required Map<String, String> params,
    required String? cookie,
    required String deviceId,
    required int accountEpoch,
    int? responseLimitBytes,
  }) async {
    if (enableLogging) {
      _log('[NCM Host] --> $path query: $params');
      if (path == '/playlist/catlist') {
        _log(
          '[NCM Host] $path upstream=/eapi/playlist/catalogue '
          'crypto=eapi uaPolicy=explicit-override-or-default-iphone '
          'budgetMs=${budget.inMilliseconds} '
          'maxResponseBytes=${responseLimitBytes ?? maxResponseBytes}',
        );
      }
    }
    final stopwatch = enableLogging ? (Stopwatch()..start()) : null;
    final NcmTransportResponse response;
    try {
      response = await transport.request(
        path: path,
        params: params,
        cookie: cookie,
        deviceId: deviceId,
        accountEpoch: accountEpoch,
        budget: budget,
        maxResponseBytes: responseLimitBytes ?? maxResponseBytes,
      );
    } on AppError catch (error) {
      if (enableLogging) {
        _log(
          '[NCM Host] <-- failed $path '
          'elapsedMs=${stopwatch?.elapsedMilliseconds} '
          'budgetMs=${budget.inMilliseconds} code=${error.code} '
          'diagnostic=${error.diagnosticId} retryable=${error.retryable}',
        );
      }
      rethrow;
    }
    final time = response.serverTime;
    if (time != null) onServerTime?.call(time);
    final body = response.body;
    if (body is! Map<String, Object?>) {
      throw providerFailure('provider.schemaChanged', 'ncm.host.shape.$path');
    }
    if (enableLogging) {
      _logResponse(
        path: path,
        status: response.status,
        elapsed: stopwatch?.elapsed,
        setCookie: response.setCookie,
        body: responseWhitelist.contains(path) ? body : null,
      );
    }
    if (response.status != HttpStatus.ok) {
      throw _statusError(response.status, body, path);
    }
    return (body: _classified(body, path), setCookie: response.setCookie);
  }

  void _logRequest({
    required String path,
    required Uri uri,
    required Map<String, String> query,
  }) {
    final sanitizedQuery = Map<String, String>.from(query);
    final cookie = sanitizedQuery.remove('cookie');
    _log('[NCM] --> GET $path query: ${_safeLogValue(sanitizedQuery)}');
    if (!_privateLoginRoute(path) &&
        cookieWhitelist.contains(path) &&
        cookie != null &&
        cookie.isNotEmpty) {
      _log('[NCM Cookies] Request Cookie: ${maskCookieString(cookie)}');
    }
  }

  static bool _privateLoginRoute(String path) => const {
    '/captcha/sent',
    '/login/cellphone',
    '/deviceinfo/center/upload',
  }.contains(path);

  void _logResponse({
    required String path,
    required int status,
    Duration? elapsed,
    List<String>? setCookie,
    Object? body,
  }) {
    final ms = elapsed != null ? ' (${elapsed.inMilliseconds}ms)' : '';
    _log('[NCM] <-- $status $path$ms');
    if (!_privateLoginRoute(path) &&
        cookieWhitelist.contains(path) &&
        setCookie != null &&
        setCookie.isNotEmpty) {
      for (final header in setCookie) {
        _log('[NCM Cookies] Set-Cookie: ${maskSetCookieHeader(header)}');
      }
    }
    if (!_privateLoginRoute(path) && body != null) {
      _log('[NCM Response Body] $path:\n${_formatBody(body)}');
    }
  }

  static Object? _safeLogValue(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): switch (entry.key.toString().toLowerCase()) {
            'code' || 'status' || 'limit' || 'offset' || 'timestamp' =>
              entry.value is num || entry.value is bool
                  ? entry.value
                  : '[redacted]',
            _ => '[redacted]',
          },
      };
    }
    return '[redacted]';
  }

  static String _formatBody(Object body) {
    try {
      final text = const JsonEncoder.withIndent(
        '  ',
      ).convert(_safeLogValue(body));
      if (text.length > 10000) {
        return '${text.substring(0, 10000)}\n... [truncated, total: ${text.length} chars]';
      }
      return text;
    } catch (_) {
      return '[unavailable]';
    }
  }

  /// Masks sensitive tokens in a cookie string (e.g. `query['cookie']`).
  static String maskCookieString(String cookie) {
    if (cookie.isEmpty) return cookie;
    return cookie
        .split(';')
        .map((pair) {
          final trimmed = pair.trim();
          final eqIndex = trimmed.indexOf('=');
          if (eqIndex <= 0) return '[redacted]';
          final name = trimmed.substring(0, eqIndex).trim();
          final value = trimmed.substring(eqIndex + 1).trim();
          final upperName = name.toUpperCase();
          if (upperName == 'MUSIC_U' || upperName == 'MUSIC_A') {
            if (value.isEmpty) return '$name= (cleared)';
            if (value.length > 10) {
              return '$name=${value.substring(0, 6)}***${value.substring(value.length - 4)} (len: ${value.length})';
            }
            return '$name=***';
          }
          if (name == 'deviceId' && value.length > 8) {
            return '$name=${value.substring(0, 8)}...';
          }
          if (name == '__csrf' && value.length > 8) {
            return '$name=${value.substring(0, 4)}***';
          }
          return '$name=[redacted]';
        })
        .join('; ');
  }

  /// Masks sensitive cookie values in a `Set-Cookie` response header.
  static String maskSetCookieHeader(String header) {
    if (header.isEmpty) return header;
    final parts = header.split(';');
    if (parts.isEmpty) return header;
    final cookiePart = maskCookieString(parts.first);
    if (parts.length == 1) return cookiePart;
    final attributes = parts.skip(1).join(';');
    return '$cookiePart;$attributes';
  }

  /// The `Set-Cookie` header values of [response], each with its attributes
  /// still attached (`MUSIC_U=…; Max-Age=…; Path=/; HTTPOnly`). Which of the
  /// attributes matter, and which parts are cookies, is the caller's business:
  /// this executor reports the exchange, it does not interpret it.
  static List<String> _setCookieValues(HttpClientResponse response) =>
      response.headers[HttpHeaders.setCookieHeader] ?? const [];

  /// Reads at most the bound chosen for this successful body.
  Future<Uint8List> _readBody(
    HttpClientResponse response,
    HttpClientRequest request,
    String path,
    int responseLimitBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > responseLimitBytes) {
        request.abort();
        throw providerFailure(
          'ncm.responseTooLarge',
          'ncm.body.tooLarge.$path',
        );
      }
    }
    return bytes.takeBytes();
  }

  /// Reads a bounded prefix of an error body, so a small error document can be
  /// classified but a large one is never held.
  Future<Map<String, Object?>> _readErrorBody(
    HttpClientResponse response,
    HttpClientRequest request,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _errorBodyLimit) {
        request.abort();
        break;
      }
      bytes.add(chunk);
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      // An error body that is not JSON is not worth guessing at; the status code
      // is the classification.
      return const {};
    }
  }

  /// Refuses a successful body that carries a failure in its business code.
  ///
  /// The pinned route map answers some failures inside a 2xx body — an expired
  /// session is `{"code": 301}` with status 200 — so a caller that only looked
  /// at the payload would report "no such song" for a login problem. A code with
  /// no mapping of its own is left to the payload mappers, which know what an
  /// absent field means for their own route.
  Map<String, Object?> _classified(Map<String, Object?> body, String path) {
    final loginError = _loginError(body, path);
    if (loginError != null) throw loginError;
    final business = body['code'];
    if (business is num && business != HttpStatus.ok) {
      final mapped = _businessError(business.toInt(), path);
      if (mapped != null) throw mapped;
    }
    return body;
  }

  /// Decodes a successful body into the JSON object the mappers expect.
  Map<String, Object?> _decode(Uint8List bytes, String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw providerFailure('provider.schemaChanged', 'ncm.http.shape.$path');
    }
    if (decoded is! Map<String, Object?>) {
      throw providerFailure('provider.schemaChanged', 'ncm.http.shape.$path');
    }
    return decoded;
  }

  /// The [AppError] one non-2xx answer maps to.
  ///
  /// The pinned route map answers some failures inside a 2xx body (`code: 301`
  /// for an expired session), so a business code in the body is consulted first,
  /// then the status.
  AppError _statusError(int status, Map<String, Object?> body, String path) {
    final loginError = _loginError(body, path);
    if (loginError != null) return loginError;
    final business = body['code'];
    if (business is num && business != HttpStatus.ok) {
      final mapped = _businessError(business.toInt(), path);
      if (mapped != null) return mapped;
    }
    return switch (status) {
      HttpStatus.unauthorized => accountFailure(
        'ncm.authRequired',
        'ncm.http.401.$path',
        category: AppErrorCategory.authentication,
      ),
      HttpStatus.forbidden => accountFailure(
        'ncm.permissionDenied',
        'ncm.http.403.$path',
        category: AppErrorCategory.permission,
      ),
      HttpStatus.badRequest => providerFailure(
        'ncm.badRequest',
        'ncm.http.400.$path',
      ),
      HttpStatus.notFound => providerFailure(
        'ncm.trackNotFound',
        'ncm.http.404.$path',
      ),
      HttpStatus.tooManyRequests => networkFailure(
        'network.rateLimited',
        'ncm.http.429.$path',
      ),
      // The service itself is unwell: a retry is the right first response, which
      // is why this is no longer reported as a schema change.
      >= 500 => providerFailure(
        'ncm.upstreamError',
        'ncm.http.$status.$path',
        retryable: true,
      ),
      _ => providerFailure('provider.schemaChanged', 'ncm.http.$status.$path'),
    };
  }

  AppError? _loginError(Map<String, Object?> body, String path) {
    if ((path != '/captcha/sent' && path != '/login/cellphone') ||
        body['code'] == 200) {
      return null;
    }
    // Interpret only known error categories; never expose remote text in UI or diagnostics.
    final message = '${body['message'] ?? body['msg'] ?? ''}'.toLowerCase();
    final code = switch (message) {
      final text when RegExp(r'过期|失效|expired').hasMatch(text) =>
        'auth.codeExpired',
      final text
          when RegExp(
            r'验证码错误|验证码不正确|验证码不匹配|invalid.*code|incorrect.*code',
          ).hasMatch(text) =>
        'auth.codeInvalid',
      final text when RegExp(r'频繁|次数|上限|too many|rate limit').hasMatch(text) =>
        'network.rateLimited',
      final text
          when RegExp(
            r'安全验证|滑块|风控|captcha required|verifycaptcha',
          ).hasMatch(text) =>
        'auth.verificationRequired',
      _ => null,
    };
    return code == null
        ? null
        : providerFailure(code, 'ncm.login.rejected.$path');
  }

  /// The business codes a 2xx body can carry, as the stable errors they mean.
  AppError? _businessError(int code, String path) {
    if (path == '/captcha/sent' || path == '/login/cellphone') {
      final mapped = switch (code) {
        501 => 'auth.phoneNotRegistered',
        502 || 503 => 'network.rateLimited',
        509 => 'network.rateLimited',
        506 => 'auth.codeInvalid',
        415 || 416 || 405 || -460 || 460 => 'auth.verificationRequired',
        _ => null,
      };
      if (mapped != null) {
        return providerFailure(mapped, 'ncm.login.$code.$path');
      }
    }
    return switch (code) {
      // 需要登录 / 登录态失效.
      301 || 401 => accountFailure(
        'ncm.authRequired',
        'ncm.body.$code.$path',
        category: AppErrorCategory.authentication,
      ),
      // 无权限（例如需要会员）.
      403 => accountFailure(
        'ncm.permissionDenied',
        'ncm.body.$code.$path',
        category: AppErrorCategory.permission,
      ),
      // 参数/风控拒绝：fixed provider 把 `100..600` 之外的上游业务码（例如
      // `-460 cheating`）折成 400，而 400 又在特殊状态码表里被归一为 200，所以
      // 这条既可能以 HTTP 400 到达，也可能是 2xx body 里的 400。它是"请求被拒"，
      // 不是"服务改了结构"，两者对恢复策略的含义完全不同。
      400 => providerFailure('ncm.badRequest', 'ncm.body.400.$path'),
      _ => null,
    };
  }
}
