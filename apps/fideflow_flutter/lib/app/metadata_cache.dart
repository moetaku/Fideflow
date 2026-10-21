import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:flutter/foundation.dart';

/// Opens the launch's metadata cache.
///
/// It is deliberately forgiving: a launch with no home directory, or a cache
/// directory that cannot be written, gets a store that misses. The cache is an
/// optimisation, and losing it must never be the reason an app fails to start
/// or a page fails to open (design §4, §10).
///
/// Only stable codes are logged — never a record's contents, a search term or a
/// signed URL (design §11).
MetadataCacheStore openMetadataCache({required String? directory}) {
  if (directory == null || directory.isEmpty) {
    return const DisabledMetadataCacheStore();
  }
  return SqliteMetadataCacheStore.open(
    path: '$directory/metadata.db',
    onDiagnostic: (code) => debugPrint('Fideflow: cache $code'),
  );
}
