/// Voice-call endpoint resolution (PLAN-VOICEUI §4.5). Pure logic over
/// LocalStore/AppSettings; nothing here hardcodes any operator's host —
/// a tailnet hostname in this file is exactly the android_manifest_test
/// hazard moved one layer in (call_source_hygiene_test enforces it).
/// The gear dialog lives at the bottom of this file (call7c): D17 keeps
/// it OUT of SettingsPage so existing find.byType(TextField) settings
/// tests keep their indices.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../providers.dart';
import '../settings/local_store.dart';
import 'call_audio.dart';
import 'call_providers.dart';

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

/// MICPICK R1: a device the platform would not name is "Microphone N",
/// numbered by its position in the list (1-based).
String micDisplayName(AppStrings strings, AudioInputDevice device, int index) =>
    device.label.isNotEmpty
    ? device.label
    : strings.resolve(MessageKey.callMicNumbered, args: {'n': index + 1});

/// The gear dialog over the call entry points (§4.5/D17). Two fields only:
/// the override URL (blank = derive from the server URL) and the vault
/// token (blank = reuse the Hermes API key, D7). An invalid URL is caught
/// HERE, before any socket opens — the error line resolves a MessageKey at
/// paint time so an open dialog follows a language switch.
Future<void> showCallSettingsDialog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(
      context: context,
      builder: (_) => CallSettingsDialog(
        store: ref.read(localStoreProvider),
        serverUrl: ref.read(settingsProvider).url,
        audioFactory: ref.read(callAudioFactoryProvider),
      ),
    );

/// Public only so widget tests can mount it without a provider scope.
class CallSettingsDialog extends StatefulWidget {
  const CallSettingsDialog({
    super.key,
    required this.store,
    required this.serverUrl,
    this.audioFactory,
  });
  final LocalStore store;
  final String serverUrl;

  /// MICPICK R1: a throwaway audio seam used only to ask permission and
  /// enumerate inputs (stopped right after); null hides the mic picker.
  final CallAudio Function()? audioFactory;

  @override
  State<CallSettingsDialog> createState() => _CallSettingsDialogState();
}

class _CallSettingsDialogState extends State<CallSettingsDialog> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  MessageKey? _urlError;

  // MICPICK R1/R2: null = system default; the saved id stays untouched
  // unless the user actually picks something (_micTouched).
  String? _micId;
  bool _micTouched = false;
  bool _micLoading = true;
  bool _micPermitted = false;
  List<AudioInputDevice> _mics = const [];

  @override
  void initState() {
    super.initState();
    _url.text = widget.store.voiceUrl() ?? '';
    _token.text = ''; // vault read is async; empty = "keep current/derived"
    _micId = widget.store.voiceMicId();
    unawaited(_loadToken());
    unawaited(_loadMics());
  }

  /// Permission first (the existing ensurePermission flow): before it a
  /// browser enumerates only anonymous rows, so a refusal shows the
  /// "visible after granting" hint instead of a list of blanks.
  Future<void> _loadMics() async {
    final factory = widget.audioFactory;
    if (factory == null) return;
    final probe = factory();
    var permitted = false;
    var mics = const <AudioInputDevice>[];
    try {
      permitted = await probe.ensurePermission() == MicPermission.granted;
      if (permitted) mics = await probe.listInputs();
    } catch (_) {
      permitted = false;
    } finally {
      // the probe must never keep the mic open behind the dialog
      unawaited(probe.stop().catchError((Object _) {}));
    }
    if (!mounted) return;
    setState(() {
      _micLoading = false;
      _micPermitted = permitted;
      _mics = mics;
    });
  }

  Future<void> _loadToken() async {
    final stored = await widget.store.voiceToken();
    if (mounted) setState(() => _token.text = stored);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _url.text.trim();
    if (raw.isNotEmpty) {
      final error = validateVoiceUrl(
        raw,
        pageIsHttps: kIsWeb && Uri.base.scheme == 'https',
      );
      if (error != null) {
        setState(() => _urlError = error);
        return;
      }
    }
    await widget.store.saveVoiceUrl(raw);
    await widget.store.saveVoiceToken(_token.text.trim());
    if (_micTouched) await widget.store.saveVoiceMicId(_micId);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return AlertDialog(
      key: const ValueKey('call.settings.dialog'),
      title: Text(strings.resolve(MessageKey.callSettingsTitle)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('call.settings.url'),
            controller: _url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: strings.resolve(MessageKey.callSettingsUrl),
              helperText: _urlError == null
                  ? deriveVoiceUrl(widget.serverUrl)
                  : strings.resolve(_urlError!),
              helperStyle: _urlError == null
                  ? null
                  : const TextStyle(color: Colors.redAccent),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('call.settings.token'),
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: strings.resolve(MessageKey.callSettingsToken),
              helperText: strings.resolve(MessageKey.callSettingsTokenHint),
            ),
          ),
          if (widget.audioFactory != null) ...[
            const SizedBox(height: 12),
            _micPicker(strings),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.resolve(MessageKey.commonCancel)),
        ),
        FilledButton(
          key: const ValueKey('call.settings.save'),
          onPressed: _save,
          child: Text(strings.resolve(MessageKey.commonSave)),
        ),
      ],
    );
  }

  Widget _micPicker(AppStrings strings) {
    // R4: a saved id that is not in the list shows as system default; a
    // dropdown value with no matching item would assert, i.e. crash
    final value = resolveInputDevice(_micId, _mics);
    final String? helper;
    if (_micLoading) {
      helper = null;
    } else if (!_micPermitted) {
      helper = strings.resolve(MessageKey.callMicNeedsPermission);
    } else if (_micId != null && value == null) {
      helper = strings.resolve(MessageKey.callMicFallback);
    } else {
      helper = null;
    }
    return InputDecorator(
      decoration: InputDecoration(
        labelText: strings.resolve(MessageKey.callMicLabel),
        helperText: helper,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          key: const ValueKey('call.settings.mic'),
          value: value,
          isExpanded: true,
          isDense: true,
          items: [
            DropdownMenuItem<String?>(
              key: const ValueKey('call.settings.mic.default'),
              value: null,
              child: Text(strings.resolve(MessageKey.callMicDefault)),
            ),
            for (final (i, d) in _mics.indexed)
              DropdownMenuItem<String?>(
                key: ValueKey('call.settings.mic.${d.id}'),
                value: d.id,
                child: Text(
                  micDisplayName(strings, d, i),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _micPermitted
              ? (id) => setState(() {
                  _micId = id;
                  _micTouched = true;
                })
              : null,
        ),
      ),
    );
  }
}
