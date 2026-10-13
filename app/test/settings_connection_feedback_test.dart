import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/features/settings/settings_page.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

class _AuthFailureRepo extends HermesRepository {
  _AuthFailureRepo() : super('http://test.invalid', 'fake');

  @override
  Future<void> checkCapabilities() async =>
      throw const ApiException.local(MessageKey.apiM006, status: 401);

  @override
  Future<Map<String, dynamic>?> autoWakeFeature() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('connection test shows typed authentication failure', (
    tester,
  ) async {
    final repo = _AuthFailureRepo();
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: 'http://test.invalid', key: 'fake'),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(SettingsPage(repositoryFactory: (_, _) => repo)),
      ),
    );
    final button = find.text('Test connection');
    await tester.scrollUntilVisible(
      button,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pump();
    expect(find.text('Key rejected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    repo.close();
  });
}
