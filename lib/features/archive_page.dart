import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/remote_zip.dart';
import '../data/webdav_client.dart';
import '../state/browse_providers.dart';
import 'video_page.dart';

String _extractMessage(Object error) {
  if (error is ZipFailure) return error.message;
  if (error is WebDavError) return error.message;
  return '解压失败';
}

/// HTML 05（旧版）：压缩包浏览页。
///
/// 只 Range 读中央目录列条目，点开哪个解压哪个，绝不全量解压（需求 §3.5）。
class ArchivePage extends ConsumerStatefulWidget {
  const ArchivePage({required this.entry, super.key});

  final RemoteEntry entry;

  @override
  ConsumerState<ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends ConsumerState<ArchivePage> {
  String _prefix = '';

  /// ZIP 内部前缀以 `/` 结尾，根目录是空串，和 RemotePath 的规则不同。
  void _upOneLevel() {
    var p = _prefix;
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final slash = p.lastIndexOf('/');
    setState(() => _prefix = slash < 0 ? '' : p.substring(0, slash + 1));
  }

  @override
  Widget build(BuildContext context) {
    final key = (path: widget.entry.path, size: widget.entry.size);
    final zip = ref.watch(remoteZipProvider(key));

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              VaultAppBar(
                leading: IconBtn(icon: 'back', onTap: () {
                  if (_prefix.isEmpty) {
                    Navigator.of(context).maybePop();
                  } else {
                    _upOneLevel();
                  }
                }),
                title: widget.entry.name,
                subtitle: 'ZIP · 只读浏览',
              ),
              zip.when(
                loading: () => const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
                        ),
                        SizedBox(height: 16),
                        Text('正在读取中央目录…', style: TextStyle(fontSize: 12.5, color: VaultColors.muted)),
                      ],
                    ),
                  ),
                ),
                error: (error, _) => Expanded(
                  child: VaultEmpty(
                    icon: 'zip',
                    title: error is ZipFailure ? error.message : '无法读取这个压缩包',
                    action: GhostButton(label: '返 回', onPressed: () => Navigator.of(context).maybePop()),
                  ),
                ),
                data: (value) => Expanded(child: _body(value)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(RemoteZip zip) {
    final children = RemoteZip.childrenOf(zip.entries, _prefix);
    var bytes = 0;
    for (final entry in zip.entries) {
      bytes += entry.uncompressedSize;
    }

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: VaultColors.green.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: VaultColors.green.withValues(alpha: 0.16)),
          ),
          child: Row(
            children: [
              const VIcon('shieldCheck', size: 15, color: VaultColors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('可按需浏览', style: TextStyle(fontSize: 12.5, color: VaultColors.green)),
                    const SizedBox(height: 2),
                    Text(
                      '${formatCount(zip.entries.length)} 个条目 · 解压后约 ${formatBytes(bytes)} · 点开才解压',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF6F8A80)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: VaultColors.green.withValues(alpha: 0.3)),
                ),
                child: const Text('只读', style: TextStyle(fontSize: 9.5, color: VaultColors.green)),
              ),
            ],
          ),
        ),
        if (_prefix.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
            child: Row(
              children: [
                const VIcon('folderOpen', size: 13, color: VaultColors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _prefix,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: VaultColors.muted,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: children.isEmpty
              ? const VaultEmpty(icon: 'zip', title: '这个目录是空的')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                  itemCount: children.length,
                  itemBuilder: (context, index) => _row(zip, children[index]),
                ),
        ),
      ],
    );
  }

  Widget _row(RemoteZip zip, ZipEntry entry) {
    final icon = entry.isDir
        ? 'folder'
        : switch (_kindOf(entry)) {
            FileKind.image => 'image',
            FileKind.video => 'video',
            FileKind.archive => 'zip',
            _ => 'list',
          };
    final tileColor = switch (entry.isDir ? FileKind.folder : _kindOf(entry)) {
      FileKind.folder => VaultColors.blue,
      FileKind.image => VaultColors.green,
      FileKind.video => VaultColors.purple,
      FileKind.archive => VaultColors.orange,
      _ => VaultColors.muted,
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(zip, entry),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: VaultColors.line)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: tileColor.withValues(alpha: 0.11),
              ),
              child: Center(child: VIcon(icon, size: 19, color: tileColor)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: VaultColors.text, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(_subtitle(entry), style: const TextStyle(fontSize: 11.5, color: VaultColors.muted)),
                ],
              ),
            ),
            if (!entry.isDir && entry.isEncrypted)
              const Padding(padding: EdgeInsets.only(right: 6), child: VIcon('lock', size: 14)),
            const VIcon('chevron', size: 16, color: Color(0xFF3A3F46)),
          ],
        ),
      ),
    );
  }

  String _subtitle(ZipEntry entry) {
    if (entry.isDir) return '文件夹';
    if (entry.isEncrypted) return '有密码 · 暂不支持';
    final size = entry.uncompressedSize > 0 ? formatBytes(entry.uncompressedSize) : '—';
    final time = formatRelativeTime(entry.modified);
    return time.isEmpty ? size : '$size · $time';
  }

  static FileKind _kindOf(ZipEntry entry) {
    final name = entry.displayName;
    return RemoteEntry(name: name, path: '/$name', isDir: false).kind;
  }

  Future<void> _open(RemoteZip zip, ZipEntry entry) async {
    if (entry.isDir) {
      setState(() => _prefix = entry.name);
      return;
    }
    if (entry.isEncrypted) {
      showVaultToast(context, '这个条目有密码，v1 暂不解密', error: true);
      return;
    }
    final kind = _kindOf(entry);
    if (kind != FileKind.image && kind != FileKind.video) {
      showVaultToast(context, '${entry.displayName} 不提供预览', error: true);
      return;
    }
    if (entry.uncompressedSize > RemoteZip.maxEntryBytes) {
      showVaultToast(context, '单个文件超过 ${RemoteZip.maxEntryBytes ~/ (1024 * 1024)} MB，不预览', error: true);
      return;
    }

    final key = (archive: zip.path, archiveSize: zip.totalSize, entry: entry.name);
    File file;
    try {
      file = await ref.read(zipEntryFileProvider(key).future);
    } on Object catch (error) {
      if (mounted) {
        showVaultToast(context, _extractMessage(error), error: true);
      }
      return;
    }

    if (!mounted) return;
    final synthetic = RemoteEntry(
      name: entry.displayName,
      path: entry.name,
      isDir: false,
      size: entry.uncompressedSize,
    );
    if (kind == FileKind.image) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ExtractedImageView(entry: synthetic, file: file)));
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPage(entry: synthetic, localFile: file)));
    }
  }
}

