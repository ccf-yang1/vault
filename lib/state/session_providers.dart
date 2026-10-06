import 'dart:io';

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

/// 一次登录尝试的完整过程。连接页把它原样摊开给人看——「无法连接服务器」这种
/// 话不够用的时候，至少能看见真实请求长什么样、系统回的原话是什么。
class ConnectAttempt {
  ConnectAttempt({
    required this.at,
    required this.config,
    required this.requestUrl,
    required this.elapsed,
    this.error,
  });

  final DateTime at;
  final ConnectionConfig config;

  /// 归一化之后真正发 PROPFIND 的地址；地址本身解析不了时为 null。
  final String? requestUrl;
  final Duration elapsed;
  final WebDavError? error;

  bool get ok => error == null;

  String render() {
    final e = error;
    return [
      '时间  ${at.toIso8601String()}',
      '系统  ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '类型  ${config.type.label}',
      '填写  ${config.baseUrl}',
      '请求  ${requestUrl == null ? '（地址没能解析成 URL）' : 'PROPFIND $requestUrl  Depth:1'}',
      '用户  ${config.username.isEmpty ? '（空）' : config.username}',
      '密码  ${config.password.isEmpty ? '（空）' : '${config.password.length} 位'}',
      '耗时  ${elapsed.inMilliseconds} ms',
      '结果  ${e == null ? '成功' : '失败 · ${e.kind.name}'}',
      if (e != null && e.statusCode != null) '状态  HTTP ${e.statusCode}',
      if (e != null) '说明  ${e.message}',
      if (e != null && (e.detail ?? '').trim().isNotEmpty) '原文  ${e.detail!.trim()}',
    ].join('\n');
  }
}

class ConnectResult {
  ConnectResult.ok(this.attempt) : error = null;
  ConnectResult.failed(this.error, this.attempt);

  final WebDavError? error;
  final ConnectAttempt attempt;
  bool get isSuccess => error == null;
  bool get needsCertificateWarning => error?.kind == WebDavErrorKind.tls;
  String get message => error?.message ?? '已连接';
}

/// 保存的凭据 + 一次探活，就是「自动登录」（需求 §3.1）。
class SessionController extends AsyncNotifier<Session?> {
  /// 最近一次探活（包括启动时那次自动登录），连接页用它填诊断面板。
  ConnectAttempt? lastAttempt;

  /// 探活一次并留下完整过程。失败时负责关掉 client。
  Future<({WebDavClient? client, ConnectAttempt attempt})> _probe(
    ConnectionConfig config,
    bool allowInsecure,
  ) async {
    final client = WebDavClient(config, allowInsecureCertificate: allowInsecure);
    final watch = Stopwatch()..start();
    String? url;
    WebDavError? failure;
    try {
      url = client.urlFor('/').toString();
      await client.list('/');
    } on WebDavError catch (e) {
      failure = e;
    }
    watch.stop();
    final attempt = ConnectAttempt(
      at: DateTime.now(),
      config: config,
      requestUrl: url,
      elapsed: watch.elapsed,
      error: failure,
    );
    if (failure != null) {
      client.close();
      return (client: null, attempt: attempt);
    }
    return (client: client, attempt: attempt);
  }

  @override
  Future<Session?> build() async {
    final config = await ref.read(credentialStoreProvider).load();
    if (config == null || config.baseUrl.isEmpty) return null;
    final probe = await _probe(config, false);
    lastAttempt = probe.attempt;
    final client = probe.client;
    // 自动登录失败不弹错误，停在连接页让用户自己确认。
    if (client == null) return null;
    return Session(config, client);
  }

  Future<ConnectResult> connect(ConnectionConfig config, {bool allowInsecure = false}) async {
    final probe = await _probe(config, allowInsecure);
    lastAttempt = probe.attempt;
    final client = probe.client;
    if (client == null) return ConnectResult.failed(probe.attempt.error!, probe.attempt);
    ref.read(sessionProvider).valueOrNull?.client.close();
    state = const AsyncLoading();
    state = AsyncData(Session(config, client));
    if (config.remember) {
      await ref.read(credentialStoreProvider).save(config);
    } else {
      await ref.read(credentialStoreProvider).clear();
    }
    return ConnectResult.ok(probe.attempt);
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
