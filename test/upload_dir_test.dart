import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/core/models.dart';
import 'package:vault/data/credential_store.dart';
import 'package:vault/data/prefs_repository.dart';
import 'package:vault/state/session_providers.dart';

/// 上传目标目录：既要按账号各存各的（切 A→B 不能残留 A 的路径，否则报「没路径」），
/// 又要在非隐藏模式下不把隐藏目录当成上传去处。
void main() {
  final accountA = ConnectionConfig(
    type: StorageType.webdav,
    baseUrl: 'http://192.168.1.17:5244',
    username: 'admin',
    password: 'pw',
  );
  final accountB = ConnectionConfig(
    type: StorageType.webdav,
    baseUrl: 'http://192.168.1.17:5244',
    username: 'guest',
    password: 'pw',
  );

  Future<(ProviderContainer, PrefsRepository, StateController<ConnectionConfig?>)> makeContainer({
    ConnectionConfig? initial,
    List<HiddenEntry> hidden = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsRepository(await SharedPreferences.getInstance());
    if (hidden.isNotEmpty) await prefs.saveHidden(hidden);
    final holder = StateProvider<ConnectionConfig?>((ref) => initial);
    final container = ProviderContainer(overrides: [
      prefsProvider.overrideWithValue(prefs),
      connectionConfigProvider.overrideWith((ref) => ref.watch(holder)),
    ]);
    addTearDown(container.dispose);
    // 常驻监听：uploadDirProvider 非 autoDispose，但要保证切账号 / 切隐藏模式即时重算。
    container.listen(uploadDirProvider, (_, __) {});
    return (container, prefs, container.read(holder.notifier));
  }

  group('上传目录按账号切换', () {
    test('切到从没设过的账号时回到根目录，不残留上一个账号的路径', () async {
      final (container, _, account) = await makeContainer(initial: accountA);

      expect(container.read(uploadDirProvider), '/');
      container.read(uploadDirProvider.notifier).set('/A/照片');
      expect(container.read(uploadDirProvider), '/A/照片');

      account.state = accountB;
      expect(container.read(uploadDirProvider), '/');
    });

    test('两个账号各存各的：来回切都认得自己存过的', () async {
      final (container, prefs, account) = await makeContainer(initial: accountA);
      container.read(uploadDirProvider.notifier).set('/旅行');
      expect(prefs.loadUploadPath(CredentialStore.idOf(accountA)), '/旅行');

      account.state = accountB;
      expect(container.read(uploadDirProvider), '/');
      container.read(uploadDirProvider.notifier).set('/工作');

      account.state = accountA;
      expect(container.read(uploadDirProvider), '/旅行');
      account.state = accountB;
      expect(container.read(uploadDirProvider), '/工作');
    });
  });

  group('上传目录过滤隐藏', () {
    final private = HiddenEntry(path: '/私人', name: '私人', hiddenAt: DateTime(2026, 10, 1));

    test('非隐藏模式下，落在隐藏目录里的目标退回可见上级', () async {
      final (container, prefs, _) = await makeContainer(initial: accountA, hidden: [private]);

      container.read(uploadDirProvider.notifier).set('/私人/子');
      expect(container.read(uploadDirProvider), '/');
      // 存的是原路径，只是普通模式下藏起来不用它。
      expect(prefs.loadUploadPath(CredentialStore.idOf(accountA)), '/私人/子');
    });

    test('进了隐藏模式，真实目标原样可见', () async {
      final (container, _, _) = await makeContainer(initial: accountA, hidden: [private]);
      container.read(uploadDirProvider.notifier).set('/私人/子');
      expect(container.read(uploadDirProvider), '/');

      container.read(hiddenModeProvider.notifier).state = true;
      expect(container.read(uploadDirProvider), '/私人/子');
    });

    test('目标不在隐藏目录里时原样保留', () async {
      final (container, _, _) = await makeContainer(initial: accountA, hidden: [private]);
      container.read(uploadDirProvider.notifier).set('/旅行/2026');
      expect(container.read(uploadDirProvider), '/旅行/2026');
    });
  });
}
