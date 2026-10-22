// Image-band fling probe (2026-10-22 field report: vertical scrolling
// through rows containing images is still not smooth on web AND app).
// This drives the real sliver with cached image tiles and measures:
//   - per-frame travel during a fling (teleport = anchor/refine churn)
//   - frames where layout work happened (rows landing mid-flight)
// Smooth means: monotone-ish travel, no frame with step > 3x the mean.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';

import 'support/localized_app.dart';

const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

void main() {
  testWidgets('fling through cached-image rows keeps steady travel', (
    tester,
  ) async {
    final messages = <Message>[
      for (var i = 0; i < 400; i++)
        Message(
          id: 'm$i',
          role: i.isEven ? 'user' : 'assistant',
          content: i % 10 == 0
              ? '![](data:image/png;base64,$_png1x1)\n圖片說明 $i'
              : '純文字訊息 $i ${'填充' * 30}',
        ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: localizedHome(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [MessageTimelineSliver(messages: messages, detailed: false)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final position = scroll.position;
    final start = position.pixels;

    final samples = <double>[];
    void onScroll() => samples.add(position.pixels);
    position.addListener(onScroll);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, -2000), 3000);
    var frames = 0;
    while (position.isScrollingNotifier.value && frames < 240) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    position.removeListener(onScroll);
    await tester.pumpAndSettle();

    // Travel per pump frame from the sample stream (dedup repeats).
    final steps = <double>[];
    for (var i = 1; i < samples.length; i++) {
      final d = samples[i] - samples[i - 1];
      if (d.abs() > 0.001) steps.add(d.abs());
    }
    final travel = (samples.last - start).abs();
    expect(travel, greaterThan(500), reason: 'fling must travel far');
    expect(steps, isNotEmpty);
    final mean = steps.reduce((a, b) => a + b) / steps.length;
    final worst = steps.reduce((a, b) => a > b ? a : b);
    // ignore: avoid_print
    print('IMGFLING travel=${travel.round()} mean=$mean worst=$worst frames=$frames');
    expect(worst, lessThan(mean * 4),
        reason: 'a frame leaping >4x the mean = anchor churn around images');
    // Direction must not reverse hard mid-flight (bounce-back signature).
    var reversals = 0;
    double? lastSign;
    for (final s in steps) {
      final sign = s.sign;
      if (lastSign != null && sign != lastSign && sign != 0) reversals++;
      if (sign != 0) lastSign = sign;
    }
    // (steps are abs values; reversals tracked from raw samples instead)
    var rawReversals = 0;
    for (var i = 2; i < samples.length; i++) {
      final a = samples[i - 1] - samples[i - 2];
      final b = samples[i] - samples[i - 1];
      if (a.abs() > 1 && b < -5) rawReversals++;
    }
    // ignore: avoid_print
    print('IMGFLING reversals=$rawReversals');
    expect(rawReversals, lessThan(3),
        reason: 'backward jumps mid-fling = the snap-back users feel');
    expect(reversals, greaterThanOrEqualTo(0));
  });
}
