import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/clarify_inbox.dart';
import 'package:hermes_app/features/chat/clarify_inbox_view.dart';
import 'package:hermes_app/features/settings/local_store.dart';

class SpyPort implements HttpPort {
  final posts = <String>[];
  final paths = <String>[];
  bool fail = false;
  int status = 200;
  @override
  Future<PortResponse> send(String method, Uri uri, {
    Map<String, String> headers = const {}, Stream<List<int>>? body,
    int? contentLength, Future<void>? abortTrigger, Duration? headersTimeout,
    DispatchObservation? observation,
  }) async {
    paths.add('$method ${uri.path}');
    if (method == 'POST') posts.add(await utf8.decoder.bind(body!).join());
    return PortResponse(fail ? 409 : status, {'content-type': 'application/json'},
      Stream.value(utf8.encode(method == 'GET' ? '{"pending":[]}' : fail
        ? '{"detail":{"code":"clarify_choice_required","qid":"q1"}}' : '{}')));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, dynamic> request({bool multi = false, List<String>? choices}) => {
  'clarify_id': 'q1', 'session_id': 's1', 'run_id': null,
  'questions': [{'qid': 'q1', 'question': '選擇路徑',
    'choices': choices ?? ['甲', '乙', 'Other', 'skip'], 'multi_select': multi}], 'timeout_seconds': 30, 'issued_at': 100.0,
};

void main() {
  test('reconnect replay and GET preserve identity and answered tombstone', () {
    final inbox = ClarifyInbox()..request(request());
    final first = inbox.entries.single;
    inbox.mergeSnapshot({'pending': [request()]});
    expect(identical(first, inbox.entries.single), isTrue);
    inbox.resolve({'clarify_id': 'q1', 'outcome': 'answered', 'answers': {'q1': '甲'}});
    inbox.request(request());
    expect(inbox.entries, hasLength(1));
    expect(inbox.pending, isEmpty);
    expect(first.answers, {'q1': '甲'});
  });

  for (final mode in ['single', 'other', 'multi', 'skip', 'free']) {
    testWidgets('$mode event card tap sends exact POST payload', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final port = SpyPort();
      final controller = ChatController(
        HermesRepository('http://x.test', 'k', port: port),
        LocalStore(await SharedPreferences.getInstance()), 's1');
      addTearDown(controller.dispose);
      controller.clarifyInbox.request(request(multi: mode == 'multi',
        choices: mode == 'free' ? [] : null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AnimatedBuilder(
        animation: controller, builder: (_, _) => ClarifyInboxView(
          requests: controller.clarifyInbox.entries, onAnswer: controller.answerClarify)))));
      expect(find.text('選擇路徑'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'skip'), findsNothing);
      String expected;
      if (mode == 'single') {
        expected = '甲';
        await tester.tap(find.text('甲'));
        await tester.pump();
        expect(port.posts, isEmpty);
        await tester.tap(find.text('送出'));
      } else if (mode == 'multi') {
        expected = '甲,乙';
        await tester.tap(find.text('乙')); await tester.pump();
        await tester.tap(find.text('甲')); await tester.pump();
        await tester.tap(find.text('送出'));
      } else {
        if (mode != 'free') { await tester.tap(find.text('其他')); await tester.pump(); }
        final value = mode == 'skip' ? 'skip' : '保留 原文';
        expected = mode == 'other' ? 'other:$value' : value;
        await tester.enterText(find.byType(TextField), value);
        await tester.pump(); await tester.tap(find.text('送出'));
      }
      await tester.pumpAndSettle();
      expect(port.posts, [jsonEncode({'answers': {'q1': expected}})]);
      expect(port.paths, contains('POST /v1/sessions/s1/clarify/q1'));
      expect(controller.clarifyInbox.pending, isEmpty);
    });
  }

