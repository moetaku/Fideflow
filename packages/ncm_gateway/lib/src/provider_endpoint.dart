import 'dart:async';

import 'package:fideflow_domain/domain.dart';

import 'remote_provider_config.dart';

/// What the endpoint a provider calls is doing right now.
///
/// It exists so a page or a use case can tell "coming up" from "will not come
/// up" without knowing whether the endpoint is a LAN service or a local process
/// the Rust host supervises (docs/design/provider.md).
sealed class ProviderEndpointState {
  const ProviderEndpointState();
}

/// The endpoint is not answering yet, and something is still working on it.
final class ProviderEndpointStarting extends ProviderEndpointState {
  const ProviderEndpointStarting();
}

/// A serving in-process provider, without an HTTP endpoint.
final class ProviderHostReady extends ProviderEndpointState {
  const ProviderHostReady();
}

/// The endpoint answers, and this is its base URL.
final class ProviderEndpointReady extends ProviderEndpointState {
  const ProviderEndpointReady(this.baseUri);

  /// The base URL to call: scheme and authority only.
  final Uri baseUri;
}

/// The endpoint is not there and nothing is bringing it back.
///
/// [code] is the stable reason (`provider.unavailable` when
/// the reason was not a specific one), never a message or a URL.
final class ProviderEndpointUnavailable extends ProviderEndpointState {
  const ProviderEndpointUnavailable(this.code);

  /// The stable diagnostic code.
  final String code;
}

/// Where a provider's base URL comes from.
///
/// The provider itself only maps HTTP to the domain; where the HTTP is served
/// from - a remote service, or a child process the host owns - is this
/// interface's business, which keeps the deployment replaceable (docs/design/provider.md) and
/// keeps the provider's contract tests runnable without a process at all.
abstract interface class ProviderEndpoint {
  /// The current state, without waiting.
  ProviderEndpointState get state;

  /// State changes, with the current value first.
  Stream<ProviderEndpointState> watch();

  /// The base URL to use, waiting for it to appear.
  ///
  /// Throws an [AppError] with `provider.starting` while the endpoint is still
  /// coming up (the caller may try again) or `provider.unavailable` when it will
  /// not serve. Neither is retried here: retries belong to the caller's budget.
  Future<Uri> baseUri();
}

/// An endpoint at a fixed address: the remote service, and every test.
final class StaticProviderEndpoint implements ProviderEndpoint {
  StaticProviderEndpoint(this.config);

  /// The deployment configuration whose base URL is served.
  final RemoteProviderConfig config;

  @override
  ProviderEndpointState get state => ProviderEndpointReady(config.baseUri);

  @override
  Stream<ProviderEndpointState> watch() => Stream.value(state);

  @override
  Future<Uri> baseUri() async => config.baseUri;
}

/// An endpoint driven by callbacks.
///
/// This connects an externally managed HTTP endpoint without this package
/// depending on `dart:ffi`, the media host, or a process's lifetime: the
/// composition root knows both, and this class is the seam between them.
final class CallbackProviderEndpoint implements ProviderEndpoint {
  CallbackProviderEndpoint({
    required this.resolve,
    ProviderEndpointState Function()? current,
    this.states,
  }) : _current = current ?? (() => const ProviderEndpointStarting());

  /// Answers with the base URL to call, or throws an [AppError] saying why not.
  final Future<Uri> Function() resolve;

  /// The seam's state changes, if it has any to report.
  final Stream<ProviderEndpointState>? states;

  final ProviderEndpointState Function() _current;

  @override
  ProviderEndpointState get state => _current();

  @override
  Stream<ProviderEndpointState> watch() async* {
    yield state;
    final reported = states;
    if (reported != null) yield* reported;
  }

  @override
  Future<Uri> baseUri() async {
    try {
      return await resolve();
    } on AppError {
      rethrow;
    } catch (error) {
      // A seam that throws something the layers above cannot map is a bug; it
      // must still arrive as a domain error rather than a raw exception.
      throw AppError(
        category: AppErrorCategory.provider,
        code: 'provider.unavailable',
        retryable: true,
        diagnosticId: 'endpoint.unmapped.${error.runtimeType}',
      );
    }
  }
}
