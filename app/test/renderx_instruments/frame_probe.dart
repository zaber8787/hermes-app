import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';

/// Element hook counts actual rebuilds, including cached/offstage rows.
/// Wall time includes build/layout/paint and runner overhead; not GPU time.
class FrameProbe {
  final widgets = <String, int>{};
  final rows = <Element>{};
  int peakWidgets = 0;
  int peakRows = 0;
  int peakMicros = 0;
  int frames = 0;
  void Function(Element, bool)? _previous;

  void attach() {
    _previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      _previous?.call(element, builtOnce);
      final name = element.widget.runtimeType.toString();
      widgets.update(name, (n) => n + 1, ifAbsent: () => 1);
      if (element.widget is EntryView) rows.add(element);
    };
  }

  void detach() => debugOnRebuildDirtyWidget = _previous;

  Future<void> pump(WidgetTester tester) async {
    widgets.clear();
    rows.clear();
    final watch = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    watch.stop();
    frames++;
    final count = widgets.values.fold(0, (a, b) => a + b);
    if (count > peakWidgets) peakWidgets = count;
    // Lazy wrapper and EntryView represent one logical row.
    final rebuilt = rows.length;
    if (rebuilt > peakRows) peakRows = rebuilt;
    if (watch.elapsedMicroseconds > peakMicros) {
      peakMicros = watch.elapsedMicroseconds;
    }
    final viewport = tester.getRect(
      find.byKey(const ValueKey('chat.timelineScroll')),
    );
    for (final row
        in find
            .byWidgetPredicate((w) => w.runtimeType.toString() == '_LazyRow')
            .evaluate()) {
      final box = row.renderObject as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) continue;
      if (!(box.localToGlobal(Offset.zero) & box.size).overlaps(viewport)) {
        continue;
      }
      var real = false;
      void visit(Element e) {
        if (e.widget is EntryView) real = true;
        e.visitChildren(visit);
      }

      row.visitChildren(visit);
      expect(
        real,
        isTrue,
        reason: 'frame $frames: onstage placeholder ${row.widget.key}',
      );
    }
    final onstage = find.byType(EntryView).evaluate().where((element) {
      final box = element.renderObject as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) return false;
      final top = box.localToGlobal(Offset.zero).dy;
      return top <
              tester.view.physicalSize.height / tester.view.devicePixelRatio &&
          top + box.size.height > 0;
    }).length;
    expect(
      watch.elapsedMicroseconds,
      lessThan(16667),
      reason: 'debug VM CPU frame exceeds 60Hz budget',
    );
    expect(
      rebuilt,
      lessThanOrEqualTo(onstage * 1.5),
      reason: 'frame $frames: $rebuilt row rebuilds / $onstage onstage',
    );
  }

  @override
  String toString() =>
      'frames=$frames peakWidgets=$peakWidgets '
      'peakRows=$peakRows peakPumpUs=$peakMicros';
}

double maxSampleStep(List<double> samples) {
  var maximum = 0.0;
  for (var i = 1; i < samples.length; i++) {
    final step = (samples[i] - samples[i - 1]).abs();
    if (step > maximum) maximum = step;
  }
  return maximum;
}
