import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/models.dart';

/// 本机保存的多个账号（需求：可登录两个账号，并在设置里切换当前用哪一个）。
///
/// 整个列表连同「当前是哪一个」放在 Keychain 的一个键里，卸载即随沙盒消失。
/// 账号身份用 `type|baseUrl|username` 判定，同 id 覆盖、不同 id 追加，
/// 这样重连同一个服务器+账号不会产生重复条目。
class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  static const _key = 'vault.accounts';
  static const _legacyKey = 'vault.connection';

  final FlutterSecureStorage _storage;

  static String idOf(ConnectionConfig c) => '${c.type.name}|${c.baseUrl}|${c.username}';

  Future<_Vault> _read() async {
    final raw = await _storage.read(key: _key);
    if (raw != null && raw.isNotEmpty) {
      try {
        return _Vault.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } on Object {
        // 解不出来就当作没有，别把 App 卡死在启动。
      }
    }
    // 迁移旧版单账号键。
    final legacy = await _storage.read(key: _legacyKey);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        final one = ConnectionConfig.fromJson(jsonDecode(legacy) as Map<String, dynamic>);
        final vault = _Vault(accounts: [one], current: 0);
        await _write(vault);
        await _storage.delete(key: _legacyKey);
        return vault;
      } on Object {
        // 旧键也坏了就忽略。
      }
    }
    return _Vault.empty();
  }

  Future<void> _write(_Vault vault) => _storage.write(key: _key, value: jsonEncode(vault.toJson()));

  Future<List<ConnectionConfig>> loadAll() async => (await _read()).accounts;

  /// 当前账号：越界自动夹回，空则 null。
  Future<ConnectionConfig?> current() async {
    final vault = await _read();
    if (vault.accounts.isEmpty) return null;
    return vault.accounts[vault.current.clamp(0, vault.accounts.length - 1)];
  }

  Future<int> currentId() async {
    final vault = await _read();
    if (vault.accounts.isEmpty) return -1;
    return vault.current.clamp(0, vault.accounts.length - 1);
  }

  /// 记住/更新一个账号，并把它设为当前。
  Future<void> saveAccount(ConnectionConfig config) async {
    final vault = await _read();
    final list = [...vault.accounts];
    final id = idOf(config);
    final idx = list.indexWhere((e) => idOf(e) == id);
    if (idx >= 0) {
      list[idx] = config;
    } else {
      list.add(config);
    }
    await _write(_Vault(accounts: list, current: list.length - 1));
  }

  /// 删除指定下标并修正 current 指针。删掉的是不是「当前」交给调用方判断，
  /// 这里只保证指针不越界。
  Future<void> removeAt(int index) async {
    final vault = await _read();
    final list = [...vault.accounts];
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    if (list.isEmpty) {
      await _write(_Vault.empty());
      return;
    }
    // 删的是当前：留在原位（原来的下一个顶上来），越界则退一格；
    // 删的不是当前：当前在它之后就前移一格，否则不动。
    final wasCurrent = index == vault.current;
    final current = wasCurrent
        ? index.clamp(0, list.length - 1)
        : (index < vault.current ? vault.current - 1 : vault.current);
    await _write(_Vault(accounts: list, current: current));
  }

  Future<void> clear() => _storage.delete(key: _key);
}

class _Vault {
  _Vault({required this.accounts, required this.current});
  _Vault.empty() : accounts = const [], current = 0;

  final List<ConnectionConfig> accounts;
  final int current;

  factory _Vault.fromJson(Map<String, dynamic> json) {
    final accounts = (json['accounts'] as List<dynamic>? ?? const [])
        .map((e) => ConnectionConfig.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((c) => c.baseUrl.isNotEmpty)
        .toList();
    final current = (json['current'] as num?)?.toInt() ?? 0;
    return _Vault(accounts: accounts, current: current);
  }

  Map<String, dynamic> toJson() => {
        'accounts': accounts.map((e) => e.toJson()).toList(),
        'current': current,
      };
}
