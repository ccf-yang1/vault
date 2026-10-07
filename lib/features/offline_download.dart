import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/box_cache_api.dart';
import '../state/session_providers.dart';

/// tab1 长按目录弹出的动作面板。
///
/// 长按原本只被隐藏模式占用（用户其实多用行尾的小眼睛），所以这里统一成动作面板：
/// 目录才有「下载到盒子」，隐藏模式下再并列一条「隐藏 / 取消隐藏」。
Future<void> showEntryActionsSheet(
  BuildContext context,
  RemoteEntry entry, {
  required bool hiddenMode,
  required bool hidden,
  required VoidCallback onToggleHidden,
}) async {
  if (!entry.isDir) return;
  final src = cacheSrcFor(entry.path);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: VaultColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                VIcon('folderLine', size: 17, color: VaultColors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: VaultColors.text),
                  ),
                ),
              ],
            ),
          ),
          if (src != null)
            _SheetAction(
              icon: 'download',
              title: '下载到盒子',
              caption: '把这个云端目录整体缓存到盒子本地盘',
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final task = await showDialog<CacheTask>(
                  context: context,
                  builder: (_) => OfflineDownloadDialog(entry: entry, src: src),
                );
                if (task != null && context.mounted) {
                  showVaultToast(context, '已提交「${entry.name}」，进度到 设置 · 离线下载任务 里查');
                }
              },
            )
          else
            _SheetAction(
              icon: 'download',
              title: '下载到盒子',
              caption: '顶层目录本身就是云盘挂载点，没法再往上取一层',
              enabled: false,
              onTap: () {},
            ),
          if (hiddenMode)
            _SheetAction(
              icon: hidden ? 'eye' : 'eyeOff',
              title: hidden ? '取消隐藏此目录' : '隐藏此目录',
              caption: '只在 App 里藏起来，服务器上不动',
              onTap: () {
                Navigator.of(sheetContext).pop();
                onToggleHidden();
              },
            ),
          const SizedBox(height: 4),
        ],
      ),
    ),
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
    this.enabled = true,
  });

  final String icon;
  final String title;
  final String caption;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? VaultColors.text : VaultColors.dim;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            VIcon(icon, size: 19, color: enabled ? VaultColors.accent : VaultColors.dim),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14, color: color)),
                  const SizedBox(height: 2),
                  Text(
                    caption,
                    style: TextStyle(fontSize: 11.5, color: enabled ? VaultColors.muted : VaultColors.dim, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Phase { probing, ready, boxError, submitting, submitError }

/// 「下载到盒子」确认框：进去先探盒子是否就绪、有哪些落点，顺手估个大小。
///
/// 估算只是加分项：大目录列云端要几分钟，所以只等 10 秒，问不到就降级成「大小未知」
/// 继续让用户提交；盒子空间不足（`will_fit=false`）时禁用提交按钮，省得白跑一趟。
class OfflineDownloadDialog extends ConsumerStatefulWidget {
  const OfflineDownloadDialog({required this.entry, required this.src, super.key});

  final RemoteEntry entry;

  /// 接口要的云端路径：浏览路径剥掉第一层（云盘挂载目录），见 [cacheSrcFor]。
  final String src;

  @override
  ConsumerState<OfflineDownloadDialog> createState() => _OfflineDownloadDialogState();
}

class _OfflineDownloadDialogState extends ConsumerState<OfflineDownloadDialog> {
  _Phase _phase = _Phase.probing;
  List<String> _targets = const [];
  String? _to;
  CacheEstimate? _estimate;
  bool _estimating = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
  }

  Future<void> _probe() async {
    final api = ref.read(boxCacheProvider);
    try {
      final health = await api.health();
      if (!mounted) return;
      if (!health.ready) {
        setState(() {
          _phase = _Phase.boxError;
          _message = '盒子端还没准备好（rclone 或管理脚本缺失），现在提交必然失败。请在盒子上跑 ol-setup 修好再来。';
        });
        return;
      }
      if (health.targets.isEmpty) {
        setState(() {
          _phase = _Phase.boxError;
          _message = '盒子上没有可用的缓存落点目录。';
        });
        return;
      }
      final first = health.targets.first;
      setState(() {
        _targets = health.targets;
        _to = first;
        _phase = _Phase.ready;
      });
      await _estimateFor(first);
    } on BoxCacheError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.boxError;
        _message = e.humanMessage;
      });
    }
  }

  /// 换落点要重算：`sub` 由 `src` 推，落点决定 dest 与剩余空间。
  Future<void> _estimateFor(String to) async {
    setState(() {
      _to = to;
      _estimate = null;
      _estimating = true;
    });
    final estimate = await ref
        .read(boxCacheProvider)
        .estimate(to: to, src: widget.src, sub: cacheSubFor(widget.src));
    if (!mounted || _to != to) return;
    setState(() {
      _estimate = estimate;
      _estimating = false;
    });
  }

  Future<void> _submit() async {
    final to = _to;
    if (to == null || _phase == _Phase.submitting) return;
    setState(() => _phase = _Phase.submitting);
    try {
      final task = await ref
          .read(boxCacheProvider)
          .create(to: to, src: widget.src, sub: cacheSubFor(widget.src));
      await ref.read(cacheTasksProvider.notifier).add(CacheTaskRecord.fromTask(task));
      if (!mounted) return;
      Navigator.of(context).pop(task);
    } on BoxCacheError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.submitError;
        _message = e.humanMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VaultColors.surface,
      title: Text(_title, style: TextStyle(fontSize: 16, color: VaultColors.text)),
      content: SizedBox(width: 300, child: _body()),
      actions: _actions(),
    );
  }

  String get _title => switch (_phase) {
        _Phase.submitting => '正在提交',
        _Phase.boxError || _Phase.submitError => '没法提交',
        _ => '下载到盒子',
      };

  Widget _body() {
    if (_phase == _Phase.probing) return _busy('正在问盒子…');
    if (_phase == _Phase.submitting) {
      return _busy('正在提交。大目录服务端要先列一遍云端，最长可能等两分钟。\n\n'
          '这期间别重复提交 —— 就算这里超时了，盒子那边多半照样把任务跑起来了，'
          '可以去 设置 · 离线下载任务 里点「查询状态」确认。');
    }
    if (_phase == _Phase.boxError || _Phase.submitError == _phase) {
      return Text(_message, style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6));
    }
    final entry = widget.entry;
    final estimate = _estimate;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('「${entry.name}」', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: VaultColors.text)),
        const SizedBox(height: 3),
        Text('云端目录：${widget.src}', style: TextStyle(fontSize: 11.5, color: VaultColors.dim)),
        const SizedBox(height: 10),
        if (_targets.length > 1) ...[
          Text('缓存到', style: TextStyle(fontSize: 12, color: VaultColors.muted)),
          for (final target in _targets)
            _TargetOption(
              label: _targetLabel(target),
              selected: _to == target,
              onTap: () => _estimateFor(target),
            ),
          const SizedBox(height: 8),
        ] else
          Text('缓存到：${_targetLabel(_to ?? 'local')}', style: TextStyle(fontSize: 12.5, color: VaultColors.muted)),
        const SizedBox(height: 10),
        Text(
          _estimating
              ? '正在估算大小…'
              : estimate == null
                  ? '大小暂时问不出来（云端列目录慢），仍可以提交。'
                  : '约 ${formatBytes(estimate.cloudBytes ?? 0)}'
                      '${estimate.cloudFiles == null ? '' : ' · ${estimate.cloudFiles} 个文件'}'
                      ' · 盒子还剩 ${estimate.freeGb?.toStringAsFixed(1) ?? '?'} GB',
          style: TextStyle(fontSize: 12.5, color: _willNotFit ? VaultColors.danger : VaultColors.text, height: 1.5),
        ),
        const SizedBox(height: 12),
        Text(
          '搬的是这个目录里的全部文件，不只视频；云端原文件不动。\n'
          '下载速度由云盘限流决定，实测 180 MB 约 16 分钟，几十 GB 可能跑几小时；'
          '提交后可以退出 App，盒子会接着跑。',
          style: TextStyle(fontSize: 11.5, color: VaultColors.dim, height: 1.55),
        ),
      ],
    );
  }

  bool get _willNotFit => _estimate?.willFit == false;

  Widget _busy(String text) => Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, color: VaultColors.muted, height: 1.55)),
          ),
        ],
      );

  List<Widget> _actions() => switch (_phase) {
        _Phase.probing || _Phase.submitting => [],
        _Phase.boxError || _Phase.submitError => [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
          ],
        _ => [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('取消', style: TextStyle(color: VaultColors.muted))),
            TextButton(
              onPressed: _willNotFit ? null : _submit,
              child: Text(_willNotFit ? '空间不够' : '开始缓存', style: TextStyle(color: VaultColors.accent)),
            ),
          ],
      };

  static String _targetLabel(String to) => switch (to) {
        'local' => '私人那份（:5244 的 /local）',
        'common' => '家庭那份（:15244 的 /common）',
        _ => to,
      };
}

/// 落点单选：跟主题页那种「一行一个候选」的观感一致，不用系统 Radio。
class _TargetOption extends StatelessWidget {
  const _TargetOption({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? VaultColors.accent : VaultColors.line, width: 2),
              ),
              child: selected ? Center(child: Container(width: 6, height: 6, decoration: BoxDecoration(color: VaultColors.accent, shape: BoxShape.circle))) : null,
            ),
            const SizedBox(width: 9),
            Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, color: selected ? VaultColors.text : VaultColors.muted))),
          ],
        ),
      ),
    );
  }
}
