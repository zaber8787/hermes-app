// REGRESSION probes for the 2026-10-22 field reports: tall content landing
// on a row while a reader is mid-scroll must publish (not clip until
// scroll-end). Tool results and images were invisible / bouncy because the
// scroll-lock deferred FIRST content reveals along with settled jitter.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_app/features/chat/timeline_row_geometry.dart';

class _Bridge extends StatefulWidget {
  const _Bridge({required this.scrolling, required this.onExtent});
  final ValueListenable<bool> scrolling;
  final ValueChanged<double> onExtent;
  @override
  State<_Bridge> createState() => BridgeState();
}

class BridgeState extends State<_Bridge> {
  int step = 0;
  final List<double> published = [];

  void grow() => setState(() => step += 1);

  void jitter() => setState(() {}); // same child, layout unchanged

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: TimelineRowGeometry(
        scrolling: widget.scrolling,
        onExtent: (h) {
          published.add(h);
          widget.onExtent(h);
        },
        child: SizedBox(
          width: 300,
          child: SizedBox(height: step == 0 ? 60 : 500),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('tall content landing mid-scroll publishes, never clips', (
    tester,
  ) async {
    final scrolling = ValueNotifier<bool>(false);
    await tester.pumpWidget(_Bridge(scrolling: scrolling, onExtent: (_) {}));
    await tester.pump();
    final bridge = tester.state<BridgeState>(find.byType(_Bridge));
    expect(bridge.published, contains(60.0));

    // Reader is mid-drag when the tool result / image lands.
    scrolling.value = true;
    await tester.pump();
    bridge.grow();
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(SizedBox).last).height, 500);
    expect(bridge.published.last, 500);
  });

  testWidgets('settled row keeps the scroll-lock contract', (tester) async {
    final scrolling = ValueNotifier<bool>(false);
    await tester.pumpWidget(_Bridge(scrolling: scrolling, onExtent: (_) {}));
    await tester.pump();
    final bridge = tester.state<BridgeState>(find.byType(_Bridge));
    bridge.grow(); // idle growth publishes
    await tester.pump();
    expect(bridge.published.last, 500);

    // Now the row is settled at 500: while scrolling, a rebuild that would
    // shrink it (tile toggle shape) must stay published at 500.
    scrolling.value = true;
    await tester.pump();
    bridge.jitter();
    await tester.pump();
    bridge.jitter();
    await tester.pump();
    expect(bridge.published.last, 500);
  });
}
