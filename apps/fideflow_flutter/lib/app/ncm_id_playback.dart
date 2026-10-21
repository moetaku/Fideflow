import 'dart:async';

import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_media_sdk/media_sdk.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/foundation.dart';

/// What one「网易云 ID 播放」round trip did.
sealed class NcmPlayOutcome {
  const NcmPlayOutcome();
}

/// The input was empty or the dialog was dismissed; nothing worth saying.
final class NcmPlaySilent extends NcmPlayOutcome {
  const NcmPlaySilent();
}

/// The queue was installed and the session has not confirmed audio yet.
///
/// ``Accepted'' is not ``playing'': the song is being resolved, opened and sent
/// to the output device, and the honest thing to say is that it is on its way.
final class NcmPlaySubmitted extends NcmPlayOutcome {
  const NcmPlaySubmitted({required this.track});

  final Track track;
}

/// The session's own snapshot says this track is playing.
final class NcmPlayPlaying extends NcmPlayOutcome {
  const NcmPlayPlaying({required this.track, required this.levelLabel});

  final Track track;

  /// The quality actually in effect, for the words the user sees.
  final String levelLabel;
}

/// The lookup, the load or the first playback attempt failed; [code] is the
/// stable code to map.
final class NcmPlayFailed extends NcmPlayOutcome {
  const NcmPlayFailed(this.code);

  final String code;
}

/// The app's「输入网易云 ID，听到这首歌」flow.
///
/// The widget keeps a button and a text field; this class
/// does the steps — extract the id, fetch the track, start the queue, wait for
/// the session to confirm — in one place a test can drive without a window.
///
/// Two rules make the result trustworthy, and they are the point of the class:
///
/// * the song is resolved exactly once, by the host while it builds the queue's
///   item; nothing here resolves a second time, so a second request can never
///   contradict the first;
/// * ``playing'' comes from the authoritative snapshot (architecture §6.3), not
///   from the accepted command: a refusal is reported as a failure, and a load
///   that is accepted but never starts is reported as [NcmPlaySubmitted], and
///   the quality the user is told about is the one that snapshot *confirmed* —
///   the same standard the player bar and the settings page read.
final class NcmIdPlayback {
  NcmIdPlayback({
    required this.provider,
    required this.controller,
    this.qualityPreference,
    this.confirmationTimeout = const Duration(seconds: 8),
  });

  /// Where the song detail comes from — the same `CatalogRepository` the rest of
  /// the app browses through.
  final CatalogRepository provider;

  /// The playback state the queue is started through.
  final BrowseAndPlayController controller;

  /// How long a submitted song may take to reach a playing (or failed) snapshot
  /// before this flow stops waiting and reports [NcmPlaySubmitted].
  final Duration confirmationTimeout;

  /// The user's level, when this launch has one: an ID play is a content choice
  /// like a list row, so it is resolved at the preference rather than at a
  /// constant, and the next song by ID follows a change made here.
  final AudioQuality Function()? qualityPreference;

  /// The level this flow asks for when the launch has no preference to consult.
  /// It is the product default (极高 / HQ, with the provider's own entitlement
  /// degradation behind it). It is only what the queue is *asked* for: the words
  /// the user sees come from the snapshot that confirmed what opened.
  static const requestedQuality = AudioQuality.high;

  bool _busy = false;

  /// True from the first request until the flow settles, so the UI can disable
  /// its entry point instead of stacking requests.
  bool get isBusy => _busy;

  Future<NcmPlayOutcome> run(String input) async {
    final text = input.trim();
    if (text.isEmpty) return const NcmPlaySilent();
    if (_busy) return const NcmPlaySilent();
    _busy = true;
    try {
      final numericId = extractNcmTrackId(text);
      final track = await provider.getTrack(TrackId(ncmTrackId(numericId)));
      final submitted = await controller.playSingleTrack(
        track,
        quality: qualityPreference?.call() ?? requestedQuality,
      );
      if (!submitted.isAccepted) {
        // The session refused the load outright: nothing was installed and
        // nothing will play, so this is the end of the flow.
        return NcmPlayFailed(submitted.errorCode ?? 'playback.rejected');
      }
      // Awaited so the flow stays busy until the session has answered: the
      // entry point must not become clickable again mid-flight.
      return await _awaitPlayback(track);
    } on AppError catch (error) {
      debugPrint('Fideflow: NCM id playback failed: ${error.code}');
      return NcmPlayFailed(error.code);
    } catch (error) {
      // Nothing raw reaches the UI: an unexpected failure still has to become a
      // stable code the page can render.
      debugPrint('Fideflow: NCM id playback failed unexpectedly: $error');
      return const NcmPlayFailed('internal.unknown');
    } finally {
      _busy = false;
    }
  }

  /// Waits for the session to say what happened to the item it was handed.
  ///
  /// The wait is bounded: a song that is still preparing when the budget runs
  /// out is reported as submitted rather than as playing, because claiming sound
  /// is not the flow's to claim.
  Future<NcmPlayOutcome> _awaitPlayback(Track track) async {
    PlaybackSnapshot? settled(PlaybackSnapshot playback) {
      if (playback.currentTrack?.id != track.id) return null;
      return switch (playback.status) {
        PlaybackStatus.playing || PlaybackStatus.error => playback,
        _ => null,
      };
    }

    final already = settled(controller.current.playback);
    try {
      final snapshot =
          already ??
          await controller.states
              .map((state) => state.playback)
              .firstWhere((playback) => settled(playback) != null)
              .timeout(confirmationTimeout);
      if (snapshot.status == PlaybackStatus.error) {
        return NcmPlayFailed(snapshot.errorCode ?? 'playback.rejected');
      }
      // The label describes what is in effect, so it comes from the snapshot that
      // confirmed it — the same source the player bar and the settings page read
      // — and not from the host's record of what was asked for. Nothing
      // confirmed (a fake backend, or a source that named no tier) is unknown.
      final quality = snapshot.quality;
      final level = (quality != null && quality.confirmed)
          ? quality.level
          : null;
      return NcmPlayPlaying(
        track: track,
        levelLabel: level == null
            ? UiMessages.unknownAudioQuality
            : qualityLabel(level),
      );
    } on TimeoutException {
      return NcmPlaySubmitted(track: track);
    }
  }
}
