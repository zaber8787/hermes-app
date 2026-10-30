import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// PLAN-VOICEUI §6.2 call_source_hygiene_test: lib/features/call/ carries NO
// deployment config — no tailnet host, no tailnet TLD, no CGNAT range
// literal (android_manifest_test.dart's rule moved into the Dart layer;
// deriveVoiceUrl is generic so nothing needs these constants anyway).

const _forbidden = ['ts.net', 'tail592d86', '100.81.'];

void main() {
  final dir = Directory('lib/features/call');

  test('lib/features/call exists and is non-empty', () {
    expect(dir.existsSync(), isTrue);
    expect(
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')),
      isNotEmpty,
    );
  });

  test('no tailnet literals anywhere in the call sources', () {
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final needle in _forbidden) {
        expect(source.contains(needle), isFalse,
            reason: '${file.path} must not hardcode "$needle"');
      }
    }
  });

  test('controller diagnostics never carry the token (once it lands)', () {
    final controller = File('lib/features/call/call_controller.dart');
    if (!controller.existsSync()) return; // UI/controller rod (call7b)
    for (final line in controller.readAsLinesSync()) {
      if (line.contains('Diagnostic')) {
        expect(line.contains('token'), isFalse,
            reason: 'diagnostics may log event types/codes, never secrets');
      }
    }
  });
}
