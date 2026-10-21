/// Phase 0 deployment configuration. The app still composes fake adapters.
final class RemoteProviderConfig {
  const RemoteProviderConfig({
    this.baseUrl = const String.fromEnvironment(
      'FF_PROVIDER_BASE_URL',
      defaultValue: 'http://127.0.0.1:8000',
    ),
    this.protocolVersion = 1,
  });

  final String baseUrl;
  final int protocolVersion;

  Uri get baseUri {
    final uri = Uri.parse(baseUrl);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Provider URL must be an absolute HTTP URL');
    }
    return uri;
  }
}
