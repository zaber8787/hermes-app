/// Voice-call endpoint resolution (PLAN-VOICEUI §4.5). Pure logic over
/// LocalStore/AppSettings; nothing here hardcodes any operator's host —
/// a tailnet hostname in this file is exactly the android_manifest_test
/// hazard moved one layer in (call_source_hygiene_test enforces it).
library;

import '../../l10n/message_key.dart';
import '../settings/local_store.dart';

const _loopbackHosts = {'127.0.0.1', 'localhost', '::1'};

/// Default call URL derived from the server URL: a loopback server means
/// the App and gateway share the Mac (direct ws on the gateway port);
/// anything else goes through the tailscale-serve wss front on :10000
/// (§3.3/D4/D5). A junk/empty server URL lands on the loopback default —
/// the dialog re-validates before use either way.
String deriveVoiceUrl(String serverUrl) {
  String host = '';
  try {
    host = Uri.parse(serverUrl.trim()).host;
  } on FormatException {
    host = '';
  }
  if (host.isEmpty) return 'ws://127.0.0.1:18765/';
  if (_loopbackHosts.contains(host)) return 'ws://127.0.0.1:18765/';
  return 'wss://$host:10000/';
}

/// null = acceptable; otherwise the MessageKey naming the failure (§4.8).
/// Rules (§4.5): ws/wss only, non-empty host, no userinfo/query/fragment;
/// an https page may not open a non-loopback ws:// (mixed content).
MessageKey? validateVoiceUrl(String raw, {required bool pageIsHttps}) {
  Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    return MessageKey.callSettingsUrlInvalid;
  }
  final scheme = uri.scheme;
  if (scheme != 'ws' && scheme != 'wss') return MessageKey.callSettingsUrlInvalid;
  if (uri.host.isEmpty) return MessageKey.callSettingsUrlInvalid;
  if (uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return MessageKey.callSettingsUrlInvalid;
  }
  if (pageIsHttps &&
      scheme == 'ws' &&
      !_loopbackHosts.contains(uri.host)) {
    return MessageKey.callSettingsNeedsWss;
  }
  return null;
}

/// Effective endpoint: stored `voice.url` wins over the derived default;
/// vault `voice.token` wins over the Hermes API key (§4.5, D7 — reusing
/// the API key means zero extra setup when the gateway reads the same
/// HERMES_API_KEY). Never logs or returns the token to any UI layer.
Future<({Uri url, String token})> resolveCallEndpoint(
  LocalStore store,
  AppSettings settings,
) async {
  final stored = (store.voiceUrl() ?? '').trim();
  final raw = stored.isNotEmpty ? stored : deriveVoiceUrl(settings.url);
  final storedToken = await store.voiceToken();
  return (
    url: Uri.parse(raw),
    token: storedToken.isNotEmpty ? storedToken : settings.key,
  );
}

// TODO(call7b): showCallSettingsDialog — the gear dialog over the call
// entry points (§4.5/D17; deliberately NOT in SettingsPage so existing
// find.byType(TextField) settings tests keep their indices). UI rod.
