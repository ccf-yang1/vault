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
    return MaterialApp.router(
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: buildVaultTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
