import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/session_providers.dart';
import '../state/upload_providers.dart';
import 'dir_picker_page.dart';

/// HTML 04（新版）：上传页。按天分组、可选本日 / 最近 N 天 / 单选，
/// 导出到 App 沙盒临时文件再 PUT，传完即删（需求 §3.6）。
class UploadPage extends ConsumerStatefulWidget {
  const UploadPage({super.key});

  @override
  ConsumerState<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends ConsumerState<UploadPage> {
  String _directory = '/';
  bool _directoryLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(uploadProvider.notifier).requestPermissionAndLoad();
    });
  }

  Future<void> _pickDirectory() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => DirPickerPage(initial: _directory)),
    );
    if (picked == null) return;
    setState(() => _directory = picked);
    ref.read(settingsProvider.notifier).setUploadPath(picked);
  }

  Future<void> _customDays() async {
    var chosen = ref.read(settingsProvider).recentDays.clamp(1, 30);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: VaultColors.surface,
          title: const Text('最近 N 天', style: TextStyle(fontSize: 16, color: VaultColors.text)),
          content: SizedBox(
            width: 240,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('选中最近 $chosen 天拍摄的照片', style: const TextStyle(fontSize: 12.5, color: VaultColors.muted)),
                const SizedBox(height: 12),
                Slider(
                  value: chosen.toDouble(),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  label: '$chosen 天',
                  onChanged: (value) => setDialogState(() => chosen = value.round()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('选中')),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await ref.read(uploadProvider.notifier).selectRecentDays(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(uploadProvider);
    final controller = ref.read(uploadProvider.notifier);
    final settings = ref.watch(settingsProvider);
    if (!_directoryLoaded) {
      _directory = settings.defaultUploadPath;
      _directoryLoaded = true;
    }

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const VaultAppBar(title: '上传'),
              _destCard(),
              _chips(state),
              Expanded(child: _assets(state, controller)),
              if (state.uploading || state.tasks.isNotEmpty) _queue(state, controller),
              _selBar(state, controller),
            ],
          ),
        ),
      ),
    );
  }

  Widget _destCard() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _pickDirectory,
      child: Container(
        height: 44,
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: VaultColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VaultColors.line),
        ),
        child: Row(
          children: [
            const VIcon('folder', size: 16, color: VaultColors.accent),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                _directory,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFC9CDD4),
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const Text('更改', style: TextStyle(fontSize: 12, color: VaultColors.accent)),
          ],
        ),
      ),
    );
  }

  Widget _chips(UploadState state) {
    Widget chip(String label, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 7),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              color: VaultColors.field,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: VaultColors.line),
            ),
            child: Text(label, style: const TextStyle(fontSize: 12, color: VaultColors.muted)),
          ),
        ),
      );
    }

    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          chip('今天全部', () {
            ref.read(uploadProvider.notifier).selectToday();
          }),
          chip('最近 2 天', () {
            ref.read(uploadProvider.notifier).selectRecentDays(2);
          }),
          chip('最近 3 天', () {
            ref.read(uploadProvider.notifier).selectRecentDays(3);
          }),
          chip('自定义', _customDays),
          chip('清空选择', () {
            ref.read(uploadProvider.notifier).clearSelection();
          }),
        ],
      ),
    );
  }

  Widget _assets(UploadState state, UploadController controller) {
    if (state.loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
        ),
      );
    }
    if (!permissionGranted(state.permission)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const VIcon('image', size: 28, color: Color(0xFF3A3F46)),
              const SizedBox(height: 14),
              const Text(
                '没有相册读取权限，无法选择要上传的照片。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: '重新请求权限',
                onPressed: () => controller.requestPermissionAndLoad(),
              ),
              const SizedBox(height: 10),
              GhostButton(
                label: '去系统设置',
                onPressed: () => PhotoManager.openSetting(),
              ),
            ],
          ),
        ),
      );
    }
    if (state.assets.isEmpty) {
      return const VaultEmpty(icon: 'image', title: '相册是空的');
    }

    final buckets = groupByDay(state.assets);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: buckets.length,
      itemBuilder: (context, index) {
        final bucket = buckets[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 9),
              child: Row(
                children: [
                  Expanded(child: Text(formatDayLabel(bucket.day), style: const TextStyle(fontSize: 12.5, color: Color(0xFFB9BEC6)))),
                  Text('${bucket.assets.length} 项', style: const TextStyle(fontSize: 11, color: VaultColors.dim)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => controller.selectAll(bucket.assets),
                    child: const Text('全选', style: TextStyle(fontSize: 11.5, color: VaultColors.accent)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                ),
                itemCount: bucket.assets.length > 12 ? 12 : bucket.assets.length,
                itemBuilder: (context, i) => _Cell(
                  asset: bucket.assets[i],
                  selected: state.selected.contains(bucket.assets[i].id),
                  onTap: () => controller.toggle(bucket.assets[i]),
                ),
              ),
            ),
            if (bucket.assets.length > 12)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text('还有 ${bucket.assets.length - 12} 项未显示', style: const TextStyle(fontSize: 11, color: VaultColors.dim)),
              ),
          ],
        );
      },
    );
  }

  Widget _queue(UploadState state, UploadController controller) {
    final tasks = state.tasks;
    final shown = tasks.length > 4 ? tasks.sublist(tasks.length - 4) : tasks;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: VaultColors.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VaultColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '上传中 ${state.doneCount} / ${tasks.length}',
                style: const TextStyle(fontSize: 12, color: VaultColors.text),
              ),
              const Spacer(),
              if (state.uploading)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: controller.cancelUpload,
                  child: const Text('取消', style: TextStyle(fontSize: 12, color: Color(0xFFE0736A))),
                )
              else if (state.failedCount > 0)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: controller.retryFailed,
                  child: Text('重试 ${state.failedCount} 项', style: const TextStyle(fontSize: 12, color: VaultColors.accent)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: state.overallProgress,
              minHeight: 3,
              backgroundColor: VaultColors.surface2,
              valueColor: AlwaysStoppedAnimation(state.failedCount > 0 ? VaultColors.orange : VaultColors.accent),
            ),
          ),
          const SizedBox(height: 8),
          for (final task in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    switch (task.status) {
                      UploadStatus.done => Icons.check_circle_outline_rounded,
                      UploadStatus.failed => Icons.error_outline_rounded,
                      UploadStatus.canceled => Icons.remove_circle_outline_rounded,
                      _ => Icons.arrow_upward_rounded,
                    },
                    size: 13,
                    color: switch (task.status) {
                      UploadStatus.done => VaultColors.green,
                      UploadStatus.failed => const Color(0xFFE0736A),
                      UploadStatus.canceled => VaultColors.dim,
                      _ => VaultColors.accent,
                    },
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      task.error != null ? '${task.fileName} · ${task.error}' : task.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: VaultColors.muted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _selBar(UploadState state, UploadController controller) {
    final message = state.message;
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: VaultColors.line))),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(message, style: const TextStyle(fontSize: 11.5, color: Color(0xFFE0736A))),
            ),
          Row(
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 12.5, color: VaultColors.muted),
                    children: [
                      TextSpan(
                        text: '${state.selected.length}',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFEDEEF0)),
                      ),
                      TextSpan(text: ' 项 · ${formatBytes(state.selectedBytes)}'),
                    ],
                  ),
                ),
              ),
              PrimaryButton(
                label: state.uploading ? '上传中' : '上传到 WebDAV',
                compact: true,
                loading: state.uploading,
                onPressed: state.uploading || state.selected.isEmpty
                    ? null
                    : () => controller.startUpload(_directory),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.asset, required this.selected, required this.onTap});

  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Thumb(asset: asset),
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? VaultColors.accent : Colors.black.withValues(alpha: 0.28),
                border: Border.all(color: selected ? VaultColors.accent : Colors.white70, width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
                  : null,
            ),
          ),
          if (selected)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: VaultColors.accent, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.asset});

  final AssetEntity asset;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize(180, 180)),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Container(color: VaultColors.surface2);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        );
      },
    );
  }
}
