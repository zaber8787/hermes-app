import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

class _PreviewRepo extends HermesRepository {
  _PreviewRepo() : super('http://test.invalid', 'fake');
  final complete = Completer<List<Session>>();

  @override
  Future<void> checkCapabilities() async {}

  @override
  Future<bool> health() async => true;

  @override
  Future<List<Session>> sessions() {
    sessionsPreview.value = const [
      Session(
        id: 's',
        title: 'Ready first page',
        count: 0,
        startedAt: 1,
        activity: 1,
        source: 'api_server',
      ),
    ];
    return complete.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('directory renders first page while complete list is pending', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _PreviewRepo();
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
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('Ready first page'), findsOneWidget);
    repo.complete.complete(repo.sessionsPreview.value!);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    repo.close();
  });
}
