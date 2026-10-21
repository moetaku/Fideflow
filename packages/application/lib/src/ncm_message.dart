import 'package:fideflow_domain/domain.dart';

/// The words a stable NCM code maps to.
///
/// The same rule as `playback_message.dart`, for the codes the remote NCM
/// provider raises: the UI renders words from this mapping, never a provider
/// string, and an unknown code still names itself so a new failure is not
/// silent.
/// Returns a resource reference, resolved by the presentation's current locale.
String ncmMessage(String code) => switch (code) {
  'ncm.invalidId' => UiMessages.invalidNeteaseCloudMusicIdOrShareLink,
  // The local provider is a process the host supervises (docs/design/provider.md). "Starting"
  // is not a failure: the app is still coming up, and waiting is the right
  // advice. Everything else the host can report means no endpoint right now.
  'provider.starting' => UiMessages.theLocalMusicServiceIsStartingPleaseTry,
  'provider.unavailable' =>
    UiMessages.theLocalMusicServiceCouldNotStartRestart2,
  'provider.deviceIdInvalid' => UiMessages.theDeviceIdFileIsCorruptCheckThe,
  'provider.deviceIdUnavailable' => UiMessages.couldNotReadOrSaveTheDeviceId,
  'ncm.trackNotFound' => UiMessages.trackNotFoundCheckTheId,
  'ncm.albumNotFound' => UiMessages.albumNotFoundCheckTheId,
  'ncm.artistNotFound' => UiMessages.artistNotFoundCheckTheId,
  'ncm.playlistNotFound' => UiMessages.playlistNotFoundCheckTheId,
  'ncm.urlUnavailable' => UiMessages.theTrackSPlaybackUrlIsUnavailableVip,
  'provider.unsupported' =>
    UiMessages.thisContentSourceDoesNotSupportThisOperation,
  'provider.schemaChanged' =>
    UiMessages.theMusicServiceReturnedUnrecognizedData,
  // The network half: the endpoint may be perfectly healthy, so the advice is to
  // try again rather than to fix anything.
  'network.timeout' => UiMessages.musicServiceConnectionTimedOutPleaseTryAgain,
  'network.unreachable' => UiMessages.couldNotConnectToTheMusicServiceCheck2,
  'network.rateLimited' => UiMessages.tooManyRequestsPleaseTryAgainLater,
  // The service answered, and the answer is a failure of its own.
  'ncm.upstreamError' =>
    UiMessages.theMusicServiceIsTemporarilyUnavailablePleaseTry,
  'ncm.responseTooLarge' =>
    UiMessages.theMusicServiceReturnedUnusuallyLargeDataReading,
  // The request itself was refused (a bad parameter, or a risk-control block).
  // Changing nothing and asking again is what this code says not to do, so the
  // advice is to wait rather than to retry immediately.
  'ncm.badRequest' => UiMessages.theMusicServiceRejectedThisRequestPleaseTry,
  // The account may only hear a preview of this song, so there is no full
  // source to play and nothing a retry would change.
  'ncm.previewOnly' => UiMessages.onlyAPreviewIsAvailableMembershipIsRequired,
  // The account, not the network: retrying without signing in will not help.
  'ncm.authRequired' => UiMessages.signInToYourNeteaseAccountToContinue,
  'auth.notAuthorized' =>
    UiMessages.noCredentialsWereObtainedAfterPhoneConfirmationScan,
  'auth.epochMismatch' => UiMessages.signInStateChangedScanAgainToSign,
  'auth.logoutNoCredential' =>
    UiMessages.noCredentialsFoundForThisAccountRemoteSign,
  'auth.logoutRejected' => UiMessages.neteaseDidNotConfirmSignOutPleaseTry,
  'auth.logoutUnverified' =>
    UiMessages.neteaseStillAcceptsTheseCredentialsSignOutIs,
  'auth.secretServiceLocked' => UiMessages.linuxKeyringLocked,
  'auth.secretServiceUnavailable' => UiMessages.linuxSecretServiceUnavailable,
  'auth.secureStorageWriteFailed' => UiMessages.linuxCredentialSaveFailed,
  'auth.secureStorageDeleteFailed' => UiMessages.linuxCredentialDeleteFailed,
  'ncm.permissionDenied' => UiMessages.thisAccountDoesNotHavePermissionToPlay,
  _ => UiMessages.couldNotObtainTrackInformation((code).toString()),
};

/// Whether [code] is worth telling the user about at all.
///
/// Reserved for parity with `isSilentPlaybackCode`; nothing the provider
/// currently raises should be swallowed.
bool isSilentNcmCode(String code) => false;
