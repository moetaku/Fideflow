import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';

/// The volume control: a mute toggle and the session's gain, drawn as a slider.
///
/// The session owns the gain exactly as it owns the position, so the rules are
/// the progress bar's rules: the slider *interpolates* between the snapshots it
/// is handed, a drag is a local gesture that ignores incoming values while the
/// thumb is under the finger, and one [permille] is reported when the gesture
/// ends. Tapping the icon toggles between silence and the level that was heard
/// before it, which is the one piece of local memory this widget keeps - and it
/// keeps it only until the next snapshot says otherwise.
final class VolumeControl extends StatefulWidget {
  const VolumeControl({
    required this.snapshot,
    required this.onVolumeChanged,
    this.isCompact = false,
    super.key,
  });

  final PlaybackSnapshot snapshot;

  /// Called once per finished drag, with the gain as a permille of full scale.
  final ValueChanged<int> onVolumeChanged;

  /// Whether to render a compact popover icon instead of an inline slider.
  final bool isCompact;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

final class _VolumeControlState extends State<VolumeControl> {
  /// The gain under the finger, while it is down. Null when it is not.
  int? _drag;

  /// The last level the session reported as audible, so unmute restores it.
  int _lastAudible = 800;

  /// The level the snapshot reports, corrected for a drag in flight.
  int get _value {
    final value = _drag ?? widget.snapshot.volume;
    return value.clamp(0, 1000);
  }

  bool get _muted => _value == 0;

  void _toggleMute() {
    widget.onVolumeChanged(
      _muted ? (_lastAudible == 0 ? 800 : _lastAudible) : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    if (!_muted) _lastAudible = value;
    final icon = _muted
        ? Icons.volume_off_outlined
        : value < 500
        ? Icons.volume_down_outlined
        : Icons.volume_up_outlined;

    if (widget.isCompact) {
      return MenuAnchor(
        builder: (context, controller, child) {
          return IconButton(
            tooltip: localizeOptionalUiText(context, UiMessages.volume),
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            icon: Icon(icon, size: 20),
          );
        },
        menuChildren: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              width: 56,
              height: 176,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SizedBox(
                          width: 120,
                          child: SliderTheme(
                            data: SliderTheme.of(
                              context,
                            ).copyWith(trackHeight: 3),
                            child: Slider(
                              value: value.toDouble(),
                              max: 1000,
                              onChangeStart: (val) =>
                                  setState(() => _drag = val.round()),
                              onChanged: (val) =>
                                  setState(() => _drag = val.round()),
                              onChangeEnd: (val) {
                                setState(() => _drag = null);
                                widget.onVolumeChanged(val.round());
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: localizeOptionalUiText(
                      context,
                      _muted ? UiMessages.unmute : UiMessages.mute,
                    ),
                    onPressed: _toggleMute,
                    icon: Icon(icon, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: localizeOptionalUiText(
            context,
            _muted ? UiMessages.unmute : UiMessages.mute,
          ),
          onPressed: _toggleMute,
          icon: Icon(icon, size: 20),
        ),
        SizedBox(
          width: 92,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3),
            child: Slider(
              value: value.toDouble(),
              max: 1000,
              onChangeStart: (val) => setState(() => _drag = val.round()),
              onChanged: (val) => setState(() => _drag = val.round()),
              onChangeEnd: (val) {
                setState(() => _drag = null);
                widget.onVolumeChanged(val.round());
              },
            ),
          ),
        ),
      ],
    );
  }
}
