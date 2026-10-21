import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';

import '../../app/appearance.dart';
import '../../l10n/ui_text.dart';
import '../../shared/widgets/settings_option_grid.dart';

const _roleNames = {
  ThemeColorRole.accent: UiMessages.accent,
  ThemeColorRole.background: UiMessages.background,
  ThemeColorRole.panel: UiMessages.panel,
  ThemeColorRole.text: UiMessages.text,
  ThemeColorRole.muted: UiMessages.secondaryText,
  ThemeColorRole.border: UiMessages.border,
  ThemeColorRole.success: UiMessages.successColor,
  ThemeColorRole.warning: UiMessages.warningColor,
  ThemeColorRole.error: UiMessages.errorColor,
};

enum _ThemeFilter { all, dark, light, custom }

/// The settings host lays these parts out in its own lazy scrollable. Actions
/// and filter state still belong to one AppearanceSettings instance.
final class AppearanceSettingsContent {
  const AppearanceSettingsContent({
    required this.leading,
    required this.themeIds,
    required this.itemBuilder,
    required this.trailing,
  });
  final Widget leading;
  final List<String> themeIds;
  final IndexedWidgetBuilder itemBuilder;
  final Widget trailing;
}

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({
    required this.controller,
    this.contentBuilder,
    super.key,
  });
  final AppearanceController controller;
  final Widget Function(BuildContext, AppearanceSettingsContent)?
  contentBuilder;
  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  String? _message;
  bool _busy = false;
  _ThemeFilter _filter = _ThemeFilter.all;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is FormatException
              ? e.message
              : UiMessages.operationFailedPleaseTryAgain,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(ThemeDefinition original, {bool copy = false}) async {
    final c = widget.controller;
    final draft = c
        .effective(original)
        .copyWith(
          id: copy ? c.newId() : original.id,
          name: copy
              ? c.uniqueName(
                  localizeUiText(context, UiMessages.copy(original.name)),
                )
              : original.name,
        );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ThemeEditor(controller: c, initial: draft),
    );
  }

  Future<void> _rename(ThemeDefinition t) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _RenameThemeDialog(controller: widget.controller, theme: t),
    );
  }

  Future<void> _delete(ThemeDefinition t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LocalizedText(UiMessages.deleteTheme),
        content: LocalizedText(
          UiMessages.delete2(
            (t.name).toString(),
            (t.id == widget.controller.selectedId
                    ? UiMessages.themeDeletionFallback
                    : '')
                .toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LocalizedText(UiMessages.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LocalizedText(UiMessages.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(() => widget.controller.delete(t.id));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final busy = _busy || c.saving;
      final filteredThemes = c.themes.where((t) {
        return switch (_filter) {
          _ThemeFilter.all => true,
          _ThemeFilter.dark => t.brightness == Brightness.dark,
          _ThemeFilter.light => t.brightness == Brightness.light,
          _ThemeFilter.custom => c.isCustom(t.id),
        };
      }).toList();

      final leading = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              SegmentedButton<_ThemeFilter>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(
                    value: _ThemeFilter.all,
                    label: LocalizedText(UiMessages.all),
                  ),
                  ButtonSegment(
                    value: _ThemeFilter.dark,
                    label: LocalizedText(UiMessages.dark),
                  ),
                  ButtonSegment(
                    value: _ThemeFilter.light,
                    label: LocalizedText(UiMessages.light),
                  ),
                  ButtonSegment(
                    value: _ThemeFilter.custom,
                    label: LocalizedText(UiMessages.customThemeBadge),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: (set) =>
                    setState(() => _filter = set.first),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => _edit(c.selected, copy: true),
                    icon: const Icon(Icons.palette_outlined, size: 16),
                    label: const LocalizedText(UiMessages.createCustomTheme),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _run(() async {
                            final imported = await c.importTheme();
                            if (imported != null && mounted) {
                              setState(
                                () => _message =
                                    UiMessages.importedClickTheThemeToApplyIt(
                                      (imported.name).toString(),
                                    ),
                              );
                            }
                          }),
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: const LocalizedText(UiMessages.importJson),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      );
      Widget itemBuilder(BuildContext context, int index) {
        final t = filteredThemes[index];
        return _ThemeOptionCard(
          key: ValueKey('theme-card-${t.id}'),
          theme: t,
          selected: t.id == c.selectedId,
          isCustom: c.isCustom(t.id),
          busy: busy,
          onSelect: () => _run(() => c.select(t.id)),
          onDuplicate: () => _edit(t, copy: true),
          onEdit: () => _edit(t),
          onRename: () => _rename(t),
          onDelete: () => _delete(t),
          onExport: () => _run(() async {
            final saved = await c.exportTheme(t);
            if (saved && mounted) {
              setState(() => _message = UiMessages.themeExported);
            }
          }),
        );
      }

      final trailing = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const LocalizedText(UiMessages.currentThemeAccentColor),
              InkWell(
                onTap: busy
                    ? null
                    : () async {
                        final value = await showDialog<Color>(
                          context: context,
                          builder: (context) => _AccentDialog(
                            initial: c.effective(
                              c.selected,
                            )[ThemeColorRole.accent],
                          ),
                        );
                        if (value != null) await _run(() => c.setAccent(value));
                      },
                child: Container(
                  width: 36,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c.effective(c.selected)[ThemeColorRole.accent],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.edit,
                    size: 16,
                    color: readableOn(
                      c.effective(c.selected)[ThemeColorRole.accent],
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: busy ? null : () => _run(() => c.setAccent(null)),
                child: const LocalizedText(UiMessages.restoreDefaultColor),
              ),
            ],
          ),
          if (c.persistenceNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LocalizedText(
                c.persistenceNotice!,
                style: TextStyle(color: AppColors.of(context).warning),
              ),
            ),
          if (_message != null || c.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LocalizedText(
                _message ?? c.error!,
                key: const ValueKey('appearance-message'),
              ),
            ),
        ],
      );
      final content = AppearanceSettingsContent(
        leading: leading,
        themeIds: [for (final theme in filteredThemes) theme.id],
        itemBuilder: itemBuilder,
        trailing: trailing,
      );
      return widget.contentBuilder?.call(context, content) ??
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leading,
              SettingsOptionGrid(
                children: [
                  for (var i = 0; i < filteredThemes.length; i++)
                    itemBuilder(context, i),
                ],
              ),
              trailing,
            ],
          );
    },
  );
}

