import 'dart:convert';
import 'dart:io';
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
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// OPENPERF P4 (定案1 防回退): the durable timeline must stay a row list.
/// Baseline f134e52 mounted ALL 200 EntryViews on first build (native
/// ~1886 ms / Chrome ~4863 ms debug — .perf-scratch/render-probe.log).
/// These pins are deliberately relaxed (CI varies); they only catch a
/// regression BACK to eager full-Column mounting: a first build that
/// mounts the whole page, or one that pays full-markdown layout for every
/// swept row during the cold-open jump.
class FakeOpenRepo extends HermesRepository {
  FakeOpenRepo() : super('http://test.invalid', 'fake');

  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = const [];

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async => {
    'id': sid,
    'message_count': 0, // P1 harness shape
  };

  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      events.stream;

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => offset == 0 ? history : const [];
}

void main() {
 testWidgets('400 real detailed messages land on visible text', (tester) async {
 SharedPreferences.setMockInitialValues({});
 final store = LocalStore(await SharedPreferences.getInstance());
 await store.setDetailed('http://test.invalid', 's', true);
 final repo = FakeOpenRepo();
 final raw = jsonDecode(File('test/fixtures/detailblackout_real_msgs.json').readAsStringSync()) as List;
 expect(raw, hasLength(400));
 repo.history = raw.map((r) => Message.fromJson({...Map<String, dynamic>.from(r as Map), 'tool_name': r['tool'], 'timestamp': r['ts']})).toList();
 final container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store), initialSettingsProvider.overrideWithValue(const AppSettings(url: 'http://test.invalid', key: 'fake')), repositoryProvider.overrideWithValue(repo), skillsProvider.overrideWith((ref) async => [])]);
 await tester.pumpWidget(UncontrolledProviderScope(container: container, child: localizedWrap(ChatPage(session: Session(id: 's', title: 'Real', count: 400, startedAt: 0, activity: 0, source: 'api_server')), locale: AppLocale.zhHant)));
 await tester.pumpAndSettle(const Duration(milliseconds: 50));
 final viewport = tester.getRect(find.byType(CustomScrollView).first);
 final visible = find.byType(EntryView).evaluate().where((element) {
 final box = element.renderObject;
 if (box is! RenderBox || !box.attached || !box.hasSize) return false;
 if (!viewport.overlaps(box.localToGlobal(Offset.zero) & box.size)) return false;
 return find.descendant(of: find.byWidget(element.widget), matching: find.byType(RichText)).evaluate().any((e) => (e.widget as RichText).text.toPlainText().trim().isNotEmpty);
 }).length;
 expect(visible, greaterThan(0), reason: 'landed viewport must contain real message text');
 expect(tester.takeException(), isNull);
 await tester.pumpWidget(const SizedBox()); container.dispose(); unawaited(repo.events.close()); repo.close();
 });
}
