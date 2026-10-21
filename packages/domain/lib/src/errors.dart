enum AppErrorCategory {
  network,
  authentication,
  permission,
  provider,
  playback,
  storage,
  internal,
}

final class AppError implements Exception {
  const AppError({
    required this.category,
    required this.code,
    required this.retryable,
    this.diagnosticId,
  });

  final AppErrorCategory category;
  final String code;
  final bool retryable;
  final String? diagnosticId;

  @override
  String toString() => 'AppError($category, $code, retryable: $retryable)';
}
