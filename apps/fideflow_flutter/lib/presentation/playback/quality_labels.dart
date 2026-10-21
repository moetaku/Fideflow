import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';

/// The description of the audio that is really playing, in the user's words.
///
/// It is built from the host's own record of the source it handed the session
/// ([PlaybackQuality]), never from the level that was asked for, and it refuses to
/// name a level nothing confirmed: an unconfirmed source reads as unknown, which
/// is the honest answer while a song is still being opened. The bitrate and sample
/// rate are what the provider said it was serving, so they appear only when it
/// said.
///
/// A replacement on its way is said out loud, in both shapes it can take: while
/// nothing is confirmed yet there is no level to keep showing, and while the old
/// source is still confirmed the line names it and adds that it is changing. A
/// page that showed only the new level, or only the old one with no hint, would
/// leave the user unable to tell which of the two they are hearing.
String qualityInEffectLabel(PlaybackQuality? quality) {
  if (quality == null) return UiMessages.unknownAudioQuality;
  final switching = quality.switching;
  final level = quality.level;
  if (!quality.confirmed) {
    return switching
        ? UiMessages.switchingAudioQuality
        : UiMessages.unknownAudioQuality;
  }
  if (level == null) {
    // Confirmed, but the source named no tier this app knows: say so instead of
    // substituting the level the user asked for.
    return switching
        ? UiMessages.currentAudioQualityUnknownSwitching
        : UiMessages.unknownAudioQuality;
  }
  final details = <String>[
    if (quality.bitrateKbps case final kbps? when kbps > 0) '$kbps kbps',
    if (quality.sampleRateHz case final hz? when hz > 0) _sampleRate(hz),
    if (quality.codec case final codec? when codec.isNotEmpty)
      codec.toUpperCase(),
  ];
  final label = qualityLabel(level);
  final head =
      '$label${details.isEmpty ? '' : '  ·  ${details.join('  ·  ')}'}';
  return switching
      ? UiMessages.stillPlayingAtSwitching((head).toString())
      : head;
}

/// Details can preview a tier before the session confirms the playing source.
/// Keep this estimate in the UI; it must never become decoder confirmation.
String qualityDetailsLabel({
  required Track track,
  required PlaybackQuality? quality,
  AudioQuality? preference,
}) {
  if (quality?.switching == true ||
      (quality?.confirmed == true && quality?.level == null)) {
    return qualityInEffectLabel(quality);
  }
  if (quality?.level != null) {
    final source = quality!;
    final tier = switch (source.level!) {
      AudioQuality.standard => TrackQuality.standard,
      AudioQuality.high => TrackQuality.high,
      AudioQuality.lossless => TrackQuality.lossless,
      AudioQuality.hiRes => TrackQuality.hiRes,
    };
    final specs = track.audioSpecs.where((s) => s.quality == tier).firstOrNull;
    return qualityInEffectLabel(
      PlaybackQuality(
        level: source.level,
        bitrateKbps: (source.bitrateKbps ?? 0) > 0
            ? source.bitrateKbps
            : specs?.bitrateKbps,
        sampleRateHz: (source.sampleRateHz ?? 0) > 0
            ? source.sampleRateHz
            : specs?.sampleRateHz,
        codec: source.codec,
        confirmed: true,
      ),
    );
  }
  final metadata =
      track.objectiveQuality != null &&
          track.objectiveQuality != TrackQuality.unknown
      ? track.objectiveQuality!
      : track.maxPotentialQuality;
  final ceiling = switch (metadata) {
    TrackQuality.standard => AudioQuality.standard,
    TrackQuality.high => AudioQuality.high,
    TrackQuality.lossless => AudioQuality.lossless,
    TrackQuality.hiRes => AudioQuality.hiRes,
    TrackQuality.unknown => null,
  };
  if (ceiling == null) return UiMessages.unknownAudioQuality;
  final estimate = preference != null && preference.index < ceiling.index
      ? preference
      : ceiling;
  final metadataTier = switch (estimate) {
    AudioQuality.standard => TrackQuality.standard,
    AudioQuality.high => TrackQuality.high,
    AudioQuality.lossless => TrackQuality.lossless,
    AudioQuality.hiRes => TrackQuality.hiRes,
  };
  final specs = track.audioSpecs
      .where((s) => s.quality == metadataTier)
      .firstOrNull;
  return qualityInEffectLabel(
    PlaybackQuality(
      level: estimate,
      bitrateKbps: specs?.bitrateKbps,
      sampleRateHz: specs?.sampleRateHz,
      confirmed: true,
    ),
  );
}

/// The same displayed tier drives the badge and the popup checkmark.
AudioQuality? qualityDisplayLevel(
  Track? track,
  PlaybackQuality? quality,
  AudioQuality preference,
) {
  if (quality?.level != null) return quality!.level;
  if (quality?.confirmed == true || track == null) return null;
  final metadata =
      track.objectiveQuality != null &&
          track.objectiveQuality != TrackQuality.unknown
      ? track.objectiveQuality!
      : track.maxPotentialQuality;
  final ceiling = switch (metadata) {
    TrackQuality.standard => AudioQuality.standard,
    TrackQuality.high => AudioQuality.high,
    TrackQuality.lossless => AudioQuality.lossless,
    TrackQuality.hiRes => AudioQuality.hiRes,
    TrackQuality.unknown => null,
  };
  if (ceiling == null) return null;
  return preference.index < ceiling.index ? preference : ceiling;
}

/// A sample rate in kHz, with a decimal only when it needs one.
String _sampleRate(int hz) {
  final khz = hz / 1000;
  final text = khz == khz.roundToDouble()
      ? khz.round().toString()
      : khz.toStringAsFixed(1);
  return '$text kHz';
}
