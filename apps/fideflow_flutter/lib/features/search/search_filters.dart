import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';

final class SearchFilters extends StatelessWidget {
  const SearchFilters({
    required this.selectedType,
    required this.onTypeChanged,
    required this.onlyPlayable,
    required this.onOnlyPlayableChanged,
    this.selectedQuality,
    this.onQualityChanged,
    super.key,
  });

  final SearchType selectedType;
  final ValueChanged<SearchType> onTypeChanged;
  final bool onlyPlayable;
  final ValueChanged<bool> onOnlyPlayableChanged;
  final TrackQuality? selectedQuality;
  final ValueChanged<TrackQuality?>? onQualityChanged;

  static const _types = [
    (SearchType.track, UiMessages.tracks7),
    (SearchType.playlist, UiMessages.playlist),
    (SearchType.album, UiMessages.album),
    (SearchType.artist, UiMessages.artist),
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (type, label) in _types) ...[
              _TypeTab(
                label: label,
                selected: selectedType == type,
                onTap: () => onTypeChanged(type),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
      if (selectedType == SearchType.track) ...[
        const SizedBox(height: 14),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onOnlyPlayableChanged(!onlyPlayable),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 20,
                          width: 20,
                          child: Checkbox(
                            value: onlyPlayable,
                            activeColor: AppColors.of(context).accent,
                            checkColor: AppColors.of(context).onAccent,
                            onChanged: (val) =>
                                onOnlyPlayableChanged(val ?? false),
                          ),
                        ),
                        const SizedBox(width: 6),
                        LocalizedText(
                          UiMessages.playableOnly,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.of(context).text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: localizeOptionalUiText(
                    context,
                    UiMessages
                        .excludePreviewsAndUnconfirmedSourcesShowOnlyFully,
                  ),
                  child: Icon(
                    Icons.help_outline_rounded,
                    size: 15,
                    color: AppColors.of(context).muted,
                  ),
                ),
              ],
            ),
            if (onQualityChanged != null)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  LocalizedText(
                    UiMessages.audioQuality2,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                  _QualityChip(
                    label: UiMessages.all,
                    selected: selectedQuality == null,
                    onTap: () => onQualityChanged!(null),
                  ),
                  _QualityChip(
                    label: 'Hi-Res',
                    selected: selectedQuality == TrackQuality.hiRes,
                    onTap: () => onQualityChanged!(TrackQuality.hiRes),
                  ),
                  _QualityChip(
                    label: UiMessages.sqLossless,
                    selected: selectedQuality == TrackQuality.lossless,
                    onTap: () => onQualityChanged!(TrackQuality.lossless),
                  ),
                  _QualityChip(
                    label: UiMessages.hqHighQuality,
                    selected: selectedQuality == TrackQuality.high,
                    onTap: () => onQualityChanged!(TrackQuality.high),
                  ),
                ],
              ),
          ],
        ),
      ],
    ],
  );
}

final class _TypeTab extends StatelessWidget {
  const _TypeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.of(context).accent.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected
              ? AppColors.of(context).accent.withValues(alpha: 0.4)
              : AppColors.of(context).border,
        ),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected
              ? AppColors.of(context).accentForeground
              : AppColors.of(context).muted,
        ),
      ),
    ),
  );
}

final class _QualityChip extends StatelessWidget {
  const _QualityChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.of(context).accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected
              ? AppColors.of(context).accent.withValues(alpha: 0.3)
              : AppColors.of(context).border,
        ),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
          color: selected
              ? AppColors.of(context).accentForeground
              : AppColors.of(context).muted,
        ),
      ),
    ),
  );
}
