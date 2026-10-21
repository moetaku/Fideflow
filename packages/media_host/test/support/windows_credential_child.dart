import 'package:fideflow_media_host/media_host.dart';

/// Second process used by the DPAPI test: it must see the credential written
/// by the parent process and be able to delete it.
Future<void> main(List<String> args) async {
  final storage = WindowsDpapiCredentialStorage(
    paths: PlatformPaths(dataDirectory: args[0]),
  );
  if (await storage.read('account_token:ncm:user:123') != 'test-cookie-中文') {
    throw StateError('Cross-process credential restore failed');
  }
  await storage.delete('account_token:ncm:user:123');
}
