import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('defaults to a loopback remote service deployment', () {
    const config = RemoteProviderConfig();
    expect(config.baseUri.host, '127.0.0.1');
    expect(config.baseUri.port, 8000);
    expect(config.protocolVersion, 1);
  });

  test('rejects a relative endpoint', () {
    const config = RemoteProviderConfig(baseUrl: '/provider');
    expect(() => config.baseUri, throwsFormatException);
  });
}
