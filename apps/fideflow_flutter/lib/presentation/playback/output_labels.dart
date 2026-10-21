import 'package:fideflow_domain/domain.dart';

String outputErrorMessage(String code) => switch (code) {
  'outputDeviceRemoved' || 'outputDeviceUnavailable' =>
    UiMessages.thePlaybackDeviceIsDisconnectedOrUnavailablePlayback,
  'outputStopped' => UiMessages.audioOutputWasInterruptedCheckTheDeviceThen,
  'outputExclusiveUnavailable' =>
    UiMessages.couldNotAcquireExclusiveAccessTheDeviceMay,
  'outputEnumerationFailed' =>
    UiMessages.couldNotRefreshPlaybackDevicesPleaseTryAgain,
  'outputUnavailable' =>
    UiMessages.thisVersionDoesNotProvideAudioDeviceControls,
  _ => UiMessages.audioOutputFailedCheckTheDeviceAndTry,
};
