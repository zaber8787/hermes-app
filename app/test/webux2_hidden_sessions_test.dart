// TASK-WEBUX2-01 Ticket A: hidden sessions are withheld by the GATEWAY, not
// by the client switch. These tests run against a fake that copies the REAL
// gateway list contract (api_server.py:3019-3065 + hermes_state_sessions.py
// :1371,1416-1440): limit clamped to 200, hidden rows dropped unless a title
// filter is present, pinned rows back-filled past the window, `has_more`
// counted over NON-pinned window rows only. The old hidden_toggle_test fake
// cooperated by returning hidden rows on include_hidden=true; the real
// gateway never does — that is why every pre-existing test missed this bug.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/models/message.dart' show Message;
import 'package:hermes_app/models/session.dart' show Skill;
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

const url = 'http://test.invalid';

/// A row of the fake DB.
class _Row {
  _Row(this.id, {this.hidden = false, this.pinned = false, this.activity = 0});
  final String id;
  final bool hidden, pinned;
  final double activity;
}

/// Fake of the REAL gateway list handler + state layer (see header comment).
class _GatewayContractPort implements HttpPort {
  _GatewayContractPort(this.db);
  final List<_Row> db;
  final offsets = <String>[];

  @override
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
    DispatchObservation? observation,
  }) async {
    if (uri.path != '/api/sessions') return _resp({'data': []});
    offsets.add(uri.queryParameters['offset'] ?? '?');
    // api_server.py:3019 — limit defaults 50, maximum 200.
    final limit =
        (int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50).clamp(0, 200);
    final offset = int.tryParse(uri.queryParameters['offset'] ?? '') ?? 0;
    // api_server.py:3026 — include_hidden is honored ONLY with a title filter.
    final titleFilter = (uri.queryParameters['title'] ?? '').isNotEmpty;
    final includeHidden =
        titleFilter && uri.queryParameters['include_hidden'] == 'true';
    // hermes_state_sessions.py:1371 — without include_hidden: s.hidden = 0.
    final eligible =
        db.where((r) => includeHidden || !r.hidden).toList()
          ..sort((a, b) => b.activity.compareTo(a.activity));
    // The window is LIMIT rows at OFFSET; the order is already last-active.
    final window = eligible.skip(offset).take(limit).toList();
    // hermes_state_sessions.py:1416-1440 — every visible pin OUTSIDE the
    // window is back-filled, appended, and excluded from has_more.
    final inWindow = window.map((r) => r.id).toSet();
    final backfill = eligible
        .where((r) => r.pinned && !inWindow.contains(r.id))
        .toList();
    // api_server.py:3062-3065 — has_more counts only non-pinned window rows.
    final windowed = window.where((r) => !r.pinned).length;
    return _resp({
      'object': 'list',
      'data': [...window, ...backfill].map(_rowJson).toList(),
      'limit': limit,
      'offset': offset,
      'has_more': windowed >= limit,
    });
  }

  static Map<String, Object> _rowJson(_Row r) => {
        'id': r.id,
        'title': r.id,
        'hidden': r.hidden,
        'pinned': r.pinned,
        'message_count': 0,
        'started_at': 1,
        // The row carries its own last-activity: no per-session probe (P3).
        'last_active': r.activity,
      };

  static PortResponse _resp(Map<String, Object> body) => PortResponse(
        200,
        {'content-type': 'application/json'},
        Stream.value(utf8.encode(jsonEncode(body))),
      );

  @override
  void close() {}
}

class _Repo extends HermesRepository {
  _Repo(HttpPort port) : super('http://test.invalid', 'fake', port: port);
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<bool> health() async => true;
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<List<Message>> messages(String sid,
          {int offset = 0, int limit = 200}) async =>
      const [Message(id: '1', role: 'assistant', content: 'webux2 body')];
  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      const Stream<SseEvent>.empty();
}

