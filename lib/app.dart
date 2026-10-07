import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'features/connect_page.dart';
import 'features/shell_page.dart';
import 'state/session_providers.dart';
/// 顶层只有三个路由：启动 / 连接 / 主框架。查看器一类带对象的页面走
/// `Navigator.push`，不给它们编路由更省事。
final routerProvider = Provider<GoRouter>((ref) {
  // ref.listen 不构成依赖，所以这个 Provider 本身不会重建 GoRouter，
  // 导航栈（比如浏览页的层级）不会被重登打断。
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(sessionProvider, (_, __) => refresh.value++);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      if (session.isLoading) return null;
      final loggedIn = session.valueOrNull != null;
      final atConnect = state.matchedLocation == '/connect';
      final atMain = state.matchedLocation == '/main';
      if (!loggedIn && !atConnect) return '/connect';
      if (loggedIn && !atMain) return '/main';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashPage()),
      GoRoute(path: '/connect', builder: (context, state) => const ConnectPage()),
      GoRoute(path: '/main', builder: (context, state) => const ShellPage()),
    ],
  );
});

class VaultApp extends ConsumerWidget {
  const VaultApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider).themeMode;
    final palette = paletteFor(mode);
    // 先把调色板写进全局，MaterialApp 及其下所有 push 页的 getter 才读到新值。
    setActivePalette(palette);
    return MaterialApp.router(
      // 按模式打 key：主题一改整棵树重建，那些直接读 VaultColors getter 的
      // push 页（视频/音频/压缩包…）才会立刻重绘取到新色，而不是停在旧帧。
      key: ValueKey(mode),
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: buildVaultTheme(palette),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