  testWidgets('timeout is a one-line summary and cannot replay pending', (tester) async {
    final inbox = ClarifyInbox()..request(request());
    inbox.resolve({'clarify_id': 'q1', 'outcome': 'timed_out'});
    inbox.request(request());
    await tester.pumpWidget(MaterialApp(home: ClarifyInboxView(
      requests: inbox.entries, onAnswer: (_, _) async => fail('must not answer'))));
    expect(find.text('選擇路徑 · 已逾時'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('busy lock prevents double POST; failure retains card for retry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final port = SpyPort()..fail = true;
    final controller = ChatController(
      HermesRepository('http://x.test', 'k', port: port),
      LocalStore(await SharedPreferences.getInstance()), 's1');
    addTearDown(controller.dispose);
    controller.clarifyInbox.request(request());
    final first = controller.answerClarify('q1', {'q1': '甲'});
    final duplicate = controller.answerClarify('q1', {'q1': '乙'});
    await Future.wait([first, duplicate]);
    expect(port.posts, [jsonEncode({'answers': {'q1': '甲'}})]);
    final entry = controller.clarifyInbox.entries.single;
    expect(entry.pending, isTrue);
    expect(entry.busy, isFalse);
    expect(entry.error, isNotNull);
    expect(entry.invalidQids, {'q1'});
    await tester.pumpWidget(MaterialApp(home: ClarifyInboxView(
      requests: [entry], onAnswer: controller.answerClarify)));
    expect(find.byKey(const ValueKey('clarify-error-q1')), findsOneWidget);
    port.fail = false;
    await controller.answerClarify('q1', {'q1': '乙'});
    expect(port.posts.last, jsonEncode({'answers': {'q1': '乙'}}));
    expect(entry.pending, isFalse);
  });

  testWidgets('form requires every question and sends one exact answers map', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final port = SpyPort();
    final controller = ChatController(
      HermesRepository('http://x.test', 'k', port: port),
      LocalStore(await SharedPreferences.getInstance()), 's1');
    addTearDown(controller.dispose);
    final data = request();
    data['questions'] = <Object?>[...(data['questions'] as List),
      <String, Object?>{'qid': 'q2', 'question': '補充說明',
        'choices': null, 'multi_select': false}];
    controller.clarifyInbox.request(data);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AnimatedBuilder(
      animation: controller, builder: (_, _) => ClarifyInboxView(
        requests: controller.clarifyInbox.entries, onAnswer: controller.answerClarify)))));
    expect(find.text('補充說明'), findsOneWidget);
    await tester.tap(find.text('甲'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '送出')).onPressed, isNull);
    await controller.answerClarify('q1', {'q1': '甲'});
    expect(port.posts, isEmpty);
    await tester.enterText(find.byType(TextField), 'skip');
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(port.posts, ['{"answers":{"q1":"甲","q2":"skip"}}']);
    expect(controller.clarifyInbox.entries.single.answers, {'q1': '甲', 'q2': 'skip'});
  });

  testWidgets('five questions render together with one submit button', (tester) async {
    final data = request();
    data['questions'] = [for (var i = 1; i <= 5; i++)
      {'qid': 'q$i', 'question': '題目$i', 'choices': null, 'multi_select': false}];
    final inbox = ClarifyInbox()..request(data);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ClarifyInboxView(requests: inbox.entries, onAnswer: (_, _) async {})))));
    for (var i = 1; i <= 5; i++) {
      expect(find.text('題目$i'), findsOneWidget);
    }
    expect(find.byType(TextField), findsNWidgets(5));
    expect(find.widgetWithText(FilledButton, '送出'), findsOneWidget);
  });

  test('404 collapses an already resolved form', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(
      HermesRepository('http://x.test', 'k', port: SpyPort()..status = 404),
      LocalStore(await SharedPreferences.getInstance()), 's1');
    addTearDown(controller.dispose);
    controller.clarifyInbox.request(request());
    await controller.answerClarify('q1', {'q1': '甲'});
    expect(controller.clarifyInbox.pending, isEmpty);
    expect(controller.clarifyInbox.entries.single.outcome, 'answered');
  });

  test('resolution preceding replay is retained', () {
    final inbox = ClarifyInbox();
    inbox.resolve({'clarify_id': 'q1', 'outcome': 'cancelled'});
    inbox.request(request());
    expect(inbox.pending, isEmpty);
  });
}
