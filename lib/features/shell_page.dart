import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/widgets.dart';
import 'browse_page.dart';
import 'settings_page.dart';
import 'upload_page.dart';

/// 三个 Tab：浏览 / 上传 / 设置。用 IndexedStack 保留各自状态，
/// 免得每次切 Tab 都重新 PROPFIND。
class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({super.key});

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends ConsumerState<ShellPage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: IndexedStack(
          index: _index,
          children: [
            BrowsePage(onOpenSettings: () => setState(() => _index = 2)),
            const UploadPage(),
            const SettingsPage(),
          ],
        ),
        bottomNavigationBar: VaultBottomBar(
          index: _index,
          onSelect: (index) => setState(() => _index = index),
        ),
      ),
    );
  }
}
