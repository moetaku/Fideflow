import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../l10n/ui_text.dart';
import '../../presentation/playback/quality_labels.dart';
import '../music_scope.dart';

export '../../presentation/playback/quality_labels.dart';

/// Picks the level later songs are resolved at, and says what is playing now.
///
/// The two halves are deliberately different controls and different statements:
/// the choice is the *preference*, which applies to what is started next, and the
/// line above it describes the audio that is really in effect. A song that cannot
/// be reopened on the new source keeps playing the old one, so the page must be
/// able to say "this is what you are hearing" separately from "this is what you
/// chose" — otherwise a failed switch would look like a successful one.
///
/// [busy] covers both halves of "a change is under way": a selection the backend
/// has not answered yet, and a source swap the session has not settled. It comes
/// from one place for both entry points, so the player and the settings page
/// disable alike.
final class QualitySelector extends StatelessWidget {
  const QualitySelector({
    required this.preference,
    required this.quality,
    required this.onSelected,
    this.busy = false,
    this.compact = false,
    super.key,
  });

  /// The level later resolutions ask for (the stored preference).
  final AudioQuality preference;

  /// What is in effect for the song playing, when the backend can say.
  final PlaybackQuality? quality;

  /// Called with the level the user picked. A backend that cannot re-resolve the
  /// current song still remembers the preference.
  final ValueChanged<AudioQuality> onSelected;

  /// Whether a selection is being applied, so the buttons do not stack requests.
  final bool busy;

  /// Draws the labels as a menu rather than as a row of segments, for a narrow
  /// column (the mini bar).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final switching = quality?.switching ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              switching ? Icons.autorenew_rounded : Icons.graphic_eq_rounded,
              size: 14,
              color: AppColors.of(context).accentForeground,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: LocalizedText(
                qualityInEffectLabel(quality),
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.of(context).muted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (compact)
          _Menu(preference: preference, onSelected: onSelected, enabled: !busy)
        else
          _Segments(
            preference: preference,
            onSelected: onSelected,
            enabled: !busy,
          ),
      ],
    );
  }
}

/// Every level as a row of segments.
///
/// Five names are wider than three, so the row scrolls sideways instead of
/// overflowing a narrow player: the choice stays one control, and a window with
/// room shows all four at once.
final class _Segments extends StatelessWidget {
  const _Segments({
    required this.preference,
    required this.onSelected,
    required this.enabled,
  });

  final AudioQuality preference;
  final ValueChanged<AudioQuality> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SegmentedButton<AudioQuality>(
      segments: [
        for (final level in AudioQuality.values)
          ButtonSegment(
            value: level,
            label: LocalizedText(
              qualityLabel(level),
              style: const TextStyle(fontSize: 11),
            ),
          ),
      ],
      selected: {preference},
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelectionChanged: enabled
          ? (selection) => onSelected(selection.first)
          : null,
    ),
  );
}

/// The same choice as a menu, for a width that has no room for the segments.
final class _Menu extends StatelessWidget {
  const _Menu({
    required this.preference,
    required this.onSelected,
    required this.enabled,
  });

  final AudioQuality preference;
  final ValueChanged<AudioQuality> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => PopupMenuButton<AudioQuality>(
    enabled: enabled,
    tooltip: localizeOptionalUiText(context, UiMessages.chooseAudioQuality),
    initialValue: preference,
    onSelected: onSelected,
    itemBuilder: (context) => [
      for (final level in AudioQuality.values)
        PopupMenuItem(value: level, child: LocalizedText(qualityLabel(level))),
    ],
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LocalizedText(
          qualityLabel(preference),
          style: TextStyle(fontSize: 12, color: AppColors.of(context).text),
        ),
        const Icon(Icons.arrow_drop_down_rounded, size: 18),
      ],
    ),
  );
}

/// Circular icon badge representing an audio quality tier.
///
/// This is the popup's badge — the tiers as they are offered. The bar draws
/// [QualityTextBadge] instead, so the tier in effect never looks like one of
/// the choices.
final class QualityIconBadge extends StatelessWidget {
  const QualityIconBadge({
    required this.quality,
    this.size = 32,
    this.backgroundColor,
    this.foregroundColor,
    super.key,
  });

