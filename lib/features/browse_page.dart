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
import 'archive_page.dart';
import 'audio_player_page.dart';
import 'doc_viewer_page.dart';
import 'image_viewer_page.dart';
import 'media_filter_page.dart';
import 'video_page.dart';

/// HTML 02 / 03：浏览页。正常模式过滤隐藏目录，隐藏模式全部可见并给眼睛按钮。
class BrowsePage extends ConsumerStatefulWidget {
  const BrowsePage({
    super.key,
    this.directory = '/',
    this.canPop = false,
    this.onOpenSettings,
  });

  final String directory;
  final bool canPop;

  /// 只有 Tab 根页面传这个回调；子目录页不显示齿轮。
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends ConsumerState<BrowsePage> {
  bool _searching = false;
  final _search = TextEditingController();

  // 已删项先本地过滤掉，保证 Dismissible 在服务器刷新回来之前能干净移除，
  // 不会触发「已 dismiss 却还在树上」断言。
  final _dismissed = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _path => widget.directory;

  void _open(RemoteEntry entry) {
    switch (entry.kind) {
      case FileKind.folder:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => BrowsePage(directory: entry.path, canPop: true)),
        );
      case FileKind.image:
        final images = ref.read(dirImagesProvider(_path));
        final index = images.indexWhere((e) => e.path == entry.path);
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ImageViewerPage(images: images, initialIndex: index)),
        );
      case FileKind.video:
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPage(entry: entry)));
      case FileKind.audio:
        final audios = ref.read(dirAudiosProvider(_path));
        final index = audios.indexWhere((e) => e.path == entry.path);
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AudioPlayerPage(playlist: audios, initialIndex: index < 0 ? 0 : index)),
        );
      case FileKind.archive:
        if (!entry.isZip) {
          showVaultToast(context, 'v1 只支持 ZIP，RAR / 7z 暂未实现', error: true);
          return;
        }
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ArchivePage(entry: entry)));
      case FileKind.doc:
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocViewerPage(entry: entry)));
      case FileKind.other:
        showVaultToast(context, '${entry.name} 不是可预览的文件类型', error: true);
    }
  }

  Future<void> _toggleHidden(RemoteEntry entry) async {
    final hidden = ref.read(hiddenDirsProvider.notifier).isHidden(entry.path);
    await ref.read(hiddenDirsProvider.notifier).setHidden(entry, !hidden);
    if (!mounted) return;
    showVaultToast(context, hidden ? '已取消隐藏 ${entry.name}' : '已隐藏 ${entry.name}');
  }

  List<RemoteEntry> _filtered(List<RemoteEntry> entries) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return entries;
    return entries.where((e) => e.name.toLowerCase().contains(query)).toList();
  }

  Future<void> _refresh() async {
    ref.invalidate(dirRawProvider(_path));
    await ref.read(dirRawProvider(_path).future);
  }

  /// 左滑删除：先二次确认（远端永久删除，不可恢复），确认后才发 DELETE。
  /// 返回 true 才让 Dismissible 收起；失败弹提示并返回 false，行自动弹回。
  Future<bool> _confirmAndDelete(RemoteEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VaultColors.surface,
        title: Text(
          entry.isDir ? '删除整个目录？' : '删除这个文件？',
          style: TextStyle(fontSize: 16, color: VaultColors.text),
        ),
        content: Text(
          '「${entry.name}」${entry.isDir ? ' 及其内部所有内容' : ''}将从服务器上永久删除，无法恢复。',
          style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: VaultColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    try {
      await ref.read(davProvider).delete(entry.path);
    } on WebDavError catch (e) {
      if (mounted) showVaultToast(context, e.message, error: true);
      return false;
    } on Object catch (e) {
      if (mounted) showVaultToast(context, '删除失败：$e', error: true);
      return false;
    }
    if (!mounted) return false;
    setState(() => _dismissed.add(entry.path));
    showVaultToast(context, '已删除 ${entry.name}');
    return true;
  }

  Widget _deleteSlate(RemoteEntry entry) {
    final label = entry.isDir ? '删除目录' : '删除';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        color: VaultColors.dangerBg,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          VIcon('trash', size: 18, color: VaultColors.danger),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12.5, color: VaultColors.danger)),
        ],
      ),
    );
  }

  /// 顶部搜索框：按名称过滤当前目录已可见条目（本地，不重新发 PROPFIND）。
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: VaultColors.field,
          borderRadius: BorderRadius.circular(VaultRadius.field),
          border: Border.all(color: VaultColors.line2),
        ),
        child: Row(
          children: [
            VIcon('search', size: 16, color: VaultColors.dim),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                style: TextStyle(fontSize: 13.5, color: VaultColors.text),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '按名称搜索当前目录',
                  hintStyle: TextStyle(fontSize: 13.5, color: VaultColors.dim),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 三点分类过滤：图片 / 视频 / 音频。进入独立页，递归当前目录子树后平铺展示。
  void _showFilterMenu() {
    final width = MediaQuery.of(context).size.width;
    final top = MediaQuery.of(context).padding.top + 52;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(width - 132, top, 12, 0),
      color: VaultColors.surface,
      items: [
        PopupMenuItem(value: 'image', child: _FilterMenuItem(icon: 'image', label: '图片', color: VaultColors.green)),
        PopupMenuItem(value: 'video', child: _FilterMenuItem(icon: 'video', label: '视频', color: VaultColors.purple)),
        PopupMenuItem(value: 'audio', child: _FilterMenuItem(icon: 'audio', label: '音频', color: VaultColors.accentText)),
      ],
    ).then((value) {
      if (value == null || !mounted) return;
      final kind = switch (value) {
        'image' => FileKind.image,
        'video' => FileKind.video,
        _ => FileKind.audio,
      };
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MediaFilterPage(root: _path, kind: kind)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final hiddenMode = ref.watch(hiddenModeProvider);
    final preload = ref.watch(settingsProvider).preloadEnabled;
    final list = ref.watch(dirRawProvider(_path));
    final visible = _filtered(ref.watch(dirEntriesProvider(_path)))
        .where((e) => !_dismissed.contains(e.path))
        .toList();

    return VaultAnnotatedRegion(
      child: Scaffold(
        body: Column(
          children: [
            SizedBox(height: MediaQuery.of(context).padding.top),
            VaultAppBar(
              title: widget.canPop ? RemotePath.nameOf(_path) : '浏览',
              leading: widget.canPop
                  ? IconBtn(icon: 'back', onTap: () => Navigator.of(context).maybePop())
                  : null,
              actions: [
                if (hiddenMode && !widget.canPop) const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: HmBadge(text: '隐藏模式', icon: 'lock'),
                    ),
                IconBtn(
                  icon: 'search',
                  color: _searching ? VaultColors.accent : VaultColors.muted,
                  onTap: () => setState(() {
                    _searching = !_searching;
                    if (!_searching) _search.clear();
                  }),
                ),
                IconBtn(icon: 'more', color: VaultColors.muted, onTap: _showFilterMenu),
                if (widget.onOpenSettings != null) IconBtn(icon: 'gear', onTap: widget.onOpenSettings),
              ],
            ),
            _breadcrumb(hiddenMode, preload),
            if (_searching) _searchBar(),
            Expanded(
              child: list.when(
                loading: () => const Center(
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2)),
                ),
                error: (error, _) => VaultEmpty(
                  icon: 'shield',
                  title: error is WebDavError ? error.message : '无法读取该目录',
                  action: PrimaryButton(label: '重新连接', compact: true, onPressed: () {
                    ref.invalidate(sessionProvider);
                  }),
                ),
                data: (entries) {
                  if (entries.isEmpty) {
                    return const VaultEmpty(icon: 'folderOpen', title: '这个目录还是空的');
                  }
                  if (visible.isEmpty) {
                    return const VaultEmpty(icon: 'search', title: '没有匹配的条目');
                  }
                  return RefreshIndicator(
                    color: VaultColors.accent,
                    backgroundColor: VaultColors.surface2,
                    onRefresh: _refresh,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 2, 14, 24),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final entry = visible[index];
                        return Dismissible(
                          key: ValueKey('swipe-${entry.path}'),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (_) => _confirmAndDelete(entry),
                          onDismissed: (_) => _refresh(),
                          background: _deleteSlate(entry),
                          child: _EntryRow(
                            entry: entry,
                            hiddenMode: hiddenMode,
                            onTap: () => _open(entry),
                            onLongPress: hiddenMode ? () => _toggleHidden(entry) : null,
                            onToggleHidden: () => _toggleHidden(entry),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 面包屑：左侧路径，右侧预加载状态（隐藏模式时改成紫色提示）。
  Widget _breadcrumb(bool hiddenMode, bool preload) {
    final crumbs = RemotePath.breadcrumbs(_path);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0) Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Text('/', style: TextStyle(fontSize: 12.5, color: VaultColors.chevron)),
                        ),
                    Text(
                      i == 0 ? '根目录' : RemotePath.nameOf(crumbs[i]),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: i == crumbs.length - 1 ? VaultColors.text : VaultColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hiddenMode ? VaultColors.purple : (preload ? VaultColors.green : VaultColors.dim),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                hiddenMode ? '长按行可隐藏' : (preload ? '预加载已开启' : '预加载已关闭'),
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.2,
                  color: hiddenMode ? VaultColors.purpleDeep : (preload ? VaultColors.green : VaultColors.dim),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends ConsumerWidget {
  const _EntryRow({
    required this.entry,
    required this.hiddenMode,
    required this.onTap,
    required this.onToggleHidden,
    this.onLongPress,
  });

  final RemoteEntry entry;
  final bool hiddenMode;
  final VoidCallback onTap;
  final VoidCallback onToggleHidden;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHidden = ref.watch(hiddenDirsProvider).any((e) => e.path == entry.path);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: _tileColor(isHidden).withValues(alpha: 0.11),
              ),
              child: Center(
                child: VIcon(_iconName(isHidden), size: 19, color: _tileColor(isHidden)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: isHidden ? const Color(0xFFC4B8DC) : VaultColors.text,
                          ),
                        ),
                      ),
                      if (isHidden) ...[
                        const SizedBox(width: 6),
                        const HmBadge(text: '已隐藏', icon: 'lock', dense: true),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(context, ref),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isHidden ? const Color(0xFF7A6F92) : VaultColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (hiddenMode)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggleHidden,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: isHidden ? VaultColors.purple.withValues(alpha: 0.1) : Colors.transparent,
                  ),
                  child: Center(
                    child: VIcon(
                      'eye',
                      size: 17,
                      color: isHidden ? VaultColors.purple : VaultColors.subtle,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            VIcon('chevron', size: 16, color: VaultColors.chevron),
          ],
        ),
      ),
    );
  }

  String _iconName(bool isHidden) {
    if (isHidden) return 'lock';
    return switch (entry.kind) {
      FileKind.folder => 'folder',
      FileKind.image => 'image',
      FileKind.video => 'video',
      FileKind.audio => 'audio',
      FileKind.archive => 'zip',
      FileKind.doc => 'doc',
      FileKind.other => 'list',
    };
  }

  Color _tileColor(bool isHidden) {
    if (isHidden) return VaultColors.purpleDeep;
    return switch (entry.kind) {
      FileKind.folder => VaultColors.blue,
      FileKind.image => VaultColors.green,
      FileKind.video => VaultColors.purple,
      FileKind.audio => VaultColors.accentText,
      FileKind.archive => VaultColors.orange,
      FileKind.doc => VaultColors.accent,
      FileKind.other => VaultColors.muted,
    };
  }

  String _subtitle(BuildContext context, WidgetRef ref) {
    if (entry.isDir) {
      final stat = ref.watch(folderStatProvider(entry.path));
      final base = stat.when(
        loading: () => '统计中…',
        error: (_, __) => '—',
        data: (value) => value.count == 0 ? '空目录' : '${formatCount(value.count)} 项 · ${formatBytes(value.bytes)}',
      );
      if (ref.watch(hiddenModeProvider) && ref.watch(hiddenDirsProvider).any((e) => e.path == entry.path)) {
        return '$base · 仅隐藏模式下可见';
      }
      return base;
    }
    final time = formatRelativeTime(entry.modified);
    final size = entry.size > 0 ? formatBytes(entry.size) : '—';
    if (entry.kind == FileKind.archive && entry.isZip) return '$size · 按需解压后可浏览';
    return time.isEmpty ? size : '$size · $time';
  }
}

/// 三点菜单里的一行：小图标 + 文字。
class _FilterMenuItem extends StatelessWidget {
  const _FilterMenuItem({required this.icon, required this.label, required this.color});

  final String icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        VIcon(icon, size: 17, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13.5, color: VaultColors.text)),
      ],
    );
  }
}
