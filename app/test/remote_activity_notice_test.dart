import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/remote_activity_notice.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/app_strings.dart';

void main() {
  testWidgets(
    'empty observation explains coverage and offers a read-only check',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var reads = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteActivityNotice(
              strings: const AppStrings(AppLocale.zhHant),
              onRefresh: () {
                reads++;
                return pending.future;
              },
            ),
          ),
        ),
      );
      expect(find.text('插話與執行狀態'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat.remoteActivityHelp')));
      await tester.pumpAndSettle();
      expect(find.textContaining('排程或背景工作'), findsOneWidget);
      final refresh = find.byKey(const ValueKey('chat.remoteActivityRefresh'));
      await tester.tap(refresh);
      await tester.pump();
      expect(reads, 1);
      expect(tester.widget<TextButton>(refresh).onPressed, isNull);
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
