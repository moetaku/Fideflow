import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import '../../shared/widgets/settings_tile.dart';
import 'account_list.dart';

final class AccountManagerSheet extends StatelessWidget {
  const AccountManagerSheet({required this.authController, super.key});
  final AuthController authController;
  static Future<void> show(
    BuildContext context,
    AuthController authController,
  ) => showAdaptiveSettingsSheetOrDialog<void>(
    context: context,
    title: UiMessages.account,
    maxWidth: 520,
    child: AccountManagerSheet(authController: authController),
  );
  @override
  Widget build(BuildContext context) =>
      AccountList(authController: authController, framed: false);
}
