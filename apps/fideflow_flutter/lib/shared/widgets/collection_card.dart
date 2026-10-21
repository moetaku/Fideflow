import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/catalog/compact_count.dart';
import '../artwork.dart';

final class CollectionCard extends StatelessWidget {
  const CollectionCard({
    required this.title,
    required this.subtitle,
    required this.index,
    required this.onTap,
    this.artworkUri,
    this.isCircular = false,
    this.badge,
    this.onPlay,
    this.isPrivate = false,
    this.playCount,
    this.width = 168,
    this.imageSize = 158,
    super.key,
  });

  final String title;
  final String subtitle;
  final int index;
  final VoidCallback onTap;
  final Uri? artworkUri;
  final bool isCircular;
  final String? badge;
  final VoidCallback? onPlay;
  final bool isPrivate;
  final int? playCount;
  final double width;
  final double imageSize;

  static String _formatPlayCount(BuildContext context, int count) =>
      compactCount(
        count,
        locale:
            Localizations.of<AppLocalizations>(
              context,
              AppLocalizations,
            )?.localeName ??
            'zh_Hans',
      );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Column(
          crossAxisAlignment: isCircular
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    isCircular ? imageSize / 2 : 16,
                  ),
                  child: Artwork(
                    index: index,
                    size: imageSize,
                    radius: isCircular ? imageSize / 2 : 16,
                    artworkUri: artworkUri,
                  ),
                ),
                if (badge != null)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: LocalizedText(
                        badge!,
                        style: TextStyle(
                          color: AppColors.overlayText,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                if (playCount != null)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_arrow_rounded,
                            size: 13,
                            color: AppColors.overlayText,
                          ),
                          const SizedBox(width: 2),
                          LocalizedText(
                            _formatPlayCount(context, playCount!),
                            style: TextStyle(
                              color: AppColors.overlayText,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (isPrivate)
                  Positioned(
                    right: onPlay != null ? 50 : 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.lock_rounded,
                        size: 14,
                        color: AppColors.overlayText,
                      ),
                    ),
                  ),
                if (onPlay != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Material(
                      color: AppColors.of(context).accent,
                      shape: const CircleBorder(),
                      elevation: 4,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onPlay,
                        child: SizedBox(
                          width: 38,
                          height: 38,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: AppColors.of(context).onAccent,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            LocalizedText(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isCircular ? TextAlign.center : TextAlign.start,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 3),
              LocalizedText(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: isCircular ? TextAlign.center : TextAlign.start,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.of(context).muted,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
