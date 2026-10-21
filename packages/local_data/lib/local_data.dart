/// Persistence ports and development adapters, free of platform I/O.
///
/// The application layer depends on this library; a concrete file adapter lives
/// behind `local_data_io.dart`, so a pure consumer never pulls `dart:io` in.
library;

export 'src/cache/cache_models.dart';
export 'src/cache/cache_store.dart';
export 'src/playback_checkpoint.dart';
export 'src/playback_checkpoint_store.dart';
export 'src/quality_preference_store.dart';
export 'src/recent_playback_store.dart';
