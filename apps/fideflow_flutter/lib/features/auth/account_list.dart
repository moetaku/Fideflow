import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../app/http_overrides.dart';
import '../../l10n/ui_text.dart';
import 'login_dialog.dart';

final class AccountList extends StatelessWidget {
  const AccountList({
    this.authController,
    this.framed = true,
    this.showDebugActions = false,
  });
  final bool framed;
  final bool showDebugActions;
  final AuthController? authController;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    if (!context.mounted) return;
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: LocalizedText(
              error is AppError
                  ? ncmMessage(error.code)
                  : UiMessages.accountOperationFailedRetryOrRemoveTheAccount,
            ),
            action: SnackBarAction(
              label: localizeUiText(context, UiMessages.retry),
              onPressed: () => _run(context, action),
            ),
          ),
        );
      }
    }
  }

  Future<void> _exportCookie(BuildContext context, SavedAccount account) async {
    if (!kDebugMode || !showDebugActions) return;
    final export = authController?.debugExportCookie;
    if (export == null) return;
    try {
      await export(account.user.userId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText(UiMessages.debugCookieCopied)),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(UiMessages.debugCookieExportFailed),
          ),
        );
      }
    }
  }

  Future<void> _remove(BuildContext context, SavedAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LocalizedText(UiMessages.removeAccountFromThisDevice),
        content: LocalizedText(
          UiMessages.deletesLocalSignInInformationPrivateCacheAnd(
            (account.user.nickname).toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LocalizedText(UiMessages.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LocalizedText(UiMessages.remove),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _run(
        context,
        () => authController!.removeAccount(account.user.userId),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = authController;
    if (auth == null) {
      return const LocalizedText(
        UiMessages.accountManagementIsUnavailableInThisVersion,
      );
    }
    return StreamBuilder<AuthState>(
      stream: auth.states,
      initialData: auth.current,
      builder: (context, snapshot) {
        final state = snapshot.data ?? auth.current;
        final busy =
            state.isManagingAccounts ||
            state.isSwitching ||
            state.isSigningOut ||
            state.status == AuthStatus.restoringSession;
        final accounts = auth.accounts;
        return Material(
          color: framed ? AppColors.of(context).panel : Colors.transparent,
          shape: !framed
              ? null
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: AppColors.of(context).border),
                ),
          child: Padding(
            padding: EdgeInsets.all(framed ? 18 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (accounts.isEmpty || state.session == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: LocalizedText(
                      state.session?.user.nickname ??
                          UiMessages.notSignedInUsingAsALocalGuest,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.of(context).text,
                      ),
                    ),
                  ),
                for (final account in accounts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: AppColors.of(context).selected,
                          foregroundImage: account.user.avatarUri == null
                              ? null
                              : NetworkImage(
                                  account.user.avatarUri.toString(),
                                  headers: defaultImageHeaders,
                                ),
                          onForegroundImageError: account.user.avatarUri == null
                              ? null
                              : (_, _) {},
                          child: const Icon(Icons.person_rounded, size: 19),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LocalizedText(
                                account.user.nickname,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.of(context).text,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              LocalizedText(
                                account.needsLogin
                                    ? UiMessages.signInAgainRequired
                                    : state.session?.user.userId ==
                                          account.user.userId
                                    ? UiMessages.currentlyActive(
                                        (account.user.vipType > 0
                                                ? UiMessages.neteaseVipMember
                                                : UiMessages
                                                      .neteaseCloudMusicUser)
                                            .toString(),
                                      )
                                    : account.user.vipType > 0
                                    ? UiMessages.neteaseVipMember
                                    : UiMessages.neteaseCloudMusicUser,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.of(context).muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (state.session?.user.userId != account.user.userId ||
                            account.needsLogin)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => account.needsLogin
                                      ? LoginDialog.show(context, auth)
                                      : _run(
                                          context,
                                          () => auth.switchAccount(
                                            account.user.userId,
                                          ),
                                        ),
                            child: LocalizedText(
                              account.needsLogin
                                  ? UiMessages.signInAgain
                                  : UiMessages.switch2,
                            ),
                          ),
                        PopupMenuButton<String>(
                          enabled: !busy,
                          tooltip: localizeOptionalUiText(
                            context,
                            UiMessages.accountActions2,
                          ),
                          onSelected: (value) {
                            if (value == 'export-cookie' &&
                                kDebugMode &&
                                showDebugActions) {
                              _exportCookie(context, account);
                            } else if (value == 'logout') {
                              _run(
                                context,
                                () => auth.signOutAccount(account.user.userId),
                              );
                            } else {
                              _remove(context, account);
                            }
                          },
                          itemBuilder: (_) => [
                            if (showDebugActions &&
                                kDebugMode &&
                                auth.debugExportCookie != null &&
                                !account.needsLogin)
                              const PopupMenuItem(
                                value: 'export-cookie',
                                child: LocalizedText(
                                  UiMessages.debugExportCookie,
                                ),
                              ),
                            if (!account.needsLogin)
                              const PopupMenuItem(
                                value: 'logout',
                                child: LocalizedText(UiMessages.signOut2),
                              ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: LocalizedText(
                                UiMessages.removeFromThisDevice,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (accounts.isNotEmpty)
                  Divider(color: AppColors.of(context).border, height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => LoginDialog.show(context, auth),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                    label: const LocalizedText(UiMessages.addAccount),
                  ),
                ),
                if (showDebugActions &&
                    kDebugMode &&
                    auth.debugSwitchToGuest != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: busy || state.session == null
                          ? null
                          : () => _run(context, auth.switchToGuestForDebug),
                      icon: const Icon(Icons.person_outline_rounded, size: 18),
                      label: const Text('切换到游客（Debug）'),
                    ),
                  ),
                if (state.status == AuthStatus.restoreError)
                  TextButton(
                    onPressed: busy ? null : auth.restoreSession,
                    child: const LocalizedText(UiMessages.retryRestoringSignIn),
                  ),
                if (state.errorCode == 'auth.playbackRestoreFailed' &&
                    state.session != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _run(
                            context,
                            () =>
                                auth.switchAccount(state.session!.user.userId),
                          ),
                    child: const LocalizedText(
                      UiMessages.retryRestoringPlaybackHistory,
                    ),
                  ),
                if (state.errorMessage != null)
                  LocalizedText(
                    state.errorCode == 'auth.playbackRestoreFailed'
                        ? UiMessages.accountSwitchedButPlaybackHistoryCouldNotBe
                        : state.errorMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).muted,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
