import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/music_scope.dart';
import 'add_to_playlist.dart';
import 'music_feedback.dart';

final class MusicFavoriteButton extends StatelessWidget {
  const MusicFavoriteButton({
    required this.track,
    this.size = 18,
    this.buttonSize,
    super.key,
  });

  final TrackId track;
  final double size;
  final Size? buttonSize;

  @override
  Widget build(BuildContext context) {
    final c = MusicManagementScope.maybeOf(context);
    final isRemote =
        c?.isRemoteTrack(track) ??
        (NcmKind.track.digitsOf(track.value) != null);
    if (!isRemote) return const SizedBox.shrink();
    final favorite = c?.favorite(track) ?? FavoriteState.unliked;
    final targetSize = buttonSize ?? const Size(28, 36);
    return IconButton(
      style: _trackActionStyle(targetSize),
      tooltip: localizeOptionalUiText(
        context,
        favorite == FavoriteState.liked
            ? UiMessages.unlike
            : favorite == FavoriteState.unknown
            ? UiMessages.favoriteStatusUnknownClickToLoad
            : UiMessages.like,
      ),
      icon: Icon(
        favorite == FavoriteState.liked
            ? Icons.favorite
            : favorite == FavoriteState.unknown
            ? Icons.favorite_outline
            : Icons.favorite_border,
        size: size,
      ),
      color: favorite == FavoriteState.liked
          ? AppColors.of(context).accentForeground
          : null,
      onPressed: (c?.busy('likes') ?? false)
          ? null
          : () async {
              if (c == null) {
                await showDialog<void>(
                  context: context,
                  builder: (dialogCtx) => AlertDialog(
                    title: const LocalizedText(UiMessages.likeMusic),
                    content: const LocalizedText(
                      UiMessages.signInToSyncYourFavoriteMusic,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                        child: const LocalizedText(UiMessages.ok),
                      ),
                    ],
                  ),
                );
                return;
              }
              if (!await requireMusicLogin(context, c) || !context.mounted) {
                return;
              }
              if (favorite == FavoriteState.unknown) {
                await c.loadFavorites();
                if (context.mounted && c.favoriteError != null) {
                  showMusicResult(
                    context,
                    MusicOperationResult(c.favoriteError!),
                  );
                }
                return;
              }
              final result = await c.setLiked(
                track,
                favorite != FavoriteState.liked,
              );
              if (context.mounted) showMusicResult(context, result);
            },
    );
  }
}

/// Button to collect/add a track to a playlist with a modal dialog.
final class MusicCollectButton extends StatelessWidget {
  const MusicCollectButton({
    required this.track,
    this.size = 18,
    this.buttonSize,
    super.key,
  });

  final TrackId track;
  final double size;
  final Size? buttonSize;

  @override
  Widget build(BuildContext context) {
    final c = MusicManagementScope.maybeOf(context);
    final targetSize = buttonSize ?? const Size(28, 36);
    return IconButton(
      style: _trackActionStyle(targetSize),
      tooltip: localizeOptionalUiText(context, UiMessages.addToPlaylist),
      icon: Icon(Icons.playlist_add_rounded, size: size),
      onPressed: () async {
        if (c == null) {
          await showDialog<void>(
            context: context,
            builder: (dialogCtx) => AlertDialog(
              title: const LocalizedText(UiMessages.addToPlaylist),
              content: const LocalizedText(
                UiMessages.signInToAddMusicToPlaylists,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const LocalizedText(UiMessages.ok),
                ),
              ],
            ),
          );
          return;
        }
        await showAddToPlaylist(context, c, [track]);
      },
    );
  }
}

ButtonStyle _trackActionStyle(Size size) => IconButton.styleFrom(
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  minimumSize: size,
  fixedSize: size,
  alignment: Alignment.center,
);
