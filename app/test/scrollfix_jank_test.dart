import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// SCROLLFIX: up/down browsing of a long history must not jump the viewport
/// around and must not re-measure every row on every scroll event. Reuses
/// the OPENPERF harness (200 heavy rows) and probes the settled-state
/// geometry invariants a human reads as '乱跳'.
class FakeScrollRepo extends HermesRepository {
  FakeScrollRepo() : super('http://test.invalid', 'fake');

  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = const [];

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
  Future<List<Message>> messages(String sid, {int offset = 0, int limit = 200}) async =>
      offset == 0 ? history : const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeScrollRepo repo;
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeScrollRepo();
    // Uneven rows — placeholder-vs-real height correction only shows up
    // when rows genuinely differ in height.
    repo.history = List.generate(
      200,
      (i) => Message(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: '${List.filled(1 + i % 8, '段落內容 $i 帶點長度').join(' ')}\n\n',
        timestamp: 1000.0 + i,
      ),
    );
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
        child: localizedWrap(ChatPage(session: sessionA), locale: AppLocale.zhHant),
      ),
    );
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
  }

  ScrollPosition timelinePosition(WidgetTester t) {
    final scroller = find
        .descendant(
          of: find.byKey(const ValueKey('chat.timelineScroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    return t.state<ScrollableState>(scroller).position;
  }

  testWidgets('settled scroll does not drift on landing ticks', (t) async {
    await open(t);
    final pos = timelinePosition(t);
    pos.jumpTo(pos.maxScrollExtent * 0.5);
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    await t.pump();
    final settled = pos.pixels;
    // Placeholder→real landings after settling must not shove the viewport.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 120));
    }
    expect(pos.pixels, closeTo(settled, 1.0),
        reason: 'viewport must stay where the reader left it');
  });

  testWidgets('total extent stays stable while browsing (thumb does not '
      'jump wildly)', (t) async {
    await open(t);
    final pos = timelinePosition(t);
    pos.jumpTo(pos.maxScrollExtent * 0.3);
    await t.pumpAndSettle();
    final baseline = pos.maxScrollExtent;
    pos.jumpTo(pos.maxScrollExtent * 0.7);
    await t.pumpAndSettle();
    final after = pos.maxScrollExtent;
    // Realisation only replaces estimates with measured heights; total may
    // move a little, a thrashing sliver moves it by whole viewports.
    final drift = (after - baseline).abs() / baseline;
    expect(drift, lessThan(0.35),
        reason: 'maxScrollExtent thrash makes the scrollbar thumb jump '
            'wildly: $baseline → $after');
  });

  testWidgets('no placeholder band inside the settled viewport', (t) async {
    await open(t);
    final pos = timelinePosition(t);
    pos.jumpTo(pos.maxScrollExtent * 0.45);
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    // Any bare fixed-height SizedBox directly under the sliver inside the
    // viewport window == a placeholder frozen under the reader's eyes.
    var placeholdersOnstage = 0;
    void visit(Element e) {
      final w = e.widget;
      if (w is SizedBox && w.height != null && w.child == null) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.attached) {
          final pd = ro.parentData;
          if (pd is SliverMultiBoxAdaptorParentData &&
              pd.layoutOffset != null) {
            final top = pd.layoutOffset!;
            if (top < pos.pixels + pos.viewportDimension &&
                top + (ro.size.height) > pos.pixels) {
              placeholdersOnstage++;
            }
          }
        }
      }
      e.visitChildren(visit);
    }

    find.byType(ChatPage).first.evaluate().single.visitChildren(visit);
    expect(placeholdersOnstage, 0,
        reason: 'placeholders must not linger in the settled viewport');
  });
}
