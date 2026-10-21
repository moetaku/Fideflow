import 'dart:async';
import 'dart:math';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:flutter/material.dart';

import '../../../l10n/ui_text.dart';
import '../../../shared/artwork.dart';
import '../../../shared/artwork_color_extractor.dart';

/// Presentation layout mode for [HeartbeatRecommendCard].
enum HeartbeatRecommendCardLayout {
  /// Vertical layout (Form A): Unified cover capsule with bottom gradient text frame.
  vertical,

  /// Horizontal banner layout (Form B, when both cards fit side by side):
  /// Adaptive color background, left info badge + text, right feathered cover.
  horizontal,
}

/// Featured card for "心动模式" (Heartbeat Mode) on the Recommend page.
///
/// Automatically supports Form A (unified vertical capsule card)
/// and Form B (horizontal widescreen banner with feathered cover).
final class HeartbeatRecommendCard extends StatefulWidget {
  const HeartbeatRecommendCard({
    this.playback,
    this.intelligence,
    this.artworkUri,
    this.layout = HeartbeatRecommendCardLayout.vertical,
    this.onTap,
    super.key,
  });

  final PlaybackSnapshot? playback;
  final IntelligenceModeController? intelligence;
  final Uri? artworkUri;
  final HeartbeatRecommendCardLayout layout;
  final VoidCallback? onTap;

  @override
  State<HeartbeatRecommendCard> createState() => _HeartbeatRecommendCardState();
}

class _HeartbeatRecommendCardState extends State<HeartbeatRecommendCard> {
  bool _isHovered = false;
  Color? _extractedColor;
  int _colorRequest = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _extractColor();
  }

  @override
  void didUpdateWidget(covariant HeartbeatRecommendCard oldWidget) {
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
        horizontal: widget.layout == HeartbeatRecommendCardLayout.horizontal,
      ).then((color) {
        if (mounted && request == _colorRequest && _extractedColor != color) {
          setState(() => _extractedColor = color);
        }
      }),
    );
  }

  void _handleStart() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    if (widget.intelligence != null && !widget.intelligence!.loading) {
      widget.intelligence!.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isIntelligence = widget.playback?.isIntelligenceMode == true;
    final isLoading = widget.intelligence?.loading == true;
    const subtitle = UiMessages.heartbeatExploreSubtitle;

    final fallbackColor = Color.alphaBlend(
      colors.accent.withValues(alpha: isIntelligence ? 0.24 : 0.16),
      colors.panel,
    );
    final cardColor = _extractedColor ?? fallbackColor;
    final hasExtractedColor = _extractedColor != null;

    if (widget.layout == HeartbeatRecommendCardLayout.horizontal) {
      return _buildHorizontalBanner(
        context,
        colors,
        isIntelligence,
        isLoading,
        subtitle,
        cardColor,
        hasExtractedColor,
      );
    } else {
      return _buildVerticalCard(
        context,
        colors,
        isIntelligence,
        isLoading,
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
    bool isIntelligence,
    bool isLoading,
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
                color: isIntelligence
                    ? colors.accent.withValues(alpha: 0.28)
                    : colors.background.withValues(
                        alpha: _isHovered ? 0.35 : 0.20,
                      ),
                blurRadius: _isHovered || isIntelligence ? 16 : 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isIntelligence || _isHovered
                  ? colors.accent
                  : colors.border.withValues(alpha: 0.6),
              width: isIntelligence || _isHovered ? 1.5 : 1.0,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: isLoading ? null : _handleStart,
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
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment.center,
                                radius: 0.85,
                                colors: [
                                  Color.alphaBlend(
                                    colors.accent.withValues(
                                      alpha: isIntelligence ? 0.35 : 0.22,
                                    ),
                                    colors.background,
                                  ),
                                  colors.background,
                                ],
                              ),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.favorite_rounded,
                                size: 48,
                                color: colors.accentForeground.withValues(
                                  alpha: 0.45,
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
                                UiMessages.heartbeatMode,
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
                            label: localizeUiText(
                              context,
                              UiMessages.startHeartbeatMode2,
                            ),
                            child: InkWell(
                              onTap:
                                  (widget.intelligence == null &&
                                          widget.onTap == null) ||
                                      isLoading
                                  ? null
                                  : _handleStart,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.accent,
                                ),
                                child: Center(
                                  child: isLoading
                                      ? SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            color: colors.onAccent,
                                          ),
                                        )
                                      : Icon(
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
    bool isIntelligence,
    bool isLoading,
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
            if (_isHovered || isIntelligence)
              BoxShadow(
                color: colors.accent.withValues(
                  alpha: isIntelligence ? 0.22 : 0.15,
                ),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isIntelligence || _isHovered
                ? colors.accent
                : colors.border.withValues(alpha: 0.6),
            width: isIntelligence || _isHovered ? 1.5 : 1.0,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isLoading ? null : _handleStart,
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

                // 3. Left side content: Classic heartbeat badge and text (no right play button)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      // Left: Classic heartbeat icon badge
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
                                  color: isIntelligence
                                      ? colors.accent.withValues(alpha: 0.6)
                                      : colors.border.withValues(alpha: 0.7),
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
                                        UiMessages.heartbeat,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: colors.accentForeground,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Icon(
                                      Icons.favorite_rounded,
                                      size: 26,
                                      color: colors.accentForeground,
                                      shadows: [
                                        Shadow(
                                          color: colors.accent.withValues(
                                            alpha: isIntelligence ? 0.6 : 0.35,
                                          ),
                                          blurRadius: isIntelligence ? 12 : 6,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Center(
                              child: IgnorePointer(
                                ignoring: !_isHovered || isLoading,
                                child: AnimatedOpacity(
                                  opacity: _isHovered ? 1 : 0,
                                  duration: const Duration(milliseconds: 140),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Semantics(
                                      button: true,
                                      label: localizeUiText(
                                        context,
                                        UiMessages.startHeartbeatMode2,
                                      ),
                                      child: InkWell(
                                        onTap: isLoading ? null : _handleStart,
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
                                            child: isLoading
                                                ? SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color:
                                                              colors.onAccent,
                                                        ),
                                                  )
                                                : Icon(
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
                              UiMessages.heartbeatMode,
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
