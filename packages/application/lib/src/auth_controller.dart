import 'dart:async';

import 'package:fideflow_domain/domain.dart';

import 'ncm_message.dart';

enum AuthStatus {
  unauthenticated,
  restoringSession,
  restoreError,
  qrLoading,
  qrReady,
  qrScanned,
  authenticated,
  error,
}

final class AuthState {
  const AuthState({
    required this.status,
    this.session,
    this.qrSession,
    this.userPlaylists = const [],
    this.isLoadingPlaylists = false,
    this.isUserPlaylistsPartial = false,
    this.hasLoadedPlaylists = false,
    this.playlistLoadFailed = false,
    this.isSigningOut = false,
    this.isSwitching = false,
    this.isManagingAccounts = false,
    this.isSendingCode = false,
    this.isPhoneSigningIn = false,
    this.codeResendSeconds = 0,
    this.errorMessage,
    this.errorCode,
  });

  const AuthState.initial()
    : status = AuthStatus.unauthenticated,
      session = null,
      qrSession = null,
      userPlaylists = const [],
      isLoadingPlaylists = false,
      isUserPlaylistsPartial = false,
      hasLoadedPlaylists = false,
      playlistLoadFailed = false,
      isSigningOut = false,
      isSwitching = false,
      isManagingAccounts = false,
      isSendingCode = false,
      isPhoneSigningIn = false,
      codeResendSeconds = 0,
      errorMessage = null,
      errorCode = null;

  final bool isSendingCode;
  final bool isPhoneSigningIn;
  final int codeResendSeconds;
  final AuthStatus status;
  final AuthSession? session;
  final QrCodeSession? qrSession;
  final List<PlaylistSummary> userPlaylists;
  final bool isLoadingPlaylists;
  final bool isUserPlaylistsPartial;
  final bool hasLoadedPlaylists;
  final bool playlistLoadFailed;
  final bool isSigningOut;
  final bool isSwitching;
  final bool isManagingAccounts;
  final String? errorMessage;
  final String? errorCode;

  bool get isAuthenticated =>
      session != null &&
      !isSwitching &&
      !isSigningOut &&
      (status == AuthStatus.authenticated ||
          status == AuthStatus.qrLoading ||
          status == AuthStatus.qrReady ||
          status == AuthStatus.qrScanned ||
          status == AuthStatus.error);

  /// The account's "我喜欢的音乐" playlist, or null before the lists load.
  ///
  /// `/user/playlist` lists created and favored playlists together and promises
  /// nothing about their order, so a page that took the first entry would title
  /// one playlist with another one's songs. See [likedPlaylistOf].
  PlaylistSummary? get likedPlaylist =>
      likedPlaylistOf(userPlaylists, userId: session?.user.userId);

  AuthState copyWith({
    AuthStatus? status,
    AuthSession? session,
    bool clearSession = false,
    QrCodeSession? qrSession,
    bool clearQrSession = false,
    List<PlaylistSummary>? userPlaylists,
    bool? isLoadingPlaylists,
    bool? isUserPlaylistsPartial,
    bool? hasLoadedPlaylists,
    bool? playlistLoadFailed,
    bool? isSigningOut,
    bool? isSwitching,
    bool? isManagingAccounts,
    bool? isSendingCode,
    bool? isPhoneSigningIn,
    int? codeResendSeconds,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? errorCode,
    bool clearErrorCode = false,
  }) => AuthState(
    status: status ?? this.status,
    session: clearSession ? null : (session ?? this.session),
    qrSession: clearQrSession ? null : (qrSession ?? this.qrSession),
    userPlaylists: userPlaylists ?? this.userPlaylists,
    isLoadingPlaylists: isLoadingPlaylists ?? this.isLoadingPlaylists,
    isUserPlaylistsPartial:
        isUserPlaylistsPartial ?? this.isUserPlaylistsPartial,
    hasLoadedPlaylists: hasLoadedPlaylists ?? this.hasLoadedPlaylists,
    playlistLoadFailed: playlistLoadFailed ?? this.playlistLoadFailed,
    isSigningOut: isSigningOut ?? this.isSigningOut,
    isSwitching: isSwitching ?? this.isSwitching,
    isManagingAccounts: isManagingAccounts ?? this.isManagingAccounts,
    isSendingCode: isSendingCode ?? this.isSendingCode,
    isPhoneSigningIn: isPhoneSigningIn ?? this.isPhoneSigningIn,
    codeResendSeconds: codeResendSeconds ?? this.codeResendSeconds,
    errorMessage: clearErrorMessage
        ? null
        : (errorMessage ?? this.errorMessage),
    errorCode: clearErrorCode ? null : (errorCode ?? this.errorCode),
  );
}

