import 'package:fideflow_domain/domain.dart';

/// The words a stable playback code maps to.
///
/// The architecture keeps this mapping out of the presentation layer and out of
/// the native host: the UI must never show a raw Rust or provider string, and a
/// code that means "this file cannot be decoded" should read the same in the
/// player bar, in a snack bar and in a diagnostic. Keeping it here also makes it
/// testable without a window.
///
/// Codes are the stable wire values from `schemas/media-control.v1.schema.json`
/// and the decoder's `DecodeError` names; an unknown code still produces a
/// readable message that carries the code, so a new failure is never silent.
/// Returns a resource reference, resolved by the presentation's current locale.
String playbackMessage(String code) => switch (code) {
  'playback.vipExpired' => UiMessages.vipMembershipExpiredPlaybackStopped,
  'playback.offlineGap' => UiMessages.thisSegmentIsNotCachedConnectToThe,
  'quality.vipRequired' => UiMessages.thisAudioQualityRequiresVipMembership,
  'intelligence.loginRequired' => UiMessages.signInToUseHeartbeatMode,
  'intelligence.noSeed' =>
    UiMessages.noPlayableFavoriteTracksAddSomeFavoritesFirst,
  'intelligence.empty' =>
    UiMessages.noNewHeartbeatRecommendationsPleaseTryAgainLater,
  'intelligence.failed' =>
    UiMessages.couldNotLoadHeartbeatRecommendationsCheckYourNetwork,
  'intelligence.sourceRestricted' =>
    UiMessages.severalHeartbeatTracksAreRestrictedByCopyrightRefresh,
  // Decoding and the source itself.
  'sourceUnsupported' => UiMessages.thisFileCannotBeDecodedAndWasSkipped,
  'sourceOpenFailed' => UiMessages.couldNotOpenThisFile,
  'sourceHasNoAudio' => UiMessages.thisFileContainsNoAudio,
  'decodeFailed' => UiMessages.decodingFailedTrackSkipped,
  'decodeUnavailable' => UiMessages.thisVersionHasNoDecoder,
  'seekFailed' => UiMessages.thisFileDoesNotSupportSeeking,
  // Output.
  'audio.focusDenied' ||
  'audio.activationFailed' => UiMessages.audioOutputInterruptedClickPlayToRetry,
  'outputUnavailable' => UiMessages.noAudioDeviceAvailable,
  'outputOpenFailed' => UiMessages.couldNotOpenTheAudioDevice,
  'workerUnavailable' => UiMessages.couldNotStartThePlaybackThread,
  // Queue and command state.
  'emptyQueue' => UiMessages.thePlayQueueIsEmpty,
  'playback.queueEmpty' => UiMessages.thePlayQueueIsEmpty,
  'queue.invalid' => UiMessages.thisItemIsNotInTheQueue,
  'unknownQueueItem' => UiMessages.thisItemIsNotInTheQueue,
  'unknownStartItem' => UiMessages.thisItemIsNotInTheQueue,
  'queue.revisionConflict' => UiMessages.theQueueJustChangedPleaseTryAgain,
  'staleQueueRevision' => UiMessages.theQueueJustChangedPleaseTryAgain,
  'queueBoundary' => UiMessages.youHaveReachedTheEndOfTheQueue,
  'idempotencyConflict' => UiMessages.thisCommandHasAlreadyBeenExecuted,
  'malformedCommand' => UiMessages.thePlayerRejectedThisCommand,
  'unsupportedCommand' => UiMessages.thePlayerDoesNotSupportThisOperationYet,
  'unsupportedSchemaVersion' => UiMessages.playerAndInterfaceVersionsDoNotMatch,
  'sessionMismatch' => UiMessages.thePlaybackSessionWasRecreated,
  // Transport.
  'media.notAttached' => UiMessages.thePlayerIsNotConnectedYet,
  'media.closed' => UiMessages.thePlayerIsClosed,
  'media.timeout' => UiMessages.thePlayerDidNotRespondPleaseTryAgain,
  'media.unsupported' => UiMessages.thePlayerRejectedThisMessage,
  'media.malformedMessage' => UiMessages.thePlayerRejectedThisMessage,
  'media.invalidArgument' => UiMessages.thePlayerRejectedThisMessage,
  'media.nullHandle' => UiMessages.thePlayerHasBeenReleased,
  'media.internal' => UiMessages.internalPlayerError,
  'playback.rejected' => UiMessages.thePlayerRejectedThisCommand,
  // A quality change that only partly took: the new source is remembered but the
  // song playing could not be reopened on it, so what is audible is unchanged.
  //
  // The wording says the *preference* was updated rather than that it was saved
  // to disk: persistence is best-effort here, and the store reports nothing back,
  // so a page must not promise more than the app knows.
  'playback.qualitySwitchPartial' =>
    UiMessages.preferenceUpdatedItWillTakeEffectLaterFor,
  _ => UiMessages.playbackError((code).toString()),
};

/// Whether [code] is worth telling the user about at all.
///
/// A stale generation is what a seek that arrives just after a song change looks
/// like: the user did nothing wrong, the command was simply too late, and the
/// target it named is no longer the thing on screen. Showing a message for it
/// would train people to ignore the ones that matter.
bool isSilentPlaybackCode(String code) =>
    code == 'staleGeneration' || code == 'cancelled';
