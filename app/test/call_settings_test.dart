import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/call/call_settings.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';

// PLAN-VOICEUI §6.2 call_settings_test: URL derivation, validation and the
// store/token precedence of resolveCallEndpoint.
class MapVault implements KeyVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  group('deriveVoiceUrl', () {
    test('remote https server gets the tailscale-serve wss front on 10000', () {
      expect(
        deriveVoiceUrl('https://bot.example.ts.net'),
        'wss://bot.example.ts.net:10000/',
      );
      expect(deriveVoiceUrl('https://lan.example.org:8700'),
          'wss://lan.example.org:10000/');
    });

    test('loopback server keeps the direct ws gateway port', () {
      expect(deriveVoiceUrl('http://127.0.0.1:8700'), 'ws://127.0.0.1:18765/');
      expect(deriveVoiceUrl('https://localhost'), 'ws://127.0.0.1:18765/');
      expect(deriveVoiceUrl('http://[::1]:8700'), 'ws://127.0.0.1:18765/');
    });

    test('empty or junk server URL falls back to the loopback default', () {
      expect(deriveVoiceUrl(''), 'ws://127.0.0.1:18765/');
      expect(deriveVoiceUrl('not a url at all %%%'), 'ws://127.0.0.1:18765/');
    });
  });

  group('validateVoiceUrl', () {
    test('wss anywhere, ws on http pages, ws to loopback on https pages', () {
      expect(validateVoiceUrl('wss://h.example/', pageIsHttps: true), isNull);
      expect(validateVoiceUrl('wss://h.example/', pageIsHttps: false), isNull);
      expect(validateVoiceUrl('ws://h.example:18765/', pageIsHttps: false),
          isNull);
      expect(validateVoiceUrl('ws://127.0.0.1:18765/', pageIsHttps: true),
          isNull);
      expect(validateVoiceUrl('ws://localhost/', pageIsHttps: true), isNull);
    });

    test('ws:// from an https page → needsWss (§4.5 mixed content)', () {
      expect(validateVoiceUrl('ws://host:1/', pageIsHttps: true),
          MessageKey.callSettingsNeedsWss);
    });

    test('userinfo/query/fragment, wrong scheme, empty host → invalid', () {
      expect(validateVoiceUrl('wss://u:p@h/', pageIsHttps: false),
          MessageKey.callSettingsUrlInvalid);
      expect(validateVoiceUrl('https://h.example/', pageIsHttps: false),
          MessageKey.callSettingsUrlInvalid);
      expect(validateVoiceUrl('wss:///path', pageIsHttps: false),
          MessageKey.callSettingsUrlInvalid);
      expect(validateVoiceUrl('wss://h/?token=x', pageIsHttps: false),
          MessageKey.callSettingsUrlInvalid);
      expect(validateVoiceUrl('wss://h/#frag', pageIsHttps: false),
          MessageKey.callSettingsUrlInvalid);
      expect(validateVoiceUrl('', pageIsHttps: false),
          MessageKey.callSettingsUrlInvalid);
    });
  });

  group('LocalStore voice fields', () {
    test('url round-trips; null/empty removes; token lives in the vault', () async {
      SharedPreferences.setMockInitialValues({});
      final vault = MapVault();
      final prefs = await SharedPreferences.getInstance();
      final store = LocalStore(prefs, vault: vault);

      expect(store.voiceUrl(), isNull);
      await store.saveVoiceUrl('wss://relay.example:10000/');
      expect(store.voiceUrl(), 'wss://relay.example:10000/');
      await store.saveVoiceUrl('');
      expect(store.voiceUrl(), isNull);
      await store.saveVoiceUrl('wss://x/');
      await store.saveVoiceUrl(null);
      expect(store.voiceUrl(), isNull);

      expect(await store.voiceToken(), '');
      await store.saveVoiceToken('vk-123');
      expect(await store.voiceToken(), 'vk-123');
      expect(vault.values['voice.token'], 'vk-123');
      // never in prefs, and server.key is untouched by voice writes:
      expect(prefs.getString('voice.token'), isNull);
      expect(vault.values.containsKey('server.key'), isFalse);
    });
  });

  group('resolveCallEndpoint', () {
    SharedPreferences.setMockInitialValues({});
    Future<LocalStore> fresh() async =>
        LocalStore(await SharedPreferences.getInstance(), vault: MapVault());

    test('blank vault token falls back to the Hermes API key (D7)', () async {
      final store = await fresh();
      final e = await resolveCallEndpoint(
        store,
        const AppSettings(url: 'https://srv.example', key: 'hermes-key'),
      );
      expect(e.token, 'hermes-key');
      expect(e.url.toString(), 'wss://srv.example:10000/');
    });

    test('stored voice.token wins over the API key', () async {
      final store = await fresh();
      await store.saveVoiceToken('vg-only');
      final e = await resolveCallEndpoint(
        store,
        const AppSettings(url: 'http://127.0.0.1:8700', key: 'hermes-key'),
      );
      expect(e.token, 'vg-only');
      expect(e.url.toString(), 'ws://127.0.0.1:18765/');
    });

    test('stored voice.url wins over the derived default', () async {
      final store = await fresh();
      await store.saveVoiceUrl('wss://alt.example:10000/');
      final e = await resolveCallEndpoint(
        store,
        const AppSettings(url: 'https://srv.example', key: 'k'),
      );
      expect(e.url.toString(), 'wss://alt.example:10000/');
    });
  });
}
