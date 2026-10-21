import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import '../../l10n/ui_text.dart';

final class PageStateView extends StatelessWidget {
  const PageStateView({
    this.message,
    this.icon,
    this.onRetry,
    this.loading = false,
    super.key,
  });
  const PageStateView.loading({super.key})
    : message = null,
      icon = null,
      onRetry = null,
      loading = true;
  final String? message;
  final IconData? icon;
  final VoidCallback? onRetry;
  final bool loading;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: loading
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 48, color: AppColors.of(context).muted),
                  const SizedBox(height: 12),
                ],
                if (message != null)
                  LocalizedText(
                    message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.of(context).muted),
                  ),
                if (onRetry != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: onRetry,
                    child: const LocalizedText(UiMessages.retry),
                  ),
                ],
              ],
            ),
    ),
  );
}

final class SliverPageStateView extends StatelessWidget {
  const SliverPageStateView({
    this.message,
    this.onRetry,
    this.loading = false,
    super.key,
  });
  final String? message;
  final VoidCallback? onRetry;
  final bool loading;
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: PageStateView(
        message: message,
        onRetry: onRetry,
        loading: loading,
      ),
    ),
  );
}