  final AudioQuality quality;
  final double size;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? AppColors.of(context).panel;
    final border = AppColors.of(context).border;
    final fg = foregroundColor ?? AppColors.of(context).text;

    final Widget content = switch (quality) {
      AudioQuality.hiRes => LocalizedText(
        'Hi-Res',
        style: TextStyle(
          fontSize: size * 0.28,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: -0.4,
          height: 1.0,
        ),
      ),
      AudioQuality.lossless => LocalizedText(
        'SQ',
        style: TextStyle(
          fontSize: size * 0.40,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: -0.3,
          height: 1.0,
        ),
      ),
      AudioQuality.high => LocalizedText(
        'HQ',
        style: TextStyle(
          fontSize: size * 0.40,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: -0.3,
          height: 1.0,
        ),
      ),
      AudioQuality.standard => LocalizedText(
        'STD',
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: -0.4,
          height: 1.0,
        ),
      ),
    };

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 1),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: size * 0.08),
          child: content,
        ),
      ),
    );
  }
}

/// The four tiers as the player bar names them, ordered low to high.
///
/// The menu spells each tier out ([qualityMenuTitle]) because it is the place
/// that *chooses*; the bar has one short line to say what is in effect, so it
/// gets the name alone — 标准, 极高, 无损, Hi-Res.
String qualityBadgeLabel(AudioQuality quality) => switch (quality) {
  AudioQuality.standard => UiMessages.standard,
  AudioQuality.high => UiMessages.high,
  AudioQuality.lossless => UiMessages.lossless,
  AudioQuality.hiRes => 'Hi-Res',
};

/// The tier as the player bar draws it: a white outlined box around the tier's
/// name.
///
/// The bar and the popup answer two different questions, so they must not look
/// like one control: the popup's [QualityIconBadge] circles are the tiers on
/// offer, this box is the tier in effect, and the difference has to be visible
/// before either is read. Nothing here is a capability claim — it names only
/// what [QualityMenuButton] already worked out.
final class QualityTextBadge extends StatelessWidget {
  const QualityTextBadge({required this.quality, super.key});

  final AudioQuality quality;

  /// Fixed width and height for the audio quality text badge border so that
  /// all tiers (标准, 极高, 无损, Hi-Res) maintain a consistent size and aspect ratio.
  static const double badgeWidth = 46.0;
  static const double badgeHeight = 20.0;

  @override
  Widget build(BuildContext context) => Container(
    width: badgeWidth,
    height: badgeHeight,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.of(context).text, width: 1.0),
      borderRadius: BorderRadius.circular(4),
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: LocalizedText(
        qualityBadgeLabel(quality),
        maxLines: 1,
        style: TextStyle(
          color: AppColors.of(context).text,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          height: 1.0,
          letterSpacing: 0.2,
        ),
      ),
    ),
  );
}

/// Mini VIP indicator badge with vinyl record icon and text.
final class QualityVipBadge extends StatelessWidget {
  const QualityVipBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
    decoration: BoxDecoration(
      color: AppColors.of(context).warning.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.of(context).warning, width: 0.8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.album_rounded,
          size: 10,
          color: AppColors.of(context).warning,
        ),
        SizedBox(width: 3),
        LocalizedText(
          'VIP',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: AppColors.of(context).warning,
            letterSpacing: 0.5,
            height: 1.0,
          ),
        ),
      ],
    ),
  );
}

/// Display titles for audio quality options in the popup menu.
String qualityMenuTitle(AudioQuality quality) => switch (quality) {
  AudioQuality.hiRes => UiMessages.highResolutionLosslessHiRes,
  AudioQuality.lossless => UiMessages.losslessSq,
  AudioQuality.high => UiMessages.highHq,
  AudioQuality.standard => UiMessages.standard,
};

/// Subtitle specifications and experience descriptions for each quality.
String qualityMenuSubtitle(AudioQuality quality) => switch (quality) {
  AudioQuality.hiRes => UiMessages.fullerClearerHighResolutionAudioUpTo192,
  AudioQuality.lossless => UiMessages.highFidelityLosslessAudioUpTo48Khz,
  AudioQuality.high => UiMessages.nearCdQualityWithDetailedSoundUpTo,
  AudioQuality.standard => '128kbps',
};

/// Whether this audio quality tier requires VIP membership.
bool isQualityVip(AudioQuality quality) =>
    quality == AudioQuality.lossless || quality == AudioQuality.hiRes;

