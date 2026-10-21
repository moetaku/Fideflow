import 'package:fideflow_domain/domain.dart';

/// Where the user's quality preference is kept.
///
/// One immutable owner per store. The composition root supplies a separate
/// store for each account (including guest), so delayed writes cannot change
/// another account's preference. The audible tier still belongs to playback.
abstract interface class QualityPreferenceStore {
  /// The stored preference, or null when nothing was ever stored.
  ///
  /// A read that fails is also null: an unreadable setting is the default one,
  /// never a launch that cannot play.
  Future<AudioQuality?> read();

  /// Stores [quality] for the next launch.
  Future<void> write(AudioQuality quality);
}

/// A store that keeps the preference in memory only.
///
/// For tests and for the fake backend, where a restart is a new process anyway.
final class InMemoryQualityPreferenceStore implements QualityPreferenceStore {
  InMemoryQualityPreferenceStore([this._value]);

  AudioQuality? _value;

  @override
  Future<AudioQuality?> read() async => _value;

  @override
  Future<void> write(AudioQuality quality) async {
    _value = quality;
  }
}

/// The wire name of a level, so a stored file stays readable by a human.
String qualityPreferenceName(AudioQuality quality) => quality.name;

/// Unknown or retired stored values use lossless SQ.
AudioQuality qualityPreferenceFromName(String? name) {
  for (final quality in AudioQuality.values) {
    if (quality.name == name) return quality;
  }
  return AudioQuality.lossless;
}
