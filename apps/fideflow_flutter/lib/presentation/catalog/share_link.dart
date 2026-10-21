import 'package:fideflow_domain/domain.dart';

Uri? catalogShareLink(NcmKind kind, String id) {
  if (id.startsWith('ncm-') &&
      !id.startsWith(kind.prefix) &&
      !RegExp(r'^ncm-\d+$').hasMatch(id)) {
    return null;
  }
  final digits = kind.digitsOf(id);
  if (digits == null ||
      (BigInt.tryParse(digits) ?? BigInt.zero) <= BigInt.zero) {
    return null;
  }
  final resource = switch (kind) {
    NcmKind.track => 'song',
    NcmKind.album => 'album',
    NcmKind.playlist => 'playlist',
    _ => null,
  };
  return resource == null
      ? null
      : Uri.https('music.163.com', '/$resource', {'id': digits});
}

abstract interface class ClipboardWriter {
  Future<void> write(String text);
}
