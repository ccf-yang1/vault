import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/core/models.dart';
import 'package:vault/data/prefs_repository.dart';
import 'package:vault/data/vault_cache.dart';
import 'package:vault/data/webdav_client.dart';
import 'package:vault/state/browse_providers.dart';
import 'package:vault/state/session_providers.dart';

import 'mock_webdav.dart';

class _StubSession extends SessionController {
  _StubSession(this._value);

  final Session? _value;

  @override
  Future<Session?> build() async => _value;
}

void main() {
  group('隐藏口令', () {
    final noon = DateTime(2026, 10, 6, 12, 12);

    test('输入当前 HHmm 命中', () {
      expect(matchesUnlockCode('1212', now: noon), isTrue);
    });

    test('输入过程中分钟跳走了也算', () {
      expect(matchesUnlockCode('1211', now: noon), isTrue);
    });

    test('错码、长度不对、非数字都不开', () {
      expect(matchesUnlockCode('0000', now: noon), isFalse);
      expect(matchesUnlockCode('121', now: noon), isFalse);
      expect(matchesUnlockCode('12121', now: noon), isFalse);
      expect(matchesUnlockCode('abcd', now: noon), isFalse);
    });

    test('跨小时边界：12:59 时 1259 与 1258 都接受', () {
      final edge = DateTime(2026, 10, 6, 12, 59);
      expect(matchesUnlockCode('1259', now: edge), isTrue);
      expect(matchesUnlockCode('1258', now: edge), isTrue);
      expect(matchesUnlockCode('1300', now: edge), isFalse);
    });
  });

  group('隐藏目录列表', () {
    late PrefsRepository repo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = PrefsRepository(await SharedPreferences.getInstance());
    });

    test('add / remove 用完整路径，重开不丢', () async {
      await repo.add(HiddenEntry(path: '/私人相册', name: '私人相册', hiddenAt: DateTime(2026, 10, 1)));
      await repo.add(HiddenEntry(path: '/相册/私人相册', name: '私人相册', hiddenAt: DateTime(2026, 10, 2)));
      expect(repo.loadHidden(), hasLength(2));

      // 同名不同路径不会被合并。
      await repo.remove('/私人相册');
      expect(repo.loadHidden().single.path, '/相册/私人相册');
    });

    test('设置存默认值，写回后读得到', () async {
      expect(repo.loadSettings().cacheLimitMB, 500);
      await repo.saveSettings(const AppSettings(preloadEnabled: false, cacheLimitMB: 1000, recentDays: 3));
      final reread = PrefsRepository(await SharedPreferences.getInstance()).loadSettings();
      expect(reread.preloadEnabled, isFalse);
      expect(reread.cacheLimitMB, 1000);
      expect(reread.recentDays, 3);
      expect(reread.wifiOnlyUpload, isFalse);
    });
  });

  group('浏览页隐藏过滤', () {
    late MockWebDav server;
    late WebDavClient client;
    late PrefsRepository repo;

    setUp(() async {
      server = MockWebDav();
      await server.start();
      server.files['/旅行/a.jpg'] = Uint8List(4);
      server.files['/私人相册/b.jpg'] = Uint8List(4);
      server.dirs.addAll(['/旅行', '/私人相册']);
      client = WebDavClient(ConnectionConfig(
        type: StorageType.openlist,
        baseUrl: server.baseUrl,
        username: server.username,
        password: server.password,
      ));
      SharedPreferences.setMockInitialValues({});
      repo = PrefsRepository(await SharedPreferences.getInstance());
      await repo.add(HiddenEntry(path: '/私人相册', name: '私人相册', hiddenAt: DateTime(2026, 10, 1)));
    });

    tearDown(() async {
      client.close();
      await server.stop();
    });

    Future<ProviderContainer> makeContainer() async {
      final container = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(repo),
          sessionProvider.overrideWith(() => _StubSession(Session(client.config, client))),
        ],
      );
      // sessionProvider 是 AsyncNotifier，不先落地成 AsyncData 的话 davProvider 拿不到 client。
      await container.read(sessionProvider.future);
      // dirRawProvider 是 autoDispose：没有 listener 的话它一完成就被回收，
      // 之后 dirEntriesProvider watch 到的永远是 AsyncLoading → 空列表。
      final sub = container.listen(dirRawProvider('/'), (_, __) {});
      addTearDown(sub.close);
      addTearDown(container.dispose);
      return container;
    }

    test('正常模式完全看不到隐藏目录', () async {
      final container = await makeContainer();
      await container.read(dirRawProvider('/').future);
      final names = container.read(dirEntriesProvider('/')).map((e) => e.name).toList();
      expect(names, ['旅行']);
    });

    test('隐藏模式下可见，且眼睛按钮切换后立刻生效', () async {
      final container = await makeContainer();
      await container.read(dirRawProvider('/').future);
      container.read(hiddenModeProvider.notifier).state = true;

      expect(container.read(dirEntriesProvider('/')).map((e) => e.name), containsAll(['旅行', '私人相册']));

      final dir = container.read(dirEntriesProvider('/')).firstWhere((e) => e.name == '私人相册');
      await container.read(hiddenDirsProvider.notifier).setHidden(dir, false);
      expect(container.read(hiddenDirsProvider).any((e) => e.path == '/私人相册'), isFalse);
      // 眼睛按钮取消隐藏后立刻生效：退出隐藏模式它就是普通目录。
      container.read(hiddenModeProvider.notifier).state = false;
      expect(container.read(dirEntriesProvider('/')).map((e) => e.name), ['旅行', '私人相册']);
    });

    test('切换隐藏模式不会重新发 PROPFIND', () async {
      final container = await makeContainer();
      final first = await container.read(dirRawProvider('/').future);
      container.read(hiddenModeProvider.notifier).state = true;
      final second = container.read(dirRawProvider('/')).valueOrNull;
      expect(identical(first, second), isTrue);
    });
  });

  group('沙盒缓存', () {
    late Directory root;
    late VaultCache cache;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('vault-cache');
      cache = VaultCache(rootOverride: root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('同名远程文件靠路径哈希分开', () async {
      final a = await cache.fileFor(CacheBucket.images, remotePath: '/a/x.jpg', displayName: 'x.jpg', etag: '1', ext: 'jpg');
      final b = await cache.fileFor(CacheBucket.images, remotePath: '/b/x.jpg', displayName: 'x.jpg', etag: '1', ext: 'jpg');
      expect(a.path, isNot(b.path));
      expect(a.path, startsWith(root.path));
    });

    test('文件名清洗奇怪字符并保留扩展名', () async {
      final name = cache.fileNameFor('/x', '照片 1#?.jpg', etag: 'e', ext: 'jpg');
      expect(name, endsWith('.jpg'));
      expect(name.contains(' '), isFalse);
      expect(name.contains('?'), isFalse);
    });

    test('超出上限先删最旧（LRU）', () async {
      final dir = await cache.bucketDir(CacheBucket.images);
      final old = File('${dir.path}/old.jpg')..createSync();
      old.writeAsBytesSync(List.filled(600 * 1024, 1));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final fresh = File('${dir.path}/fresh.jpg')..createSync();
      fresh.writeAsBytesSync(List.filled(600 * 1024, 2));

      final removed = await cache.enforceLimit(1);
      expect(removed, 1);
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test('清除缓存不动凭据与隐藏列表', () async {
      final dir = await cache.bucketDir(CacheBucket.videos);
      File('${dir.path}/v.mp4').writeAsBytesSync([1, 2, 3]);
      await cache.clear();
      expect(await cache.totalBytes(), 0);
    });
  });
}
