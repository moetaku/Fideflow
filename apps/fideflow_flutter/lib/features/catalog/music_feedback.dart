import 'package:fideflow_application/application.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../auth/login_dialog.dart';

void showMusicResult(BuildContext context, MusicOperationResult result) {
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: LocalizedText(result.message)));
  }
}

Future<bool> requireMusicLogin(
  BuildContext context,
  AccountMusicController c,
) async {
  if (c.authenticated) return true;
  await LoginDialog.show(context, c.auth);
  return false;
}
