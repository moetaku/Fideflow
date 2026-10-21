import 'package:fideflow_design_system/design_system.dart';
import 'package:flutter/material.dart';
import '../../l10n/ui_text.dart';

final class CategoryPickerBody extends StatelessWidget {
  const CategoryPickerBody({
    required this.groups,
    required this.selectedGroup,
    required this.onGroupChanged,
    required this.tags,
    required this.tagBuilder,
    required this.scrollController,
    required this.emptyMessage,
    super.key,
  });
  final Map<String, String> groups;
  final String selectedGroup;
  final ValueChanged<String> onGroupChanged;
  final List<String> tags;
  final Widget Function(String) tagBuilder;
  final ScrollController scrollController;
  final String emptyMessage;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in groups.entries) ...[
              InkWell(
                onTap: () => onGroupChanged(entry.key),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LocalizedText(
                        entry.value,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selectedGroup == entry.key
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selectedGroup == entry.key
                              ? AppColors.of(context).text
                              : AppColors.of(context).muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        height: 2.5,
                        width: 18,
                        decoration: BoxDecoration(
                          color: selectedGroup == entry.key
                              ? AppColors.of(context).accent
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
      const SizedBox(height: 10),
      Expanded(
        child: tags.isEmpty
            ? Center(
                child: LocalizedText(
                  emptyMessage,
                  style: TextStyle(color: AppColors.of(context).muted),
                ),
              )
            : Scrollbar(
                controller: scrollController,
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.only(right: 6),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [for (final tag in tags) tagBuilder(tag)],
                  ),
                ),
              ),
      ),
    ],
  );
}

final class CategoryTagChip extends StatelessWidget {
  const CategoryTagChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.of(context).accent.withValues(alpha: 0.18)
            : AppColors.of(context).selected,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? AppColors.of(context).accent
              : AppColors.of(context).border,
        ),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
          color: selected
              ? AppColors.of(context).accentForeground
              : AppColors.of(context).muted,
        ),
      ),
    ),
  );
}
