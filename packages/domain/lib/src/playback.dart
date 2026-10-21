import 'ids.dart';
import 'models.dart';

/// The tiers this app can ask a source resolver for.
///
/// Available streaming tiers, resolved through the gateway's fallback chains.
///
/// The names are the persisted ones: `qualityPreferenceName` writes them into
/// `quality-preference.json`, so a value must never be renamed without a
/// migration.
enum AudioQuality { standard, high, lossless, hiRes }

/// How the queue advances when an item ends.
///
/// Ordinary queues offer list loop, repeat one and shuffle. Heart streams offer
/// [sequential] (stop at the tail) and [repeatOne], with manual navigation never
/// wrapping. The media session owns the resulting order.
enum PlaybackMode { listLoop, repeatOne, shuffle, sequential }

enum NetworkPolicy { onlineOnly, preferCache }

final class ResolvedMediaSource {
  const ResolvedMediaSource({
    required this.trackId,
    required this.uri,
    required this.actualQuality,
    required this.expiresAt,
    this.headers = const {},
    this.codec,
    this.bitrateKbps,
    this.sampleRateHz,
    this.resourceId,
    this.normalizationGainDb,
    this.normalizationPeak,
    this.access = SongAccess.unknown,
    this.resourceFree = false,
    this.fullContent,
    this.allowedByteRanges = const [],
    this.totalBytes,
    this.requiredEntitlements = const {},
  });

  final SongAccess access;
  final bool resourceFree;

  /// Null when the provider has not established the representation scope.
  final bool? fullContent;

  /// Explicit half-open scope for a trial representation; empty means unknown.
  final List<MediaByteRange> allowedByteRanges;
  final int? totalBytes;
  final Set<String> requiredEntitlements;
  final TrackId trackId;
  final Uri uri;

  /// Stable representation identity supplied by the provider (e.g. content MD5).
  /// Independent of expiring URLs; used to safely join cached byte ranges.
  final String? resourceId;

  /// Effective song normalization gain in decibels.
  /// For NCM this is the adopted resource's `gain - closedGain`.
  final double? normalizationGainDb;

  /// Provider sample peak; zero or absent means unknown.
  final double? normalizationPeak;

  /// The tier this source really is, or null when it has none to name.
  ///
  /// An online request only adopts a tier it recognises, so this is named for
  /// every source a provider returned; it is null for a source that has no
  /// streaming tier at all — a local file is whatever it is, and reporting the
  /// user's *preference* here would describe a request instead of the audio.
  final AudioQuality? actualQuality;
  final DateTime expiresAt;
  final Map<String, String> headers;
  final String? codec;

  /// The bitrate the provider said it was serving, in kbit/s, when it said.
  ///
  /// A provider's own number for the thing behind [uri], used to describe the
  /// audio honestly; null means "it did not say", never a guess.
  final int? bitrateKbps;

  /// The sample rate the provider said it was serving, in Hz, when it said.
  final int? sampleRateHz;
}

/// The tier a track's own ceiling names, or null when it names none.
///
/// Hi-Res keeps its own tier and an unknown ceiling maps to null.
AudioQuality? toAudioQuality(TrackQuality quality) => switch (quality) {
  TrackQuality.standard => AudioQuality.standard,
  TrackQuality.high => AudioQuality.high,
  TrackQuality.lossless => AudioQuality.lossless,
  TrackQuality.hiRes => AudioQuality.hiRes,
  TrackQuality.unknown => null,
};

/// Classification established by a fresh provider response, never by cache presence.
enum SongAccess { nonVip, vip, unavailable, unknown }

final class AccountEntitlement {
  const AccountEntitlement({
    required this.kind,
    required this.active,
    this.expiresAt,
  });
  final String kind;
  final bool active;
  final DateTime? expiresAt;
  bool validAt(DateTime time) =>
      active && (expiresAt == null || time.isBefore(expiresAt!));
}

final class MediaByteRange {
  const MediaByteRange(this.start, this.end);
  final int start;
  final int end;
}

/// User-selectable target PCM rates in Hz, mirrored by the native control schema.
const resamplingSampleRates = <int>[44100, 48000, 88200, 96000, 176400, 192000];
