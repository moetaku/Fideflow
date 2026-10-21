import 'dart:async';
import 'dart:convert';

import 'package:fideflow_domain/domain.dart';

import 'account_playback_gate.dart';
import 'playback_source_broker.dart';

/// Coordinates authentication credentials, manages the active session in memory,
/// enforces monotonic auth epochs for account isolation (docs/design/accounts.md), and coordinates
/// with [RemoteAuthClient], [SecureCredentialStorage], and [PlaybackSourceBroker].
///
/// The credential itself — the cookie that authorizes every request — lives only
/// here: it is read from [storage], kept in a private field, and handed to the
/// client. It is deliberately *not* part of [AuthSession], so no application
/// state, page or serialized snapshot can carry it (architecture §1.3, §5.2).
final class StorageAuthRevocationJournal implements AuthRevocationJournalPort {
  const StorageAuthRevocationJournal(this.storage);

  final SecureCredentialStorage storage;
  static const _key = 'auth_revocation_journal';

  @override
  Future<bool> canRestoreSession() async {
    final value = await storage.read(_key);
    return value != 'revoked';
  }

  @override
  Future<void> recordRevocation() => storage.write(_key, 'revoked');

  @override
  Future<void> recordAuthSuccess() => storage.write(_key, 'ok');
}

/// Coordinates authentication credentials, manages the active session in memory,
/// enforces monotonic auth epochs for account isolation (docs/design/accounts.md), and coordinates
/// with [RemoteAuthClient], [SecureCredentialStorage], and [PlaybackSourceBroker].
///
/// The credential itself — the cookie that authorizes every request — lives only
/// here: it is read from [storage], kept in a private field, and handed to the
/// client. It is deliberately *not* part of [AuthSession], so no application
/// state, page or serialized snapshot can carry it (architecture §1.3, §5.2).
final class CredentialCoordinator
    implements MultiAccountRepository, AuthFailureReporter {
  CredentialCoordinator({
    required this.storage,
    required this.authClient,
    this.broker,
    this.playbackGate,
    this.onCookieChanged,
    AuthRevocationJournalPort? revocationJournal,
    this.accountCleanup,
    this.restorePlayback,
    this.removeAccountData,
    this.onTransitionChanged,
    this.deviceNameProvider,
  }) : revocationJournal =
           revocationJournal ?? StorageAuthRevocationJournal(storage);

  /// Delivers one saved account's credential directly to a debug export sink.
  Future<void> exportCookieForDebug(
    UserId account,
    Future<void> Function(String cookie) export,
  ) async {
    final saved = _accounts.where((item) => item.user.userId == account);
    if (saved.isEmpty || saved.first.needsLogin) {
      throw StateError('auth.debugCookieUnavailable');
    }
    final token = await storage.read(_tokenKey(_id(account)));
    if (token == null || token.isEmpty) {
      throw StateError('auth.debugCookieUnavailable');
    }
    await export(token);
  }

  final Future<String?> Function()? deviceNameProvider;
  final SecureCredentialStorage storage;
  final RemoteAuthClient authClient;
  final PlaybackSourceBroker? broker;
  final AccountPlaybackGate? playbackGate;
  final void Function(String? cookie)? onCookieChanged;
  final AuthRevocationJournalPort revocationJournal;
  final AccountCleanupPort? accountCleanup;

  /// Runs after credentials change, before publishing the session. Must restore paused.
  final Future<void> Function(String account)? restorePlayback;
  final void Function(bool busy)? onTransitionChanged;
  final Future<void> Function(String account)? removeAccountData;
  final _sessionController = StreamController<AuthSession?>.broadcast();
  final _accountsController = StreamController<List<SavedAccount>>.broadcast();
  final _transitions = StreamController<bool>.broadcast();
  static const _indexKey = 'accounts_v1';
  List<SavedAccount> _accounts = [];
  String? _activeId;
  String? _playbackRestoreFailed;
  bool _loaded = false;
  Future<void>? _tail;
  final Map<String, Future<dynamic>> _inFlight = {};
  int _authEpoch = 0;
  int _authOperationGeneration = 0;
  AuthSession? _currentSession;
  String? _credential;
  String? _offlinePlaybackAccount;

  /// Securely remembered identity permits local playback, without claiming a
  /// verified login when the account endpoint is unreachable.
  String get playbackAccountId => _currentSession == null
      ? (_offlinePlaybackAccount ?? 'guest')
      : _id(_currentSession!.user.userId);
  ({String unikey, String cookie, int generation})? _authorizedQrCheck;
  bool _disposed = false;

  int get authEpoch => _authEpoch;
  @override
  AuthSession? get currentSession => _currentSession;
  @override
  Stream<AuthSession?> get sessionChanges => _sessionController.stream;
  @override
  List<SavedAccount> get accounts => List.unmodifiable(_accounts);
  @override
  Stream<List<SavedAccount>> get accountChanges => _accountsController.stream;
  @override
  Stream<bool> get transitionChanges => _transitions.stream;
  String _id(UserId id) => NcmKind.user.canonical(id.value);
  String _tokenKey(String id) => 'account_token:$id';
  void _publishAccounts() {
    if (!_disposed) _accountsController.add(accounts);
  }

  void _publishSession() {
    if (!_disposed) _sessionController.add(_currentSession);
  }

  void _busy(bool value, {bool gate = true}) {
    if (gate) onTransitionChanged?.call(value);
    if (!_disposed && gate) _transitions.add(value);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _tail;
    final result = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    late final Future<void> tail;
    tail = result
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
        .whenComplete(() {
          if (identical(_tail, tail)) _tail = null;
        });
    _tail = tail;
    return result;
  }

  Future<T> _single<T>(String key, Future<T> Function() action) {
    final existing = _inFlight[key];
    if (existing != null) return existing as Future<T>;
    final future = action().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<void> savePlaybackEntitlements(
    String account,
    List<AccountEntitlement> rights,
    DateTime verifiedAt, {
    int permissionGeneration = 0,
    String validationState = 'verified',
  }) async {
    final epoch = _authEpoch;
    await storage.write(
      'ff.playback-rights.$account',
      jsonEncode({
        'verifiedAt': verifiedAt.toUtc().toIso8601String(),
        'permissionGeneration': permissionGeneration,
        'validationState': validationState,
        'rights': [
          for (final r in rights)
            {
              'kind': r.kind,
              'active': r.active,
              'expiresAt': r.expiresAt?.toUtc().toIso8601String(),
            },
        ],
      }),
    );
    if (_disposed || epoch != _authEpoch || account != playbackAccountId) {
      return;
    }
    unawaited(
      _serial(() async {
        if (_disposed || epoch != _authEpoch || account != playbackAccountId) {
          return;
        }
        final session = _currentSession;
        if (session == null) return;
        final active = rights.any(
          (r) => r.kind == 'music' && r.validAt(DateTime.now()),
        );
        final old = session.user;
        final vipType = active ? (old.vipType > 0 ? old.vipType : 1) : 0;
        if (old.vipType == vipType) return;
        final user = UserProfile(
          userId: old.userId,
          nickname: old.nickname,
          avatarUri: old.avatarUri,
          vipType: vipType,
          signature: old.signature,
        );
        _currentSession = AuthSession(user: user, authEpoch: epoch);
        _accounts = [
          for (final a in _accounts)
            if (_id(a.user.userId) == account)
              SavedAccount(
                user: user,
                lastUsedAt: a.lastUsedAt,
                needsLogin: a.needsLogin,
                loginMethod: a.loginMethod,
              )
            else
              a,
        ];
        await _save(_accounts, _activeId);
        _publishSession();
        _publishAccounts();
      }).catchError((Object _) {}),
    );
  }

  Future<List<AccountEntitlement>> loadPlaybackEntitlements(
    String account,
  ) async {
    try {
      final raw = await storage.read('ff.playback-rights.$account');
      if (raw == null) return [];
      final data = jsonDecode(raw) as Map;
      return [
        for (final r in data['rights'] as List)
          AccountEntitlement(
            kind: r['kind'] as String,
            active: r['active'] == true,
            expiresAt: r['expiresAt'] == null
                ? null
                : DateTime.parse(r['expiresAt'] as String),
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _load() async {
    if (_loaded) return;
    final raw = await storage.read(_indexKey);
    if (raw != null) {
      // security -w prints non-ASCII Keychain values as hexadecimal. Recover
      // indexes written before profiles were escaped; never decode token keys.
      final encoded = raw.trim();
      final json = RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(encoded)
          ? utf8.decode([
              for (var i = 0; i < encoded.length; i += 2)
                int.parse(encoded.substring(i, i + 2), radix: 16),
            ])
          : encoded;
      final data = jsonDecode(json) as Map<String, dynamic>;
      if (data['version'] != 1) throw StateError('Unsupported account index');
      _activeId = data['active'] as String?;
      _accounts = (data['accounts'] as List).map((entry) {
        final e = entry as Map<String, dynamic>;
        return SavedAccount(
          user: UserProfile(
            userId: UserId(e['id'] as String),
            nickname: e['nickname'] as String,
            avatarUri: e['avatar'] == null
                ? null
                : Uri.parse(e['avatar'] as String),
            vipType: e['vip'] as int,
          ),
          lastUsedAt: DateTime.parse(e['used'] as String),
          needsLogin: e['needsLogin'] == true,
          loginMethod: e['loginMethod'] == LoginMethod.phoneCode.name
              ? LoginMethod.phoneCode
              : LoginMethod.qrCode,
        );
      }).toList();
    }
    if (_activeId != null &&
        !_accounts.any(
          (a) => _id(a.user.userId) == _activeId && !a.needsLogin,
        )) {
      throw StateError('Active account is not in the restoration allowlist');
    }
    _loaded = true;
    _publishAccounts();
  }

  Future<void> _save(List<SavedAccount> values, String? active) =>
      storage.write(
        _indexKey,
        jsonEncode({
          'version': 1,
          'active': active,
          'accounts': values
              .map(
                (a) => {
                  'id': _id(a.user.userId),
                  'nickname': a.user.nickname,
                  'avatar': a.user.avatarUri?.toString(),
                  'vip': a.user.vipType,
                  'used': a.lastUsedAt.toUtc().toIso8601String(),
                  'needsLogin': a.needsLogin,
                  'loginMethod': a.loginMethod.name,
                },
              )
              .toList(),
        }).replaceAllMapped(
          RegExp(r'[^\x20-\x7E]'),
          (match) => match[0]!.codeUnits
              .map((unit) => '\\u${unit.toRadixString(16).padLeft(4, '0')}')
              .join(),
        ),
      );
  bool _invalid(Object error) =>
      error is AppError &&
      const [
        'ncm.authRequired',
        'ncm.unauthenticated',
        'auth.unauthenticated',
      ].contains(error.code);
  void _ensure(int generation) {
    if (_disposed || generation != _authOperationGeneration) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.epochMismatch',
        retryable: false,
      );
    }
  }

  @override
  void cancelPendingLogin() {
    _authOperationGeneration++;
    _authorizedQrCheck = null;
  }

  @override
  Future<QrCodeSession> createQrCodeSession() {
    _authorizedQrCheck = null;
    return authClient.createQrCodeSession();
  }

  @override
  Future<QrCodeScanStatus> checkQrCodeStatus(String unikey) async {
    final generation = _authOperationGeneration;
    final result = await authClient.checkQrCodeStatus(unikey);
    if (generation == _authOperationGeneration &&
        result.status == QrCodeScanStatus.authorized &&
        result.cookie != null &&
        result.cookie!.isNotEmpty) {
      _authorizedQrCheck = (
        unikey: unikey,
        cookie: result.cookie!,
        generation: generation,
      );
    }
    return result.status;
  }

  @override
  Future<AuthSession> completeLogin(String unikey) {
    final generation = _authOperationGeneration;
    return _serial(() async {
      await _load();
      _ensure(generation);
      final cached = _authorizedQrCheck;
      _authorizedQrCheck = null;
      final check = cached?.unikey == unikey && cached?.generation == generation
          ? (status: QrCodeScanStatus.authorized, cookie: cached!.cookie)
          : await authClient.checkQrCodeStatus(unikey);
      _ensure(generation);
      final token = check.cookie;
      if (check.status != QrCodeScanStatus.authorized ||
          token == null ||
          token.isEmpty) {
        throw const AppError(
          category: AppErrorCategory.authentication,
          code: 'auth.notAuthorized',
          retryable: false,
        );
      }
      final user = await authClient.getUserAccount(cookie: token);
      _ensure(generation);
      return _activate(
        user,
        token,
        generation,
        persistToken: true,
        loginMethod: LoginMethod.qrCode,
      );
    });
  }

  @override
  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) => authClient.sendLoginCode(phone: phone, countryCode: countryCode);

  @override
  Future<AuthSession> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) {
    final generation = _authOperationGeneration;
    return _serial(() async {
      await _load();
      _ensure(generation);
      final token = await authClient.loginWithCode(
        phone: phone,
        countryCode: countryCode,
        code: code,
      );
      _ensure(generation);
      final user = await authClient.getUserAccount(cookie: token);
      _ensure(generation);
      return _activate(
        user,
        token,
        generation,
        persistToken: true,
        loginMethod: LoginMethod.phoneCode,
      );
    });
  }

  Future<void> _uploadDeviceName(String token, int epoch) async {
    try {
      final name = (await deviceNameProvider?.call())?.trim();
      if (_disposed ||
          epoch != _authEpoch ||
          name == null ||
          name.isEmpty ||
          _credential != token) {
        return;
      }
      await authClient.uploadDeviceName(name, cookie: token);
    } catch (_) {
      // Optional metadata must never invalidate a successful login.
    }
  }

  Future<AuthSession> _activate(
    UserProfile user,
    String token,
    int generation, {
    bool persistToken = false,
    LoginMethod? loginMethod,
  }) async {
    _ensure(generation);
    final id = _id(user.userId);
    final previous = _currentSession;
    final oldToken = _credential;
    final oldAccounts = _accounts;
    final oldActive = _activeId;
    final next = [
      SavedAccount(
        user: user,
        lastUsedAt: DateTime.now(),
        loginMethod:
            loginMethod ??
            _accounts
                .where((a) => _id(a.user.userId) == id)
                .firstOrNull
                ?.loginMethod ??
            LoginMethod.qrCode,
      ),
      ..._accounts.where((a) => _id(a.user.userId) != id),
    ];
    final oldStoredToken = persistToken
        ? await storage.read(_tokenKey(id))
        : null;
    var stopped = false;
    var committed = false;
    var tokenWriteAttempted = false;
    _busy(true);
    _authEpoch++;
    broker?.beginAccountEpoch(_authEpoch);
    try {
      // Stop and fence all old sources before adopting a different credential.
      if (previous != null || restorePlayback != null) {
        await playbackGate
            ?.onAccountRevoked(_authEpoch)
            .timeout(const Duration(seconds: 3));
      }
      stopped = true;
      _ensure(generation);
      if (persistToken) {
        tokenWriteAttempted = true;
        await storage.write(_tokenKey(id), token);
      }
      _ensure(generation);
      await _save(next, id);
      try {
        _ensure(generation);
      } catch (_) {
        await _save(oldAccounts, oldActive);
        rethrow;
      }
      committed = true;
      _credential = token;
      _currentSession = AuthSession(user: user, authEpoch: _authEpoch);
      _offlinePlaybackAccount = null;
      _accounts = next;
      _activeId = id;
      authClient.setCookie(token);
      onCookieChanged?.call(token);
      _publishAccounts();
      unawaited(_uploadDeviceName(token, _authEpoch));
      try {
        await restorePlayback?.call(id);
        _playbackRestoreFailed = null;
      } catch (_) {
        _playbackRestoreFailed = id;
        // Credentials are committed; report the recoverable playback failure.
        _publishSession();
        throw const AppError(
          category: AppErrorCategory.playback,
          code: 'auth.playbackRestoreFailed',
          retryable: true,
        );
      }
      _publishSession();
      // Legacy entry is no longer a restoration path once the index exists.
      // Perform cleanup only after the committed account and playback state
      // have been published; keyring failure must not strand the UI mid-login.
      await _deleteRevokedToken('session_token');
      return _currentSession!;
    } catch (error, stack) {
      if (!committed) {
        if (tokenWriteAttempted) {
          try {
            if (oldStoredToken == null) {
              await storage.delete(_tokenKey(id));
            } else {
              await storage.write(_tokenKey(id), oldStoredToken);
            }
          } catch (_) {
            // Keep the original credential error. The old in-memory session
            // still needs restoring even when the keyring remains unavailable.
          }
        }
        authClient.setCookie(oldToken);
        if (previous != null) {
          _currentSession = AuthSession(
            user: previous.user,
            authEpoch: _authEpoch,
          );
        }
        if (stopped) {
          try {
            await restorePlayback?.call(oldActive ?? 'guest');
          } catch (_) {}
        }
        // A failed cold restore has no session change to announce. Publishing
        // null here would overwrite the caller's recoverable error state.
        if (previous != null) _publishSession();
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _busy(false);
    }
  }

  @override
  Future<AuthSession> switchAccount(UserId id) {
    final generation = ++_authOperationGeneration;
    return _serial(() async {
      await _load();
      _ensure(generation);
      final key = _id(id);
      if (_currentSession != null &&
          _id(_currentSession!.user.userId) == key &&
          _playbackRestoreFailed != key) {
        return _currentSession!;
      }
      final account = _accounts
          .where((a) => _id(a.user.userId) == key)
          .firstOrNull;
      if (account == null || account.needsLogin) {
        throw const AppError(
          category: AppErrorCategory.authentication,
          code: 'auth.unauthenticated',
          retryable: false,
        );
      }
      final token = await storage.read(_tokenKey(key));
      if (token == null || token.isEmpty) {
        await _markInvalid(key);
        throw const AppError(
          category: AppErrorCategory.authentication,
          code: 'auth.unauthenticated',
          retryable: false,
        );
      }
      try {
        final user = await authClient.getUserAccount(cookie: token);
        _ensure(generation);
        if (_id(user.userId) != key) {
          throw StateError('Credential identity mismatch');
        }
        return await _activate(user, token, generation);
      } catch (error) {
        if (_invalid(error)) await _markInvalid(key);
        rethrow;
      }
    });
  }

  /// The index has already fenced these credentials from restoration.
  Future<void> _deleteRevokedToken(String key) => storage.delete(key);

  Future<void> _markInvalid(String id) async {
    await storage.delete('ff.playback-rights.$id');
    if (_offlinePlaybackAccount == id) {
      _authEpoch++;
      broker?.beginAccountEpoch(_authEpoch);
      await playbackGate
          ?.onAccountRevoked(_authEpoch)
          .timeout(const Duration(seconds: 3));
      _offlinePlaybackAccount = null;
      _credential = null;
      authClient.setCookie(null);
      onCookieChanged?.call(null);
    }
    final next = _accounts
        .map(
          (a) => _id(a.user.userId) == id
              ? SavedAccount(
                  user: a.user,
                  lastUsedAt: a.lastUsedAt,
                  needsLogin: true,
                  loginMethod: a.loginMethod,
                )
              : a,
        )
        .toList();
    final active = _activeId == id ? null : _activeId;
    await _save(next, active);
    _accounts = next;
    _activeId = active;
    await _deleteRevokedToken(_tokenKey(id));
    _publishAccounts();
  }

  @override
  Future<AuthSession?> restoreSession() => _single(
    'restore',
    () => _serial(() async {
      final generation = _authOperationGeneration;
      await _load();
      final rawIndex = await storage.read(_indexKey);
      final id = _activeId;
      if (rawIndex != null && id == null) {
        await restorePlayback?.call('guest');
        _publishSession();
        return null;
      }
      if (rawIndex == null && !await revocationJournal.canRestoreSession()) {
        await storage.delete('session_token');
        await restorePlayback?.call('guest');
        return null;
      }
      final token = await storage.read(
        id == null ? 'session_token' : _tokenKey(id),
      );
      if (token == null || token.isEmpty) {
        if (id != null) await _markInvalid(id);
        await restorePlayback?.call('guest');
        return null;
      }
      try {
        final user = await authClient.getUserAccount(cookie: token);
        if (generation != _authOperationGeneration) return null;
        if (id != null && _id(user.userId) != id) {
          throw StateError('Credential identity mismatch');
        }
        return await _activate(
          user,
          token,
          generation,
          persistToken: id == null,
        );
      } catch (error) {
        if (generation != _authOperationGeneration) return null;
        if (!_invalid(error)) {
          if (error is AppError &&
              error.category == AppErrorCategory.network &&
              id != null &&
              _accounts.any((a) => _id(a.user.userId) == id && !a.needsLogin)) {
            _offlinePlaybackAccount = id;
            _authEpoch++;
            broker?.beginAccountEpoch(_authEpoch);
            _credential = token;
            authClient.setCookie(token);
            onCookieChanged?.call(token);
            await restorePlayback?.call(id);
          }
          rethrow;
        }
        if (id != null) {
          await _markInvalid(id);
        } else {
          _offlinePlaybackAccount = null;
          await storage.delete('session_token');
        }
        await restorePlayback?.call('guest');
        return null;
      }
    }),
  );
  @override
  Future<List<PlaylistSummary>> getUserPlaylists(UserId userId) async {
    final epoch = _authEpoch;
    final values = await authClient.getUserPlaylists(
      userId,
      cookie: _credential,
    );
    if (epoch != _authEpoch) {
      throw const AppError(
        category: AppErrorCategory.authentication,
        code: 'auth.epochMismatch',
        retryable: false,
      );
    }
    return values;
  }

  /// Leaves saved credentials intact so debug sessions can switch back.
  Future<void> switchToGuestForDebug() {
    ++_authOperationGeneration;
    return _serial(() async {
      await _load();
      final previous = _currentSession;
      final oldActive = _activeId;
      var stopped = false;
      var committed = false;
      _busy(true);
      _authEpoch++;
      broker?.beginAccountEpoch(_authEpoch);
      try {
        await playbackGate
            ?.onAccountRevoked(_authEpoch)
            .timeout(const Duration(seconds: 3));
        stopped = true;
        await _save(_accounts, null);
        committed = true;
        _activeId = null;
        _currentSession = null;
        _offlinePlaybackAccount = null;
        _credential = null;
        authClient.setCookie(null);
        onCookieChanged?.call(null);
        await _deleteRevokedToken('session_token');
        try {
          await restorePlayback?.call('guest');
        } finally {
          _publishSession();
        }
      } catch (_) {
        if (!committed) {
          if (previous != null) {
            _currentSession = AuthSession(
              user: previous.user,
              authEpoch: _authEpoch,
            );
          }
          if (stopped) {
            try {
              await restorePlayback?.call(oldActive ?? 'guest');
              _playbackRestoreFailed = null;
            } catch (_) {
              _playbackRestoreFailed = oldActive;
            }
          }
          if (previous != null) _publishSession();
        }
        rethrow;
      } finally {
        _busy(false);
      }
    });
  }

  @override
  Future<void> signOut() => _single('signOut', () {
    ++_authOperationGeneration;
    return _serial(() async {
      await _load();
      final id = _currentSession == null
          ? _activeId
          : _id(_currentSession!.user.userId);
      if (id != null) {
        await _remove(id, remote: true);
      } else {
        await _save(_accounts, null);
        _activeId = null;
        await revocationJournal.recordRevocation();
        await _deleteRevokedToken('session_token');
        _authEpoch++;
        broker?.beginAccountEpoch(_authEpoch);
        _publishSession();
      }
    });
  });
  @override
  Future<void> signOutAccount(UserId id) {
    ++_authOperationGeneration;
    return _serial(() async {
      await _load();
      await _remove(_id(id), remote: true);
    });
  }

  @override
  Future<void> removeAccount(UserId id) {
    ++_authOperationGeneration;
    return _serial(() async {
      await _load();
      await _remove(_id(id), remote: false);
    });
  }

  Future<void> _remove(
    String id, {
    required bool remote,
    bool keepIdentity = false,
  }) async {
    final active = playbackAccountId == id;
    final token = active ? _credential : await storage.read(_tokenKey(id));
    // A logout client must never install or clear the active credential itself.
    if (remote && token != null) {
      await authClient.logout(cookie: token);
    }
    _busy(true, gate: active);
    var committed = false;
    try {
      if (active) {
        _authEpoch++;
        broker?.beginAccountEpoch(_authEpoch);
        await playbackGate
            ?.onAccountRevoked(_authEpoch)
            .timeout(const Duration(seconds: 3));
      }
      final next = keepIdentity
          ? _accounts
                .map(
                  (a) => _id(a.user.userId) == id
                      ? SavedAccount(
                          user: a.user,
                          lastUsedAt: a.lastUsedAt,
                          needsLogin: true,
                          loginMethod: a.loginMethod,
                        )
                      : a,
                )
                .toList()
          : _accounts.where((a) => _id(a.user.userId) != id).toList();
      final nextActive = _activeId == id ? null : _activeId;
      // Index removal is the durable tombstone, even if token deletion fails.
      await _save(next, nextActive);
      _accounts = next;
      _activeId = nextActive;
      committed = true;
      _publishAccounts();
      if (active) {
        _currentSession = null;
        _offlinePlaybackAccount = null;
        _credential = null;
        authClient.setCookie(null);
        onCookieChanged?.call(null);
      }
      Object? cleanupError;
      StackTrace? cleanupStack;
      Future<void> attemptCleanup(Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          cleanupError ??= error;
          cleanupStack ??= stack;
        }
      }

      await attemptCleanup(() => _deleteRevokedToken(_tokenKey(id)));
      await attemptCleanup(() => _deleteRevokedToken('session_token'));
      if (accountCleanup != null) {
        await attemptCleanup(() async {
          final owner = CleanupOwner(
            namespace: 'ncm',
            accountId: id,
            authEpoch: _authEpoch,
            lifecycleSeq: _authOperationGeneration,
          );
          await accountCleanup!.prepareRevocation(owner);
          final cleanup = await accountCleanup!.finishRevocation(owner);
          if (cleanup != CleanupOutcome.stopped) {
            throw const AppError(
              category: AppErrorCategory.storage,
              code: 'auth.cleanupUnconfirmed',
              retryable: true,
            );
          }
        });
      }
      if (removeAccountData != null) {
        await attemptCleanup(() => removeAccountData!.call(id));
      }
      if (active) await attemptCleanup(revocationJournal.recordRevocation);
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError!, cleanupStack!);
      }
    } catch (_) {
      if (active && _currentSession != null) {
        _currentSession = AuthSession(
          user: _currentSession!.user,
          authEpoch: _authEpoch,
        );
        _publishSession();
      }
      rethrow;
    } finally {
      try {
        // Once the index commits, failures in cleanup must still publish guest.
        if (committed && active) {
          try {
            await restorePlayback?.call('guest');
          } finally {
            _publishSession();
          }
        }
      } finally {
        _busy(false, gate: active);
      }
    }
  }

  Future<void> revokeSession() {
    ++_authOperationGeneration;
    return _serial(() async {
      final id = _currentSession?.user.userId;
      if (id != null) await _remove(_id(id), remote: false, keepIdentity: true);
    });
  }

  @override
  Future<void> reportAuthFailure(AuthFailureReport report) async {
    if (report.namespace != 'ncm' ||
        !const [
          'ncm.authRequired',
          'ncm.unauthenticated',
          'auth.unauthenticated',
        ].contains(report.code) ||
        report.category != AppErrorCategory.authentication ||
        report.authMode != RequestAuthMode.establishedSession ||
        report.accountId != _currentSession?.user.userId.value ||
        report.authEpoch != _authEpoch) {
      return;
    }
    await revokeSession();
  }

  void dispose() {
    _disposed = true;
    cancelPendingLogin();
    _credential = null;
    _sessionController.close();
    _accountsController.close();
    _transitions.close();
  }
}
