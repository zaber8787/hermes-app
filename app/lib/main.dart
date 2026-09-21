import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/settings/local_store.dart';
import 'features/settings/settings_page.dart';
import 'features/sessions/sessions_page.dart';
import 'providers.dart';
import 'diagnostics/diagnostics.dart';
import 'platform/stream_keepalive.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Diagnostics.initialize();
  StreamKeepalive.initialize();
  final store = LocalStore(await SharedPreferences.getInstance());
  var settings = const AppSettings();
  String? error;
  try {
    settings = await store.loadSettings();
  } catch (_) {
    error = '無法讀取安全儲存，請重新輸入連線設定。';
  }
  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(settings),
      ],
      child: HermesApp(initialError: error),
    ),
  );
}

class HermesApp extends ConsumerWidget {
  const HermesApp({super.key, this.initialError});
  final String? initialError;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'Hermes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff72e0be),
          brightness: Brightness.dark,
          surface: const Color(0xff10171d),
        ),
        scaffoldBackgroundColor: const Color(0xff10171d),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xff10171d)),
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xff19232b),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      home: settings.configured
          ? const SessionsPage()
          : SettingsPage(initialError: initialError),
    );
  }
}
