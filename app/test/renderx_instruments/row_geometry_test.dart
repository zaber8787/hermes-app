import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/chat/timeline_row_geometry.dart';
import 'package:hermes_app/models/message.dart';

import '../support/localized_app.dart';

class _LateImageRepo extends HermesRepository {
  _LateImageRepo() : super('https://test.invalid', 'fixture');
  final landing = Completer<Uint8List>();
  @override
  Future<Uint8List> downloadServerFile(String path) => landing.future;
}

void main() {
  testWidgets(
    'late downloaded pixels keep viewport row height until scroll idle',
    (tester) async {
      final repo = _LateImageRepo();
      final scrolling = ValueNotifier(false);
      final measured = <double>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: localizedHome(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  child: TimelineRowGeometry(
                    scrolling: scrolling,
                    onExtent: measured.add,
                    child: const ServerPathImage('/late.png'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final initial = tester.getSize(find.byType(TimelineRowGeometry)).height;
      expect(initial, 120);
      scrolling.value = true;
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      final context = tester.element(find.byType(ServerPathImage));
      await tester.runAsync(() => precacheImage(MemoryImage(bytes), context));
      repo.landing.complete(bytes);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(find.byType(MessageImageMemory), findsOneWidget);
      // CONTRACT (2026-10-22 field fix): a tall landing (>60px growth) is
      // published even mid-drag. The old defer-until-idle contract clipped
      // images/tool results out of sight and the lock/release extent
      // oscillation bounced flings off image bands. Settled small reflows
      // still defer (see the sub-threshold case below).
      expect(
        tester.getSize(find.byType(TimelineRowGeometry)).height,
        greaterThan(initial),
      );
      expect(measured.last, greaterThan(initial));
      scrolling.value = false;
      await tester.pumpAndSettle();
      final landed = tester.getSize(find.byType(TimelineRowGeometry)).height;
      expect(
        landed,
        208,
        reason: '200px decoded image plus 8px vertical padding',
      );
      expect(measured.last, landed);
      await tester.pumpWidget(const SizedBox());
      scrolling.dispose();
      repo.close();
    },
  );

  testWidgets(
    'descendant-only layout publishes height without ancestor rebuild',
    (tester) async {
      final height = ValueNotifier<double>(80);
      final scrolling = ValueNotifier<bool>(false);
      final measured = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: TimelineRowGeometry(
              scrolling: scrolling,
              onExtent: measured.add,
              child: ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, _) => SizedBox(width: 100, height: value),
              ),
            ),
          ),
        ),
      );
      expect(measured, [80]);
      scrolling.value = true;
      height.value = 280;
      await tester.pump();
      // CONTRACT (2026-10-22): +200px is a content landing, not settled
      // jitter — it publishes immediately so the reader can SEE the new
      // content instead of a clipped frame of it. Sub-threshold reflows
      // remain deferred; visual anchoring is the refine loop's job.
      expect(tester.getSize(find.byType(TimelineRowGeometry)).height, 280);
      expect(measured, [80, 280]);
      scrolling.value = false;
      await tester.pump();
      expect(measured, [80, 280]);
      height.value = 40;
      await tester.pump();
      expect(measured, [80, 280, 40]);
      await tester.pumpWidget(const SizedBox());
      height.dispose();
      scrolling.dispose();
    },
  );

  testWidgets('extent memory follows ExpansionTile animation and collapse', (
    tester,
  ) async {
    final memory = <Object, double>{};
    final messages = List.generate(
      50,
      (i) => Message(
        id: 'm$i',
        role: i == 0 ? 'system' : 'user',
        content: i == 0 ? List.filled(30, 'detail\n').join() : 'row $i',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: localizedHome(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                MessageTimelineSliver(
                  messages: messages,
                  detailed: true,
                  extentMemory: memory,
                  reveal: const TimelineReveal(
                    pixels: 0,
                    viewport: 600,
                    revision: 0,
                    realFrom: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rowKey = memory.keys.firstWhere(
      (key) => key.toString().endsWith(':m0'),
    );
    final collapsed = memory[rowKey]!;
    await tester.tap(
      find
          .descendant(
            of: find.byType(ExpansionTile).first,
            matching: find.byType(ListTile),
          )
          .first,
    );
    await tester.pumpAndSettle();
    final expanded = memory[rowKey]!;
    expect(expanded, greaterThan(collapsed + 100));
    await tester.tap(
      find
          .descendant(
            of: find.byType(ExpansionTile).first,
            matching: find.byType(ListTile),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(memory[rowKey], closeTo(collapsed, 0.01));
    expect(tester.takeException(), isNull);
  });
}