final class _ThemeOptionCard extends StatelessWidget {
  const _ThemeOptionCard({
    required this.theme,
    required this.selected,
    required this.isCustom,
    required this.busy,
    required this.onSelect,
    required this.onDuplicate,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
    required this.onExport,
    super.key,
  });

  final ThemeDefinition theme;
  final bool selected;
  final bool isCustom;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onDuplicate;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final bg = theme[ThemeColorRole.background];
    final text = theme[ThemeColorRole.text];
    final muted = theme[ThemeColorRole.muted];
    final border = theme[ThemeColorRole.border];
    final panel = theme[ThemeColorRole.panel];
    final accent = theme[ThemeColorRole.accent];
    final accentSurface = Color.alphaBlend(accent.withValues(alpha: 0.15), bg);
    final accentForeground = ensureContrast(accent, accentSurface);
    final panelAccentForeground = ensureContrast(accent, panel);

    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      label: localizeOptionalUiText(context, theme.name),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: busy ? null : onSelect,
          borderRadius: BorderRadius.circular(14),
          hoverColor: text.withValues(alpha: 0.04),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? accent : border.withValues(alpha: 0.7),
                width: 1.6,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: panel,
                    shape: BoxShape.circle,
                    border: Border.all(color: border, width: 1.0),
                  ),
                  child: Icon(
                    Icons.palette_outlined,
                    size: 18,
                    color: panelAccentForeground,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      LocalizedText(
                        theme.name,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: text,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: panel,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: border.withValues(alpha: 0.7),
                                width: 0.8,
                              ),
                            ),
                            child: LocalizedText(
                              theme.brightness == Brightness.dark
                                  ? UiMessages.dark
                                  : UiMessages.light,
                              style: TextStyle(fontSize: 10.5, color: muted),
                            ),
                          ),
                          if (isCustom) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: accent.withValues(alpha: 0.4),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  uiCopy(context).customThemeBadge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: accentForeground,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  enabled: !busy,
                  tooltip: localizeOptionalUiText(
                    context,
                    UiMessages.actions(theme.name.toString()),
                  ),
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_horiz, size: 20, color: muted),
                  onSelected: (action) {
                    switch (action) {
                      case 'copy':
                        onDuplicate();
                      case 'edit':
                        onEdit();
                      case 'rename':
                        onRename();
                      case 'delete':
                        onDelete();
                      case 'export':
                        onExport();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'copy',
                      child: LocalizedText(UiMessages.duplicate),
                    ),
                    if (isCustom) ...[
                      const PopupMenuItem(
                        value: 'edit',
                        child: LocalizedText(UiMessages.edit),
                      ),
                      const PopupMenuItem(
                        value: 'rename',
                        child: LocalizedText(UiMessages.rename),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: LocalizedText(UiMessages.delete),
                      ),
                    ],
                    const PopupMenuItem(
                      value: 'export',
                      child: LocalizedText(UiMessages.exportJson),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                if (selected)
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.check_rounded,
                      size: 13,
                      color: readableOn(accent),
                    ),
                  )
                else
                  Icon(
                    Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: muted.withValues(alpha: 0.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RenameThemeDialog extends StatefulWidget {
  const _RenameThemeDialog({required this.controller, required this.theme});
  final AppearanceController controller;
  final ThemeDefinition theme;
  @override
  State<_RenameThemeDialog> createState() => _RenameThemeDialogState();
}

class _RenameThemeDialogState extends State<_RenameThemeDialog> {
  late final name = TextEditingController(text: widget.theme.name);
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.rename(widget.theme.id, name.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : UiMessages.couldNotSavePleaseTryAgain,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const LocalizedText(UiMessages.renameTheme),
      content: TextField(
        controller: name,
        enabled: !busy,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(
          labelText: localizeOptionalUiText(context, UiMessages.themeName),
          errorText: localizeOptionalUiText(context, error),
        ),
        onSubmitted: (_) => save(),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const LocalizedText(UiMessages.cancel),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: LocalizedText(busy ? UiMessages.saving : UiMessages.save),
        ),
      ],
    ),
  );
}

