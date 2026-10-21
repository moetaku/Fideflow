final class ProviderCapabilities {
  const ProviderCapabilities({
    required this.protocolVersion,
    required this.supportsQrLogin,
    required this.supportsLossless,
  });

  final int protocolVersion;
  final bool supportsQrLogin;
  final bool supportsLossless;
}

abstract interface class NcmProvider {
  Future<ProviderCapabilities> negotiateCapabilities();
}
