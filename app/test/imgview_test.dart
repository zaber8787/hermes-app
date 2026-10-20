import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/image_viewer.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/platform/save_file.dart';
import 'support/localized_app.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7n8AAAAASUVORK5CYII=',
  );
  testWidgets('downloaded thumbnail opens viewer and returns', (t) async {
    // Natural-size render: a 1px test png would be an un-hittable touch
    // target, so constrain the slot like the real timeline does.
    await t.pumpWidget(
      localizedApp(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: MessageImageMemory(png),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byType(Image));
    await t.pumpAndSettle();
    expect(find.byType(MessageImageViewer), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(MessageImageViewer), findsNothing);
  });

  testWidgets('gallery opens tapped index and supports swipe and arrows', (
    t,
  ) async {
    await t.pumpWidget(
      localizedApp(
        Scaffold(
          body: MessageGallery(
            images: {
              'one': ViewerImage('one.png', () async => png),
              'two': ViewerImage('two.png', () async => png),
            },
            child: MessageImageMemory(png, source: 'two'),
          ),
        ),
      ),
    );
    await t.tap(find.byType(Image));
    await t.pumpAndSettle();
    expect(find.textContaining('2/2'), findsOneWidget);
    await t.drag(find.byType(PageView), const Offset(600, 0));
    await t.pumpAndSettle();
    expect(find.textContaining('1/2'), findsOneWidget);
    await t.tap(find.byIcon(Icons.chevron_right));
    await t.pumpAndSettle();
    expect(find.textContaining('2/2'), findsOneWidget);
  });

  testWidgets('download invokes injected saver for current page', (t) async {
    String? name;
    Uint8List? saved;
    await t.pumpWidget(
      localizedApp(
        MessageImageViewer(
          images: [
            ViewerImage('first.png', () async => png),
            ViewerImage('second.png', () async => png),
          ],
          downloader: (filename, bytes) async {
            name = filename;
            saved = bytes;
            return const BrowserStarted();
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.chevron_right));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.download_outlined));
    await t.pumpAndSettle();
    expect(name, 'second.png');
    expect(saved, orderedEquals(png));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('failed download leaves retry available', (t) async {
    var attempts = 0;
    await t.pumpWidget(
      localizedApp(
        MessageImageViewer(
          images: [ViewerImage('one.png', () async => png)],
          downloader: (_, _) async {
            attempts++;
            throw StateError('failure');
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.download_outlined));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.download_outlined));
    await t.pumpAndSettle();
    expect(attempts, 2);
  });
}
