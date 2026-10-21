import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../../l10n/ui_text.dart';

final class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.title,
    this.action,
    this.onAction,
    this.status = HomeSectionStatus.ready,
    this.onRetry,
    super.key,
  });

  final String title;
  final String? action;
  final VoidCallback? onAction;
  final HomeSectionStatus status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      LocalizedText(
        title,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      if (status == HomeSectionStatus.failed && onRetry != null) ...[
        const SizedBox(width: 12),
        TextButton.icon(
          onPressed: onRetry,
          icon: Icon(
            Icons.refresh_rounded,
            size: 14,
            color: AppColors.of(context).accentForeground,
          ),
          label: LocalizedText(
            UiMessages.retry,
            style: TextStyle(color: AppColors.of(context).accentForeground),
          ),
        ),
      ],
      const Spacer(),
      if (action != null)
        TextButton(
          onPressed: onAction ?? () {},
          child: LocalizedText(
            action!,
            style: TextStyle(color: AppColors.of(context).accentForeground),
          ),
        ),
    ],
  );
}
