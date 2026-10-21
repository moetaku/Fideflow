import 'dart:convert';
import 'dart:io';

import 'package:fideflow/app/appearance.dart';
import 'package:fideflow/app/json_settings_file.dart';
import 'package:fideflow/app/language.dart';
import 'package:fideflow/app/sidebar_preference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fideflow-settings-');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('concurrent sidebar edits persist the last requested state', () async {
    final store = FileSidebarPreferenceStore(directory.path);
    for (var round = 0; round < 10; round++) {
      final writes = List.generate(
        20,
        (index) => store.writeCollapsed(index.isOdd),
      );
      // A read waits for all edits already requested, even before callers await.
      expect(await store.readCollapsed(), isTrue);
      await Future.wait(writes);
      expect(
        await FileSidebarPreferenceStore(directory.path).readCollapsed(),
        isTrue,
      );
    }
    expect(directory.listSync().map((file) => file.uri), [
      File('${directory.path}/sidebar.json').uri,
    ]);
  });

  test('queued settings capture mutable drafts at request time', () async {
    final file = File('${directory.path}/settings.json');
    final settings = JsonSettingsFile(file);
    final draft = <String, Object?>{
      'values': [1],
    };
    final write = settings.write(draft);
    (draft['values'] as List<int>).add(2);
    await write;
    expect(await settings.read(), {
      'values': [1],
    });
  });

  test(
    'failed replacement preserves the old file and allows later edits',
    () async {
      final file = File('${directory.path}/settings.json');
      final settings = JsonSettingsFile(file);
      await settings.write({'value': 1});
      // Force replacement to fail without changing the existing destination.
      final parent = directory.path;
      final blocked = JsonSettingsFile(
        File('$parent/settings.json/child.json'),
      );
      await expectLater(
        blocked.write({'value': 2}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await settings.read(), {'value': 1});
      await file.delete();
      await blocked.write({'value': 3});
      expect(await blocked.read(), {'value': 3});
    },
  );

  test('invalid JSON and absent files use the default', () async {
    final file = File('${directory.path}/sidebar.json');
    final store = FileSidebarPreferenceStore(directory.path);
    expect(await store.readCollapsed(), isNull);
    for (final contents in ['{bad', '[]', '{"collapsed":"true"}']) {
      await file.writeAsString(contents);
      expect(await store.readCollapsed(), isNull);
    }
    // Existing unversioned files remain readable without migration.
    await file.writeAsString('{"collapsed":false}');
    expect(await store.readCollapsed(), isFalse);
    await store.writeCollapsed(true);
    expect(jsonDecode(await file.readAsString()), {'collapsed': true});
  });

  test('sidebar without a settings directory remains usable', () async {
    final store = FileSidebarPreferenceStore(null);
    await store.writeCollapsed(true);
    await store.flush();
    expect(await store.readCollapsed(), isNull);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'shared writer preserves language and appearance file formats',
    () async {
      final language = FileLanguageStore(directory.path);
      final appearance = FileAppearanceStore(directory.path);
      final sidebar = FileSidebarPreferenceStore(directory.path);
      final appearanceDraft = <String, Object?>{
        'selected': 'material-light',
        'custom': <Object?>[],
      };
      await Future.wait([
        language.write('en'),
        appearance.write(appearanceDraft),
        sidebar.writeCollapsed(true),
      ]);
      expect(await language.read(), {'mode': 'en'});
      expect(await appearance.read(), appearanceDraft);
      expect(await sidebar.readCollapsed(), isTrue);
      expect(language.file.path, '${directory.path}/language.json');
      expect(appearance.file.path, '${directory.path}/appearance.json');
    },
  );
}
