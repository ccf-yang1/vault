import 'dart:convert';
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
    this.declaresLocalNetwork = true,
    this.reachability,
  });

  final DateTime at;
  final ConnectionConfig config;

  /// 归一化之后真正发 PROPFIND 的地址；地址本身解析不了时为 null。
  final String? requestUrl;
  final Duration elapsed;
  final WebDavError? error;

  /// 安装包自己的 Info.plist 里有没有 `NSLocalNetworkUsageDescription`。
  /// iOS 只认二进制里的这个键：没有它既不弹框、也不会在设置里列出 App。
  final bool declaresLocalNetwork;

  /// 公网 / 目标地址的 TCP 对照结果，用来区分「手机没网」和「局域网被拦」。
  final String? reachability;

  bool get ok => error == null;

  /// 给用户看的那一句。本地网络被拦有两种完全不同的成因，混在一起说等于没说。
  String get advice {
    final e = error;
    if (e == null) return '已连接';
    if (e.kind == WebDavErrorKind.localNetworkBlocked && !declaresLocalNetwork) {
      return '这个安装包里没有「本地网络」权限声明，iOS 会直接拒掉对局域网的连接。'
          '请改装最近一次构建的 IPA（旧包重装也不会补上这个键）。';
    }
    return e.message;
  }

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
      if (e != null) '说明  $advice',
      if (e != null && (e.detail ?? '').trim().isNotEmpty) '原文  ${e.detail!.trim()}',
      '声明  ${declaresLocalNetwork ? '安装包已含 NSLocalNetworkUsageDescription' : '安装包缺少 NSLocalNetworkUsageDescription'}',
      if (reachability != null) '对照  $reachability',
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
  String get message => attempt.advice;
}

/// 读自己包里的 Info.plist，看有没有声明本地网络权限。
///
/// iOS 只在二进制里有这个键时才会弹框、才会把 App 列进 设置 → 隐私与安全性 → 本地网络，
/// 所以「设置里找不到这个 App」本身就意味着跑的是没声明的那版包。binary plist 的键名
/// 是明文 ASCII，直接按字节找子串就够，不必引一个 plist 解析器。
bool bundleDeclaresLocalNetwork() {
  try {
    final bundle = File(Platform.resolvedExecutable).parent;
    final plist = File('${bundle.path}/Info.plist');
    if (!plist.existsSync()) return false;
    return latin1
        .decode(plist.readAsBytesSync(), allowInvalid: true)
        .contains('NSLocalNetworkUsageDescription');
  } catch (_) {
    return false;
  }
}

/// 公网和目标各试一次 TCP：只有「公网通、局域网不通」才说明是局域网那一层被拦，
/// 两台都不通就是手机根本没网 / 连错 Wi-Fi。
Future<String> reachabilityProbe(String lanHost, int lanPort) async {
  final public = await _tryConnect('223.5.5.5', 443);
  final local = await _tryConnect(lanHost, lanPort);
  return '公网 223.5.5.5:443 → $public；$lanHost:$lanPort → $local';
}

Future<String> _tryConnect(String host, int port) async {
  try {
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    socket.destroy();
    return '可达';
  } on SocketException catch (e) {
    return '不可达（${e.osError?.message ?? e.message}）';
  } catch (e) {
    return '失败（$e）';
  }
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
    // 连不上时才花这一趟：能明确区分「手机没网」和「局域网被拦」，
    // 前者再怎么改 App 都没用，后者才是本地网络权限。
    String? reach;
    if (failure != null &&
        const {
          WebDavErrorKind.network,
          WebDavErrorKind.localNetworkBlocked,
          WebDavErrorKind.timeout,
        }.contains(failure.kind)) {
      final uri = url == null ? null : Uri.tryParse(url);
      if (uri != null && uri.host.isNotEmpty) {
        reach = await reachabilityProbe(uri.host, uri.port);
      }
    }
    final attempt = ConnectAttempt(
      at: DateTime.now(),
      config: config,
      requestUrl: url,
      elapsed: watch.elapsed,
      error: failure,
      declaresLocalNetwork: bundleDeclaresLocalNetwork(),
      reachability: reach,
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

  /// 退出登录：只断开当前会话，凭据原样留着——下次打开照常自动登录。
  /// 真要把本机记录抹掉，去连接页点输入框后面的清空。
  Future<void> logout() async {
    ref.read(sessionProvider).valueOrNull?.client.close();
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