Future<ProviderContainer> _boot(WidgetTester tester, _Repo repo,
    {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(
      {for (final e in prefs.entries) e.key: e.value});
  final container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      localStoreProvider.overrideWithValue(
        LocalStore(await SharedPreferences.getInstance()),
      ),
      initialSettingsProvider.overrideWith(
        (ref) => const AppSettings(url: url, key: 'fake'),
      ),
      skillsProvider.overrideWith((ref) async => []),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: localizedWrap(const SessionsPage(), locale: AppLocale.zhHant),
    ),
  );
  // Clock-free pumps only: SessionsPage runs a 30s periodic health timer.
  for (var i = 0; i < 10; i++) {
    await tester.pump();
  }
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('webux2 A: 250 rows across clamped gateway pages all arrive', () async {
    // 250 rows; the pinned row sits OUTSIDE the first window, where the
    // gateway back-fills it (hermes_state_sessions.py:1416) — page 1 then
    // carries 201 rows while has_more stays true. The client must page by
    // the echoed limit (200): page.length (201) would skip r49, and the old
    // `page.length < 500` stop would quit after page 1 at 200 rows.
    // NOTE (second NEEDS_CORE, report §5): a pin INSIDE the window makes the
    // gateway's own has_more undercount (windowed 199 < 200) and page 2 is
    // never fetched by ANY client — no client-side fix exists.
    final db = [
      for (var i = 0; i < 250; i++)
        _Row('r$i', pinned: i == 0, activity: i.toDouble()),
    ];
    final repo = _Repo(_GatewayContractPort(db));
    try {
      final sessions = await repo.sessions();
      expect(sessions.length, 250);
      expect(sessions.map((s) => s.id).toSet(), db.map((r) => r.id).toSet());
    } finally {
      repo.close();
    }
  });

  testWidgets(
    'webux2 A: show-hidden names the gateway policy for withheld ids',
    (tester) async {
      final repo = _Repo(_GatewayContractPort([
        _Row('v1'),
        _Row('h1', hidden: true, activity: 5),
      ]));
      await _boot(tester, repo, prefs: {
        'flutter.hidden.$url': <String>['h1'],
        'flutter.hidden.migrated.$url': true,
      });
      await tester.tap(find.byType(Switch).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      // h1 was known-hidden locally but the gateway never returned it.
      expect(find.byKey(const ValueKey('hidden-not-returned')), findsOneWidget);
      expect(find.textContaining('gateway 政策'), findsOneWidget);
      repo.close();
    },
  );

  // D2 (diagnostic, green before and after): the switch itself does fire the
  // refetch with include_hidden=true; the gateway still withholds h1.
  testWidgets('webux2 A D2: toggle reloads; gateway still withholds hidden',
      (tester) async {
    final port = _GatewayContractPort([
      _Row('v1'),
      _Row('h1', hidden: true),
    ]);
    final repo = _Repo(port);
    await _boot(tester, repo);
    expect(find.text('v1'), findsOneWidget);
    expect(find.text('h1'), findsNothing);
    await tester.tap(find.byType(Switch).first);
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(port.offsets.length, greaterThan(1)); // a refetch did happen
    expect(find.text('h1'), findsNothing); // withheld by the gateway
    repo.close();
  });

  // D4 (diagnostic, green before and after): a row the SERVER lists as
  // visible but the store mirror still marks hidden must be openable; the
  // second reading of the complaint ("listed but can't open") is not a bug.
  testWidgets('webux2 A D4: a store-hidden row the server lists opens',
      (tester) async {
    final repo = _Repo(_GatewayContractPort([
      _Row('m1', activity: 5), // server: hidden=false
    ]));
    await _boot(tester, repo, prefs: {
      'flutter.hidden.$url': <String>['m1'],
      'flutter.hidden.migrated.$url': true,
    });
    await tester.tap(find.byType(Switch).first);
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(find.text('m1'), findsOneWidget); // _effHidden: server wins
    await tester.tap(find.text('m1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // push transition
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.textContaining('webux2 body'), findsWidgets);
    repo.close();
  });
}
