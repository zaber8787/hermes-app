import 'key_vault_io.dart' if (dart.library.js_interop) 'key_vault_web.dart'
    as impl;

/// Secret storage split: platform keystore on devices, localStorage on the
/// web (where any "encryption" key would sit next to the ciphertext anyway).
abstract class KeyVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

KeyVault newKeyVault() => impl.newVault();
