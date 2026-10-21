import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/desktop_window.dart';
import '../../app/http_overrides.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/app_localizations_zh.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/navigation/routes.dart';
import '../../shared/widgets/fideflow_brand_mark.dart';
import '../../shared/widgets/quality_selector.dart';
import '../auth/login_dialog.dart';

final class HomeSidebar extends StatelessWidget {
  const HomeSidebar({
    required this.selectedDestination,
    required this.onSelected,
    required this.onOpenSettings,
    required this.onToggleCollapsed,
    required this.settingsSelected,
    required this.collapsed,
    required this.width,
    this.authController,
  });

  final String? selectedDestination;
  final ValueChanged<String> onSelected;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleCollapsed;
  final bool settingsSelected;
  final bool collapsed;
  final AuthController? authController;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('desktop-sidebar'),
    width: width,
    color: desktopNavigationBackground(AppColors.of(context)),
    child: DesktopDragArea(
      maximizeOnDoubleTap: false,
      child: SafeArea(
        right: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            collapsed ? 8 : 16,
            DesktopWindow.supported ? 8 : 20,
            collapsed ? 8 : 16,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) ...[
                const SizedBox(height: 32),
                const SizedBox(height: 8),
              ],
              _Brand(collapsed: collapsed),
              const SizedBox(height: 20),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Center(
                  child: _AccountCard(
                    authController: authController,
                    collapsed: collapsed,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverList.list(
                      children: [
                        if (authController?.current.isAuthenticated == true)
                          _NavigationItem(
                            icon: Icons.explore_outlined,
                            selected:
                                selectedDestination == NavigationIds.recommend,
                            label: UiMessages.recommendations,
                            collapsed: collapsed,
                            onTap: () => onSelected(NavigationIds.recommend),
                          ),
                        _NavigationItem(
                          icon: Icons.queue_music_outlined,
                          selected:
                              selectedDestination ==
                              NavigationIds.playlistSquare,
                          label: UiMessages.featuredPlaylists,
                          collapsed: collapsed,
                          onTap: () => onSelected(NavigationIds.playlistSquare),
                        ),
                        _NavigationItem(
                          icon: Icons.library_music_outlined,
                          selected:
                              selectedDestination == NavigationIds.library,
                          label: UiMessages.myMusic,
                          collapsed: collapsed,
                          onTap: () => onSelected(NavigationIds.library),
                        ),
                      ],
                    ),
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Expanded(
                            child: DesktopDragArea(
                              child: SizedBox(width: double.infinity),
                            ),
                          ),
                          _NavigationItem(
                            icon: Icons.settings_outlined,
                            selected: settingsSelected,
                            label: UiMessages.settings,
                            collapsed: collapsed,
                            onTap: onOpenSettings,
                          ),
                          _NavigationItem(
                            icon: collapsed
                                ? Icons.keyboard_double_arrow_right
                                : Icons.keyboard_double_arrow_left,
                            selected: false,
                            label: collapsed
                                ? uiCopy(context).expandSidebar
                                : uiCopy(context).collapseSidebar,
                            collapsed: collapsed,
                            onTap: onToggleCollapsed,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _Brand extends StatelessWidget {
  const _Brand({this.collapsed = false});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Row(
      mainAxisAlignment: collapsed
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors.accent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: FideflowBrandMark(color: colors.onAccent),
        ),
        if (!collapsed) const SizedBox(width: 11),
        if (!collapsed)
          const Flexible(
            child: LocalizedText(
              'Fideflow',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

final class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
  });

  final bool collapsed;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final item = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: collapsed ? 48 : double.infinity,
            maxWidth: collapsed ? 48 : double.infinity,
            minHeight: 48,
            maxHeight: collapsed ? 48 : double.infinity,
          ),
          child: Material(
            color: selected
                ? colors.accent.withValues(alpha: 0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: collapsed
                  ? SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: Icon(
                          icon,
                          size: 20,
                          color: selected
                              ? colors.accentForeground
                              : colors.muted,
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            icon,
                            size: 20,
                            color: selected
                                ? colors.accentForeground
                                : colors.muted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: LocalizedText(
                              label,
                              softWrap: true,
                              style: TextStyle(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selected
                                    ? colors.accentForeground
                                    : colors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    return collapsed
        ? Tooltip(message: localizeUiText(context, label), child: item)
        : item;
  }
}

final class _AccountCard extends StatelessWidget {
  const _AccountCard({this.authController, this.collapsed = false});

  final bool collapsed;

  final AuthController? authController;

  @override
  Widget build(BuildContext context) {
    if (authController == null) {
      return _GuestAccountCard(collapsed: collapsed);
    }
    return StreamBuilder<AuthState>(
      stream: authController!.states,
      initialData: authController!.current,
      builder: (context, snapshot) {
        final state = snapshot.data ?? authController!.current;
        if (state.status == AuthStatus.restoringSession) {
          return _SessionRecoveryCard(loading: true, collapsed: collapsed);
        }
        if (state.status == AuthStatus.restoreError) {
          return Tooltip(
            message: localizeOptionalUiText(
              context,
              state.errorMessage ?? UiMessages.couldNotRestoreSignIn,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => authController!.restoreSession(),
              child: _SessionRecoveryCard(loading: false, collapsed: collapsed),
            ),
          );
        }
        if (state.session == null) {
          if (state.isSwitching || state.isSigningOut) {
            return _SessionRecoveryCard(loading: true, collapsed: collapsed);
          }
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => LoginDialog.show(context, authController!),
            child: _GuestAccountCard(collapsed: collapsed),
          );
        }

        final user = state.session!.user;
        final avatar = CircleAvatar(
          radius: 17,
          backgroundColor: AppColors.of(context).selected,
          backgroundImage: user.avatarUri != null
              ? NetworkImage(
                  user.avatarUri.toString(),
                  headers: defaultImageHeaders,
                )
              : null,
          onBackgroundImageError: user.avatarUri != null ? (_, _) {} : null,
          child: user.avatarUri == null
              ? LocalizedText(
                  user.nickname.isNotEmpty
                      ? user.nickname.characters.first
                      : '?',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.of(context).text,
                  ),
                )
              : null,
        );
        return Container(
          padding: EdgeInsets.all(collapsed ? 0 : 12),
          decoration: collapsed
              ? null
              : BoxDecoration(
                  border: Border.all(color: AppColors.of(context).border),
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.of(context).panel,
                ),
          child: Row(
            mainAxisAlignment: collapsed
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                position: PopupMenuPosition.under,
                tooltip: localizeOptionalUiText(context, user.nickname),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(
                          Icons.logout,
                          size: 16,
                          color: AppColors.of(context).error,
                        ),
                        SizedBox(width: 8),
                        LocalizedText(
                          UiMessages.signOut,
                          style: TextStyle(color: AppColors.of(context).error),
                        ),
                      ],
                    ),
                  ),
                ],
                onSelected: (action) =>
                    _handleAccountAction(context, authController!, action),
                child: avatar,
              ),
              if (!collapsed) const SizedBox(width: 10),
              if (!collapsed)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: LocalizedText(
                              user.nickname,
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                                color: AppColors.of(context).text,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (user.vipType > 0) ...[
                            const SizedBox(width: 8),
                            const QualityVipBadge(),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              if (state.isSigningOut ||
                  state.isSwitching ||
                  state.isManagingAccounts)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleAccountAction(
    BuildContext context,
    AuthController controller,
    String action,
  ) async {
    if (action != 'logout') return;
    try {
      await controller.signOut();
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppError
          ? ncmMessage(error.code)
          : UiMessages.couldNotSignOutPleaseTryAgainLater;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: LocalizedText(message)));
    }
  }
}

final class _SessionRecoveryCard extends StatelessWidget {
  const _SessionRecoveryCard({required this.loading, this.collapsed = false});

  final bool collapsed;

  final bool loading;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(collapsed ? 8 : 12),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.of(context).border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: AppColors.of(context).selected,
          child: Icon(Icons.sync_rounded, size: 19),
        ),
        if (!collapsed) const SizedBox(width: 10),
        if (!collapsed)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocalizedText(
                  loading
                      ? UiMessages.restoringSignIn
                      : UiMessages.couldNotRestoreSignIn2,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                LocalizedText(
                  loading
                      ? UiMessages.pleaseWait
                      : UiMessages.yourCredentialsHaveBeenKeptClickToRetry,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.of(context).muted,
                  ),
                ),
              ],
            ),
          ),
        if (!collapsed && loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (!collapsed)
          Icon(Icons.refresh, size: 18, color: AppColors.of(context).muted),
      ],
    ),
  );
}

final class _GuestAccountCard extends StatelessWidget {
  const _GuestAccountCard({this.collapsed = false});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final label =
        (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                AppLocalizationsZhHans())
            .clickToSignIn;
    final card = Container(
      padding: EdgeInsets.all(collapsed ? 8 : 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.of(context).border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: collapsed
          ? const Icon(Icons.person_outline, size: 24)
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
    );
    return collapsed ? Tooltip(message: label, child: card) : card;
  }
}
