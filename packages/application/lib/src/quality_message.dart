import 'package:fideflow_domain/domain.dart';

/// The words a domain [AudioQuality] maps to.
///
/// The same rule as `playback_message.dart`: the UI renders words from this
/// mapping and never a provider's own level string, so the upstream names
/// (`higher`, `exhigh`, `hires`, …) stay inside the gateway where
/// they are mapped into the domain enum, and the persisted file keeps the stable
/// English identifiers rather than these labels.
///
/// Returns a stable resource reference rather than translated display text.
String qualityLabel(AudioQuality quality) => switch (quality) {
  AudioQuality.standard => UiMessages.standardQuality,
  AudioQuality.high => UiMessages.highQualityHq,
  AudioQuality.lossless => UiMessages.losslessQualitySq,
  AudioQuality.hiRes => UiMessages.highResolutionLosslessHiRes2,
};

/// One line about what picking [quality] asks for, and what it cannot promise.
///
/// The promise is deliberately weak, because the service has the last word: the
/// entitlement of the signed-in account, the track's own ceiling and what the
/// provider happens to serve at that moment all decide what is really opened.
/// Each tier therefore says what it prefers and where it falls back to, and each
/// one ends at 无损 before going lower.
String qualityDescription(AudioQuality quality) => switch (quality) {
  AudioQuality.standard =>
    UiMessages.usesLessDataAndPrefersStandardQualityReducing,
  AudioQuality.high => UiMessages.prefersHighQualityFallingBackToLowerAnd,
  AudioQuality.lossless =>
    UiMessages.prefersLosslessQualityFallingBackToHighLower,
  AudioQuality.hiRes =>
    UiMessages.prefersHighResolutionLosslessFallingBackToLossless,
};

/// The disclaimer the settings page shows under the four choices.
const String qualityFallbackNote =
    UiMessages.yourChoiceRequestsAPreferredQualityButDoes;
