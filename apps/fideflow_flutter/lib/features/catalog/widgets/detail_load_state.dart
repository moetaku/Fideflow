import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../../l10n/ui_text.dart';
import '../../../shared/widgets/page_state_view.dart';

/// Detail navigation remains escapable while loading or when no page exists.
class DetailLoadState extends StatelessWidget {
  const DetailLoadState({
    required this.kind,
    required this.onRetry,
    this.error,
    this.onBack,
    super.key,
  });
  final String kind;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final unavailable =
        error == 'ncm.artistNotFound' || error == 'ncm.albumNotFound';
    return Column(
      children: [
        if (onBack != null)
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: AppBreakpoints.pagePadding(
                AppBreakpoints.of(context),
                bottom: 8,
              ),
              child: IconButton(
                onPressed: onBack,
                tooltip: localizeOptionalUiText(context, UiMessages.back),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
          ),
        Expanded(
          child: error == null
              ? const PageStateView.loading()
              : PageStateView(
                  message: unavailable
                      ? UiMessages.noDetailsAvailableForThis(kind)
                      : UiMessages.couldNotLoad(kind),
                  onRetry: unavailable ? null : onRetry,
                ),
        ),
      ],
    );
  }
}
