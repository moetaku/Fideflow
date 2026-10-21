import 'package:fideflow/shared/music_scope.dart';
import 'package:fideflow/shared/widgets/quality_selector.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/application/test/support/account_music_fakes.dart';

void main() {
  for (final change in ['account', 'epoch', 'vip', 'dispose']) {
    testWidgets(
      'an open quality menu ignores its result after $change changes',
      (tester) async {
        final repository = TestAuth();
        final auth = AuthController(repository);
        repository.login();
        await tester.pump();
        final catalog = TestCatalog();
        final music = AccountMusicController(
          repository: TestMusic(catalog),
          catalog: catalog,
          auth: auth,
        );
        await tester.pump();
        addTearDown(() async {
          music.dispose();
          auth.dispose();
          await repository.events.close();
        });
        var vip = true;
        var visible = true;
        var revision = 0;
        final selected = <AudioQuality>[];
        late StateSetter rebuild;
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  rebuild = setState;
                  return MusicManagementScope(
                    controller: music,
                    revision: revision,
                    child: visible
                        ? QualityMenuButton(
                            preference: AudioQuality.high,
                            quality: null,
                            isVip: vip,
                            currentTrack: track(track1),
                            onSelected: selected.add,
                          )
                        : const SizedBox(),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.byType(QualityMenuButton));
        await tester.pumpAndSettle();
        if (change == 'account' || change == 'epoch') {
          final previous = music.accountKey;
          repository.login(id: change == 'account' ? '43' : '42', epoch: 2);
          await tester.pump();
          expect(music.accountKey, isNot(previous));
        }
        rebuild(() {
          revision++;
          if (change == 'vip') vip = false;
          if (change == 'dispose') visible = false;
        });
        await tester.pump();
        navigator.currentState!.pop(AudioQuality.standard);
        await tester.pumpAndSettle();
        expect(selected, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
