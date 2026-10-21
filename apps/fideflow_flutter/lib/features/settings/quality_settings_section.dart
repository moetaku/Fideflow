import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../l10n/ui_text.dart';
import '../../shared/widgets/quality_selector.dart';
import '../../shared/widgets/settings_option_grid.dart';
import 'settings_copy.dart';

TextStyle _captionStyle(BuildContext context) =>
    TextStyle(fontSize: 11, height: 1.5, color: AppColors.of(context).muted);

/// Edits the shared online quality preference. The playback snapshot is used
/// only to prevent overlapping changes while a source switch is in flight.
final class QualitySettingsSection extends StatelessWidget {
  const QualitySettingsSection({
    required this.playback,
    this.controller,
    super.key,
  });

  /// Used to disable choices while the current source is switching.
  final PlaybackSnapshot playback;

  /// The shared preference. Null on a launch without one, which then says so
  /// instead of drawing a choice nothing would remember.
  final QualityController? controller;

  @override
  Widget build(BuildContext context) {
    final quality = controller;
    if (quality == null) {
      return LocalizedText(
        UiMessages.thisVersionHasNoAudioQualityPreferenceStorage,
        style: _captionStyle(context),
      );
    }
    return StreamBuilder<QualityState>(
      stream: quality.states,
      initialData: quality.current,
      builder: (context, snapshot) {
        final state = snapshot.data ?? quality.current;
        // Two layers of "a change is under way": a selection the backend has not
        // answered, and a source swap the session has not settled. Either one
        // disables the options, so a tap can never stack on a change already in
        // flight — and both clear on their own (the second one with the next
        // snapshot), so the choice cannot stay locked.
        final busy = state.applying || (playback.quality?.switching ?? false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusLine(
              icon: Icons.tune_rounded,
              label: UiMessages.selectedPreference,
              value: qualityLabel(state.preference),
            ),
            const SizedBox(height: 20),
            SettingsOptionGrid(
              children: [
                for (final level in AudioQuality.values)
                  _QualityOption(
                    level: level,
                    selected: level == state.preference,
                    canSelectVip: state.canSelectVip,
                    enabled: !busy && qualityIsSelectable(level),
                    busy: busy && level == state.preference,
                    unverified: !qualityIsSelectable(level),
                    onSelected: (value) =>
                        _apply(context, quality, value, state.canSelectVip),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (!state.canSelectVip) ...[
              LocalizedText(
                UiMessages.losslessAndHiResAudioRequireVipMembership,
                style: _captionStyle(context),
              ),
              const SizedBox(height: 6),
            ],
            LocalizedText(qualityFallbackNote, style: _captionStyle(context)),
          ],
        );
      },
    );
  }

  /// Applies the level the user picked and says so when it only partly took.
  ///
  /// The preference is published by the controller itself, so nothing here
  /// decides what is in effect; a switch that could not reopen the current song
  /// comes back as an outcome and is reported with the application layer's words.
  Future<void> _apply(
    BuildContext context,
    QualityController controller,
    AudioQuality level,
    bool canSelectVip,
  ) async {
    if (!canSelectVip && isQualityVip(level)) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: LocalizedText(
              UiMessages.thisAudioQualityRequiresVipMembership,
            ),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final decision = await controller.select(level);
    final code = decision.outcome.errorCode;
    if (code == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: LocalizedText(playbackMessage(code))));
  }
}

/// One of the two statements above the choice.
final class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.of(context).accentForeground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.of(context).panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.of(context).border, width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                LocalizedText(
                  '$label：',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.of(context).muted,
                  ),
                ),
                LocalizedText(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.of(context).text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One tier as a selectable row: what it is called, what it asks for, and
/// whether it can be chosen at all.
final class _QualityOption extends StatelessWidget {
  const _QualityOption({
    required this.level,
    required this.selected,
    required this.canSelectVip,
    required this.enabled,
    required this.busy,
    required this.unverified,
    required this.onSelected,
  });

  final AudioQuality level;
  final bool selected;
  final bool canSelectVip;
  final bool enabled;
  final bool busy;
  final bool unverified;
  final ValueChanged<AudioQuality> onSelected;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isVipTier = isQualityVip(level);
    final isLocked = !canSelectVip && isVipTier;
    final active = selected && enabled && !isLocked;

    return Semantics(
      selected: selected,
      enabled: enabled,
      inMutuallyExclusiveGroup: true,
      button: true,
      label: localizeOptionalUiText(context, qualityMenuTitle(level)),
      child: Material(
        color: active
            ? primary.withValues(alpha: 0.10)
            : AppColors.of(context).panel,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? () => onSelected(level) : null,
          borderRadius: BorderRadius.circular(14),
          hoverColor: AppColors.of(context).text.withValues(alpha: 0.04),
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active
                    ? primary.withValues(alpha: 0.6)
                    : isLocked
                    ? AppColors.of(context).panel
                    : AppColors.of(context).border,
                width: active ? 1.2 : 1.0,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                QualityIconBadge(quality: level, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: LocalizedText(
                              qualityMenuTitle(level),
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: active
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isLocked
                                    ? AppColors.of(context).muted
                                    : (enabled
                                          ? AppColors.of(context).text
                                          : AppColors.of(context).muted),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isVipTier) ...[
                            const SizedBox(width: 6),
                            const QualityVipBadge(),
                          ],
                          if (unverified) ...[
                            const SizedBox(width: 6),
                            _Badge(text: qualityUnverifiedBadge),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      LocalizedText(
                        unverified
                            ? qualityUnverifiedNote
                            : qualityMenuSubtitle(level),
                        style: _captionStyle(context),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (busy)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.of(context).accentForeground,
                    ),
                  )
                else if (isLocked)
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: AppColors.of(context).muted,
                  )
                else if (active)
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: primary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.check_rounded,
                      size: 13,
                      color: AppColors.of(context).onAccent,
                    ),
                  )
                else
                  Icon(
                    Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: enabled
                        ? AppColors.of(context).muted
                        : AppColors.of(context).muted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small "not yet verified" marker.
final class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: AppColors.of(context).warning.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppColors.of(context).warning),
    ),
    child: LocalizedText(
      text,
      style: TextStyle(fontSize: 10, color: AppColors.of(context).warning),
    ),
  );
}
