import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/providers.dart';
import 'support/localized_app.dart';

class _SessionPort implements HttpPort {
  int requests = 0;
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
    final rows = <Map<String, Object>>[];
    if (uri.path == '/api/sessions') {
      requests++;
      rows.add({
        'id': 'visible',
        'title': 'Visible session',
        'hidden': false,
        'message_count': 0,
        'started_at': 1,
      });
      // Initial snapshot has only visible rows. Reload must opt into hidden.
      if (requests > 1 && uri.queryParameters['include_hidden'] == 'true') {
        rows.add({
          'id': 'hidden',
          'title': 'Hidden session',
          'hidden': true,
          'message_count': 0,
          'started_at': 1,
        });
      }
    }
    return PortResponse(200, {
      'content-type': 'application/json',
    }, Stream.value(utf8.encode(jsonEncode({'data': rows}))));
  }

  @override
  void close() {}
}

class _Repo extends HermesRepository {
  _Repo(_SessionPort port) : super('http://test.invalid', 'fake', port: port);
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<bool> health() async => true;
}

void main() {
  testWidgets(
    'show hidden reloads an inclusive list and reveals hidden session',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final port = _SessionPort();
      final repo = _Repo(port);
      final container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          localStoreProvider.overrideWithValue(
            LocalStore(await SharedPreferences.getInstance()),
          ),
          initialSettingsProvider.overrideWith(
            (ref) => const AppSettings(url: 'http://test.invalid', key: 'fake'),
          ),
          skillsProvider.overrideWith((ref) async => []),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(const SessionsPage()),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(find.text('Visible session'), findsOneWidget);
      expect(find.text('Hidden session'), findsNothing);
      await tester.tap(find.byType(Switch).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(port.requests, greaterThan(1));
      expect(find.text('Hidden session'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      repo.close();
    },
  );
}
