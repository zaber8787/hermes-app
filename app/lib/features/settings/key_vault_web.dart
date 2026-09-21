import 'package:web/web.dart' as web;

import 'key_vault.dart';

/// The browser has no keystore. flutter_secure_storage's web backend uses
/// WebCrypto AES-GCM, but the key must live in the same localStorage, so it
/// is theatre — and it hard-throws outside secure contexts. Plain storage,
/// plainly labelled, is the honest equivalent for a tailscale-only tool.
class LocalKeyVault implements KeyVault {
  static const _prefix = 'hermes.vault.';
  @override
  Future<String?> read(String key) async =>
      web.window.localStorage.getItem('$_prefix$key');
  @override
  Future<void> write(String key, String value) async =>
      web.window.localStorage.setItem('$_prefix$key', value);
}

KeyVault newVault() => LocalKeyVault();
