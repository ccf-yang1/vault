import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/session_providers.dart';

/// 个性化：浅色 / 深色 / 深蓝三选一，默认深色。每格用对应调色板画一小块真实配色预览，
/// 点选后全站即时换肤（App 根部按模式打 key 重建）。
class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(settingsProvider).themeMode;

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              VaultAppBar(
                title: '个性化',
                leading: IconBtn(icon: 'back', onTap: () => Navigator.of(context).maybePop()),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 6, bottom: 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                      child: Text(
                        '选择外观主题。深色为默认，与初始界面逐像素一致；深蓝取自音频播放页那套观感。',
                        style: TextStyle(fontSize: 12, color: VaultColors.muted, height: 1.6),
                      ),
                    ),
                    for (final mode in VaultThemeMode.values)
                      _ModeTile(
                        mode: mode,
                        selected: mode == current,
                        onTap: () => ref.read(settingsProvider.notifier).setThemeMode(mode),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.mode, required this.selected, required this.onTap});

  final VaultThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = paletteFor(mode);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: VaultColors.surface,
            borderRadius: BorderRadius.circular(VaultRadius.card),
            border: Border.all(
              color: selected ? VaultColors.accent : VaultColors.line,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              _Swatch(pal: pal),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: selected ? VaultColors.accent : VaultColors.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(_desc(mode), style: const TextStyle(fontSize: 11.5).copyWith(color: VaultColors.dim)),
                  ],
                ),
              ),
              if (selected) const VIcon('check', size: 18, color: null),
            ],
          ),
        ),
      ),
    );
  }

  static String _desc(VaultThemeMode mode) => switch (mode) {
        VaultThemeMode.dark => '黑底、蓝紫强调',
        VaultThemeMode.light => '白底、深色文字',
        VaultThemeMode.deepBlue => 'navy 底、柔蓝点缀',
      };
}

/// 一小张配色预览：底 + 卡片 + 强调点 + 一行文字，取自该模式真实调色板。
class _Swatch extends StatelessWidget {
  const _Swatch({required this.pal});

  final VaultPalette pal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 62,
      height: 46,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: pal.bg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: pal.line2),
      ),
      child: Row(
        children: [
          Container(
            width: 15,
            height: 36,
            decoration: BoxDecoration(
              color: pal.surface,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: pal.line),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 9, height: 2.5, decoration: BoxDecoration(color: pal.text, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 3),
                Container(width: 7, height: 2.5, decoration: BoxDecoration(color: pal.muted, borderRadius: BorderRadius.circular(2))),
              ],
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 3, margin: const EdgeInsets.only(bottom: 4), decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(2))),
                Container(width: 14, height: 14, decoration: BoxDecoration(color: pal.surface2, shape: BoxShape.circle, border: Border.all(color: pal.accent))),
                const Spacer(),
                Container(width: 20, height: 3, decoration: BoxDecoration(color: pal.dim, borderRadius: BorderRadius.circular(2))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
