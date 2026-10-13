import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/copy_actions.dart';

import 'support/localized_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('clipboard failure shows feedback after choosing whole message', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard-denied');
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      localizedWrap(const Scaffold(body: CopyMenuButton(text: 'hello'))),
    );
    await tester.tap(find.byType(CopyMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy the whole message'));
    await tester.pump();
    expect(find.text('Copy failed. Try again.'), findsOneWidget);
  });
}
