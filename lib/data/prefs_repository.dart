import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

/// 设置与隐藏目录列表（需求 §5.2）。
///
/// 隐藏列表在这里持久化，隐藏模式开关本身只在内存里 —— 重启即关闭（§4.4）。
class PrefsRepository {
  PrefsRepository(this._prefs);

  static const _settingsKey = 'vault.settings';
  static const _hiddenKey = 'vault.hidden_dirs';

  final SharedPreferences _prefs;

  static Future<PrefsRepository> open() async => PrefsRepository(await SharedPreferences.getInstance());

  AppSettings loadSettings() {
    final raw = _prefs.getString(_settingsKey);
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AppSettings(
        preloadEnabled: (json['preloadEnabled'] as bool?) ?? true,
        cacheLimitMB: (json['cacheLimitMB'] as num?)?.toInt() ?? 500,
        wifiOnlyUpload: (json['wifiOnlyUpload'] as bool?) ?? false,
        defaultUploadPath: RemotePath.normalize((json['defaultUploadPath'] as String?) ?? '/'),
        recentDays: ((json['recentDays'] as num?)?.toInt() ?? 7).clamp(1, 30),
      );
    } on Object {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) => _prefs.setString(_settingsKey, jsonEncode({
        'preloadEnabled': settings.preloadEnabled,
        'cacheLimitMB': settings.cacheLimitMB,
        'wifiOnlyUpload': settings.wifiOnlyUpload,
        'defaultUploadPath': RemotePath.normalize(settings.defaultUploadPath),
        'recentDays': settings.recentDays,
      }));

  List<HiddenEntry> loadHidden() {
    final raw = _prefs.getString(_hiddenKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => HiddenEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((e) => e.path.isNotEmpty)
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> saveHidden(List<HiddenEntry> entries) => _prefs.setString(
        _hiddenKey,
        jsonEncode(entries.map((e) => e.toJson()).toList()),
      );

  Future<void> remove(String path) async {
    final key = RemotePath.normalize(path);
    await saveHidden(loadHidden().where((e) => e.path != key).toList());
  }

  Future<void> add(HiddenEntry entry) async {
    final current = loadHidden().where((e) => e.path != entry.path).toList();
    current.add(entry);
    await saveHidden(current);
  }
}