/// The `specialType` netease marks its "我喜欢的音乐" playlist with.
const _likedMusicSpecialType = 5;

/// Picks the account's "我喜欢的音乐" playlist out of [playlists].
///
/// The reliable criteria come first: the service's own marker
/// (`specialType == 5`), then the id — netease gives the liked playlist the
/// account's own id. Without either evidence, return null; list order is not
/// evidence of a playlist's identity.
PlaylistSummary? likedPlaylistOf(
  List<PlaylistSummary> playlists, {
  UserId? userId,
}) {
  if (userId != null) {
    final owner = NcmKind.user.canonical(userId.value);
    playlists = playlists
        .where(
          (playlist) =>
              playlist.creatorId == null ||
              NcmKind.user.canonical(playlist.creatorId!.value) == owner,
        )
        .toList();
  }
  if (playlists.isEmpty) return null;
  for (final playlist in playlists) {
    if (playlist.specialType == _likedMusicSpecialType) return playlist;
  }
  final owner = userId == null ? null : _trailingDigits(userId.value);
  if (owner != null) {
    for (final playlist in playlists) {
      if (_trailingDigits(playlist.id.value) == owner) return playlist;
    }
  }
  return null;
}

/// The numeric tail of a domain id (`ncm-user-998877` → `998877`), which is the
/// part of it a provider assigns; null when the id carries no number.
String? _trailingDigits(String value) {
  final match = RegExp(r'(\d+)$').firstMatch(value);
  return match?.group(1);
}

final class AuthController {
  AuthController(
    this._authRepo, {
    this.qrPollingInterval = const Duration(seconds: 2),
    this.qrTimeout = const Duration(seconds: 120),
    this.maxConsecutivePollingFailures = 3,
    this.debugExportCookie,
    this.debugSwitchToGuest,
    this.now = DateTime.now,
  }) {
    _sessionSub = _authRepo.sessionChanges.listen(_onSessionChanged);
    final managed = accountRepository;
    if (managed != null) {
      _accountSub = managed.accountChanges.listen(
        (_) => _emit(_current.copyWith()),
      );
      _transitionSub = managed.transitionChanges.listen(
        (busy) => _emit(_current.copyWith(isSwitching: busy)),
      );
    }
  }

  /// Optional development-only action; never stores credentials in auth state.
  final Future<void> Function(UserId account)? debugExportCookie;

  final Future<void> Function()? debugSwitchToGuest;

  Future<void> switchToGuestForDebug() async {
    final action = debugSwitchToGuest;
    if (action != null) await _manage(action);
  }

