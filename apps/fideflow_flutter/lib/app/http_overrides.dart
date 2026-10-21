import 'dart:io';

const browserUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const defaultImageHeaders = <String, String>{
  HttpHeaders.userAgentHeader: browserUserAgent,
};

/// Global [HttpOverrides] ensuring all Dart `HttpClient` requests (including
/// Flutter's [NetworkImage] and [Image.network]) identify with a standard
/// desktop browser User-Agent rather than `Dart/<version> (dart:io)`.
///
/// NetEase Cloud Music's CDN (`*.music.126.net`) blocks default Dart User-Agent
/// requests with HTTP 403 Forbidden (`X-Error-Info: ua_acl.access`).
final class AppHttpOverrides extends HttpOverrides {
  static void install() {
    if (HttpOverrides.current == null) {
      HttpOverrides.global = AppHttpOverrides();
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.userAgent = browserUserAgent;
    return client;
  }
}
