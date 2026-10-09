import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/chat/deep_link_ingress.dart';
import 'package:hermes_app/features/chat/run_link.dart';
import 'package:hermes_app/features/settings/local_store.dart';

/// NOTIF2 B2: the NATIVE deep-link ingress (app_links stream) must feed the
/// EXISTING navigation pipeline (RunLink.parse -> route), cold and warm,
/// with the stash for pre-login links, a queue instead of a drop while a
/// route is busy, and NO permanent URL dedup.

const serverCanonical =
    'https://entry.example.com/#/chat?session=s%2F1&run=r9&event=e7&request=q3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late StreamController<String> source;
  late DeepLinkIngress ingress;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    source = StreamController<String>();
    ingress = DeepLinkIngress()..start(source.stream, store);
  });
  tearDown(() async {
    ingress.dispose();
    await source.close();
  });

  group('one canonical URL shape on every platform', () {
    test('the server run_link parses to exact, decoded ids', () {
      // compat/notification_events.py run_link(): click_base + '/#/chat?' +
      // session/run/event/request — the SAME parser serves web and native.
      final link = RunLink.tryParse(serverCanonical)!;
      expect(link.sessionId, 's/1'); // percent-decoded verbatim
      expect(link.runId, 'r9');
      expect(link.eventId, 'e7');
      expect(link.requestId, 'q3');
    });

    test('a path-style /run URL is NOT a protocol and parses to nothing', () {
      // The manifest host/path alignment keeps ONE canonical shape; a bare
      // /run?session=.. must never be half-supported on one platform only.
      expect(RunLink.tryParse('https://h/run?session=s&run=r'), isNull);
    });

    test('a secret-bearing href parses to nothing', () {
      expect(
        RunLink.tryParse('https://h/#/chat?session=s&token=SECRET'),
        isNull,
      );
    });
  });

  group('cold start before any router exists', () {
    test('the first link waits in the stash and routes exactly once', () async {
      source.add(serverCanonical);
      await pumpEventQueue();
      expect(store.peekDeepLink(), serverCanonical);

      final seen = <RunLink>[];
      ingress.attach((link) async => seen.add(link));
      await pumpEventQueue();
      expect(store.peekDeepLink(), isNull); // spent ONCE by the handoff
      expect(seen.length, 1);
      expect(seen.single.sessionId, 's/1');
      expect(seen.single.runId, 'r9');
      expect(seen.single.eventId, 'e7');
      expect(seen.single.requestId, 'q3');

      await pumpEventQueue();
      expect(seen.length, 1); // no repeat, no re-read surprise
    });

    test('a junk href before login stashes nothing and never throws',
        () async {
      source.add('https://h/#/chat?session=s&apikey=BAD');
      source.add('not a url at all');
      await pumpEventQueue();
      expect(store.peekDeepLink(), isNull);
      ingress.attach((link) async {});
      await pumpEventQueue();
      expect(store.peekDeepLink(), isNull);
    });
  });

  group('warm start with a router attached', () {
    test('later links route immediately without touching the stash', () async {
      final seen = <String>[];
      ingress.attach((link) async => seen.add(link.sessionId));
      source.add(serverCanonical);
      await pumpEventQueue();
      expect(seen, ['s/1']);
      expect(store.peekDeepLink(), isNull);
    });

    test('a link arriving while a route is busy is QUEUED, never dropped',
        () async {
      final done = <String>[];
      final first = Completer<void>();
      ingress.attach((link) async {
        if (link.runId == 'r9') await first.future; // route one hangs
        done.add(link.runId ?? '?');
      });
      source.add(serverCanonical); // run=r9 hangs inside the router
      await pumpEventQueue();
      source.add(
        'https://entry.example.com/#/chat?session=s%2F1&run=r10',
      );
      await pumpEventQueue();
      expect(done, isEmpty); // still busy — the second link WAITS

      first.complete();
      await pumpEventQueue();
      expect(done, ['r9', 'r10']); // ordered, nothing dropped
    });

    test('the same notification tapped later navigates AGAIN (no URL dedup)',
        () async {
      final done = <int>[];
      ingress.attach((link) async => done.add(1));
      source.add(serverCanonical);
      await pumpEventQueue();
      source.add(serverCanonical); // deliberate second tap, minutes later
      await pumpEventQueue();
      expect(done.length, 2);
    });

    test('detached (settings open), links wait in the stash, not the void',
        () async {
      ingress.attach((link) async {});
      ingress.detach();
      source.add(serverCanonical);
      await pumpEventQueue();
      expect(store.peekDeepLink(), serverCanonical);
    });
  });
}
