import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/models.dart';

/// 凭据只放 Keychain（需求 §5.1），卸载即随沙盒消失。
class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  static const _key = 'vault.connection';

  final FlutterSecureStorage _storage;

  Future<ConnectionConfig?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ConnectionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> save(ConnectionConfig config) =>
      _storage.write(key: _key, value: jsonEncode(config.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
