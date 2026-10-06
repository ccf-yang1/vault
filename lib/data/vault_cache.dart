import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 缓存目录：`Library/Caches/Vault/{images,videos,temp,zip}`（需求 §5.3）。
///
/// 选 Library/Caches 而不是 Documents：不进 iCloud 备份、不会被「文件」或系统
/// 相册索引；iOS 只在空间吃紧时才清理，符合「退出 App 不自动清空」。
enum CacheBucket { images, videos, temp, zip }

String bucketDirName(CacheBucket bucket) => switch (bucket) {
      CacheBucket.images => 'images',
      CacheBucket.videos => 'videos',
      CacheBucket.temp => 'temp',
      CacheBucket.zip => 'zip',
    };

/// 用于文件名，避免同名远程文件互相覆盖。
const _salt = 'vault-v1';

class VaultCache {
  VaultCache({Directory? rootOverride}) : _rootOverride = rootOverride;

  final Directory? _rootOverride;

  Future<Directory> root() async {
    final base = _rootOverride ?? await getLibraryDirectory();
    final dir = Directory('${base.path}/Caches/Vault');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> bucketDir(CacheBucket bucket) async {
    final r = await root();
    final dir = Directory('${r.path}/${bucketDirName(bucket)}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String fileNameFor(String remotePath, String displayName, {String? etag, required String ext}) {
    final stem = displayName.contains('.')
        ? displayName.substring(0, displayName.lastIndexOf('.'))
        : displayName;
    final safe = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final short = safe.length <= 24 ? safe : safe.substring(0, 24);
    return '${short}_${_fnv1a('$remotePath|${etag ?? ''}|$_salt')}.$ext';
  }

  Future<File> fileFor(
    CacheBucket bucket, {
    required String remotePath,
    required String displayName,
    String? etag,
    required String ext,
  }) async {
    final dir = await bucketDir(bucket);
    return File('${dir.path}/${fileNameFor(remotePath, displayName, etag: etag, ext: ext)}');
  }

  Future<List<File>> allFiles() async {
    final r = await root();
    if (!await r.exists()) return const [];
    final out = <File>[];
    await for (final entity in r.list(recursive: true, followLinks: false)) {
      if (entity is File) out.add(entity);
    }
    return out;
  }

  Future<int> totalBytes() async {
    var total = 0;
    for (final file in await allFiles()) {
      try {
        total += await file.length();
      } on FileSystemException {
        // 文件刚被淘汰，忽略。
      }
    }
    return total;
  }

  /// 命中缓存时 touch 一次 mtime，让 LRU 跟上真实使用。
  Future<void> touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } on FileSystemException {
      // 只影响淘汰顺序。
    }
  }

  /// 超过上限从最旧的开始删（需求 §5.3），返回删除的文件数。
  Future<int> enforceLimit(int limitMB) async {
    final limit = limitMB * 1024 * 1024;
    final files = await allFiles();
    final stats = <File, FileStat>{};
    var total = 0;
    for (final file in files) {
      try {
        final stat = await file.stat();
        stats[file] = stat;
        total += stat.size;
      } on FileSystemException {
        continue;
      }
    }
    if (total <= limit) return 0;
    final ordered = stats.keys.toList()..sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    var removed = 0;
    for (final file in ordered) {
      if (total <= limit) break;
      try {
        await file.delete();
        total -= stats[file]!.size;
        removed++;
      } on FileSystemException {
        // 正在播放的文件删不掉，下次再说。
      }
    }
    return removed;
  }

  /// 设置页「清除缓存」：不影响凭据与隐藏列表（验收 §15）。
  Future<void> clear() async {
    final r = await root();
    for (final bucket in CacheBucket.values) {
      final dir = Directory('${r.path}/${bucketDirName(bucket)}');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            await entity.delete();
          } on FileSystemException {
            // 被播放器占用的文件跳过。
          }
        }
      }
    }
  }
}

/// FNV-1a 32bit，省掉 crypto 依赖。
String _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final unit in Uint8List.fromList(input.codeUnits)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
