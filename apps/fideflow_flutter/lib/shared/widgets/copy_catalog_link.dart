import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import '../../app/clipboard_writer.dart';
import '../../l10n/ui_text.dart';
import '../../presentation/catalog/share_link.dart';

Future<void> copyCatalogLink(
  BuildContext context, {
  required NcmKind kind,
  required String id,
  required String successMessage,
  ClipboardWriter writer = const PlatformClipboardWriter(),
}) async {
  final link = catalogShareLink(kind, id);
  if (link == null) return;
  try {
    await writer.write(link.toString());
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: LocalizedText(successMessage),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: const LocalizedText(UiMessages.operationFailedPleaseTryAgain),
      ),
    );
  }
}
