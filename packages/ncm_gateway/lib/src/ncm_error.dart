/// The stable [AppError]s this package raises, built in one place.
///
/// The codes are wire values the application maps to words
/// (`packages/application/lib/src/ncm_message.dart`); the *category* and
/// `retryable` flag are what a recovery policy reads, so classification happens
/// here — at the boundary that saw the failure — rather than in a caller
/// guessing from a code string.
library;

import 'package:fideflow_domain/domain.dart';

/// A network condition a retry can survive: a timeout, a dropped connection, a
/// rate limit. The endpoint itself may be perfectly healthy.
AppError networkFailure(String code, String diagnosticId) => AppError(
  category: AppErrorCategory.network,
  code: code,
  retryable: true,
  diagnosticId: diagnosticId,
);

/// The endpoint answered, and the answer cannot be used.
///
/// [retryable] is false for the answers that describe the request or the pinned
/// service shape (a missing song, a body this gateway refuses to hold); the
/// service-side failures a retry may clear pass true.
AppError providerFailure(
  String code,
  String diagnosticId, {
  bool retryable = false,
}) => AppError(
  category: AppErrorCategory.provider,
  code: code,
  retryable: retryable,
  diagnosticId: diagnosticId,
);

/// The account has to sign in, or is not allowed to have the thing it asked for.
AppError accountFailure(
  String code,
  String diagnosticId, {
  required AppErrorCategory category,
}) => AppError(
  category: category,
  code: code,
  retryable: false,
  diagnosticId: diagnosticId,
);
