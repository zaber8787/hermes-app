// IMGPERF S1 (TASK/IMGPERF.md A1/A2): one download Future per server-path
// image identity; one base64 decode per data URL string.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7n8AAAAASUVORK5CYII=',
);

class _MediaRepo extends HermesRepository {
  _MediaRepo() : super('https://example.invalid', 'fixture');
  int downloads = 0;
  String? lastPath;
  Uint8List bytes = Uint8List.fromList(_png);
  Completer<Uint8List>? gate;
  int failures = 0;

  @override
  Future<Uint8List> downloadServerFile(String path) {
    downloads++;
    lastPath = path;
    if (gate != null) return gate!.future;
    if (failures > 0) {
      failures--;
      return Future.error(StateError('fixture download failure'));
    }
    return Future.value(bytes);
  }
}

Uint8List _shownBytes(WidgetTester t) =>
    (t.widget<Image>(find.byType(Image).last).image as MemoryImage).bytes;

class _RepoHolder extends Notifier<HermesRepository> {
  @override
  HermesRepository build() => _initialRepo;
}

final _holderProvider = NotifierProvider<_RepoHolder, HermesRepository>(
  _RepoHolder.new,
);

HermesRepository _initialRepo = _MediaRepo();

void main() {
  testWidgets('S1/A1 same-path rebuilds reuse one download future', (t) async {
    final repo = _MediaRepo();
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    for (var i = 0; i < 3; i++) {
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(
            Padding(
              padding: EdgeInsets.all(i.toDouble()),
              child: ServerPathImage('/fixture/image.png'),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
    }
    expect(
      repo.downloads,
      1,
      reason: 'same-path rebuilds must not restart the download '
          '(IMGPERF A1 red: downloadCalls 3)',
    );
    expect(_shownBytes(t), same(repo.bytes));
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
    repo.close();
  });

  testWidgets('S1/A1 a new path fetches a new image', (t) async {
    final repo = _MediaRepo();
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    for (final path in ['/fixture/a.png', '/fixture/b.png']) {
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(ServerPathImage(path)),
        ),
      );
      await t.pump();
      await t.pump();
    }
    expect(repo.downloads, 2);
    expect(repo.lastPath, '/fixture/b.png');
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
    repo.close();
  });

  testWidgets('S1/A1 repo identity swap re-fetches; late old result loses',
      (t) async {
    final repoA = _MediaRepo()..gate = Completer<Uint8List>();
    final repoB = _MediaRepo();
    _initialRepo = repoA;
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWith((ref) => ref.watch(_holderProvider)),
      ],
    );
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ServerPathImage('/same.png')),
      ),
    );
    await t.pump();
    container.read(_holderProvider.notifier).state = repoB;
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          Padding(
            padding: const EdgeInsets.all(1),
            child: ServerPathImage('/same.png'),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(repoB.downloads, 1, reason: 'new repo identity must fetch again');
    repoA.gate!.complete(repoA.bytes);
    await t.pump();
    await t.pump();
    expect(
      identical(_shownBytes(t), repoB.bytes),
      isTrue,
      reason: 'a late result from the retired identity must not overwrite',
    );
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
    repoA.close();
    repoB.close();
  });

  testWidgets('S1/A1 a failed download degrades to an actionable tile with retry',
      (t) async {
    final repo = _MediaRepo()..failures = 1;
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(Scaffold(body: ServerPathImage('/fixture/x.png'))),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.byType(AttachmentTile), findsOneWidget);
    expect(repo.downloads, 1);
    await t.tap(find.byIcon(Icons.download).hitTestable());
    await t.pump();
    await t.pump();
    expect(
      repo.downloads,
      2,
      reason: 'the failed future is not remembered — one explicit retry refetches',
    );
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
    repo.close();
  });
}
