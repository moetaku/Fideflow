import 'dart:async';
import 'package:fideflow/features/auth/login_dialog.dart';
import 'package:fideflow_application/application.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'auth_ui_test.dart' show FakeAuthRepo;

void main() {
  late FakeAuthRepo repo;
  late AuthController auth;
  tearDown(() {
    auth.dispose();
    repo.dispose();
  });

  Future<void> host(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
    double inset = 0,
    DateTime Function()? now,
  }) async {
    repo = FakeAuthRepo();
    auth = AuthController(repo, now: now ?? DateTime.now);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: inset),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(LoginDialog.show(context, auth)),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('$platform at $width uses platform default', (tester) async {
        await host(tester, width: width);
        final mobile =
            platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        expect(
          find.byKey(const ValueKey('login-phone')),
          mobile ? findsOneWidget : findsNothing,
        );
        expect(auth.current.qrSession, mobile ? isNull : isNotNull);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
      }, variant: TargetPlatformVariant.only(platform));
    }
  }

  testWidgets('switching clears code and errors but keeps number and country', (
    tester,
  ) async {
    await host(tester);
    await tester.enterText(
      find.byKey(const ValueKey('login-country-code')),
      '+1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '2025550123',
    );
    await tester.enterText(find.byKey(const ValueKey('login-code')), '987654');
    await tester.tap(find.text('扫码登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('login-phone')))
          .controller!
          .text,
      '2025550123',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('login-country-code')))
          .controller!
          .text,
      '+1',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('login-code')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('login-phone')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('login-country-code')))
          .controller!
          .text,
      '+86',
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone success closes once and duplicate open does not stack', (
    tester,
  ) async {
    await host(tester);
    await LoginDialog.show(tester.element(find.byType(LoginDialog)), auth);
    expect(find.byType(LoginDialog), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '13800138000',
    );
    await tester.enterText(find.byKey(const ValueKey('login-code')), '123456');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(auth.current.isPhoneSigningIn, isFalse);
    expect(auth.loginCompletions, 1);
    await tester.pumpAndSettle();
    expect(find.byType(LoginDialog), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(auth.loginCompletions, 1);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('SMS resend counts down from successful send and enables retry', (
    tester,
  ) async {
    var time = DateTime(2026, 10, 18);
    await host(tester, now: () => time);
    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '13800138000',
    );
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(find.text('60 秒后重发'), findsOneWidget);
    time = time.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('30 秒后重发'), findsOneWidget);
    time = time.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('获取验证码'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '获取验证码'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'phone completion only removes its own route under another dialog',
    (tester) async {
      await host(tester);
      final context = tester.element(find.byType(LoginDialog));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('Other dialog')),
        ),
      );
      await tester.pumpAndSettle();
      await auth.loginWithCode(
        phone: '13800138000',
        countryCode: '+86',
        code: '123456',
      );
      await tester.pumpAndSettle();
      expect(find.text('Other dialog'), findsOneWidget);
      expect(find.byType(LoginDialog, skipOffstage: false), findsNothing);
      Navigator.of(tester.element(find.text('Other dialog'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('small viewport, keyboard and large text remain scrollable', (
    tester,
  ) async {
    await host(tester, width: 320, scale: 3, inset: 300);
    expect(tester.takeException(), isNull);
    final code = find.byKey(const ValueKey('login-code'));
    await tester.ensureVisible(code);
    await tester.enterText(code, '123456');
    expect(
      tester.widget<TextField>(code).autofillHints,
      contains(AutofillHints.oneTimeCode),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
