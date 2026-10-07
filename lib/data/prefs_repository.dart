import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'box_cache_api.dart';

/// 设置与隐藏目录列表（需求 §5.2）。
///
/// 隐藏列表在这里持久化，隐藏模式开关本身只在内存里 —— 重启即关闭（§4.4）。
class PrefsRepository {
  PrefsRepository(this._prefs);

  static const _settingsKey = 'vault.settings';
  static const _hiddenKey = 'vault.hidden_dirs';
  static const _draftKey = 'vault.draft';
  static const _cacheTasksKey = 'vault.cache_tasks';
  /// 上传目标目录按账号各存各的：切账号时上传页才不会停在另一个账号的路径上。
  static const _uploadPathPrefix = 'vault.upload_path.';

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
        recentDays: ((json['recentDays'] as num?)?.toInt() ?? 7).clamp(1, 30),
        themeMode: VaultThemeMode.fromName(json['themeMode'] as String?),
      );
    } on Object {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) => _prefs.setString(_settingsKey, jsonEncode({
        'preloadEnabled': settings.preloadEnabled,
        'cacheLimitMB': settings.cacheLimitMB,
        'wifiOnlyUpload': settings.wifiOnlyUpload,
        'recentDays': settings.recentDays,
        'themeMode': settings.themeMode.name,
      }));

  String loadUploadPath(String accountId) =>
      RemotePath.normalize(_prefs.getString('$_uploadPathPrefix$accountId') ?? '/');

  Future<void> saveUploadPath(String accountId, String path) =>
      _prefs.setString('$_uploadPathPrefix$accountId', RemotePath.normalize(path));

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

  /// 离线下载任务：只存 App 侧这份记录（id 必须留，重启后靠它续查盒子进度）。
  List<CacheTaskRecord> loadCacheTasks() {
    final raw = _prefs.getString(_cacheTasksKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => CacheTaskRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((e) => e.id.isNotEmpty)
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> saveCacheTasks(List<CacheTaskRecord> tasks) => _prefs.setString(
        _cacheTasksKey,
        jsonEncode(tasks.map((e) => e.toJson()).toList()),
      );

  /// 连接页表单草稿：需求 §5「登录信息一直在」的载体——明文存 prefs，
  /// 只在用户点清空或成功登录（remember）时才增删；Keychain 里那份是另一回事。
  ConnectionConfig? loadDraft() {
    final raw = _prefs.getString(_draftKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ConnectionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> saveDraft(ConnectionConfig draft) =>
      _prefs.setString(_draftKey, jsonEncode(draft.toJson()));

  Future<void> clearDraft() => _prefs.remove(_draftKey);
}
