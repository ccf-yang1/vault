import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/browse_providers.dart';
import 'audio_player_page.dart';
import 'image_viewer_page.dart';
import 'video_page.dart';

/// 分类过滤页：递归「当前所在目录子树」，把指定类型的文件平铺展示，
/// 忽略原有目录层级，点进去直接进对应播放器/查看器。
class MediaFilterPage extends ConsumerStatefulWidget {
  const MediaFilterPage({required this.root, required this.kind, super.key});

  final String root;
  final FileKind kind;

  @override
  ConsumerState<MediaFilterPage> createState() => _MediaFilterPageState();
}

class _MediaFilterPageState extends ConsumerState<MediaFilterPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _label => switch (widget.kind) {
        FileKind.image => '图片',
        FileKind.video => '视频',
        FileKind.audio => '音频',
        _ => '文件',
      };

  List<RemoteEntry> _filter(List<RemoteEntry> entries) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return entries;
    return entries.where((e) => e.name.toLowerCase().contains(q)).toList();
  }

  void _open(List<RemoteEntry> list, int index) {
    final entry = list[index];
    switch (widget.kind) {
      case FileKind.image:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ImageViewerPage(images: list, initialIndex: index)),
        );
      case FileKind.video:
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPage(entry: entry)));
      case FileKind.audio:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AudioPlayerPage(playlist: list, initialIndex: index)),
        );
      default:
        showVaultToast(context, '${entry.name} 暂不支持预览', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(mediaScanProvider((root: widget.root, kind: widget.kind)));

    return VaultAnnotatedRegion(
      child: Scaffold(
        body: Column(
          children: [
            SizedBox(height: MediaQuery.of(context).padding.top),
            VaultAppBar(
              title: '$_label 过滤',
              subtitle: '仅当前目录及其子目录',
              leading: IconBtn(icon: 'back', onTap: () => Navigator.of(context).maybePop()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: VaultColors.field,
                  borderRadius: BorderRadius.circular(VaultRadius.field),
                  border: Border.all(color: VaultColors.line2),
                ),
                child: Row(
                  children: [
                    const VIcon('search', size: 16, color: VaultColors.dim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        style: const TextStyle(fontSize: 13.5, color: VaultColors.text),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '在结果里按名称搜索',
                          hintStyle: const TextStyle(fontSize: 13.5, color: VaultColors.dim),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: scan.when(
                loading: () => const _Scanning(),
                error: (error, _) => VaultEmpty(
                  icon: 'shield',
                  title: '扫描子目录失败',
                  action: PrimaryButton(
                    label: '重试',
                    compact: true,
                    onPressed: () => ref.invalidate(mediaScanProvider((root: widget.root, kind: widget.kind))),
                  ),
                ),
                data: (entries) {
                  final list = _filter(entries);
                  if (entries.isEmpty) {
                    return VaultEmpty(icon: _iconName(), title: '这个目录的子树里没有$_label文件');
                  }
                  if (list.isEmpty) {
                    return const VaultEmpty(icon: 'search', title: '没有匹配的名称');
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 2, 14, 24),
                    itemCount: list.length,
                    itemBuilder: (context, index) => _row(list, index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _iconName() => switch (widget.kind) {
        FileKind.image => 'image',
        FileKind.video => 'video',
        FileKind.audio => 'audio',
        _ => 'list',
      };

  Color _tileColor() => switch (widget.kind) {
        FileKind.image => VaultColors.green,
        FileKind.video => VaultColors.purple,
        FileKind.audio => VaultColors.accentText,
        _ => VaultColors.muted,
      };

  Widget _row(List<RemoteEntry> list, int index) {
    final entry = list[index];
    final time = formatRelativeTime(entry.modified);
    final size = entry.size > 0 ? formatBytes(entry.size) : '—';
    final base = time.isEmpty ? size : '$size · $time';
    final dir = RemotePath.parent(entry.path);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(list, index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        decoration: const BoxDecoration(borderRadius: BorderRadius.all(Radius.circular(12))),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: _tileColor().withValues(alpha: 0.11),
              ),
              child: Center(child: VIcon(_iconName(), size: 19, color: _tileColor())),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFFE4E6E9)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    base,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: VaultColors.muted),
                  ),
                  if (dir != '/')
                    Text(
                      dir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: VaultColors.dim),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const VIcon('chevron', size: 16, color: Color(0xFF3A3F46)),
          ],
        ),
      ),
    );
  }
}

class _Scanning extends StatelessWidget {
  const _Scanning();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
          ),
          SizedBox(height: 14),
          Text('正在扫描子目录…', style: TextStyle(fontSize: 12.5, color: VaultColors.muted)),
        ],
      ),
    );
  }
}
