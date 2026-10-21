import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/catalog/track_sort.dart';

Future<TrackSortState?> showTrackSortSheet(
  BuildContext context, {
  required TrackSortState state,
  List<TrackSortCriteria> fields = TrackSortCriteria.values,
}) => showModalBottomSheet<TrackSortState>(
  context: context,
  backgroundColor: AppColors.of(context).panel,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
  ),
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: LocalizedText(UiMessages.sort)),
          for (final item in fields)
            ListTile(
              title: LocalizedText(item.label),
              selected: state.criteria == item,
              trailing: state.criteria != item
                  ? null
                  : Icon(
                      item == TrackSortCriteria.defaultOrder
                          ? Icons.check_rounded
                          : state.ascending
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                    ),
              onTap: () => Navigator.pop(context, state.cycle(item)),
            ),
        ],
      ),
    ),
  ),
);
