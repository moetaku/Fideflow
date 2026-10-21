import 'package:fideflow_domain/domain.dart';

import 'models.dart';

abstract interface class MediaController {
  Future<CommandResult> execute(PlaybackCommand command);

  Future<PlaybackSnapshot> getSnapshot();

  Future<PlaybackConnection> attach();

  Future<void> detach(String connectionId);
}

/// A controller that can change the quality its sources are resolved at.
///
/// Quality belongs to whoever resolves a source, and the session never does: it
/// is handed a generic URI. So this is a capability of an implementation rather
/// than a wire command — the native host re-resolves through its broker and
/// swaps the source, while an implementation without the capability simply has
/// no answer, and a caller falls back to the per-load [LoadQueue.quality].
///
/// Every selection updates the global preference. Paused playback may defer
/// replacing its source until the next play command.
abstract interface class QualitySwitchableMediaController
    implements MediaController {
  Future<QualitySwitchOutcome> setQuality({required AudioQuality preference});
}
