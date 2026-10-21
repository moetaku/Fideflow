import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../app/language.dart';
import '../../l10n/ui_text.dart';
import '../../shared/widgets/settings_tile.dart';

final class LanguageSettings extends StatelessWidget {
  const LanguageSettings({required this.controller, super.key});

  final LanguageController controller;

  String _modeLabel(BuildContext context, LanguageMode mode) {
    return switch (mode) {
      LanguageMode.system =>
        localizeOptionalUiText(context, UiMessages.languageFollowSystem) ??
            '跟随系统',
      LanguageMode.english =>
        localizeOptionalUiText(context, UiMessages.languageNameEnglish) ??
            'English',
      LanguageMode.simplified =>
        localizeOptionalUiText(context, UiMessages.languageNameSimplified) ??
            '简体中文',
    };
  }

  void _showLanguagePicker(BuildContext context) {
    showAdaptiveSettingsSheetOrDialog<void>(
      context: context,
      title: UiMessages.languageSettings,
      maxWidth: 420,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in LanguageMode.values) ...[
              ListTile(
                title: Text(
                  _modeLabel(context, mode),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: controller.mode == mode
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: controller.mode == mode
                        ? AppColors.of(context).accentForeground
                        : AppColors.of(context).text,
                  ),
                ),
                trailing: controller.mode == mode
                    ? Icon(
                        Icons.check_rounded,
                        color: AppColors.of(context).accentForeground,
                        size: 20,
                      )
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onTap: () {
                  controller.select(mode);
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      String? subtitle;
      if (controller.saving) {
        subtitle =
            localizeOptionalUiText(context, UiMessages.languageSaving) ??
            '正在保存…';
      } else if (controller.saveFailed) {
        subtitle =
            localizeOptionalUiText(context, UiMessages.languageSaveFailed) ??
            '保存失败';
      }

      return SettingsTile(
        key: const ValueKey('language-selection'),
        leading: const Icon(Icons.language_rounded, size: 22),
        title:
            localizeOptionalUiText(context, UiMessages.languageSettings) ??
            '界面语言',
        subtitle: subtitle,
        trailingText: _modeLabel(context, controller.mode),
        onTap: () => _showLanguagePicker(context),
      );
    },
  );
}