const _menuQualityTiers = [
  AudioQuality.hiRes,
  AudioQuality.lossless,
  AudioQuality.high,
  AudioQuality.standard,
];

/// Tiers supported by [track], ordered from highest to lowest.
List<AudioQuality> supportedQualitiesFor(
  Track? track, [
  PlaybackQuality? quality,
]) {
  if (track == null || track.maxPotentialQuality == TrackQuality.unknown) {
    return _menuQualityTiers;
  }

  final max = track.maxPotentialQuality;
  final supported = <AudioQuality>{AudioQuality.standard};

  switch (max) {
    case TrackQuality.standard:
      break;
    case TrackQuality.high:
      supported.add(AudioQuality.high);
      break;
    case TrackQuality.lossless:
      supported.add(AudioQuality.high);
      supported.add(AudioQuality.lossless);

      break;
    case TrackQuality.hiRes:
      supported.add(AudioQuality.high);
      supported.add(AudioQuality.lossless);
      supported.add(AudioQuality.hiRes);

      break;
    case TrackQuality.unknown:
      return _menuQualityTiers;
  }

  if (quality?.confirmed == true && quality?.level != null) {
    supported.add(quality!.level!);
  }

  return _menuQualityTiers.where(supported.contains).toList();
}

/// A compact entry point for changing quality from the player bar.
final class QualityMenuButton extends StatefulWidget {
  const QualityMenuButton({
    required this.preference,
    required this.quality,
    required this.onSelected,
    this.currentTrack,
    this.busy = false,
    this.isVip = false,
    super.key,
  });

  final AudioQuality preference;
  final PlaybackQuality? quality;
  final Track? currentTrack;
  final ValueChanged<AudioQuality> onSelected;
  final bool busy;
  final bool isVip;

  @override
  State<QualityMenuButton> createState() => _QualityMenuButtonState();
}

final class _QualityMenuButtonState extends State<QualityMenuButton> {
  int _generation = 0;
  Object? _owner;
  AudioQuality get preference => widget.preference;
  PlaybackQuality? get quality => widget.quality;
  Track? get currentTrack => widget.currentTrack;
  ValueChanged<AudioQuality> get onSelected => widget.onSelected;
  bool get busy => widget.busy;
  bool get isVip => widget.isVip;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final music = MusicManagementScope.maybeOf(context);
    final owner = (music, music?.accountKey);
    if (_owner != owner) {
      _owner = owner;
      ++_generation;
    }
  }

  @override
  void didUpdateWidget(QualityMenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTrack?.id != currentTrack?.id ||
        oldWidget.isVip != isVip ||
        oldWidget.preference != preference) {
      ++_generation;
    }
  }

  Future<void> _openMenu(BuildContext context) async {
    final generation = _generation;
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox) return;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;

    final buttonRect = Rect.fromPoints(
      renderBox.localToGlobal(Offset.zero, ancestor: overlay),
      renderBox.localToGlobal(
        renderBox.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );

    final displayedTiers = supportedQualitiesFor(currentTrack, quality);
    final activeQuality = qualityDisplayLevel(
      currentTrack,
      quality,
      preference,
    );

    final selected = await Navigator.of(context).push<AudioQuality>(
      _QualityMenuRoute(
        buttonRect: buttonRect,
        currentTrack: currentTrack,
        quality: quality,
        preference: preference,
        displayedTiers: displayedTiers,
        activeQuality: activeQuality,
        isVip: isVip,
      ),
    );

    if (!mounted || !context.mounted || generation != _generation) return;
    if (selected != null) {
      if (!isVip && isQualityVip(selected)) {
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
      onSelected(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeQuality = qualityDisplayLevel(
      currentTrack,
      quality,
      preference,
    );
    final isBusy = busy || (quality?.switching ?? false);
    const buttonWidth = 62.0;

    return IconButton(
      tooltip: localizeOptionalUiText(context, UiMessages.audioQuality),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: buttonWidth,
        height: 36,
      ),
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(buttonWidth, 36),
        fixedSize: const Size(buttonWidth, 36),
        shape: AppButtonStyle.icon.shape?.resolve({}),
        hoverColor: AppColors.of(context).text.withValues(alpha: 0.08),
        highlightColor: AppColors.of(context).text.withValues(alpha: 0.12),
      ),
      onPressed: isBusy ? null : () => _openMenu(context),
      icon: isBusy
          ? Icon(
              Icons.autorenew_rounded,
              size: 20,
              color: AppColors.of(context).text,
            )
          : activeQuality == null
          ? Icon(
              Icons.graphic_eq_rounded,
              size: 20,
              color: AppColors.of(context).text,
            )
          : QualityTextBadge(quality: activeQuality),
    );
  }
}

