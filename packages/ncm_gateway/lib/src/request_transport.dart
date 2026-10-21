import 'provider_endpoint.dart';

/// A deployment-independent NCM exchange. Authentication is a per-call snapshot.
abstract interface class NcmRequestTransport {
  ProviderEndpointState get state;
  Future<NcmTransportResponse> request({
    required String path,
    required Map<String, String> params,
    required String? cookie,
    required String deviceId,
    required int accountEpoch,
    required Duration budget,
    required int maxResponseBytes,
  });
  void cancelBeforeEpoch(int epoch);
  void dispose();
}

/// Raw SDK result; the gateway applies the same classification as HTTP.
final class NcmTransportResponse {
  const NcmTransportResponse({
    required this.status,
    required this.body,
    this.setCookie = const [],
    this.serverTime,
  });
  final int status;
  final Object? body;
  final List<String> setCookie;
  final DateTime? serverTime;
}
