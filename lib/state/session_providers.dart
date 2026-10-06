import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_proxy.dart';
import '../data/credential_store.dart';
import '../data/prefs_repository.dart';
import '../data/vault_cache.dart';
import '../data/webdav_client.dart';
import '../core/models.dart';

/// main() 里用实例覆盖，避免各处 await SharedPreferences.getInstance()。
final prefsProvider = Provider<PrefsRepository>((ref) => throw StateError('prefsProvider 未 override'));

final credentialStoreProvider = Provider<CredentialStore>((ref) => CredentialStore());

final cacheProvider = Provider<VaultCache>((ref) => VaultCache());

class Session {
  Session(this.config, this.client);

  final ConnectionConfig config;
  final WebDavClient client;
}

class ConnectResult {
  const ConnectResult.ok() : error = null;
  const ConnectResult.failed(this.error);

  final WebDavError? error;
  bool get isSuccess => error == null;
  bool get needsCertificateWarning => error?.kind == WebDavErrorKind.tls;
  String get message => error?.message ?? '已连接';
}

/// 保存的凭据 + 一次探活，就是「自动登录」（需求 §3.1）。
class SessionController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() async {
    final config = await ref.read(credentialStoreProvider).load();
    if (config == null || config.baseUrl.isEmpty) return null;
    final client = WebDavClient(config);
    try {
      await client.list('/');
    } on WebDavError {
      client.close();
      // 自动登录失败不弹错误，停在连接页让用户自己确认。
      return null;
    }
    return Session(config, client);
  }

  Future<ConnectResult> connect(ConnectionConfig config, {bool allowInsecure = false}) async {
    final client = WebDavClient(config, allowInsecureCertificate: allowInsecure);
    WebDavError? failure;
    try {
      await client.list('/');
    } on WebDavError catch (e) {
      failure = e;
    }
    if (failure != null) {
      client.close();
      return ConnectResult.failed(failure);
    }
    ref.read(sessionProvider).valueOrNull?.client.close();
    state = const AsyncLoading();
    state = AsyncData(Session(config, client));
    if (config.remember) {
      await ref.read(credentialStoreProvider).save(config);
    } else {
      await ref.read(credentialStoreProvider).clear();
    }
    return const ConnectResult.ok();
  }

  Future<void> forget() async {
    ref.read(sessionProvider).valueOrNull?.client.close();
    await ref.read(credentialStoreProvider).clear();
    state = const AsyncData(null);
  }
}

final sessionProvider = AsyncNotifierProvider<SessionController, Session?>(SessionController.new);

/// 未登录时抛状态错误；页面都在登录之后才挂载。
final davProvider = Provider<WebDavClient>((ref) {
  final session = ref.watch(sessionProvider).valueOrNull;
  if (session == null) throw StateError('尚未连接');
  return session.client;
});

final connectionConfigProvider = Provider<ConnectionConfig?>((ref) {
  return ref.watch(sessionProvider).valueOrNull?.config;
});

/// 视频走本地回环代理，见 [AuthProxy]。
final proxyProvider = Provider<AuthProxy>((ref) {
  final client = ref.watch(davProvider);
  final proxy = AuthProxy(client);
  ref.onDispose(() async {
    await proxy.stop();
  });
  return proxy;
});

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(prefsProvider).loadSettings();

  void _write(AppSettings next) {
    state = next;
    ref.read(prefsProvider).saveSettings(next);
  }

  void setPreload(bool value) => _write(state.copyWith(preloadEnabled: value));
  void setWifiOnly(bool value) => _write(state.copyWith(wifiOnlyUpload: value));
  void setCacheLimit(int mb) => _write(state.copyWith(cacheLimitMB: mb));
  void setRecentDays(int days) => _write(state.copyWith(recentDays: days.clamp(1, 30)));
  void setUploadPath(String path) => _write(state.copyWith(defaultUploadPath: RemotePath.normalize(path)));
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// 隐藏目录列表持久化；隐藏模式开关本身只在内存（需求 §4.4）。
class HiddenDirsController extends Notifier<List<HiddenEntry>> {
  @override
  List<HiddenEntry> build() => ref.read(prefsProvider).loadHidden();

  Set<String> get paths => state.map((e) => e.path).toSet();

  bool isHidden(String path) => paths.contains(RemotePath.normalize(path));

  Future<void> setHidden(RemoteEntry entry, bool hidden) async {
    final repo = ref.read(prefsProvider);
    if (hidden) {
      await repo.add(HiddenEntry(path: entry.path, name: entry.name, hiddenAt: DateTime.now()));
    } else {
      await repo.remove(entry.path);
    }
    state = repo.loadHidden();
  }

  Future<void> clear() async {
    final repo = ref.read(prefsProvider);
    await repo.saveHidden(const []);
    state = const [];
  }
}

final hiddenDirsProvider = NotifierProvider<HiddenDirsController, List<HiddenEntry>>(HiddenDirsController.new);

final hiddenModeProvider = StateProvider<bool>((ref) => false);

/// 隐藏口令：输入当前 HHmm 才进隐藏模式（需求 §4.1）。
///
/// 分钟可能正好在输入过程中跳走，所以额外接受上一分钟。
bool matchesUnlockCode(String input, {DateTime? now}) {
  if (input.length != 4 || int.tryParse(input) == null) return false;
  final moment = now ?? DateTime.now();
  String code(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}';
  return input == code(moment) || input == code(moment.subtract(const Duration(minutes: 1)));
}
