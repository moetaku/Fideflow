import 'package:fideflow_application/application.dart';

Object browseProjection(HomeState state, BrowseAndPlayController controller) {
  final p = state.playback;
  final track = p.currentTrack;
  final q = p.quality;
  final o = p.outputSettings;
  final e = p.playbackEffects;
  return (
    state.status,
    state.feed,
    state.selectedPlaylist,
    state.errorCode,
    p.sessionId,
    p.queueRevision,
    p.projectionVersion,
    p.currentIndex,
    (
      track?.id,
      track?.title,
      track?.artistLabel,
      track?.album.id,
      track?.album.title,
      track?.album.artworkUri,
      track?.duration,
      track?.availability,
      track?.maxPotentialQuality,
    ),
    p.status,
    p.phase,
    p.failureKind,
    p.mode,
    p.playWhenReady,
    p.errorCode,
    p.buffering,
    p.isSeeking,
    p.isActuallyPlaying,
    p.duration,
    p.intelligenceSessionId,
    (
      q?.level,
      q?.confirmed,
      q?.switching,
      q?.bitrateKbps,
      q?.sampleRateHz,
      q?.codec,
    ),
    (
      o.supported,
      o.deviceUid,
      o.exclusive,
      o.resamplingEnabled,
      o.targetSampleRate,
      o.exclusiveActive,
      o.activeDeviceUid,
      o.busy,
      o.errorCode,
      o.refreshPending,
      Object.hashAll(
        o.devices.map(
          (d) => (
            d.uid,
            d.name,
            d.isDefault,
            d.exclusiveSupported,
            d.sharedSupported,
          ),
        ),
      ),
    ),
    (
      e.supported,
      e.fadeEnabled,
      e.volumeNormalizationEnabled,
      e.normalizationActive,
    ),
    controller.intelligence?.loading,
    controller.intelligence?.errorCode,
  );
}

Stream<HomeState> projectBrowseStates(
  Stream<HomeState> states,
  BrowseAndPlayController controller,
) => states
    .map((state) => (state, browseProjection(state, controller)))
    .distinct((previous, next) => previous.$2 == next.$2)
    .map((entry) => entry.$1);

Stream<HomeState> browseStates(BrowseAndPlayController controller) =>
    projectBrowseStates(controller.states, controller);