class _AccentDialog extends StatefulWidget {
  const _AccentDialog({required this.initial});
  final Color initial;
  @override
  State<_AccentDialog> createState() => _AccentDialogState();
}

class _AccentDialogState extends State<_AccentDialog> {
  late Color color = widget.initial;
  bool valid = true;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const LocalizedText(UiMessages.accent),
    content: SizedBox(
      width: 350,
      child: SingleChildScrollView(
        child: ColorTuner(
          color: color,
          onValidityChanged: (v) => setState(() => valid = v),
          onChanged: (value) => setState(() => color = value),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const LocalizedText(UiMessages.cancel),
      ),
      FilledButton(
        onPressed: valid ? () => Navigator.pop(context, color) : null,
        child: const LocalizedText(UiMessages.apply),
      ),
    ],
  );
}

enum _BaseTone { oledBlack, coolDark, warmNight, pureWhite, warmWhite }

String _baseToneName(_BaseTone tone, BuildContext context) => switch (tone) {
  _BaseTone.oledBlack => uiCopy(context).themeToneOledBlack,
  _BaseTone.coolDark => uiCopy(context).themeToneCoolDark,
  _BaseTone.warmNight => uiCopy(context).themeToneWarmNight,
  _BaseTone.pureWhite => uiCopy(context).themeTonePureWhite,
  _BaseTone.warmWhite => uiCopy(context).themeToneWarmWhite,
};

Brightness _baseToneBrightness(_BaseTone tone) => switch (tone) {
  _BaseTone.oledBlack ||
  _BaseTone.coolDark ||
  _BaseTone.warmNight => Brightness.dark,
  _BaseTone.pureWhite || _BaseTone.warmWhite => Brightness.light,
};

