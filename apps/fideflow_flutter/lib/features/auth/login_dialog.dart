import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/ui_text.dart';

/// Shared phone and QR sign-in flow.
final class LoginDialog extends StatefulWidget {
  const LoginDialog({
    required this.controller,
    this.initialCompletion = 0,
    super.key,
  });

  static final _openDialogs = Expando<bool>();

  final AuthController controller;
  final int initialCompletion;

  static Future<void> show(
    BuildContext context,
    AuthController controller,
  ) async {
    if (_openDialogs[controller] == true ||
        controller.current.isManagingAccounts ||
        controller.current.isSwitching ||
        controller.current.isSigningOut ||
        controller.current.status == AuthStatus.qrLoading ||
        controller.current.status == AuthStatus.qrReady ||
        controller.current.status == AuthStatus.qrScanned) {
      return;
    }
    _openDialogs[controller] = true;
    final initialCompletion = controller.loginCompletions;
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    controller.cancelLogin();
    if (!mobile) unawaited(controller.startQrLogin());
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (context) => LoginDialog(
          controller: controller,
          initialCompletion: initialCompletion,
        ),
      );
    } finally {
      _openDialogs[controller] = false;
      controller.cancelLogin();
    }
  }

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

final class _LoginDialogState extends State<LoginDialog> {
  StreamSubscription<AuthState>? _subscription;
  bool _closing = false;
  late bool _phoneMode;
  final _phone = TextEditingController();
  final _countryCode = TextEditingController(text: '+86');
  final _code = TextEditingController();
  AuthController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _phoneMode =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    _listen();
  }

  @override
  void didUpdateWidget(LoginDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      unawaited(_subscription?.cancel());
      _closing = false;
      _listen();
    }
  }

  void _listen() {
    _subscription = controller.states.listen(_onAuth);
    _onAuth(controller.current);
  }

  void _onAuth(AuthState state) {
    if (_closing ||
        controller.loginCompletions <= widget.initialCompletion ||
        state.isSwitching) {
      return;
    }
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _phone.dispose();
    _countryCode.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.of(context).panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.of(context).border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: StreamBuilder<AuthState>(
              stream: controller.states,
              initialData: controller.current,
              builder: (context, snapshot) {
                final state = snapshot.data ?? controller.current;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: LocalizedText(
                            UiMessages.signInToNeteaseCloudMusic,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.of(context).text,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: localizeUiText(context, UiMessages.close),
                          icon: const Icon(Icons.close, size: 20),
                          color: AppColors.of(context).muted,
                          onPressed: () => Navigator.of(context).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const LocalizedText(UiMessages.phoneSignIn),
                          selected: _phoneMode,
                          onSelected: (_) => _selectMode(true),
                        ),
                        ChoiceChip(
                          label: const LocalizedText(UiMessages.qrSignIn),
                          selected: !_phoneMode,
                          onSelected: (_) => _selectMode(false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (_phoneMode)
                      _buildPhoneContent(context, state)
                    else
                      _buildContent(context, state),
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: LocalizedText(
                        UiMessages.cancel,
                        style: TextStyle(color: AppColors.of(context).muted),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _selectMode(bool phone) {
    if (_phoneMode == phone) return;
    controller.cancelLogin();
    _code.clear();
    setState(() => _phoneMode = phone);
    if (!phone) unawaited(controller.startQrLogin());
  }

  Widget _buildPhoneContent(BuildContext context, AuthState state) {
    final busy =
        state.isSendingCode || state.isPhoneSigningIn || state.isSwitching;
    void submit() => controller.loginWithCode(
      phone: _phone.text,
      countryCode: _countryCode.text,
      code: _code.text,
    );
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('login-country-code'),
            controller: _countryCode,
            enabled: !busy,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[+0-9]')),
            ],
            decoration: InputDecoration(
              labelText: localizeUiText(context, UiMessages.countryCallingCode),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('login-phone'),
            controller: _phone,
            enabled: !busy,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: localizeUiText(context, UiMessages.phoneNumber),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('login-code'),
            controller: _code,
            enabled: !busy,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: localizeUiText(context, UiMessages.smsCode),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: busy ? null : (_) => submit(),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: busy || state.codeResendSeconds > 0
                ? null
                : () => controller.sendLoginCode(
                    phone: _phone.text,
                    countryCode: _countryCode.text,
                  ),
            child: LocalizedText(
              state.codeResendSeconds > 0
                  ? UiMessages.resendLoginCode(state.codeResendSeconds)
                  : UiMessages.sendLoginCode,
            ),
          ),
          if (state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LocalizedText(
                state.errorMessage!,
                style: TextStyle(color: AppColors.of(context).error),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: busy ? null : submit,
            child: state.isPhoneSigningIn || state.isSendingCode
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const LocalizedText(UiMessages.submitPhoneLogin),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, AuthState state) {
    return switch (state.status) {
      AuthStatus.qrLoading || AuthStatus.restoringSession => SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(height: 16),
              LocalizedText(
                UiMessages.generatingSignInQrCode,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.of(context).muted,
                ),
              ),
            ],
          ),
        ),
      ),
      AuthStatus.qrReady => Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: state.qrSession?.qrImageBytes != null
                ? Image.memory(
                    Uint8List.fromList(state.qrSession!.qrImageBytes!),
                    width: 170,
                    height: 170,
                    fit: BoxFit.contain,
                  )
                : QrImageView(
                    data: state.qrSession!.qrUrl,
                    size: 170,
                    padding: EdgeInsets.zero,
                    semanticsLabel: localizeUiText(
                      context,
                      UiMessages.neteaseSignInQrCode,
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          LocalizedText(
            UiMessages.scanWithTheNeteaseCloudMusicAppTo,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.of(context).text,
            ),
          ),
          const SizedBox(height: 4),
          LocalizedText(
            UiMessages.theQrCodeExpiresIn2Minutes,
            style: TextStyle(fontSize: 12, color: AppColors.of(context).muted),
          ),
        ],
      ),
      AuthStatus.qrScanned => SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline,
                color: AppColors.of(context).success,
                size: 48,
              ),
              SizedBox(height: 16),
              LocalizedText(
                UiMessages.qrCodeScanned,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.of(context).text,
                ),
              ),
              SizedBox(height: 8),
              LocalizedText(
                UiMessages.confirmOnYourPhoneToFinishSigningIn,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.of(context).muted,
                ),
              ),
            ],
          ),
        ),
      ),
      AuthStatus.authenticated => SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle,
                color: AppColors.of(context).success,
                size: 48,
              ),
              const SizedBox(height: 16),
              LocalizedText(
                UiMessages.signedIn,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.of(context).text,
                ),
              ),
              const SizedBox(height: 4),
              LocalizedText(
                state.session?.user.nickname ?? '',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.of(context).muted,
                ),
              ),
            ],
          ),
        ),
      ),
      AuthStatus.error => SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: AppColors.of(context).error,
                size: 48,
              ),
              const SizedBox(height: 12),
              LocalizedText(
                state.errorMessage ?? UiMessages.signInFailed,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.of(context).text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => controller.startQrLogin(),
                icon: const Icon(Icons.refresh, size: 16),
                label: const LocalizedText(UiMessages.getANewQrCode),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.of(context).selected,
                  foregroundColor: AppColors.of(context).text,
                ),
              ),
            ],
          ),
        ),
      ),
      AuthStatus.unauthenticated ||
      AuthStatus.restoreError => const SizedBox(height: 200),
    };
  }
}
