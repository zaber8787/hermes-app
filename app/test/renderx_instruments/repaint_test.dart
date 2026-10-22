import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';
import '../support/localized_app.dart';

int paints(RenderRepaintBoundary boundary) =>
    boundary.debugSymmetricPaintCount + boundary.debugAsymmetricPaintCount;

void main() {
  testWidgets('streamed tail and expansion repaint only their row boundaries', (
    tester,
  ) async {
    final content = ValueNotifier('stream');
    final controller = ScrollController();
    await tester.pumpWidget(
      ProviderScope(
        child: localizedHome(
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: content,
              builder: (_, text, _) => CustomScrollView(
                controller: controller,
                slivers: [
                  MessageTimelineSliver(
                    messages: List.generate(
                      50,
                      (i) => Message(
                        id: 'm$i',
                        role: i == 49 ? 'system' : 'user',
                        content: i == 49 ? text : 'stable row $i',
                      ),
                    ),
                    detailed: true,
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
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find
          .descendant(
            of: find.byType(ExpansionTile).last,
            matching: find.byType(ListTile),
          )
          .first,
    );
    await tester.pumpAndSettle();
    final entries = find.byType(EntryView).evaluate().toList();
    final stable = entries
        .firstWhere((e) => (e.widget as EntryView).entry.message.id == 'm48')
        .findAncestorRenderObjectOfType<RenderRepaintBoundary>()!;
    final tail = entries
        .firstWhere((e) => (e.widget as EntryView).entry.message.id == 'm49')
        .findAncestorRenderObjectOfType<RenderRepaintBoundary>()!;
    // Boundary metrics include cached layer composites. Count paintChild hits
    // BELOW the boundary to distinguish real repaint from layer reuse.
    final painted = <RenderObject>[];
    final previous = debugOnProfilePaint;
    debugOnProfilePaint = painted.add;
    addTearDown(() => debugOnProfilePaint = previous);
    bool inside(RenderObject object, RenderObject boundary) {
      RenderObject? ancestor = object;
      while (ancestor != null) {
        if (identical(ancestor, boundary)) return !identical(object, boundary);
        ancestor = ancestor.parent;
      }
      return false;
    }

    var markdownBuilds = 0;
    final previousRebuild = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousRebuild?.call(element, builtOnce);
      if (element.widget.runtimeType.toString() == 'GptMarkdown') {
        markdownBuilds++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousRebuild);
    final beforeStable = paints(stable);
    final beforeTail = paints(tail);
    content.value = 'stream updated';
    await tester.pumpAndSettle();
    expect(
      painted.where((r) => inside(r, stable)),
      isEmpty,
      reason: 'streaming must not repaint an unchanged sibling',
    );
    expect(paints(tail), greaterThan(beforeTail));
    expect(
      markdownBuilds,
      0,
      reason: 'unchanged markdown must retain its parsed widget subtree',
    );
    final expandedPaints = paints(tail);
    painted.clear();
    await tester.tap(
      find
          .descendant(
            of: find.byType(ExpansionTile).last,
            matching: find.byType(ListTile),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      painted.where((r) => inside(r, stable)),
      isEmpty,
      reason: 'expansion animation must stay inside its repaint boundary',
    );
    expect(paints(tail), greaterThan(expandedPaints));
    debugPrint(
      'RENDERX repaint: stableDelta=${paints(stable) - beforeStable} '
      'tailDelta=${paints(tail) - beforeTail}',
    );
    await tester.pumpWidget(const SizedBox());
    debugOnProfilePaint = previous;
    debugOnRebuildDirtyWidget = previousRebuild;
    content.dispose();
    controller.dispose();
  });
}