_BaseTone _detectBaseTone(ThemeDefinition theme) {
  if (theme.brightness == Brightness.dark) {
    final bg = theme[ThemeColorRole.background];
    if (bg.r < 0.03 && bg.g < 0.03 && bg.b < 0.03) {
      return _BaseTone.oledBlack;
    }
    if (bg.r > bg.b) {
      return _BaseTone.warmNight;
    }
    return _BaseTone.coolDark;
  } else {
    final bg = theme[ThemeColorRole.background];
    if (bg.r < 0.99 || bg.g < 0.99 || bg.b < 0.98) {
      return _BaseTone.warmWhite;
    }
    return _BaseTone.pureWhite;
  }
}

Map<ThemeColorRole, Color> _derivePalette({
  required _BaseTone tone,
  required Color accent,
}) {
  switch (tone) {
    case _BaseTone.oledBlack:
      return {
        ThemeColorRole.accent: accent,
        ThemeColorRole.background: const Color(0xFF000000),
        ThemeColorRole.panel: const Color(0xFF121214),
        ThemeColorRole.border: Color.alphaBlend(
          accent.withValues(alpha: 0.12),
          const Color(0xFF26262B),
        ),
        ThemeColorRole.text: const Color(0xFFF3F4F6),
        ThemeColorRole.muted: const Color(0xFF9CA3AF),
        ThemeColorRole.success: const Color(0xFF4ADE80),
        ThemeColorRole.warning: const Color(0xFFFBBF24),
        ThemeColorRole.error: const Color(0xFFF87171),
      };

    case _BaseTone.coolDark:
      return {
        ThemeColorRole.accent: accent,
        ThemeColorRole.background: const Color(0xFF111418),
        ThemeColorRole.panel: const Color(0xFF1B2028),
        ThemeColorRole.border: Color.alphaBlend(
          accent.withValues(alpha: 0.14),
          const Color(0xFF2B323E),
        ),
        ThemeColorRole.text: const Color(0xFFE5E7EB),
        ThemeColorRole.muted: const Color(0xFF94A3B8),
        ThemeColorRole.success: const Color(0xFF34D399),
        ThemeColorRole.warning: const Color(0xFFFBBF24),
        ThemeColorRole.error: const Color(0xFFF87171),
      };

    case _BaseTone.warmNight:
      return {
        ThemeColorRole.accent: accent,
        ThemeColorRole.background: const Color(0xFF181513),
        ThemeColorRole.panel: const Color(0xFF241F1C),
        ThemeColorRole.border: Color.alphaBlend(
          accent.withValues(alpha: 0.14),
          const Color(0xFF38312C),
        ),
        ThemeColorRole.text: const Color(0xFFF5EFEB),
        ThemeColorRole.muted: const Color(0xFFA89F98),
        ThemeColorRole.success: const Color(0xFF4ADE80),
        ThemeColorRole.warning: const Color(0xFFFBBF24),
        ThemeColorRole.error: const Color(0xFFF87171),
      };

    case _BaseTone.pureWhite:
      return {
        ThemeColorRole.accent: accent,
        ThemeColorRole.background: const Color(0xFFFFFFFF),
        ThemeColorRole.panel: const Color(0xFFF3F4F6),
        ThemeColorRole.border: Color.alphaBlend(
          accent.withValues(alpha: 0.10),
          const Color(0xFFE5E7EB),
        ),
        ThemeColorRole.text: const Color(0xFF111827),
        ThemeColorRole.muted: const Color(0xFF4B5563),
        ThemeColorRole.success: const Color(0xFF16A34A),
        ThemeColorRole.warning: const Color(0xFFD97706),
        ThemeColorRole.error: const Color(0xFFDC2626),
      };

    case _BaseTone.warmWhite:
      return {
        ThemeColorRole.accent: accent,
        ThemeColorRole.background: const Color(0xFFF8F5EE),
        ThemeColorRole.panel: const Color(0xFFEFEBE1),
        ThemeColorRole.border: Color.alphaBlend(
          accent.withValues(alpha: 0.12),
          const Color(0xFFDDD7C9),
        ),
        ThemeColorRole.text: const Color(0xFF231F1C),
        ThemeColorRole.muted: const Color(0xFF59524C),
        ThemeColorRole.success: const Color(0xFF15803D),
        ThemeColorRole.warning: const Color(0xFFB45309),
        ThemeColorRole.error: const Color(0xFFB91C1C),
      };
  }
}

