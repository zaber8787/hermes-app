import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/chat/deep_link.dart';
import 'package:hermes_app/features/chat/run_link.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session.dart';

/// 01412FIX F5 (M6): the RunLink CONSUMER contract — exact identity, honest
/// refusals (deleted / wrong profile / hidden), one-stash-one-navigation.
Session s(String id, {bool? hidden}) => Session(
  id: id,
  title: id,
  count: 1,
  startedAt: 1,
  activity: 1,
  source: 'api_server',
  hidden: hidden,
);

void main() {
  group('resolveDeepLink (exact identity)', () {
    test('the exact session opens, carrying run/event/request verbatim', () {
      final link = RunLink.tryParse(
        'https://host/#/chat?session=s%2F1&run=r9&event=e7&request=q3',
      )!;
      final route = resolveDeepLink(link, [s('other'), s('s/1')]);
      expect(route.opened, isTrue);
      expect(route.session!.id, 's/1'); // percent-decoded EXACT match
      expect(route.link.runId, 'r9');
      expect(route.link.eventId, 'e7');
      expect(route.link.requestId, 'q3');
    });

    test('a deleted or other-profile session is refused, never guessed', () {
      final route = resolveDeepLink(
        RunLink(sessionId: 'gone-sid'),
        [s('a'), s('b')],
      );
      expect(route.status, DeepLinkStatus.sessionNotFound);
      expect(route.session, isNull);
    });

    test('hidden sessions are refused (flag AND caller rule)', () {
      final link = RunLink(sessionId: 'h');
      expect(
        resolveDeepLink(link, [s('h', hidden: true)]).status,
        DeepLinkStatus.sessionHidden,
      );
      // the page's ONE effective-hidden rule (server field + local mirror)
      // outranks an unknown server field:
      expect(
        resolveDeepLink(link, [s('h')], hiddenOf: (_) => true).status,
        DeepLinkStatus.sessionHidden,
      );
    });

    test('a secret-carrying link never reaches the resolver at all', () {
      expect(
        RunLink.tryParse('https://h/#/chat?session=s&topic=SECRET'),
        isNull,
      );
    });
  });

  group('launch capture + login handoff', () {
    test('native Uri.base never captures', () {
      // VM/file base: captureLaunchLink() = null (no web address bar).
      expect(captureLaunchLink(), isNull);
    });

    test('the stash spends a link exactly once', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.peekDeepLink(), isNull);
      final url = const RunLink(
        sessionId: 's 1',
        runId: 'r',
        eventId: 'e',
      ).toUrl();
      await store.stashDeepLink(url);
      expect(store.peekDeepLink(), url);
      await store.clearDeepLink();
      expect(store.peekDeepLink(), isNull); // spent — never a second jump
    });
  });
}
