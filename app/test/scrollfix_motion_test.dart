// APPENDED (SCROLLFIX-2): dynamic probes — fling trajectory smoothness and
// load-older anchor convergence. Static geometry already passes; the bug is
// motion.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

class FakeScrollRepo2 extends HermesRepository {
  FakeScrollRepo2() : super('http://test.invalid', 'fake');

  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = const [];
  List<Message> olderHistory = const [];

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      events.stream;
  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => offset == 0 ? history : olderHistory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeScrollRepo2 repo;
  late ProviderContainer container;
  const url = 'http://test.invalid';
  final sessionA = Session(
    id: 's',
    title: 'A',
    count: 200,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  List<Message> rows(int n, int shift) => List.generate(
    n,
    (i) => Message(
      id: 's$shift-m$i',
      role: i.isEven ? 'user' : 'assistant',
      content: '${List.filled(1 + (i + shift) % 8, '段落內容 $i 帶點長度').join(' ')}\n\n',
      timestamp: 1000.0 + shift * 1000 + i,
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeScrollRepo2();
    repo.history = rows(200, 0);
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(
          LocalStore(await SharedPreferences.getInstance()),
        ),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        repositoryProvider.overrideWithValue(repo),
        skillsProvider.overrideWith((ref) async => []),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    if (!repo.events.isClosed) unawaited(repo.events.close());
    repo.close();
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          ChatPage(session: sessionA),
          locale: AppLocale.zhHant,
        ),
      ),
    );
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
  }

  ScrollPosition tl(WidgetTester t) {
    final scroller = find
        .descendant(
          of: find.byKey(const ValueKey('chat.timelineScroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    return t.state<ScrollableState>(scroller).position;
  }

  testWidgets('fling toward history keeps a smooth trajectory (no per-frame '
      'teleports)', (t) async {
    await open(t);
    final pos = tl(t);
    // Park mid-history so the fling runs through placeholder territory.
    pos.jumpTo(pos.maxScrollExtent * 0.6);
    await t.pumpAndSettle();
    final gesture = await t.startGesture(const Offset(200, 500));
    // Drag DOWN = reveal older content (top direction).
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await t.pump(const Duration(milliseconds: 16));
    }
    final samples = <double>[];
    final extentSamples = <double>[];
    await gesture.up();
    // Sample the whole ballistic phase frame by frame.
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 16));
      samples.add(pos.pixels);
      extentSamples.add(pos.maxScrollExtent);
    }
    // A frame-to-frame jump far beyond ballistic velocity = a teleport.
    var maxStep = 0.0;
    var maxExtentStep = 0.0;
    for (var i = 1; i < samples.length; i++) {
      maxStep = (samples[i] - samples[i - 1]).abs();
      if (maxStep > 2000) break;
      maxExtentStep =
          (extentSamples[i] - extentSamples[i - 1]).abs().clamp(
              maxExtentStep, double.infinity);
    }
    expect(
      maxStep,
      lessThan(1500),
      reason: 'fling frame must not teleport by $maxStep px '
          '(placeholder height correction firing mid-flight)',
    );
    expect(
      maxExtentStep,
      lessThan(1500),
      reason: 'maxScrollExtent swung by $maxExtentStep px in one frame — '
          'the thumb jumps even when the view does not',
    );
  });

  testWidgets('load-older converges without oscillation', (t) async {
    await open(t);
    repo.olderHistory = rows(200, -1);
    final pos = tl(t);
    pos.jumpTo(60);
    await t.pumpAndSettle();
    // Anchor row: the row nearest the viewport centre right at load time.
    final seen = <double>[];
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 32));
      seen.add(pos.pixels);
    }
    // Oscillation = direction reversals between consecutive correction
    // ticks (excluding micro noise). A converging refine loop is monotone.
    var reversals = 0;
    for (var i = 2; i < seen.length; i++) {
      final d1 = seen[i - 1] - seen[i - 2];
      final d2 = seen[i] - seen[i - 1];
      if (d1.abs() > 2 && d2.abs() > 2 && d1.sign != d2.sign) reversals++;
    }
    expect(
      reversals,
      lessThan(3),
      reason: 'anchor restore reversed direction $reversals times: $seen — '
          'the reader sees 乱跳 while it settles',
    );
  });
}
