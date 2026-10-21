import 'dart:async';
import 'dart:io';

import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/macos_player_controls.dart';
import '../../app/shortcut_config.dart';
import '../../l10n/ui_text.dart';

final class PlayerControlsScope extends InheritedWidget {
  const PlayerControlsScope({
    required this.controls,
    required super.child,
    super.key,
  });
  final PlayerControls controls;
  static PlayerControls? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PlayerControlsScope>()
      ?.controls;
  @override
  bool updateShouldNotify(PlayerControlsScope oldWidget) =>
      oldWidget.controls != controls;
}

/// Registered above the Navigator so modal routes and the full player share
/// the same bindings. EditableText gets its native editing shortcuts first.
final class PlayerKeyboardListener extends StatefulWidget {
  const PlayerKeyboardListener({
    required this.controls,
    required this.child,
    super.key,
  });
  final PlayerControls controls;
  final Widget child;
  @override
  State<PlayerKeyboardListener> createState() => _PlayerKeyboardListenerState();
}

final class _PlayerKeyboardListenerState extends State<PlayerKeyboardListener> {
  KeyEventResult _handle(KeyEvent event) {
    if (widget.controls.recording || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null &&
        (context.widget is EditableText ||
            context.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    final binding = ShortcutBinding.fromEvent(event);
    if (binding == null) return KeyEventResult.ignored;
    for (final action in PlayerAction.values) {
      if (widget.controls.config.local[action]?.identity != binding.identity) {
        continue;
      }
      if (event is! KeyRepeatEvent ||
          action == PlayerAction.volumeUp ||
          action == PlayerAction.volumeDown) {
        unawaited(widget.controls.dispatch(action.name, null));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handle);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class ShortcutSettingsSection extends StatelessWidget {
  const ShortcutSettingsSection({required this.controls, super.key});
  final PlayerControls controls;

  List<String> _shortcutTokens(ShortcutBinding binding) => [
    if (binding.control)
      (Platform.isWindows || Platform.isLinux) ? 'Ctrl' : '⌃',
    if (binding.alt) (Platform.isWindows || Platform.isLinux) ? 'Alt' : '⌥',
    if (binding.shift) (Platform.isWindows || Platform.isLinux) ? 'Shift' : '⇧',
    if (binding.meta)
      Platform.isWindows
          ? 'Win'
          : Platform.isLinux
          ? 'Super'
          : '⌘',
    supportedShortcutKeys[binding.key] ?? '?',
  ];

  Widget _buildKeycap(BuildContext context, String token) {
    final isModifier = [
      '⌘',
      '⌥',
      '⇧',
      '⌃',
      'Ctrl',
      'Alt',
      'Shift',
      'Win',
      'Super',
    ].contains(token);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isModifier ? 7 : 8,
        vertical: 3.5,
      ),
      decoration: BoxDecoration(
        color: AppColors.of(context).selected,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.of(context).border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            offset: Offset(0, 1.5),
            blurRadius: 1,
          ),
        ],
      ),
      child: LocalizedText(
        token,
        style: TextStyle(
          fontSize: isModifier ? 13 : 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.of(context).text,
          fontFamily: isModifier ? null : 'monospace',
        ),
      ),
    );
  }

  Widget _buildEmptyKeycap(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.of(context).border, width: 1),
      ),
      child: LocalizedText(
        UiMessages.notSet,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: AppColors.of(context).muted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controls,
    builder: (context, _) => Material(
      color: AppColors.of(context).panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.of(context).border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 580;
                Widget button(PlayerAction a, bool global) {
                  final binding = (global
                      ? controls.config.global
                      : controls.config.local)[a];
                  final tokens = binding != null
                      ? _shortcutTokens(binding)
                      : const <String>[];
                  return OutlinedButton(
                    key: ValueKey(
                      'shortcut-${global ? 'global' : 'local'}-${a.name}',
                    ),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.of(context).panel,
                      foregroundColor: AppColors.of(context).text,
                      side: BorderSide(color: AppColors.of(context).border),

                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => _record(context, a, global),
                    child: tokens.isEmpty
                        ? _buildEmptyKeycap(context)
                        : Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (final t in tokens) _buildKeycap(context, t),
                            ],
                          ),
                  );
                }

