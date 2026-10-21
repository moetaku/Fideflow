import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:flutter/foundation.dart';

import '../shared/artwork_service.dart';

/// Opens the launch's artwork cache, or null when this launch has no directory
/// to keep it in.
///
/// It is deliberately forgiving, like the metadata store: a cache root that
/// cannot be created is a service that misses. A cover is never worth failing a
/// launch over (design §4, §10).
ArtworkService? openArtworkService({
  required MetadataCacheStore store,
  required String? directory,
  required String namespace,
}) {
  if (directory == null || directory.isEmpty) return null;
  return ArtworkService(
    store: store,
    files: ArtworkFileStore(root: directory),
    namespace: namespace,
    // Stable codes only, never a URL (design §11).
    onDiagnostic: (code) => debugPrint('Fideflow: cache $code'),
  );
}
