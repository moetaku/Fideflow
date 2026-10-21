import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/music_scope.dart';
import 'music_feedback.dart';
import 'playlist_editor.dart';

final class MusicPlaylistActions extends StatelessWidget {
  const MusicPlaylistActions({required this.detail, this.onDeleted, super.key});
  final PlaylistDetail detail;
  final VoidCallback? onDeleted;
  @override
  Widget build(BuildContext context) {
    final c = MusicManagementScope.maybeOf(context);
    if (c == null ||
        NcmKind.playlist.digitsOf(detail.summary.id.value) == null) {
      return const SizedBox.shrink();
    }
    final p = detail.summary;
    final busy = c.busy(c.playlistKey(p.id));
    final owned = c.owns(p);
    final subscription =
        detail.accountState?.subscription ?? SubscriptionEvidence.unknown;
    if (owned) {
      return const SizedBox.shrink();
    }
    final isSubscribed = subscription == SubscriptionEvidence.subscribed;
    final tooltip = isSubscribed
        ? UiMessages.subscribed
        : subscription == SubscriptionEvidence.unknown
        ? UiMessages.checkSubscriptionStatus
        : UiMessages.subscribe;

    return IconButton.outlined(
      tooltip: localizeOptionalUiText(context, tooltip),
      icon: Icon(
        isSubscribed ? Icons.bookmark : Icons.bookmark_border,
        size: 18,
      ),
      style: IconButton.styleFrom(
        foregroundColor: isSubscribed
            ? AppColors.of(context).accentForeground
            : null,
        side: BorderSide(
          color: isSubscribed
              ? AppColors.of(context).accent
              : AppColors.of(context).border,
        ),
      ),
      onPressed: busy || p.privacy == 10
          ? null
          : () async {
              if (!await requireMusicLogin(context, c) || !context.mounted) {
                return;
              }
              if (subscription == SubscriptionEvidence.unknown) {
                try {
                  await c.fresh(p.id);
                } catch (e) {
                  if (context.mounted) {
                    showMusicResult(
                      context,
                      MusicOperationResult(musicErrorMessage(e)),
                    );
                  }
                }
                return;
              }
              final result = await c.subscribe(
                p.id,
                subscription != SubscriptionEvidence.subscribed,
              );
              if (context.mounted) showMusicResult(context, result);
            },
    );
  }
}

final class MusicAlbumActions extends StatelessWidget {
  const MusicAlbumActions({required this.summary, super.key});

  final AlbumSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = MusicManagementScope.maybeOf(context);
    if (c == null || NcmKind.album.digitsOf(summary.id.value) == null) {
      return const SizedBox.shrink();
    }
    final busy = c.busy(c.albumKey(summary.id));
    final subscribed = c.isAlbumSubscribed(summary.id);
    final tooltip = c.loadingAlbumSubscriptions
        ? UiMessages.loadingSubscriptions
        : c.albumSubscriptionError != null
        ? UiMessages.retryLoadingSubscriptions
        : subscribed
        ? UiMessages.subscribed
        : UiMessages.subscribe;

    return IconButton.outlined(
      tooltip: localizeOptionalUiText(context, tooltip),
      icon: Icon(subscribed ? Icons.bookmark : Icons.bookmark_border, size: 18),
      style: IconButton.styleFrom(
        foregroundColor: subscribed
            ? AppColors.of(context).accentForeground
            : null,
        side: BorderSide(
          color: subscribed
              ? AppColors.of(context).accent
              : AppColors.of(context).border,
        ),
      ),
      onPressed: busy || c.loadingAlbumSubscriptions
          ? null
          : () async {
              if (!await requireMusicLogin(context, c) || !context.mounted) {
                return;
              }
              if (!c.albumSubscriptionsLoaded ||
                  c.albumSubscriptionError != null) {
                await c.loadAlbumSubscriptions();
                if (!context.mounted) return;
                if (c.albumSubscriptionError != null) {
                  showMusicResult(
                    context,
                    MusicOperationResult(c.albumSubscriptionError!),
                  );
                }
                return;
              }
              final result = await c.subscribeAlbum(
                summary.id,
                !c.isAlbumSubscribed(summary.id),
              );
              if (context.mounted) showMusicResult(context, result);
            },
    );
  }
}

final class MusicPlaylistTitleActions extends StatelessWidget {
  const MusicPlaylistTitleActions({
    required this.detail,
    this.onDeleted,
    super.key,
  });

  final PlaylistDetail detail;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final c = MusicManagementScope.maybeOf(context);
    if (c == null ||
        NcmKind.playlist.digitsOf(detail.summary.id.value) == null) {
      return const SizedBox.shrink();
    }
    final p = detail.summary;
    final busy = c.busy(c.playlistKey(p.id));
    final editable = c.editable(p);

    if (!editable) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 8),
        IconButton(
          tooltip: localizeOptionalUiText(context, UiMessages.editInformation),
          icon: const Icon(Icons.edit_outlined, size: 18),
          color: AppColors.of(context).muted,
          splashRadius: 18,
          visualDensity: VisualDensity.compact,
          onPressed: busy
              ? null
              : () => showPlaylistEditor(context, c, detail: detail),
        ),
        const SizedBox(width: 2),
        IconButton(
          tooltip: localizeOptionalUiText(context, UiMessages.deletePlaylist),
          icon: const Icon(Icons.delete_outline, size: 18),
          color: AppColors.of(context).muted,
          splashRadius: 18,
          visualDensity: VisualDensity.compact,
          onPressed: busy
              ? null
              : () async {
                  final owner = c.accountKey;
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const LocalizedText(UiMessages.deleteThisPlaylist),
                      content: LocalizedText(
                        UiMessages.tracksThisCannotBeUndone(
                          (p.title).toString(),
                          p.trackCount,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const LocalizedText(UiMessages.cancel),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const LocalizedText(UiMessages.delete),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true || !context.mounted) return;
                  if (owner != c.accountKey) {
                    showMusicResult(
                      context,
                      const MusicOperationResult(
                        UiMessages.theAccountHasChangedConfirmDeletionAgain,
                      ),
                    );
                    return;
                  }
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  final result = await c.delete(p.id);
                  if (result.success) {
                    messenger?.showSnackBar(
                      const SnackBar(
                        content: LocalizedText(UiMessages.deleted),
                      ),
                    );
                    onDeleted?.call();
                  } else if (context.mounted) {
                    showMusicResult(context, result);
                  }
                },
        ),
      ],
    );
  }
}