final class _QualityMenuRoute extends PopupRoute<AudioQuality> {
  _QualityMenuRoute({
    required this.buttonRect,
    required this.currentTrack,
    required this.quality,
    required this.preference,
    required this.displayedTiers,
    required this.activeQuality,
    required this.isVip,
  });

  final Rect buttonRect;
  final Track? currentTrack;
  final PlaybackQuality? quality;
  final AudioQuality preference;
  final List<AudioQuality> displayedTiers;
  final AudioQuality? activeQuality;
  final bool isVip;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => UiMessages.closeAudioQualitySelection;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    return CustomSingleChildLayout(
      delegate: _QualityMenuLayout(
        buttonRect: buttonRect,
        insets:
            mediaQuery.padding +
            mediaQuery.viewInsets +
            const EdgeInsets.all(8),
      ),
      child: Semantics(
        role: SemanticsRole.menu,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        child: Material(
          color: AppColors.of(context).panel,
          elevation: 10,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: AppColors.of(context).border, width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PopupMenuItem<AudioQuality>(
                  enabled: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  height: 38,
                  child: LocalizedText(
                    currentTrack == null
                        ? qualityInEffectLabel(quality)
                        : qualityDetailsLabel(
                            track: currentTrack!,
                            quality: quality,
                            preference: preference,
                          ),
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).muted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const PopupMenuDivider(height: 1),
                for (final level in displayedTiers)
                  PopupMenuItem<AudioQuality>(
                    value: level,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    height: 56,
                    child: Row(
                      children: [
                        QualityIconBadge(quality: level, size: 34),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: LocalizedText(
                                      qualityMenuTitle(level),
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.of(context).text,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isQualityVip(level)) ...[
                                    const SizedBox(width: 6),
                                    const QualityVipBadge(),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              LocalizedText(
                                qualityMenuSubtitle(level),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.of(context).muted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (level == activeQuality)
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: AppColors.of(context).accent,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.check_rounded,
                              size: 13,
                              color: AppColors.of(context).onAccent,
                            ),
                          )
                        else if (!isVip && isQualityVip(level))
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 15,
                            color: AppColors.of(context).muted,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.0, 0.08),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

final class _QualityMenuLayout extends SingleChildLayoutDelegate {
  const _QualityMenuLayout({required this.buttonRect, required this.insets});

  final Rect buttonRect;
  final EdgeInsets insets;
  static const gap = 10.0;

  Rect _availableRect(Size size) => insets.deflateRect(Offset.zero & size);

  double _spaceAbove(Rect available) =>
      (buttonRect.top - gap - available.top).clamp(0.0, available.height);

  double _spaceBelow(Rect available) =>
      (available.bottom - buttonRect.bottom - gap).clamp(0.0, available.height);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final available = _availableRect(constraints.biggest);
    final above = _spaceAbove(available);
    final below = _spaceBelow(available);
    // Let the scroll view shrink to its content, or scroll within the larger
    // space beside the button when enlarged text no longer fits.
    return BoxConstraints(
      minWidth: available.width.clamp(0.0, 320.0),
      maxWidth: available.width.clamp(0.0, 320.0),
      maxHeight: above > below ? above : below,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final available = _availableRect(size);
    final left = (buttonRect.center.dx - childSize.width / 2).clamp(
      available.left,
      available.right - childSize.width,
    );
    final top = childSize.height <= _spaceAbove(available)
        ? buttonRect.top - gap - childSize.height
        : buttonRect.bottom + gap;
    return Offset(
      left,
      top.clamp(available.top, available.bottom - childSize.height),
    );
  }

  @override
  bool shouldRelayout(_QualityMenuLayout oldDelegate) =>
      buttonRect != oldDelegate.buttonRect || insets != oldDelegate.insets;
}
