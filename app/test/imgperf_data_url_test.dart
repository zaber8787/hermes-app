// IMGPERF S1/A2: one base64 decode per data URL string, bounded cache.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/message_content.dart';

import 'support/localized_app.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7n8AAAAASUVORK5CYII=',
);

void main() {
  testWidgets('S1/A2 one data URL source decodes once across rebuilds',
      (t) async {
    resetDataUrlCache();
    final s1 = 'data:image/png;base64,${base64Encode(_png)}';
    for (var i = 0; i < 3; i++) {
      await t.pumpWidget(
        ProviderScope(
          child: localizedWrap(
            Padding(
              padding: EdgeInsets.all(i.toDouble()),
              child: MessageImage(s1),
            ),
          ),
        ),
      );
      await t.pump();
    }
    expect(
      dataUrlDecodeCount,
      1,
      reason: 'the same source string must decode exactly once (A2 red: 3)',
    );
    final s2 = 'data:image/png;base64,${base64Encode(Uint8List(8))}';
    await t.pumpWidget(
        ProviderScope(child: localizedWrap(MessageImage(s2))),
      );
    await t.pump();
    expect(dataUrlDecodeCount, 2);
    expect(debugDataUrlCacheSize(), 2);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('S1/A2 the decode cache is bounded and evicts', (t) async {
    resetDataUrlCache();
    final sources = [
      for (var i = 0; i < 40; i++)
        'data:image/png;base64,${base64Encode(Uint8List(16 + i))}',
    ];
    for (final s in sources) {
      await t.pumpWidget(ProviderScope(child: localizedWrap(MessageImage(s))));
      await t.pump();
    }
    expect(debugDataUrlCacheSize(), lessThanOrEqualTo(32));
    final before = dataUrlDecodeCount;
    await t.pumpWidget(
      ProviderScope(
        child: localizedWrap(
          Padding(padding: EdgeInsets.zero, child: MessageImage(sources.first)),
        ),
      ),
    );
    await t.pump();
    expect(
      dataUrlDecodeCount,
      before + 1,
      reason: 'the oldest source was evicted, so touching it decodes again',
    );
    await t.pumpWidget(const SizedBox.shrink());
  });
}