  final AuthRepository _authRepo;
  MultiAccountRepository? get accountRepository =>
      _authRepo is MultiAccountRepository ? _authRepo : null;
  List<SavedAccount> get accounts => accountRepository?.accounts ?? const [];
  StreamSubscription<List<SavedAccount>>? _accountSub;
  StreamSubscription<bool>? _transitionSub;
  Future<void> switchAccount(UserId id) => _manage(() async {
    await accountRepository!.switchAccount(id);
  });
  Future<void> signOutAccount(UserId id) => _manage(
    () => accountRepository!.signOutAccount(id),
    affectsCurrent: _current.session?.user.userId == id,
  );
  Future<void> removeAccount(UserId id) => _manage(
    () => accountRepository!.removeAccount(id),
    affectsCurrent: _current.session?.user.userId == id,
  );
  Future<void> _manage(
    Future<void> Function() action, {
    bool affectsCurrent = true,
  }) async {
    if (_current.isManagingAccounts ||
        _current.isSwitching ||
        _current.isSigningOut) {
      return;
    }
    cancelLogin();
    _emit(
      _current.copyWith(
        isSwitching: affectsCurrent,
        isManagingAccounts: true,
        clearErrorMessage: true,
        clearErrorCode: true,
      ),
    );
    try {
      await action();
    } catch (error) {
      _emit(
        _current.copyWith(
          errorMessage: error is AppError
              ? ncmMessage(error.code)
              : UiMessages.accountOperationFailedPleaseTryAgain,
          errorCode: error is AppError ? error.code : 'auth.operationFailed',
        ),
      );
      rethrow;
    } finally {
      _emit(_current.copyWith(isSwitching: false, isManagingAccounts: false));
    }
  }

  final DateTime Function() now;
  final Duration qrPollingInterval;
  final Duration qrTimeout;
  final int maxConsecutivePollingFailures;

  final StreamController<AuthState> _states =
      StreamController<AuthState>.broadcast();
  AuthState _current = const AuthState.initial();
  StreamSubscription<AuthSession?>? _sessionSub;
  Timer? _qrPollingTimer;
  Timer? _qrTimeoutTimer;
  bool _disposed = false;

  /// Which login attempt the user is actually waiting on.
  ///
  /// A cancel, a retry, a sign-out, a session arriving from elsewhere and disposal
  /// all advance it, so a step that finishes late cannot publish into a flow that
  /// has already ended — the failure the timers alone cannot prevent, because they
  /// only stop what has not started yet.
  int _loginRequestGeneration = 0;
  int loginCompletions = 0;
  int get qrLoginCompletions => loginCompletions;
  Timer? _codeResendTimer;
  DateTime? _codeResendAt;
  int _playlistLoadGeneration = 0;

  Stream<AuthState> get states => _states.stream;
  AuthState get current => _current;

  void _emit(AuthState next) {
    if (_disposed) return;
    _current = next;
    _states.add(next);
  }

  /// Whether [request] is still the login attempt the user is waiting on.
  bool _isLoginRequestCurrent(int request) =>
      !_disposed && request == _loginRequestGeneration;

  void _onSessionChanged(AuthSession? session) {
    final previous = _current.session;
    if (session != null &&
        previous != null &&
        session.authEpoch == previous.authEpoch &&
        session.user.userId == previous.user.userId) {
      // A profile/entitlement update does not change playlist ownership or
      // invalidate an in-flight playlist response for this login.
      _emit(_current.copyWith(session: session));
      return;
    }
    // A successful QR commit is completed by its caller. Other session changes
    // invalidate the attempt; cancellation always advances the generation.
    if (!_current.isPhoneSigningIn &&
        _current.status != AuthStatus.qrLoading &&
        _current.status != AuthStatus.qrReady &&
        _current.status != AuthStatus.qrScanned) {
      _loginRequestGeneration++;
    }
    _playlistLoadGeneration++;
    if (session == null) {
      _stopTimers();
      _emit(
        _current.copyWith(
          status: AuthStatus.unauthenticated,
          clearSession: true,
          userPlaylists: const [],
          isLoadingPlaylists: false,
          isUserPlaylistsPartial: false,
          hasLoadedPlaylists: false,
          playlistLoadFailed: false,
          isSigningOut: false,
        ),
      );
    } else {
      _stopTimers();
      _emit(
        _current.copyWith(
          status: AuthStatus.authenticated,
          session: session,
          clearQrSession: true,
          userPlaylists: const [],
          isLoadingPlaylists: false,
          isUserPlaylistsPartial: false,
          hasLoadedPlaylists: false,
          playlistLoadFailed: false,
          isSigningOut: false,
        ),
      );
      loadUserPlaylists();
    }
  }