                return Column(
                  children: [
                    if (!narrow)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.of(context).background,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppColors.of(context).border,
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: LocalizedText(
                                UiMessages.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.of(context).muted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: LocalizedText(
                                UiMessages.shortcuts,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.of(context).muted,
                                ),
                              ),
                            ),
                            SizedBox(width: 16),
                            Expanded(
                              child: LocalizedText(
                                UiMessages.globalShortcuts,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.of(context).muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    for (final a in PlayerAction.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: narrow
                            ? Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.of(context).background,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: AppColors.of(context).border,
                                    width: 0.8,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    LocalizedText(
                                      a.label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.of(context).text,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              LocalizedText(
                                                UiMessages.shortcuts,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.of(
                                                    context,
                                                  ).muted,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              button(a, false),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              LocalizedText(
                                                UiMessages.globalShortcuts,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.of(
                                                    context,
                                                  ).muted,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              button(a, true),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: LocalizedText(
                                        a.label,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.of(context).text,
                                        ),
                                      ),
                                    ),
                                    Expanded(child: button(a, false)),
                                    const SizedBox(width: 16),
                                    Expanded(child: button(a, true)),
                                  ],
                                ),
                              ),
                      ),
                  ],
                );
              },
            ),
            Divider(color: AppColors.of(context).border, height: 28),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: LocalizedText(
                UiMessages.enableGlobalShortcuts,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.of(context).text,
                ),
              ),
              subtitle: LocalizedText(
                UiMessages.respondEvenWhenTheAppIsInThe,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.of(context).muted,
                ),
              ),
              value: controls.config.globalEnabled,
              onChanged: controls.available
                  ? (v) => controls.update(
                      (config) => config.copyWith(globalEnabled: v),
                    )
                  : null,
            ),
            Divider(color: AppColors.of(context).border, height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: LocalizedText(
                UiMessages.useSystemMediaShortcuts,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.of(context).text,
                ),
              ),
              subtitle: LocalizedText(
                UiMessages.mediaKeysAndControlCenterPlayPauseSkip,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.of(context).muted,
                ),
              ),
              value: controls.config.mediaEnabled,
              onChanged: controls.available
                  ? (v) => controls.update(
                      (config) => config.copyWith(mediaEnabled: v),
                    )
                  : null,
            ),
            if (!controls.available)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: LocalizedText(
                  UiMessages.globalShortcutsAndSystemMediaControlsAreAvailable,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.of(context).muted,
                  ),
                ),
              ),
            if (controls.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LocalizedText(
                  controls.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.of(context).muted,
                  side: BorderSide(color: AppColors.of(context).border),
                ),
                onPressed: () => controls.update(
                  (_) => ShortcutConfig.defaults(
                    windows: Platform.isWindows,
                    linux: Platform.isLinux,
                  ),
                ),
                icon: const Icon(Icons.restore_rounded, size: 15),
                label: const LocalizedText(UiMessages.restoreDefaults),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _record(
    BuildContext context,
    PlayerAction action,
    bool global,
  ) async {
    await controls.setRecording(true);
    if (!context.mounted) {
      await controls.setRecording(false);
      return;
    }
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => _ShortcutRecorder(
          controls: controls,
          action: action,
          global: global,
        ),
      );
    } finally {
      await controls.setRecording(false);
    }
  }
}

final class _ShortcutRecorder extends StatefulWidget {
  const _ShortcutRecorder({
    required this.controls,
    required this.action,
    required this.global,
  });
  final PlayerControls controls;
  final PlayerAction action;
  final bool global;
  @override
  State<_ShortcutRecorder> createState() => _ShortcutRecorderState();
}

final class _ShortcutRecorderState extends State<_ShortcutRecorder> {
  String? error;
  bool saving = false;
  Future<void> _save(ShortcutBinding? binding) async {
    if (saving) return;
    setState(() => saving = true);
    final ok = await widget.controls.update((config) {
      final values = Map<PlayerAction, ShortcutBinding?>.of(
        widget.global ? config.global : config.local,
      )..[widget.action] = binding;
      return widget.global
          ? config.copyWith(global: values)
          : config.copyWith(local: values);
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        saving = false;
        error = widget.controls.error;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_recordKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_recordKey);
    super.dispose();
  }

  KeyEventResult _recordKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!saving) Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final b = ShortcutBinding.fromEvent(event);
    if (b == null) {
      if ((event.physicalKey.usbHidUsage & 0xffff) < 224) {
        setState(
          () => error =
              UiMessages.unsupportedKeyUseLettersNumbersArrowsOrFunction,
        );
      }
    } else {
      unawaited(_save(b));
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    child: AlertDialog(
      backgroundColor: AppColors.of(context).panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.of(context).border),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.of(context).panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).border),
            ),
            child: Icon(
              Icons.keyboard_alt_outlined,
              size: 18,
              color: AppColors.of(context).accentForeground,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LocalizedText(
              UiMessages.composedText3(
                (widget.action.label).toString(),
                (widget.global
                        ? UiMessages.globalShortcuts
                        : UiMessages.shortcuts)
                    .toString(),
              ),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.of(context).text,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.of(context).background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.of(context).panel),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: saving
                            ? AppColors.of(context).warning
                            : AppColors.of(context).accent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (saving
                                        ? AppColors.of(context).warning
                                        : AppColors.of(context).accent)
                                    .withValues(alpha: 0.5),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    LocalizedText(
                      saving
                          ? UiMessages.saving2
                          : UiMessages.listeningForKeyInput,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.of(context).text,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LocalizedText(
                  UiMessages.pressANewKeyCombinationPressEscTo,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.of(context).muted,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          if (error != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.of(context).error.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.of(context).error),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: AppColors.of(context).error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LocalizedText(
                      error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.of(context).error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.of(context).error,
          ),
          onPressed: saving ? null : () => _save(null),
          child: const LocalizedText(UiMessages.clearBinding),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.of(context).muted,
          ),
          onPressed: saving ? null : () => Navigator.of(context).pop(),
          child: const LocalizedText(UiMessages.cancel),
        ),
      ],
    ),
  );
}
