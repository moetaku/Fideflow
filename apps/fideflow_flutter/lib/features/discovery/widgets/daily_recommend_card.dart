import 'dart:async';
import 'dart:math';

import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/ui_text.dart';
import '../../../shared/artwork.dart';
import '../../../shared/artwork_color_extractor.dart';

/// Presentation layout mode for [DailyRecommendCard].
enum DailyRecommendCardLayout {
  /// Vertical layout (Form A): Unified cover capsule with bottom gradient text frame.
  vertical,

  /// Horizontal banner layout (Form B, when both cards fit side by side):
  /// Adaptive color background, left info badge + text, right feathered cover.
  horizontal,
}

/// Top featured card for "每日推荐" (Daily Recommendation).
///
/// Automatically supports Form A (unified vertical capsule card)
/// and Form B (horizontal widescreen banner with feathered cover).
final class DailyRecommendCard extends StatefulWidget {
  const DailyRecommendCard({
    required this.onTap,
    required this.onPlay,
    this.artworkUri,
    this.firstSongTitle,
    this.layout = DailyRecommendCardLayout.vertical,
    super.key,
  });

  final VoidCallback onTap;
  final VoidCallback onPlay;
  final Uri? artworkUri;
  final String? firstSongTitle;
  final DailyRecommendCardLayout layout;

  @override
  State<DailyRecommendCard> createState() => _DailyRecommendCardState();
}

