import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/webdav_client.dart';
import '../state/browse_providers.dart';
import '../state/session_providers.dart';

/// HTML 03（旧版）：图片查看器。缩放 + 左右翻页 + 沙盒预加载计数。
class ImageViewerPage extends ConsumerStatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  final List<RemoteEntry> images;
  final int initialIndex;

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage> {
  late final PageController _controller =
      PageController(initialPage: _clamp(widget.initialIndex, widget.images.length));
  late int _index = _clamp(widget.initialIndex, widget.images.length);

  /// 已经在沙盒里的图片：路径 -> 文件。缩略图条和「预加载 N / M」都读它。
  final Map<String, File> _cached = {};

  static int _clamp(int value, int length) => length == 0 ? 0 : value.clamp(0, length - 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _preload(_index));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 前后各 5 张（需求 §3.2）；失败静默，当前这张自己会重试。
  void _preload(int index) {
    if (!ref.read(settingsProvider).preloadEnabled) return;
    final start = (index - preloadRadius).clamp(0, widget.images.length - 1);
    final end = (index + preloadRadius).clamp(0, widget.images.length - 1);
    for (var i = start; i <= end; i++) {
      final entry = widget.images[i];
      if (_cached.containsKey(entry.path)) continue;
      ref.read(cachedFileProvider(cacheKeyFor(entry)).future).then((file) {
        if (!mounted) return;
        setState(() => _cached[entry.path] = file);
      }).catchError((Object _) {
        // 预加载不到不算错误，翻到那张时再报。
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    if (images.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black, body: VaultEmpty(icon: 'image', title: '这里没有图片'));
    }
    final current = images[_index];
    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            VaultAppBar(
              leading: IconBtn(icon: 'back', color: VaultColors.text, onTap: () => Navigator.of(context).maybePop()),
              title: current.name,
              subtitle: '${_index + 1} / ${images.length}',
              actions: [IconBtn(icon: 'list', color: VaultColors.text, onTap: () => _showDetails(current))],
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: images.length,
                onPageChanged: (index) {
                  setState(() => _index = index);
                  _preload(index);
                },
                itemBuilder: (context, index) {
                  final entry = images[index];
                  return _ImagePage(
                    entry: entry,
                    onLoaded: (file) {
                      if (_cached.containsKey(entry.path)) return;
                      setState(() => _cached[entry.path] = file);
                    },
                  );
                },
              ),
            ),
            _bottomBar(images),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(List<RemoteEntry> images) {
    final cached = _cached.length;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: VaultColors.line)),
        color: Color(0xF0121417),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  const VIcon('cloudUp', size: 13, color: VaultColors.green),
                  const SizedBox(width: 6),
                  Text(
                    '沙盒预加载 $cached / ${images.length}',
                    style: const TextStyle(fontSize: 11, color: VaultColors.green, letterSpacing: 0.2),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 72,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: images.isEmpty ? 0 : cached / images.length,
                        minHeight: 3,
                        backgroundColor: VaultColors.surface2,
                        valueColor: const AlwaysStoppedAnimation(VaultColors.green),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 54,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                itemCount: images.length,
                itemBuilder: (context, index) {
                  final entry = images[index];
                  final file = _cached[entry.path];
                  final selected = index == _index;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _controller.animateToPage(
                      index,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                    ),
                    child: Container(
                      width: 54,
                      height: 46,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: selected ? VaultColors.accent : Colors.transparent, width: 1.5),
                        color: VaultColors.surface2,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: file == null
                            ? const Center(child: VIcon('image', size: 15, color: Color(0xFF3A3F46)))
                            : Image(image: FileImage(file), fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Text('仅内存 / 沙盒缓存，不写入相册', style: TextStyle(fontSize: 10.5, color: VaultColors.dim)),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetails(RemoteEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: VaultColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.name, style: const TextStyle(fontSize: 14, color: VaultColors.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text('路径  ${entry.path}', style: const TextStyle(fontSize: 12, color: VaultColors.muted, height: 1.6)),
              Text(
                '大小  ${entry.size > 0 ? formatBytes(entry.size) : '未知'}',
                style: const TextStyle(fontSize: 12, color: VaultColors.muted, height: 1.6),
              ),
              const SizedBox(height: 14),
              const Text(
                '这张图缓存在 App 沙盒的 Library/Caches/Vault 下，相册 App 看不到它。',
                style: TextStyle(fontSize: 11.5, color: VaultColors.dim, height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePage extends ConsumerWidget {
  const _ImagePage({required this.entry, required this.onLoaded});

  final RemoteEntry entry;
  final ValueChanged<File> onLoaded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(cachedFileProvider(cacheKeyFor(entry)));
    return file.when(
      loading: () => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
        ),
      ),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            error is WebDavError ? error.message : '读取失败，下拉重试',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: VaultColors.dim),
          ),
        ),
      ),
      data: (value) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onLoaded(value));
        return InteractiveViewer(
          maxScale: 6,
          child: Center(child: Image(image: FileImage(value), fit: BoxFit.contain, gaplessPlayback: true)),
        );
      },
    );
  }
}
