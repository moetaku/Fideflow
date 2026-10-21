import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/music_scope.dart';
import 'music_feedback.dart';

final class PendingMusicOperations extends StatelessWidget {
  const PendingMusicOperations({super.key});
  @override
  Widget build(BuildContext context) {
    final c = MusicManagementScope.maybeOf(context);
    if (c == null || c.pendingKeys.isEmpty) return const SizedBox.shrink();
    return Wrap(
      children: [
        for (final key in c.pendingKeys)
          TextButton.icon(
            icon: const Icon(Icons.sync_problem),
            label: LocalizedText(
              UiMessages.resultIsPendingClickToVerify(
                (key == 'likes'
                        ? UiMessages.likeTracks
                        : key == 'create'
                        ? UiMessages.createPlaylist
                        : UiMessages.playlistActions)
                    .toString(),
              ),
            ),
            onPressed: () async {
              final result = await c.reconcile(key);
              if (context.mounted) showMusicResult(context, result);
            },
          ),
      ],
    );
  }
}

final class MusicReconcileButtons extends StatelessWidget {
  const MusicReconcileButtons({
    required this.controller,
    required this.onChecked,
  });
  final AccountMusicController controller;
  final ValueChanged<MusicOperationResult> onChecked;
  @override
  Widget build(BuildContext context) => Wrap(
    children: [
      for (final key in controller.pendingKeys)
        TextButton.icon(
          icon: const Icon(Icons.sync_problem),
          label: const LocalizedText(UiMessages.verifyOperationResult),
          onPressed: () async {
            onChecked(await controller.reconcile(key));
          },
        ),
    ],
  );
}