class _DailyRecommendCardState extends State<DailyRecommendCard> {
  bool _isHovered = false;
  Color? _extractedColor;
  int _colorRequest = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _extractColor();
  }

  @override
  void didUpdateWidget(covariant DailyRecommendCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUri != widget.artworkUri ||
        oldWidget.layout != widget.layout) {
      _extractColor();
    }
  }

  void _extractColor() {
    final request = ++_colorRequest;
    _extractedColor = null;
    final uri = widget.artworkUri;
    if (uri == null) return;
    final provider = ArtworkColorExtractor.providerFor(context, uri);
    unawaited(
      ArtworkColorExtractor.extractColor(
        provider,
        horizontal: widget.layout == DailyRecommendCardLayout.horizontal,
      ).then((color) {
        if (mounted && request == _colorRequest && _extractedColor != color) {
          setState(() => _extractedColor = color);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final now = DateTime.now();
    final dayStr = now.day.toString().padLeft(2, '0');
    final copy = Localizations.of<AppLocalizations>(context, AppLocalizations);
    final monthStr = copy?.localeName.startsWith('en') == true
        ? DateFormat.MMM(copy!.localeName).format(now)
        : UiMessages.month(now.month.toString());

    final subtitle =
        widget.firstSongTitle != null &&
            widget.firstSongTitle!.trim().isNotEmpty
        ? UiMessages.dailyStartWithSong(widget.firstSongTitle!)
        : UiMessages.dailyTasteSubtitle;

    final fallbackColor = Color.alphaBlend(
      colors.accent.withValues(alpha: 0.16),
      colors.panel,
    );
    final cardColor = _extractedColor ?? fallbackColor;
    final hasExtractedColor = _extractedColor != null;

    if (widget.layout == DailyRecommendCardLayout.horizontal) {
      return _buildHorizontalBanner(
        context,
        colors,
        monthStr,
        dayStr,
        subtitle,
        cardColor,
        hasExtractedColor,
      );
    } else {
      return _buildVerticalCard(
        context,
        colors,
        monthStr,
        dayStr,
        subtitle,
        cardColor,
        hasExtractedColor,
      );
    }
  }

  /// Form A: Unified vertical card with cover at top, smooth bottom gradient to text
  Widget _buildVerticalCard(
    BuildContext context,
    AppColors colors,
    String monthStr,
    String dayStr,
    String subtitle,
    Color cardColor,
    bool hasExtractedColor,
  ) {
    final titleColor = hasExtractedColor ? AppColors.overlayText : colors.text;
    final subtitleColor = hasExtractedColor
        ? AppColors.overlayText.withValues(alpha: 0.82)
        : colors.muted;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AspectRatio(
        aspectRatio: 0.76,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: colors.background.withValues(
                  alpha: _isHovered ? 0.35 : 0.20,
                ),
                blurRadius: _isHovered ? 16 : 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isHovered
                  ? colors.accent
                  : colors.border.withValues(alpha: 0.6),
              width: _isHovered ? 1.5 : 1.0,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. Artwork cover on the top portion
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    bottom: 64,
                    child: widget.artworkUri != null
                        ? Artwork(
                            index: 0,
                            size: 400,
                            radius: 0,
                            artworkUri: widget.artworkUri,
                          )
                        : Container(
                            color: cardColor,
                            child: Center(
                              child: Icon(
                                Icons.queue_music_rounded,
                                size: 54,
                                color: colors.accentForeground.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                          ),
                  ),

                  // 2. Smooth vertical gradient transitioning into cardColor
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.40, 0.72, 1.0],
                          colors: [
                            Colors.transparent,
                            Colors.transparent,
                            cardColor.withValues(alpha: 0.85),
                            cardColor,
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 3. Bottom text and white play triangle
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              LocalizedText(
                                UiMessages.dailyRecommendations,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: titleColor,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              LocalizedText(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: subtitleColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Play triangle button
                        Material(
                          color: Colors.transparent,
                          child: Semantics(
                            button: true,
                            label: localizeUiText(context, UiMessages.play),
                            child: InkWell(
                              onTap: widget.onPlay,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.accent,
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    size: 26,
                                    color: colors.onAccent,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Form B: Horizontal widescreen card (方案 2: full cover background, left-to-right gradient, no right play button)
  Widget _buildHorizontalBanner(
    BuildContext context,
    AppColors colors,
    String monthStr,
    String dayStr,
    String subtitle,
    Color cardColor,
    bool hasExtractedColor,
  ) {
    const cardHeight = 118.0;
    final titleColor = hasExtractedColor ? AppColors.overlayText : colors.text;
    final subtitleColor = hasExtractedColor
        ? AppColors.overlayText.withValues(alpha: 0.82)
        : colors.muted;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        height: cardHeight,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            if (_isHovered)
              BoxShadow(
                color: colors.accent.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? colors.accent
                : colors.border.withValues(alpha: 0.6),
            width: _isHovered ? 1.5 : 1.0,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Full-width cover artwork background (right-aligned for best focal framing)
                if (widget.artworkUri != null) ...[
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = max(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        return Align(
                          alignment: Alignment.centerRight,
                          child: SizedBox(
                            width: size,
                            height: size,
                            child: Artwork(
                              index: 0,
                              size: size,
                              radius: 0,
                              artworkUri: widget.artworkUri,
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // 2. Left-to-right strong gradient overlay (方案 2)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: const [0.0, 0.42, 0.75, 1.0],
                          colors: [
                            cardColor,
                            cardColor.withValues(alpha: 0.94),
                            cardColor.withValues(alpha: 0.40),
                            cardColor.withValues(alpha: 0.05),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],

                // 3. Left side content: Classic calendar badge and text (no right play button)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      // Left: Classic calendar badge
                      SizedBox(
                        width: 72,
                        height: 82,
                        child: Stack(
                          alignment: Alignment.center,
                          fit: StackFit.expand,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: colors.panel.withValues(alpha: 0.90),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: colors.border.withValues(alpha: 0.7),
                                ),
                              ),
                              child: AnimatedOpacity(
                                opacity: _isHovered ? 0 : 1,
                                duration: const Duration(milliseconds: 140),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colors.accent.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: LocalizedText(
                                        monthStr,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: colors.accentForeground,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    LocalizedText(
                                      dayStr,
                                      style: TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w700,
                                        color: colors.text,
                                        height: 1.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Center(
                              child: IgnorePointer(
                                ignoring: !_isHovered,
                                child: AnimatedOpacity(
                                  opacity: _isHovered ? 1 : 0,
                                  duration: const Duration(milliseconds: 140),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Semantics(
                                      button: true,
                                      label: localizeUiText(
                                        context,
                                        UiMessages.play,
                                      ),
                                      child: InkWell(
                                        onTap: widget.onPlay,
                                        customBorder: const CircleBorder(),
                                        child: Ink(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: colors.accent,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: colors.onAccent.withValues(
                                                alpha: 0.7,
                                              ),
                                              width: 1,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.28,
                                                ),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: Icon(
                                              Icons.play_arrow_rounded,
                                              size: 26,
                                              color: colors.onAccent,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Text Description
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            LocalizedText(
                              UiMessages.dailyRecommendations,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: titleColor,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            LocalizedText(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: subtitleColor,
                              ),
                            ),
                          ],
                        ),
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
}
