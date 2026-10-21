import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';

final class PlaybackEffectsSection extends StatefulWidget {
  const PlaybackEffectsSection({
    required this.effects,
    this.controller,
    super.key,
  });
  final PlaybackEffects effects;
  final BrowseAndPlayController? controller;
  @override
  State<PlaybackEffectsSection> createState() => _PlaybackEffectsSectionState();
}

final class _PlaybackEffectsSectionState extends State<PlaybackEffectsSection> {
  bool _busy = false;
  Future<void> _apply({bool? fade, bool? normalization}) async {
    if (_busy || widget.controller == null) return;
    setState(() => _busy = true);
    try {
      final current = widget.controller!.current.playback.playbackEffects;
      final result = await widget.controller!.configurePlaybackEffects(
        fadeEnabled: fade ?? current.fadeEnabled,
        volumeNormalizationEnabled:
            normalization ?? current.volumeNormalizationEnabled,
      );
      if (!result.isAccepted) throw StateError('effects rejected');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(
              UiMessages.couldNotSavePlaybackEffectsPleaseTryAgain,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        widget.effects.supported && widget.controller != null && !_busy;
    return Material(
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: LocalizedText(
                UiMessages.fadeInAndOut,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.of(context).text,
                ),
              ),
              subtitle: LocalizedText(
                UiMessages.useA300MsVolumeTransitionWhenPlaying,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.of(context).muted,
                ),
              ),
              value: widget.effects.fadeEnabled,
              onChanged: enabled ? (value) => _apply(fade: value) : null,
            ),
            Divider(color: AppColors.of(context).border, height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: LocalizedText(
                UiMessages.normalizeTrackVolume,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.of(context).text,
                ),
              ),
              subtitle: LocalizedText(
                UiMessages.useTheTrackSGainDataToBalance,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.of(context).muted,
                ),
              ),
              value: widget.effects.volumeNormalizationEnabled,
              onChanged: enabled
                  ? (value) => _apply(normalization: value)
                  : null,
            ),
            if (!widget.effects.supported)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: LocalizedText(
                  UiMessages.playbackEffectsAreUnavailableInThisVersion,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.of(context).muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