  Future<void> restoreSession() async {
    final requestGeneration = _loginRequestGeneration;
    _emit(
      _current.copyWith(
        status: AuthStatus.restoringSession,
        clearErrorMessage: true,
        clearErrorCode: true,
      ),
    );
    try {
      final session = await _authRepo.restoreSession();
      // A login started while the stored session was being read owns the UI.
      // A late "no session" result must not hide its QR code.
      if (_disposed || requestGeneration != _loginRequestGeneration) return;
      if (session != null) {
        _emit(
          _current.copyWith(status: AuthStatus.authenticated, session: session),
        );
        await loadUserPlaylists();
      } else {
        _emit(
          _current.copyWith(
            status: AuthStatus.unauthenticated,
            clearSession: true,
          ),
        );
      }
    } catch (error) {
      if (error is AppError &&
          error.code == 'auth.playbackRestoreFailed' &&
          _authRepo.currentSession != null &&
          !_disposed) {
        _emit(
          _current.copyWith(
            status: AuthStatus.authenticated,
            session: _authRepo.currentSession,
            errorCode: error.code,
            errorMessage:
                UiMessages.couldNotRestorePlaybackHistoryPleaseTryAgain,
          ),
        );
        return;
      }

      if (_disposed || requestGeneration != _loginRequestGeneration) return;
      _emit(
        _current.copyWith(
          status: AuthStatus.restoreError,
          clearSession: true,
          errorCode: error is AppError ? error.code : 'auth.restoreFailed',
          errorMessage: error is AppError
              ? ncmMessage(error.code)
              : UiMessages.couldNotRestoreSignInPleaseTryAgain,
        ),
      );
    }
  }

  bool get _authBusy =>
      _disposed ||
      _current.isManagingAccounts ||
      _current.isSwitching ||
      _current.isSigningOut ||
      _current.isSendingCode ||
      _current.isPhoneSigningIn;

  /// Digits only on the wire; the presentation may show a leading plus.
  String _countryCode(String value) =>
      value.trim().replaceFirst(RegExp(r'^\+'), '');

  bool _validatePhone(String phone, String countryCode) {
    if (!RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(countryCode) ||
        !RegExp(r'^[0-9]{4,15}$').hasMatch(phone) ||
        (countryCode == '86' && !RegExp(r'^1[0-9]{10}$').hasMatch(phone))) {
      _emit(
        _current.copyWith(
          errorCode: 'auth.phoneInvalid',
          errorMessage: UiMessages.phoneInvalid,
        ),
      );
      return false;
    }
    return true;
  }

