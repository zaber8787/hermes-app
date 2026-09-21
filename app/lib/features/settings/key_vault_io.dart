import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_vault.dart';

class SecureKeyVault implements KeyVault {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

KeyVault newVault() => SecureKeyVault();
