// OFFLINE-SEND §7.1 browser harness: runs the REAL ChatPage / ChatController /
// HermesRepository / LocalStore / attachment pipeline against the ledger
// fixture — no send logic is duplicated here; the only substitutions are the
// test server URL and a fake key.
//
// Run (two terminals, commands from the app/ directory):
//   ../toolchain/flutter/bin/dart run test/support/offline_ledger_server.dart --port 18701
//   ../toolchain/flutter/bin/flutter run -d web-server --web-port 18700 -t test/support/offline_browser_harness.dart
//
// Then open http://localhost:18700 and drive B1–B4 of the matrix. The ledger
// counters live at http://127.0.0.1:18701/__test/ledger; reset per sub-case
// with `curl -XPOST 'http://127.0.0.1:18701/__test/reset?mode=success'`.
// Record the fake sid (ledger-sid) only — never real keys or headers.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'localized_app.dart' show localizedWrap;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = LocalStore(await SharedPreferences.getInstance());
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(store),
      // The ONLY substitutions (§7.1): test-server URL + fake key.
      initialSettingsProvider.overrideWithValue(
        const AppSettings(url: 'http://127.0.0.1:18701', key: 'fake'),
      ),
    ],
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: localizedWrap(
        locale: store.loadLocale(),
        ChatPage(
          // The fixture's fixed sid (ledger-sid) — never a real session.
          session: const Session(
            id: 'ledger-sid',
            title: 'ledger',
            count: 0,
            startedAt: 1,
            activity: 0,
            source: 'api_server',
          ),
        ),
      ),
    ),
  );
}