  Future<void> sendLoginCode({
    required String phone,
    required String countryCode,
  }) async {
    if (_authBusy || _current.codeResendSeconds > 0) return;
    phone = phone.trim();
    countryCode = _countryCode(countryCode);
    if (!_validatePhone(phone, countryCode)) return;
    final request = _loginRequestGeneration;
    _emit(
      _current.copyWith(
        isSendingCode: true,
        clearErrorMessage: true,
        clearErrorCode: true,
      ),
    );
    try {
      await _authRepo.sendLoginCode(phone: phone, countryCode: countryCode);
      if (!_isLoginRequestCurrent(request)) return;
      _codeResendAt = now().add(const Duration(seconds: 60));
      _emit(_current.copyWith(isSendingCode: false, codeResendSeconds: 60));
      _codeResendTimer?.cancel();
      _codeResendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final seconds =
            ((_codeResendAt!.difference(now()).inMilliseconds + 999) ~/ 1000)
                .clamp(0, 60);
        _emit(_current.copyWith(codeResendSeconds: seconds));
        if (seconds == 0) _codeResendTimer?.cancel();
      });
    } catch (error) {
      if (!_isLoginRequestCurrent(request)) return;
      _emit(
        _current.copyWith(
          isSendingCode: false,
          errorCode: error is AppError ? error.code : 'auth.smsFailed',
          errorMessage: _phoneMessage(error),
        ),
      );
    }
  }

  String _phoneMessage(Object error) =>
      switch (error is AppError ? error.code : '') {
        'auth.phoneNotRegistered' => UiMessages.phoneNotRegistered,
        'auth.codeInvalid' => UiMessages.codeInvalid,
        'auth.codeExpired' => UiMessages.codeExpired,
        'auth.verificationRequired' => UiMessages.loginVerificationRequired,
        'auth.smsFailed' => UiMessages.smsSendFailed,
        'network.rateLimited' => UiMessages.loginRateLimited,
        '' || 'auth.phoneLoginFailed' => UiMessages.phoneLoginFailed,
        'auth.secretServiceLocked' ||
        'auth.secretServiceUnavailable' ||
        'auth.secureStorageWriteFailed' ||
        'auth.secureStorageDeleteFailed' => ncmMessage(
          (error is AppError ? error.code : ''),
        ),
        final code => ncmMessage(code),
      };

  Future<void> loginWithCode({
    required String phone,
    required String countryCode,
    required String code,
  }) async {
    if (_authBusy) return;
    phone = phone.trim();
    countryCode = _countryCode(countryCode);
    if (!_validatePhone(phone, countryCode)) return;
    code = code.trim();
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(code)) {
      _emit(
        _current.copyWith(
          errorCode: 'auth.codeInvalid',
          errorMessage: UiMessages.codeInvalid,
        ),
      );
      return;
    }
    final request = _loginRequestGeneration;
    _emit(
      _current.copyWith(
        isPhoneSigningIn: true,
        clearErrorMessage: true,
        clearErrorCode: true,
      ),
    );
    try {
      final session = await _authRepo.loginWithCode(
        phone: phone,
        countryCode: countryCode,
        code: code,
      );
      if (!_isLoginRequestCurrent(request)) return;
      loginCompletions++;
      _emit(
        _current.copyWith(
          status: AuthStatus.authenticated,
          session: session,
          isPhoneSigningIn: false,
        ),
      );
      await loadUserPlaylists();
    } catch (error) {
      if (!_isLoginRequestCurrent(request)) return;
      _emit(
        _current.copyWith(
          isPhoneSigningIn: false,
          errorCode: error is AppError ? error.code : 'auth.phoneLoginFailed',
          errorMessage: _phoneMessage(error),
        ),
      );
    }
  }

  /// Compatibility entry point for callers that only use QR sign-in.
  void cancelQrLogin() => cancelLogin();

  Future<void> startQrLogin() async {
    if (_current.isManagingAccounts ||
        _current.isSwitching ||
        _current.isSigningOut) {
      return;
    }
    // Cancelling first invalidates the previous attempt, then this one takes the
    // next generation: an answer to *that* attempt can no longer be published.
    cancelLogin();
    final request = ++_loginRequestGeneration;
    _emit(
      _current.copyWith(
        status: AuthStatus.qrLoading,
        clearErrorMessage: true,
        clearErrorCode: true,
      ),
    );

    try {
      final qrSession = await _authRepo.createQrCodeSession();
      if (!_isLoginRequestCurrent(request)) return;
      _emit(
        _current.copyWith(status: AuthStatus.qrReady, qrSession: qrSession),
      );
      _startQrPolling(qrSession.unikey, request);
    } catch (e) {
      if (!_isLoginRequestCurrent(request)) return;
      final code = e is AppError ? e.code : 'auth.qrCreateFailed';
      _emit(
        _current.copyWith(
          status: AuthStatus.error,
          errorMessage: _qrCreationMessage(code),
          errorCode: code,
        ),
      );
    }
  }

  String _qrCreationMessage(String code) => switch (code) {
    'provider.starting' => UiMessages.theLocalMusicServiceIsStillStartingPlease,
    'provider.unavailable' =>
      UiMessages.theLocalMusicServiceCouldNotStartRestart,
    'network.timeout' => UiMessages.timedOutObtainingTheQrCodeCheckYour,
    'network.unreachable' => UiMessages.couldNotConnectToTheMusicServiceCheck,
    'network.rateLimited' =>
      UiMessages.tooManyRequestsWaitBeforeObtainingAnotherQr,
    'ncm.upstreamError' =>
      UiMessages.neteaseIsTemporarilyUnavailablePleaseTryAgainLater,
    'provider.schemaChanged' =>
      UiMessages.theMusicServiceReturnedAnInvalidQrCode,
    _ => UiMessages.couldNotObtainQrCodeTryAgainLater((code).toString()),
  };

  void _startQrPolling(String unikey, int request) {
    _stopTimers();
    var consecutiveFailures = 0;

    // A poll already in flight when this attempt ends — the failure threshold, an
    // expiry or a successful authorization — would otherwise still return and
    // publish over that terminal state: cancelling a Timer cannot recall an await.
    // The request generation alone does not cover it, because reaching the
    // threshold advances nothing; it is the cancel path that owns the counter.
    var finished = false;
    bool stale() =>
        finished ||
        !_isLoginRequestCurrent(request) ||
        _current.qrSession?.unikey != unikey;

    _qrTimeoutTimer = Timer(qrTimeout, () {
      cancelLogin();
      _emit(
        _current.copyWith(
          status: AuthStatus.error,
          errorMessage: UiMessages.theQrCodeExpiredRefreshAndTryAgain,
          errorCode: 'auth.qrExpired',
        ),
      );
    });

    _qrPollingTimer = Timer.periodic(qrPollingInterval, (_) async {
      if (stale()) return;
      try {
        final status = await _authRepo.checkQrCodeStatus(unikey);
        if (stale()) return;
        consecutiveFailures = 0;

        switch (status) {
          case QrCodeScanStatus.waitingForScan:
            if (_current.status != AuthStatus.qrReady) {
              _emit(_current.copyWith(status: AuthStatus.qrReady));
            }
            break;
          case QrCodeScanStatus.waitingForConfirmation:
            if (_current.status != AuthStatus.qrScanned) {
              _emit(_current.copyWith(status: AuthStatus.qrScanned));
            }
            break;
          case QrCodeScanStatus.authorized:
            // Claim the outcome before the first await of this branch, so a
            // concurrent tick cannot start a second completeLogin.
            finished = true;
            _stopTimers();
            try {
              final session = await _authRepo.completeLogin(unikey);
              // Completing the login is also an await, so a cancel that lands
              // while the service is verifying must not publish this result.
              if (!_isLoginRequestCurrent(request)) return;
              loginCompletions++;
              _emit(
                _current.copyWith(
                  status: AuthStatus.authenticated,
                  session: session,
                  clearQrSession: true,
                ),
              );
              await loadUserPlaylists();
            } catch (e) {
              // `finished` blocks other polling ticks, but must not hide a
              // failure in the one login attempt we claimed.
              if (!_isLoginRequestCurrent(request)) return;
              final code = e is AppError ? e.code : 'ncm.upstreamError';
              _emit(
                _current.copyWith(
                  status: AuthStatus.error,
                  errorMessage: ncmMessage(code),
                  errorCode: code,
                ),
              );
            }
            break;
          case QrCodeScanStatus.expired:
            finished = true;
            _stopTimers();
            _emit(
              _current.copyWith(
                status: AuthStatus.error,
                errorMessage: UiMessages.theQrCodeExpiredRefreshAndTryAgain,
                errorCode: 'auth.qrExpired',
              ),
            );
            break;
          case QrCodeScanStatus.unknown:
            break;
        }
      } catch (e) {
        if (stale()) return;
        consecutiveFailures++;
        if (consecutiveFailures >= maxConsecutivePollingFailures) {
          finished = true;
          _stopTimers();
          final code = e is AppError ? e.code : 'ncm.upstreamError';
          _emit(
            _current.copyWith(
              status: AuthStatus.error,
              errorMessage: ncmMessage(code),
              errorCode: code,
            ),
          );
        }
        // Transient network error while polling; wait for next tick
      }
    });
  }

  void cancelLogin() {
    accountRepository?.cancelPendingLogin();
    // Stop first, then invalidate: whatever is already running learns it is stale
    // from the generation, which the timers alone cannot tell it.
    _loginRequestGeneration++;
    _stopTimers();
    _emit(
      _current.copyWith(
        isSendingCode: false,
        isPhoneSigningIn: false,
        clearErrorMessage: true,
        clearErrorCode: true,
      ),
    );
    if (_current.status == AuthStatus.qrLoading ||
        _current.status == AuthStatus.qrReady ||
        _current.status == AuthStatus.qrScanned) {
      _emit(
        _current.copyWith(
          status: _current.session != null
              ? AuthStatus.authenticated
              : AuthStatus.unauthenticated,
          clearQrSession: true,
        ),
      );
    }
  }

  void _stopTimers() {
    _qrPollingTimer?.cancel();
    _qrPollingTimer = null;
    _qrTimeoutTimer?.cancel();
    _qrTimeoutTimer = null;
  }

  Future<void> loadUserPlaylists() async {
    final session = _current.session;
    if (session == null) return;
    final request = ++_playlistLoadGeneration;
    _emit(
      _current.copyWith(isLoadingPlaylists: true, playlistLoadFailed: false),
    );
    try {
      final playlists = await _authRepo.getUserPlaylists(session.user.userId);
      if (_disposed ||
          request != _playlistLoadGeneration ||
          _current.session?.authEpoch != session.authEpoch) {
        return;
      }
      final isPartial = playlists is UserPlaylists
          ? playlists.isPartial
          : false;
      _emit(
        _current.copyWith(
          userPlaylists: playlists,
          isLoadingPlaylists: false,
          isUserPlaylistsPartial: isPartial,
          hasLoadedPlaylists: true,
          playlistLoadFailed: false,
        ),
      );
    } catch (_) {
      if (_disposed ||
          request != _playlistLoadGeneration ||
          _current.session?.authEpoch != session.authEpoch) {
        return;
      }
      _emit(
        _current.copyWith(isLoadingPlaylists: false, playlistLoadFailed: true),
      );
    }
  }

  Future<void> signOut() async {
    if (_current.isManagingAccounts ||
        _current.isSwitching ||
        _current.isSigningOut) {
      return;
    }
    _playlistLoadGeneration++;
    cancelLogin();
    _emit(_current.copyWith(isSigningOut: true));
    try {
      await _authRepo.signOut();
    } catch (_) {
      _emit(_current.copyWith(isSigningOut: false));
      rethrow;
    }
    if (!_disposed) {
      _emit(
        _current.copyWith(
          status: AuthStatus.unauthenticated,
          clearSession: true,
          userPlaylists: const [],
          isLoadingPlaylists: false,
          isUserPlaylistsPartial: false,
          hasLoadedPlaylists: false,
          playlistLoadFailed: false,
          isSigningOut: false,
        ),
      );
    }
  }

  void dispose() {
    cancelLogin();
    _codeResendTimer?.cancel();
    _disposed = true;
    _stopTimers();
    _sessionSub?.cancel();
    _accountSub?.cancel();
    _transitionSub?.cancel();
    _states.close();
  }
}