/// 压缩包里的图片：文件已经解压在沙盒，直接本地展示，可双指/双击放大。
class _ExtractedImageView extends StatefulWidget {
  const _ExtractedImageView({required this.entry, required this.file});

  final RemoteEntry entry;
  final File file;

  @override
  State<_ExtractedImageView> createState() => _ExtractedImageViewState();
}

class _ExtractedImageViewState extends State<_ExtractedImageView> {
  final TransformationController _matrix = TransformationController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => precacheImage(FileImage(widget.file), context));
  }

  @override
  void dispose() {
    _matrix.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final zoomed = _matrix.value.getMaxScaleOnAxis() > 1.01;
    _matrix.value = zoomed
        ? Matrix4.identity()
        : Matrix4.identity()..scaleByDouble(2.5, 2.5, 2.5, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            SizedBox(height: MediaQuery.of(context).padding.top),
            VaultAppBar(
              leading: IconBtn(icon: 'back', color: VaultColors.text, onTap: () => Navigator.of(context).maybePop()),
              title: widget.entry.name,
              subtitle: '来自压缩包 · ${formatBytes(widget.entry.size)}',
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _matrix,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(80),
                  child: Center(child: Image(image: FileImage(widget.file), fit: BoxFit.contain, gaplessPlayback: true)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
