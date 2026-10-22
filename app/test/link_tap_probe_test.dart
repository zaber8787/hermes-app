// Link-tap end-to-end probe — first test ever to tap a rendered link and
// assert it reaches the platform launcher (field bug 2026-10: links not
// tappable in the app; nothing covered this path, so two releases shipped
// a broken link affordance uncaught).
// GptMarkdown renders through its own layer (no Text/RichText widgets to
// find), so the probe sweeps tap points across the rendered lines to
// locate the link hotspot; the launcher is captured at the official
// UrlLauncherPlatform seam.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:hermes_app/features/chat/message_content.dart';

import 'support/localized_app.dart';

class _RecordingLauncher extends UrlLauncherPlatform {
  final taps = <String, LaunchOptions>{};
  @override
  LinkDelegate get linkDelegate => throw UnimplementedError('unused');
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    taps[url] = const LaunchOptions();
    return true;
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    taps[url] = options;
    return true;
  }

  Future<bool> canLaunchUrl(String url) async => true;
}

Future<String?> sweepForLink(WidgetTester tester) async {
  for (final y in [7.0, 10.0, 14.0, 21.0, 28.0]) {
    for (var x = 0.0; x < 320.0; x += 7.0) {
      await tester.tapAt(Offset(x, y));
      await tester.pump();
      if ((UrlLauncherPlatform.instance as _RecordingLauncher).taps.isNotEmpty) {
        return (UrlLauncherPlatform.instance as _RecordingLauncher)
            .taps
            .keys
            .last;
      }
    }
  }
  return null;
}

void main() {
  late _RecordingLauncher launcher;

  setUp(() {
    launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;
    // The app under test is platform-branched; pin a non-Android target so
    // the url_launcher seam (not the native channel) is what we exercise.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  testWidgets('link inside MessageContent is tappable and launches', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: localizedHome(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: MessageContent('前綴文字 [官網](https://example.com/a)'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final hit = await sweepForLink(tester);
    expect(hit, contains('example.com/a'));
    expect(launcher.taps[hit]!.mode, PreferredLaunchMode.externalApplication,
        reason: 'links must open the system browser, not an in-app webview');
    debugDefaultTargetPlatformOverride = null;
  });
}
