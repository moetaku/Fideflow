import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/ui_text.dart';

enum DesktopCloseBehavior { background, quit, ask }

final class DesktopCloseController extends ChangeNotifier {
  DesktopCloseController({
    this.directory,
    this.windows = false,
    this.linux = false,
    this.write,
  });
  final String? directory;
  final bool windows;
  final bool linux;
  bool get usesSystemTray => windows || linux;
  final Future<void> Function(DesktopCloseBehavior)? write;
  DesktopCloseBehavior behavior = DesktopCloseBehavior.ask;
  bool saving = false;
  Future<String>? _request;
  final _uiReady = Completer<void>();
  Future<String> Function(bool)? prompt;

  void attach(Future<String> Function(bool) callback) {
    prompt = callback;
    if (!_uiReady.isCompleted) _uiReady.complete();
  }

  Future<void> load() async {
    if (directory == null) return;
    try {
      final data = jsonDecode(
        await File('$directory/desktop-close.json').readAsString(),
      );
      if (data is Map && data['version'] == 1) {
        behavior = DesktopCloseBehavior.values.firstWhere(
          (value) => value.name == data['behavior'],
          orElse: () => DesktopCloseBehavior.ask,
        );
      }
    } on FileSystemException {
      /* Missing preferences use ask. */
    } on FormatException {
      /* Damaged preferences use ask. */
    }
  }

  Future<void> setBehavior(DesktopCloseBehavior value) async {
    if (saving) throw StateError('A preference save is already pending');
    saving = true;
    notifyListeners();
    try {
      if (write != null) {
        await write!(value);
      } else if (directory != null) {
        final file = File('$directory/desktop-close.json');
        await file.parent.create(recursive: true);
        final temp = File(
          '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        try {
          await temp.writeAsString(
            jsonEncode({'version': 1, 'behavior': value.name}),
            flush: true,
          );
          await temp.rename(file.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      } else {
        throw StateError('Settings directory unavailable');
      }
      behavior = value;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<String> requestClose(bool canBackground) =>
      _request ??= _decide(canBackground).whenComplete(() => _request = null);

  Future<String> _decide(bool canBackground) async {
    await _uiReady.future;
    if (behavior == DesktopCloseBehavior.quit) return 'quit';
    if (behavior == DesktopCloseBehavior.background && canBackground) {
      return 'background';
    }
    return prompt!(canBackground);
  }
}

class DesktopCloseScope extends InheritedWidget {
  const DesktopCloseScope({
    required this.controller,
    required super.child,
    super.key,
  });
  final DesktopCloseController? controller;
  static DesktopCloseController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DesktopCloseScope>()
      ?.controller;
  @override
  bool updateShouldNotify(DesktopCloseScope oldWidget) =>
      controller != oldWidget.controller;
}

Future<String> showDesktopCloseDialog(
  BuildContext context,
  DesktopCloseController controller,
  bool canBackground,
) async {
  return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _CloseDialog(controller: controller, canBackground: canBackground),
      ) ??
      'cancel';
}

class _CloseDialog extends StatefulWidget {
  const _CloseDialog({required this.controller, required this.canBackground});
  final DesktopCloseController controller;
  final bool canBackground;
  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  bool remember = false;
  bool busy = false;
  String? error;
  Future<void> choose(DesktopCloseBehavior value) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (remember) await widget.controller.setBehavior(value);
      if (mounted) Navigator.pop(context, value.name);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = UiMessages.couldNotSavePleaseTryAgain;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!busy) Navigator.pop(context, 'cancel');
        },
      },
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          title: const LocalizedText(UiMessages.closeMainWindow),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LocalizedText(
                widget.canBackground
                    ? widget.controller.usesSystemTray
                          ? UiMessages.closingTheWindowHidesItInTheSystem
                          : UiMessages
                                .musicKeepsPlayingAfterTheWindowClosesClick
                    : UiMessages.theSystemTrayIsUnavailableQuitFideflowOr,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const LocalizedText(UiMessages.doNotAskAgain),
                value: remember,
                onChanged: busy
                    ? null
                    : (value) => setState(() => remember = value!),
              ),
              if (error != null)
                LocalizedText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context, 'cancel'),
              child: const LocalizedText(UiMessages.cancel),
            ),
            TextButton(
              onPressed: busy || !widget.canBackground
                  ? null
                  : () => choose(DesktopCloseBehavior.background),
              child: const LocalizedText(UiMessages.closeWindow),
            ),
            FilledButton(
              onPressed: busy ? null : () => choose(DesktopCloseBehavior.quit),
              child: const LocalizedText(UiMessages.quitFideflow),
            ),
          ],
        ),
      ),
    ),
  );
}

class DesktopCloseSettings extends StatelessWidget {
  const DesktopCloseSettings({required this.controller, super.key});
  final DesktopCloseController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LocalizedText(
          UiMessages.whenClosingTheMainWindow,
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        RadioGroup<DesktopCloseBehavior>(
          groupValue: controller.behavior,
          onChanged: (value) async {
            if (value == null || controller.saving) return;
            try {
              await controller.setBehavior(value);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: LocalizedText(
                      UiMessages.couldNotSavePleaseTryAgain,
                    ),
                  ),
                );
              }
            }
          },
          child: Column(
            children: [
              for (final value in DesktopCloseBehavior.values)
                RadioListTile<DesktopCloseBehavior>(
                  value: value,
                  enabled: !controller.saving,
                  contentPadding: EdgeInsets.zero,
                  title: LocalizedText(switch (value) {
                    DesktopCloseBehavior.background =>
                      controller.usesSystemTray
                          ? UiMessages.minimizeToSystemTray
                          : UiMessages.closeWindowAndKeepPlaying,
                    DesktopCloseBehavior.quit => UiMessages.quitFideflow,
                    DesktopCloseBehavior.ask => UiMessages.askEveryTime,
                  }),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
