import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/box_cache_api.dart';
import '../state/session_providers.dart';

/// 离线下载任务列表。
///
/// 刻意**不进页面就发请求**：盒子那边一个任务可能跑几十分钟，列表只需要记住任务 id，
/// 用户想看进展时点行右侧「查询状态」才去问一次。删任务也只删本机这条记录，
/// 不给接口发任何请求（盒子会继续把目录搬完）。
class CacheTasksPage extends ConsumerStatefulWidget {
  const CacheTasksPage({super.key});

  @override
  ConsumerState<CacheTasksPage> createState() => _CacheTasksPageState();
}

class _CacheTasksPageState extends ConsumerState<CacheTasksPage> {
  final _busy = <String>{};

  /// 查询失败时的提示，按任务 id 存，只在本页内存里。
  final _notice = <String, String>{};

  Future<void> _query(CacheTaskRecord record) async {
    if (_busy.contains(record.id)) return;
    setState(() {
      _busy.add(record.id);
      _notice.remove(record.id);
    });
    try {
      final task = await ref.read(boxCacheProvider).task(record.id);
      await ref.read(cacheTasksProvider.notifier).update(record.withTask(task));
    } on BoxCacheError catch (e) {
      if (e.code == 'no_task' || e.status == 404) {
        setState(() => _notice[record.id] = '盒子上已经没有这条记录（只保留最近 200 条），可以删掉。');
      } else {
        setState(() => _notice[record.id] = e.humanMessage);
      }
    } on Object catch (e) {
      setState(() => _notice[record.id] = '查询失败：$e');
    }
    if (!mounted) return;
    setState(() => _busy.remove(record.id));
  }

  Future<void> _delete(CacheTaskRecord record) async {
    if (record.isActive) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: VaultColors.surface,
          title: Text('删掉这条记录？', style: TextStyle(fontSize: 16, color: VaultColors.text)),
          content: Text(
            '「${record.name}」还在盒子里跑着。这里只是把记录从任务列表移掉，'
            '盒子那边会继续搬完，不会停，也不会删已下好的文件。',
            style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('删记录', style: TextStyle(color: VaultColors.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref.read(cacheTasksProvider.notifier).remove(record.id);
    if (!mounted) return;
    showVaultToast(context, '已从任务列表移除');
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(cacheTasksProvider);

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              VaultAppBar(
                title: '离线下载任务',
                leading: IconBtn(icon: 'back', onTap: () => Navigator.of(context).maybePop()),
              ),
              if (tasks.isEmpty)
                Expanded(
                  child: VaultEmpty(
                    icon: 'download',
                    title: '还没有提交过离线下载',
                    action: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '在浏览页长按目录即可把整个云端目录缓存到盒子。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: VaultColors.dim, height: 1.6),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 6, 22, 10),
                        child: Text(
                          '这里只记着任务号，不会自动去问盒子。想看进展点右侧「查询状态」。',
                          style: TextStyle(fontSize: 11.5, color: VaultColors.dim, height: 1.55),
                        ),
                      ),
                      for (final task in tasks) _taskCard(task),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _taskCard(CacheTaskRecord record) {
    final notice = _notice[record.id];
    return VaultCard(
      padding: const EdgeInsets.fromLTRB(15, 13, 13, 13),
      margin: const EdgeInsets.only(bottom: 10),
      children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 只显示目录名，不显示 src 全路径：这一行在退出隐藏模式后仍然看得见，
              // 把云端层级（例如 来自分享/高中）整个摊开等于替用户把内容来源说出去了。
              Expanded(
                child: Text(
                  record.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: VaultColors.text),
                ),
              ),
              const SizedBox(width: 10),
              _StatePill(state: record.state),
            ],
          ),
          const SizedBox(height: 9),
          Text(_summary(record), style: TextStyle(fontSize: 11.5, color: VaultColors.muted, height: 1.55)),
          if (record.error != null && record.state != CacheState.done) ...[
            const SizedBox(height: 6),
            Text(
              record.error!,
              style: TextStyle(
                // 失败用红色；被取消/被打断只是「停下来」，语气要平一些。
                fontSize: 11.5,
                color: record.state == CacheState.failed ? VaultColors.dangerSoft : VaultColors.muted,
                height: 1.55,
              ),
            ),
          ],
          if (notice != null) ...[
            const SizedBox(height: 6),
            Text(notice, style: TextStyle(fontSize: 11.5, color: VaultColors.dangerSoft, height: 1.55)),
          ],
          const SizedBox(height: 11),
          Row(
            children: [
              Text(
                '${cacheTargetLabel(record.to)} · ${formatRelativeTime(DateTime.fromMillisecondsSinceEpoch(record.createdAt * 1000))}提交',
                style: TextStyle(fontSize: 11, color: VaultColors.dim),
              ),
              const Spacer(),
              IconBtn(icon: 'trash', color: VaultColors.dim, onTap: () => _delete(record)),
              const SizedBox(width: 6),
              _QueryButton(
                label: record.state == null ? '查询状态' : '再查一次',
                busy: _busy.contains(record.id),
                onTap: () => _query(record),
              ),
            ],
          ),
      ],
    );
  }

  String _summary(CacheTaskRecord record) {
    final state = record.state;
    if (state == null) return '还没查过状态，盒子那边多半已经在跑了。';
    final parts = <String>[state.label];
    final pct = record.pct;
    if (pct != null && pct > 0) parts.add('${pct.toStringAsFixed(1)}%');
    final total = record.totalBytes;
    final done = record.doneBytes;
    if (total != null && total > 0 && done != null) {
      parts.add('${formatBytes(done)} / ${formatBytes(total)}');
    }
    if (state == CacheState.running && record.speedBps != null) {
      parts.add('${formatBytes(record.speedBps!)}/s');
    }
    // eta_s 是「按当前速度算」的粗估，云盘限流一抖就变，所以只说个约数。
    if (state.isActive && record.etaS != null) {
      final minutes = (record.etaS! / 60).ceil();
      parts.add(minutes <= 1 ? '约 1 分钟内' : '约 $minutes 分钟');
    }
    // 这三种状态用户最容易误判：排队不是卡死，打断/取消也不是白跑。
    final hint = switch (state) {
      CacheState.queued => ' —— 盒子同时只跑一个同步，前面的（或管理员手工跑的）让出锁才轮到这条',
      CacheState.interrupted => ' —— 盒子重启打断的，重新提交同一个目录会接着传，已落盘的不用重下',
      CacheState.canceled => ' —— 已落盘的部分留着，重新提交同一个目录会接着传',
      _ => '',
    };
    return '${parts.join(' · ')}$hint';
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.state});

  final CacheState? state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      null => VaultColors.dim,
      CacheState.queued => VaultColors.orange,
      CacheState.running => VaultColors.accent,
      CacheState.done => VaultColors.green,
      CacheState.failed => VaultColors.danger,
      CacheState.canceled => VaultColors.muted,
      CacheState.interrupted => VaultColors.danger,
    };
    final label = state?.label ?? '未查';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _QueryButton extends StatelessWidget {
  const _QueryButton({required this.label, required this.busy, required this.onTap});

  final String label;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: VaultColors.field,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: VaultColors.line),
        ),
        child: busy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: VaultColors.accent),
              )
            : Text(label, style: TextStyle(fontSize: 11.5, color: VaultColors.accent)),
      ),
    );
  }
}
