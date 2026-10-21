import 'dart:io';

import 'package:fideflow/app/http_overrides.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppHttpOverrides installs and applies desktop browser user-agent', () {
    AppHttpOverrides.install();
    final client = HttpClient();
    expect(client.userAgent, contains('Mozilla/5.0'));
    expect(client.userAgent, contains('Chrome/'));
    client.close(force: true);
  });
}
