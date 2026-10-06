import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/webdav_client.dart';
import '../state/browse_providers.dart';
import '../state/session_providers.dart';

/// 上传目标选择器：只能进目录，pop 时返回选中的远程路径。
class DirPickerPage extends ConsumerStatefulWidget {
  const DirPickerPage({this.initial = '/', super.key});

  final String initial;

  @override
  ConsumerState<DirPickerPage> createState() => _DirPickerPageState();
}

class _DirPickerPageState extends ConsumerState<DirPickerPage> {
  late String _path = RemotePath.normalize(widget.initial);

  void _select() => Navigator.of(context).pop(_path);

  Future<void> _createDirectory() async {
    final name = await _askName();
    if (name == null || name.trim().isEmpty) return;
    final target = RemotePath.join(_path, name.trim());
    try {
      await ref.read(davProvider).createDirectory(target);
      ref.invalidate(dirRawProvider(_path));
      if (mounted) showVaultToast(context, '已创建 $target');
    } on WebDavError catch (e) {
      if (mounted) showVaultToast(context, e.message, error: true);
    }
  }

  Future<String?> _askName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VaultColors.surface,
        title: const Text('新建目录', style: TextStyle(fontSize: 16, color: VaultColors.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 14, color: VaultColors.text),
          decoration: const InputDecoration(
            hintText: '目录名',
            hintStyle: TextStyle(color: VaultColors.dim),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hiddenMode = ref.watch(hiddenModeProvider);
    final entries = ref.watch(dirEntriesProvider(_path));

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              VaultAppBar(
                leading: IconBtn(icon: 'back', onTap: () => Navigator.of(context).maybePop()),
                title: '选择上传目录',
                subtitle: hiddenMode ? '隐藏模式 · 可见全部目录' : null,
                actions: [IconBtn(icon: 'plus', onTap: _createDirectory)],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 2, 22, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _path,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: VaultColors.accent,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ref.watch(dirRawProvider(_path)).when(
                  loading: () => const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
                    ),
                  ),
                  error: (error, _) => VaultEmpty(
                    icon: 'folder',
                    title: error is WebDavError ? error.message : '读取目录失败',
                  ),
                  data: (list) {
                    final dirs = entries.where((e) => e.isDir).toList();
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                      children: [
                        _row(name: '↑ 上一级', enabled: _path != '/', onTap: () => setState(() => _path = RemotePath.parent(_path))),
                        ...dirs.map(
                          (dir) => _row(
                            name: dir.name,
                            enabled: true,
                            isFolder: true,
                            onTap: () => setState(() => _path = dir.path),
                          ),
                        ),
                        if (dirs.isEmpty) const VaultEmpty(icon: 'folder', title: '这里还没有子目录'),
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: PrimaryButton(label: '上传到这里', onPressed: _select),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row({required String name, required bool enabled, bool isFolder = false, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: VaultColors.line))),
        child: Row(
          children: [
            VIcon(isFolder ? 'folder' : 'back', size: 18, color: isFolder ? VaultColors.blue : VaultColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: enabled ? VaultColors.text : const Color(0xFF454B53),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (enabled && isFolder) const VIcon('chevron', size: 16, color: Color(0xFF3A3F46)),
          ],
        ),
      ),
    );
  }
}