const _presetAccents = [
  Color(0xFF8B5CF6), // 紫罗兰 (Violet)
  Color(0xFF06B6D4), // 极光青 (Cyan)
  Color(0xFFF43F5E), // 珊瑚粉 (Coral)
  Color(0xFFF97316), // 活力橙 (Orange)
  Color(0xFF3B82F6), // 经典蓝 (Blue)
  Color(0xFF10B981), // 翡翠绿 (Emerald)
  Color(0xFFF59E0B), // 琥珀黄 (Amber)
  Color(0xFFEC4899), // 亮粉色 (Pink)
];

class ThemeEditor extends StatefulWidget {
  const ThemeEditor({
    required this.controller,
    required this.initial,
    super.key,
  });
  final AppearanceController controller;
  final ThemeDefinition initial;
  @override
  State<ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends State<ThemeEditor> {
  late ThemeDefinition draft = widget.initial;
  late final TextEditingController name = TextEditingController(
    text: draft.name,
  );
  late _BaseTone _selectedTone;
  ThemeColorRole role = ThemeColorRole.accent;
  bool _advancedExpanded = false;
  final Map<ThemeColorRole, Color> _slotOverrides = {};
  bool busy = false;
  bool valid = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _selectedTone = _detectBaseTone(widget.initial);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.save(draft.copyWith(name: name.text));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : UiMessages.couldNotSavePleaseTryAgain,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const LocalizedText(UiMessages.customTheme),
      content: SizedBox(
        width: 760,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;

              final controls = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    enabled: !busy,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: localizeOptionalUiText(
                        context,
                        UiMessages.themeName,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Step 1: 选基调模式
                  Row(
                    children: [
                      Icon(
                        Icons.tonality_rounded,
                        size: 15,
                        color: AppColors.of(context).accentForeground,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          uiCopy(context).themeBaseToneStep,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.of(context).text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<_BaseTone>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      segments: [
                        for (final tone in _BaseTone.values)
                          ButtonSegment(
                            value: tone,
                            label: Text(
                              _baseToneName(tone, context),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      selected: {_selectedTone},
                      onSelectionChanged: busy
                          ? null
                          : (tones) {
                              final newTone = tones.first;
                              setState(() {
                                _selectedTone = newTone;
                                draft = draft.copyWith(
                                  brightness: _baseToneBrightness(newTone),
                                  colors: {
                                    ..._derivePalette(
                                      tone: newTone,
                                      accent: draft[ThemeColorRole.accent],
                                    ),
                                    ..._slotOverrides,
                                  },
                                );
                              });
                            },
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Step 2: 选强调色 (Accent)
                  Row(
                    children: [
                      Icon(
                        Icons.palette_outlined,
                        size: 15,
                        color: AppColors.of(context).accentForeground,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          uiCopy(context).themeAccentStep,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.of(context).text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ChoiceChip(
                        label: const LocalizedText(UiMessages.accent),
                        avatar: CircleAvatar(
                          backgroundColor: draft[ThemeColorRole.accent],
                          radius: 8,
                        ),
                        selected: role == ThemeColorRole.accent,
                        onSelected: busy
                            ? null
                            : (_) {
                                if (role == ThemeColorRole.accent) return;
                                setState(() {
                                  role = ThemeColorRole.accent;
                                  valid = true;
                                });
                              },
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final c in _presetAccents)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InkWell(
                                    onTap: busy
                                        ? null
                                        : () {
                                            setState(() {
                                              role = ThemeColorRole.accent;
                                              valid = true;
                                              draft = draft.copyWith(
                                                colors: {
                                                  ...draft.colors,
                                                  ThemeColorRole.accent: c,
                                                },
                                              );
                                            });
                                          },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color:
                                              draft[ThemeColorRole.accent] == c
                                              ? AppColors.of(
                                                  context,
                                                ).accentForeground
                                              : AppColors.of(context).border,
                                          width:
                                              draft[ThemeColorRole.accent] == c
                                              ? 2.2
                                              : 1.0,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  IgnorePointer(
                    ignoring: busy,
                    child: ColorTuner(
                      key: ValueKey(role),
                      color: draft[role],
                      onValidityChanged: (v) => setState(() => valid = v),
                      onChanged: (color) => setState(() {
                        if (role != ThemeColorRole.accent) {
                          _slotOverrides[role] = color;
                        }
                        draft = draft.copyWith(
                          colors: {...draft.colors, role: color},
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Collapsible Advanced Mode
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: AppColors.of(
                          context,
                        ).border.withValues(alpha: 0.7),
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InkWell(
                          onTap: () => setState(() {
                            _advancedExpanded = !_advancedExpanded;
                            if (!_advancedExpanded &&
                                role != ThemeColorRole.accent) {
                              role = ThemeColorRole.accent;
                              valid = true;
                            }
                          }),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _advancedExpanded
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down,
                                  size: 18,
                                  color: AppColors.of(context).muted,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    uiCopy(context).themeAdvancedTuning,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.of(context).muted,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  _advancedExpanded
                                      ? uiCopy(context).themeCollapseSlots
                                      : uiCopy(context).themeExpandSlots,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.of(context).muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_advancedExpanded) ...[
                          Divider(
                            height: 1,
                            color: AppColors.of(
                              context,
                            ).border.withValues(alpha: 0.6),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  uiCopy(context).themeSlotOverrideHelp,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.of(context).muted,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final r in ThemeColorRole.values)
                                      ChoiceChip(
                                        label: LocalizedText(_roleNames[r]!),
                                        avatar: CircleAvatar(
                                          backgroundColor: draft[r],
                                          radius: 8,
                                        ),
                                        selected: role == r,
                                        onSelected: busy
                                            ? null
                                            : (_) {
                                                if (role == r) return;
                                                setState(() {
                                                  role = r;
                                                  valid = true;
                                                });
                                              },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );

              final preview = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Theme(
                    data: FideflowTheme.build(draft),
                    child: const _ThemePreview(),
                  ),
                  if (contrastRatio(
                            draft[ThemeColorRole.text],
                            draft[ThemeColorRole.background],
                          ) <
                          4.5 ||
                      contrastRatio(
                            draft[ThemeColorRole.text],
                            draft[ThemeColorRole.panel],
                          ) <
                          4.5 ||
                      contrastRatio(
                            draft[ThemeColorRole.muted],
                            draft[ThemeColorRole.background],
                          ) <
                          4.5 ||
                      contrastRatio(
                            draft[ThemeColorRole.muted],
                            draft[ThemeColorRole.panel],
                          ) <
                          4.5)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LocalizedText(
                        UiMessages
                            .textAndBackgroundContrastIsLowConsiderAdjusting,
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: LocalizedText(
                        error!,
                        key: const ValueKey('theme-editor-error'),
                      ),
                    ),
                ],
              );

              return SingleChildScrollView(
                child: isWide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: controls),
                          const SizedBox(width: 16),
                          Expanded(flex: 4, child: preview),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          controls,
                          const SizedBox(height: 16),
                          preview,
                        ],
                      ),
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const LocalizedText(UiMessages.cancel),
        ),
        FilledButton(
          onPressed: busy || !valid ? null : save,
          child: LocalizedText(
            busy ? UiMessages.saving : UiMessages.saveAndApply,
          ),
        ),
      ],
    ),
  );
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview();
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: c.background,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LocalizedText(
              UiMessages.livePreview,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LocalizedText(
                      UiMessages.cardAndBodyText,
                      style: TextStyle(color: c.text),
                    ),
                    LocalizedText(
                      UiMessages.secondaryTextAndDescriptions,
                      style: TextStyle(color: c.muted),
                    ),
                    const Divider(),
                    TextField(
                      decoration: InputDecoration(
                        hintText: localizeOptionalUiText(
                          context,
                          UiMessages.textFieldPreview,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () {},
                  child: const LocalizedText(UiMessages.primaryButton),
                ),
                OutlinedButton(
                  onPressed: () {},
                  child: const LocalizedText(UiMessages.secondaryButton),
                ),
                const FilledButton(
                  onPressed: null,
                  child: LocalizedText(UiMessages.disabled),
                ),
              ],
            ),
            ListTile(
              selected: true,
              leading: const Icon(Icons.music_note),
              title: const LocalizedText(UiMessages.selectedListItem),
            ),
            Wrap(
              spacing: 16,
              children: [
                LocalizedText(
                  UiMessages.success,
                  style: TextStyle(color: c.success),
                ),
                LocalizedText(
                  UiMessages.warning,
                  style: TextStyle(color: c.warning),
                ),
                LocalizedText(
                  UiMessages.error,
                  style: TextStyle(color: c.error),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ColorTuner extends StatefulWidget {
  const ColorTuner({
    required this.color,
    required this.onChanged,
    this.onValidityChanged,
    super.key,
  });
  final Color color;
  final ValueChanged<Color> onChanged;
  final ValueChanged<bool>? onValidityChanged;
  @override
  State<ColorTuner> createState() => _ColorTunerState();
}

class _ColorTunerState extends State<ColorTuner> {
  late HSVColor hsv = HSVColor.fromColor(widget.color);
  late final TextEditingController hex = TextEditingController(
    text: colorHex(widget.color),
  );
  String? error;
  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ColorTuner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color &&
        hsv.toColor().toARGB32() != widget.color.toARGB32()) {
      hsv = HSVColor.fromColor(widget.color);
      hex.text = colorHex(widget.color);
      error = null;
    }
  }

  void change(HSVColor value) {
    setState(() {
      hsv = value;
      hex.text = colorHex(value.toColor());
      error = null;
    });
    widget.onValidityChanged?.call(true);
    widget.onChanged(value.toColor());
  }

  void position(Offset point, Size size) => change(
    hsv
        .withSaturation((point.dx / size.width).clamp(0, 1))
        .withValue((1 - point.dy / size.height).clamp(0, 1)),
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, 150);
          return Semantics(
            label: localizeOptionalUiText(
              context,
              UiMessages.saturationAndBrightnessColorPanel,
            ),
            child: GestureDetector(
              onPanDown: (d) => position(d.localPosition, size),
              onPanUpdate: (d) => position(d.localPosition, size),
              child: SizedBox(
                height: size.height,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white,
                              HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: (hsv.saturation * size.width - 6).clamp(
                        0,
                        size.width - 12,
                      ),
                      top: ((1 - hsv.value) * size.height - 6).clamp(
                        0,
                        size.height - 12,
                      ),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: readableOn(hsv.toColor()),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      Row(
        children: [
          const LocalizedText(UiMessages.hue),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(
                        colors: [
                          for (final hue in [
                            0.0,
                            60.0,
                            120.0,
                            180.0,
                            240.0,
                            300.0,
                            360.0,
                          ])
                            HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                        ],
                      ),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                  ),
                  child: Slider(
                    value: hsv.hue,
                    min: 0,
                    max: 360,
                    label: localizeOptionalUiText(
                      context,
                      UiMessages.hue2((hsv.hue.round()).toString()),
                    ),
                    semanticFormatterCallback: (v) => localizeUiText(
                      context,
                      UiMessages.hueDegrees((v.round()).toString()),
                    ),
                    onChanged: (v) => change(hsv.withHue(v)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextField(
        controller: hex,
        decoration: InputDecoration(
          labelText: localizeOptionalUiText(context, UiMessages.hexColor),
          errorText: localizeOptionalUiText(context, error),
          prefixIcon: Padding(
            padding: const EdgeInsets.all(12),
            child: ColoredBox(color: widget.color),
          ),
        ),
        onChanged: (text) {
          try {
            final c = parseThemeColor(text);
            setState(() {
              hsv = HSVColor.fromColor(c);
              error = null;
            });
            widget.onValidityChanged?.call(true);
            widget.onChanged(c);
          } on FormatException catch (e) {
            setState(() => error = e.message);
            widget.onValidityChanged?.call(false);
          }
        },
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in const [
            Color(0xff6750a4),
            Color(0xffbd93f9),
            Color(0xff268bd2),
            Color(0xff88c0d0),
            Color(0xffe06c75),
            Color(0xffe5c07b),
            Color(0xff98c379),
          ])
            Semantics(
              label: localizeOptionalUiText(context, colorHex(c)),
              button: true,
              child: InkWell(
                onTap: () => change(HSVColor.fromColor(c)),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.of(context).border),
                  ),
                ),
              ),
            ),
        ],
      ),
    ],
  );
}
