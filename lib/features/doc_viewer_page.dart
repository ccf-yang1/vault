import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/browse_providers.dart';

/// 通用文档：下载沙盒后交给 iOS 系统 QuickLook 预览（PDF / Office / txt / rtf …）。
/// 不自绘渲染，页面只负责「下载 + 拉起 + 失败重试」；拉起成功就自动退回浏览页。
class DocViewerPage extends ConsumerStatefulWidget {
  const DocViewerPage({required this.entry, super.key});

  final RemoteEntry entry;

  @override
  ConsumerState<DocViewerPage> createState() => _DocViewerPageState();
}

class _DocViewerPageState extends ConsumerState<DocViewerPage> {
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await ref.read(cachedFileProvider(cacheKeyFor(widget.entry)).future);
      final result = await OpenFilex.open(file.path);
      if (!mounted) return;
      if (result.type == ResultType.done) {
        // QuickLook 已盖在上层，关掉这页；退出预览就回到浏览列表。
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {
        _busy = false;
        _error = result.message.isNotEmpty ? result.message : '这台设备打不开 ${widget.entry.extension}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '准备文件失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              VaultAppBar(
                title: widget.entry.name,
                leading: IconBtn(icon: 'back', onTap: () => Navigator.of(context).maybePop()),
              ),
              Expanded(
                child: Center(
                  child: _busy ? _loading() : _failure(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loading() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
          ),
          SizedBox(height: 16),
          Text(
            '正在准备文档（首次需下载）…',
            style: TextStyle(fontSize: 12.5, color: VaultColors.muted),
          ),
        ],
      );

  Widget _failure() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            VIcon('doc', size: 30, color: VaultColors.chevron),
            SizedBox(height: 14),
            Text(
              _error ?? '无法打开',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
            ),
            SizedBox(height: 20),
            GhostButton(label: '重 试', onPressed: _prepare),
          ],
        ),
      );
}
