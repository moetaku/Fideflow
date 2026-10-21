import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../../l10n/ui_text.dart';
import '../../../presentation/catalog/track_sort.dart';

export '../../../presentation/catalog/track_sort.dart';

final class SortingBar extends StatelessWidget {
  const SortingBar({
    required this.criteria,
    required this.ascending,
    required this.onChanged,
    this.fields,
    super.key,
  });

  final TrackSortCriteria criteria;
  final bool ascending;
  final void Function(TrackSortCriteria criteria, bool ascending) onChanged;
  final Iterable<TrackSortCriteria>? fields;

  @override
  Widget build(BuildContext context) {
    final items = fields ?? TrackSortCriteria.values;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        LocalizedText(
          UiMessages.sort,
          style: TextStyle(fontSize: 12, color: AppColors.of(context).muted),
        ),
        for (final item in items)
          _SortChip(
            criteria: item,
            selected: criteria == item,
            ascending: ascending,
            onTap: () {
              final next = TrackSortState(
                criteria: criteria,
                ascending: ascending,
              ).cycle(item);
              onChanged(next.criteria, next.ascending);
            },
          ),
      ],
    );
  }
}

final class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.criteria,
    required this.selected,
    required this.ascending,
    required this.onTap,
  });

  final TrackSortCriteria criteria;
  final bool selected;
  final bool ascending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.of(context).accent.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? AppColors.of(context).accent.withValues(alpha: 0.4)
              : AppColors.of(context).border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LocalizedText(
            criteria.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
              color: selected
                  ? AppColors.of(context).accentForeground
                  : AppColors.of(context).muted,
            ),
          ),
          if (selected && criteria != TrackSortCriteria.defaultOrder) ...[
            const SizedBox(width: 4),
            Icon(
              ascending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              size: 13,
              color: AppColors.of(context).accentForeground,
            ),
          ],
        ],
      ),
    ),
  );
}
