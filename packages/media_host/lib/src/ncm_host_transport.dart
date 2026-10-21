import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';

import 'media_core_api.dart';

/// Optional ABI capability. Older hosts remain usable in explicit HTTP modes.
abstract interface class NcmHostApi {
  bool get supportsNcmHost;
  void openNcmHost(void Function(String) onEvent);
  void submitNcmHost(String document);
  void cancelNcmHost(String requestId);
  void closeNcmHost();
}

final class _Pending {
  _Pending(this.epoch, this.completer, this.timer);
  final int epoch;
  final Completer<NcmTransportResponse> completer;
  final Timer timer;
}

/// Correlates native events and cancels obsolete credential generations.
final class NativeNcmTransport implements NcmRequestTransport {
  NativeNcmTransport(MediaCoreApi api)
    : _api = api is NcmHostApi ? api as NcmHostApi : null;

  final NcmHostApi? _api;
  final Map<String, _Pending> _pending = {};
  int _nextId = 0;
  int _epoch = 0;
  bool _opened = false;
  bool _disposed = false;
  bool _failed = false;

  @override
  ProviderEndpointState get state =>
      !_disposed && !_failed && (_api?.supportsNcmHost ?? false)
      ? const ProviderHostReady()
      : const ProviderEndpointUnavailable('ncmHost.unavailable');

  @override
  Future<NcmTransportResponse> request({
    required String path,
    required Map<String, String> params,
    required String? cookie,
    required String deviceId,
    required int accountEpoch,
    required Duration budget,
    required int maxResponseBytes,
  }) async {
    if (_disposed || accountEpoch < _epoch) throw _cancelled;
    final api = _api;
    if (api == null || !api.supportsNcmHost || _failed) {
      throw providerFailure('provider.unavailable', 'ncmHost.unsupported');
    }
    if (!_opened) {
      try {
        api.openNcmHost(_onEvent);
        _opened = true;
      } on MediaCoreException {
        _failed = true;
        throw providerFailure(
          'provider.unavailable',
          'ncmHost.initializationFailed',
        );
      }
    }
    final id = '${++_nextId}';
    final completer = Completer<NcmTransportResponse>();
    final timer = Timer(budget, () {
      final pending = _pending.remove(id);
      if (pending == null) return;
      api.cancelNcmHost(id);
      pending.completer.completeError(
        networkFailure('network.timeout', 'ncm.host.timeout.$path'),
      );
    });
    _pending[id] = _Pending(accountEpoch, completer, timer);
    try {
      api.submitNcmHost(
        jsonEncode({
          'requestId': id,
          'accountEpoch': accountEpoch,
          'route': path,
          'params': params,
          'cookie': cookie,
          'deviceId': deviceId,
          'budgetMs': budget.inMilliseconds,
          'maxResponseBytes': maxResponseBytes,
        }),
      );
    } on MediaCoreException {
      _pending.remove(id);
      timer.cancel();
      throw providerFailure('provider.unavailable', 'ncmHost.submitFailed');
    }
    return completer.future;
  }

  void _onEvent(String text) {
    if (_disposed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final id = decoded['requestId'];
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer.cancel();
    if (decoded['schemaVersion'] != 1 ||
        decoded['accountEpoch'] != pending.epoch) {
      pending.completer.completeError(
        providerFailure('provider.schemaChanged', 'ncm.host.envelope'),
      );
      return;
    }
    final error = decoded['error'];
    if (error is String) {
      final reason = decoded['networkReason'];
      final phase =
          const {
            'timeout',
            'connect',
            'body',
            'decode',
            'request',
            'transport',
          }.contains(reason)
          ? 'ncm.host.request.$reason'
          : 'ncm.host.request';
      final rawCauses = decoded['networkCauses'];
      const allowedCauses = {
        'dns',
        'tlsCertificate',
        'tls',
        'handshake',
        'http2',
        'http2Goaway',
        'reset',
        'brokenPipe',
        'connectionClosed',
        'incompleteMessage',
        'unexpectedEof',
        'connectionRefused',
        'networkUnreachable',
        'timeout',
        'tlsPeer',
        'invalidHeader',
        'invalidUrl',
        'cancelled',
        'connectionAborted',
        'notConnected',
        'permissionDenied',
        'ioOther',
        'unclassified',
      };
      final causes = rawCauses is List
          ? rawCauses.whereType<String>().where(allowedCauses.contains).take(24)
          : const <String>[];
      final diagnostic = causes.isEmpty ? phase : '$phase.${causes.join(".")}';
      final failure = switch (error) {
        'network.timeout' ||
        'network.unreachable' => networkFailure(error, diagnostic),
        'ncm.responseTooLarge' ||
        'provider.schemaChanged' => providerFailure(error, 'ncm.host.request'),
        'ncm.upstreamError' => providerFailure(
          error,
          'ncm.host.request',
          retryable: true,
        ),
        _ => providerFailure('provider.unavailable', 'ncm.host.request'),
      };
      pending.completer.completeError(failure);
      return;
    }
    final status = decoded['status'];
    final cookies = decoded['setCookie'];
    if (status is! int ||
        cookies is! List ||
        cookies.any((v) => v is! String)) {
      pending.completer.completeError(
        providerFailure('provider.schemaChanged', 'ncm.host.response'),
      );
      return;
    }
    DateTime? serverTime;
    final time = decoded['serverTime'];
    if (time is String) {
      try {
        serverTime = HttpDate.parse(time);
      } on HttpException {
        /* optional metadata */
      }
    }
    pending.completer.complete(
      NcmTransportResponse(
        status: status,
        body: decoded['body'],
        setCookie: cookies.cast<String>(),
        serverTime: serverTime,
      ),
    );
  }

  static const _cancelled = AppError(
    category: AppErrorCategory.authentication,
    code: 'auth.epochMismatch',
    retryable: false,
  );

  @override
  void cancelBeforeEpoch(int epoch) {
    if (epoch <= _epoch) return;
    _epoch = epoch;
    for (final entry in _pending.entries.toList()) {
      if (entry.value.epoch >= epoch) continue;
      _pending.remove(entry.key);
      entry.value.timer.cancel();
      _api?.cancelNcmHost(entry.key);
      entry.value.completer.completeError(_cancelled);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.completer.completeError(_cancelled);
    }
    _pending.clear();
    if (_opened) _api?.closeNcmHost();
    _opened = false;
  }
}
