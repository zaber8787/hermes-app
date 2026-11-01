// TASK-ATTACHJANK: history rows with images re-enter the viewport on every
// scroll pass (SliverList disposes off-screen children). A re-entry must
// paint the already-downloaded image in its FIRST frame — no 120px spinner
// frame that flips the row's height under an upward scroll, no fresh byte
// copy that misses the decoded-image cache. Plus the non-image attachment
// card (CJK filename, server path) keeps its name and download button.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7n8AAAAASUVORK5CYII=',
);

class _CountingRepo extends HermesRepository {
  _CountingRepo() : super('https://attachjank.invalid', 'fixture');
  int serverDownloads = 0;
  int artifactDownloads = 0;

  @override
  Future<Uint8List> downloadServerFile(String path) async {
    serverDownloads++;
    return Uint8List.fromList(_png);
  }

  @override
  Future<Uint8List> downloadAttachment(String id) async {
    artifactDownloads++;
    return Uint8List.fromList(_png);
  }
}

Uint8List _shownBytes(WidgetTester t) {
  var provider = t.widget<Image>(find.byType(Image).last).image;
  while (provider is ResizeImage) {
    provider = provider.imageProvider;
  }
  return (provider as MemoryImage).bytes;
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('attachjank');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => support.path);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    support.deleteSync(recursive: true);
  });

  // Mount → settle → scroll away (unmount) → scroll back, `passes` times.
  // Returns, per re-entry, whether its FIRST frame already showed the image
  // and which byte instance it painted once settled.
  Future<List<(bool, Uint8List)>> reenter(
    WidgetTester t,
    ProviderContainer container,
    Widget row,
    int passes,
  ) async {
    Widget page(bool shown) => UncontrolledProviderScope(
      container: container,
      child: localizedWrap(shown ? row : const SizedBox.shrink()),
    );
    // First landing: real async download (+ disk cache on io) settles.
    await t.pumpWidget(page(true));
    for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    expect(find.byType(Image), findsOneWidget, reason: 'first landing paints');
    final results = <(bool, Uint8List)>[];
    for (var pass = 0; pass < passes; pass++) {
      await t.pumpWidget(page(false));
      await t.pumpWidget(page(true)); // exactly ONE frame after re-entry
      final painted = find.byType(Image).evaluate().isNotEmpty;
      final spinner = find
          .byType(CircularProgressIndicator)
          .evaluate()
          .isNotEmpty;
      for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
      }
      results.add((painted && !spinner, _shownBytes(t)));
    }
    return results;
  }

  testWidgets(
    'server-path image re-entry paints in its first frame, one download',
    (t) async {
      final repo = _CountingRepo();
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      final passes = await reenter(
        t,
        container,
        const ServerPathImage('/share-out/attachjank-flow.png'),
        5,
      );
      expect(repo.serverDownloads, 1, reason: 'scrolling never re-downloads');
      expect(
        passes.map((p) => p.$1),
        everyElement(isTrue),
        reason:
            'a re-entering image row must not spend a frame as a 120px '
            'spinner — that height flip is what an upward scroll stutters on',
      );
      final first = passes.first.$2;
      expect(passes.map((p) => p.$2), everyElement(same(first)));
      await t.pumpWidget(const SizedBox.shrink());
      container.dispose();
      repo.close();
    },
  );

  testWidgets(
    'artifact image re-entry reuses one byte instance, no disk re-read',
    (t) async {
      final repo = _CountingRepo();
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      final passes = await reenter(
        t,
        container,
        // `[附件: <id> image.png]` — the shape of a user's pasted screenshot.
        const ServerPathImage(
          '0123456789abcdef0123456789abcdef',
          filename: 'image.png',
        ),
        5,
      );
      expect(repo.artifactDownloads, 1, reason: 'scrolling never re-downloads');
      expect(
        passes.map((p) => p.$1),
        everyElement(isTrue),
        reason:
            'artifact re-entry went back through the disk cache (async '
            'read, spinner frame) on every scroll pass',
      );
      final first = passes.first.$2;
      expect(
        passes.map((p) => p.$2),
        everyElement(same(first)),
        reason:
            'a fresh byte copy per re-entry misses the decoded-image '
            'cache (MemoryImage keys on byte identity) and re-decodes',
      );
      await t.pumpWidget(const SizedBox.shrink());
      container.dispose();
      repo.close();
    },
  );

  testWidgets('non-image server attachment (CJK name) shows name + download', (
    t,
  ) async {
    final repo = _CountingRepo();
    await t.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: localizedHome(
          locale: AppLocale.zhHant,
          home: const Scaffold(
            body: MessageContent(
              '好，丟一份真實檔案（PDF，6.2MB）。app 里這條應該是**附件卡**：\n\n'
              'MEDIA:/Users/zaber/share-out/2026-10-20-數位電路_CMOS開關層級設計_講義.pdf',
            ),
          ),
        ),
      ),
    );
    await t.pump();
    final tile = find.byType(AttachmentTile);
    expect(tile, findsOneWidget);
    expect(t.getSize(tile).height, greaterThan(40));
    expect(
      find.descendant(
        of: tile,
        matching: find.text('2026-10-20-數位電路_CMOS開關層級設計_講義.pdf'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.byTooltip('下載附件')),
      findsOneWidget,
    );
    expect(repo.serverDownloads, 0, reason: 'a file card never auto-fetches');
    repo.close();
  });
}
