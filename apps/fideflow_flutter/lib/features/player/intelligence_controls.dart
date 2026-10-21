import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';

/// Shared stream state and explicit exit/retry controls for all player surfaces.
final class IntelligenceControls extends StatelessWidget {
  const IntelligenceControls({
    required this.snapshot,
    this.controller,
    super.key,
  });
  final PlaybackSnapshot snapshot;
  final IntelligenceModeController? controller;

  @override
  Widget build(BuildContext context) {
    if (!snapshot.isIntelligenceMode) return const SizedBox.shrink();
    final loading = controller?.loading == true;
    final failed = controller?.errorCode != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            Icons.favorite_rounded,
            color: AppColors.of(context).accentForeground,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: LocalizedText(
              loading
                  ? UiMessages.heartbeatModeLoadingRecommendations
                  : failed
                  ? UiMessages.heartbeatRecommendationsPausedClickToRetry
                  : UiMessages.heartbeatMode,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (failed && !loading)
            TextButton(
              onPressed: controller?.retry,
              child: const LocalizedText(UiMessages.retryRecommendations),
            ),
          TextButton(
            onPressed: controller?.exit,
            child: const LocalizedText(UiMessages.exitHeartbeat),
          ),
        ],
      ),
    );
  }
}
