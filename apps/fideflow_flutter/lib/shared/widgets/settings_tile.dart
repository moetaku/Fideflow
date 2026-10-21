import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';

/// Shows an adaptive modal bottom sheet on mobile (<600dp) or a centered dialog on desktop.
Future<T?> showAdaptiveSettingsSheetOrDialog<T>({
  required BuildContext context,
  required String title,
  required Widget child,
  double maxWidth = 560,
}) {
  final isCompact = AppBreakpoints.of(context).isCompact;
  if (isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Material(
          color: AppColors.of(sheetContext).panel,
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.of(
                        sheetContext,
                      ).muted.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: LocalizedText(
                            title,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppColors.of(sheetContext).text,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: localizeUiText(context, UiMessages.close),
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: AppColors.of(dialogContext).panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: LocalizedText(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.of(dialogContext).text,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: localizeUiText(context, UiMessages.close),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: child,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A clean high-density summary tile used across settings and management sections.
final class SettingsTile extends StatelessWidget {
  const SettingsTile({
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingText,
    this.onTap,
    this.showChevron = true,
    super.key,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final String? trailingText;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 14)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (trailingText != null && trailingText!.isNotEmpty)
                Text(
                  trailingText!,
                  style: TextStyle(fontSize: 13, color: colors.muted),
                ),
              ?trailing,
              if (onTap != null && trailing == null && showChevron) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.muted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
