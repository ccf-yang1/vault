import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../data/remote_zip.dart';
import '../data/vault_cache.dart';
import 'session_providers.dart';

/// 缓存文件名需要路径 + etag + 扩展名，用 record 当 family key 白送相等性。
typedef CacheKey = ({String path, String name, String? etag, String ext});
typedef ZipKey = ({String path, int size});
typedef ZipEntryKey = ({String archive, int archiveSize, String entry});

CacheKey cacheKeyFor(RemoteEntry entry) => (
      path: entry.path,
      name: entry.name,
      etag: entry.etag,
      ext: entry.extension.isEmpty ? '.bin' : entry.extension,
    );

/// 同一时刻只放 4 个「猜目录大小」的探测请求，避免进一个目录就打爆服务器。
class Semaphore {
  Semaphore(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() body) async {
    if (_active >= maxConcurrent) {
      final gate = Completer<void>();
      _waiters.add(gate);
      await gate.future;
    }
    _active++;
    try {
      return await body();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

final folderStatGateProvider = Provider<Semaphore>((ref) => Semaphore(4));

/// 原始目录列表（网络）。隐藏过滤放在派生 provider 里，
/// 这样切换隐藏模式不会重新发 PROPFIND。
final dirRawProvider = FutureProvider.family.autoDispose<List<RemoteEntry>, String>((ref, path) async {
  final client = ref.watch(davProvider);
  return client.list(path);
});

final dirEntriesProvider = Provider.family.autoDispose<List<RemoteEntry>, String>((ref, path) {
  final entries = ref.watch(dirRawProvider(path)).valueOrNull ?? const [];
  if (ref.watch(hiddenModeProvider)) return entries;
  final hidden = ref.watch(hiddenDirsProvider).map((e) => e.path).toSet();
  return entries.where((e) => !hidden.contains(e.path)).toList();
});

/// 某个目录里「当前可见」的图片，按列表顺序，供查看器左右翻页。
final dirImagesProvider = Provider.family.autoDispose<List<RemoteEntry>, String>((ref, path) {
  return ref.watch(dirEntriesProvider(path)).where((e) => e.kind == FileKind.image).toList();
});

class FolderStat {
  const FolderStat(this.count, this.bytes);

  final int count;
  final int bytes;
}

/// 列表行的「128 项 · 2.4 GB」：懒算，失败就显示空，不打断浏览。
final folderStatProvider = FutureProvider.family.autoDispose<FolderStat, String>((ref, path) async {
  if (!ref.watch(settingsProvider).preloadEnabled) return const FolderStat(0, 0);
  // 必须 watch 隐藏集合与隐藏模式：藏掉一个目录后首页那行的数字要跟着减，
  // 否则「N 项」还带着刚藏起来的项，看上去就没生效。隐藏模式下反过来全算。
  final hidden = ref.watch(hiddenDirsProvider).map((e) => e.path).toSet();
  final showHidden = ref.watch(hiddenModeProvider);
  final gate = ref.read(folderStatGateProvider);
  try {
    return await gate.run(() async {
      final children = await ref.read(davProvider).list(path);
      var count = 0;
      var bytes = 0;
      for (final child in children) {
        if (!showHidden && hidden.contains(child.path)) continue;
        count++;
        bytes += child.size;
      }
      return FolderStat(count, bytes);
    });
  } on Object {
    return const FolderStat(0, 0);
  }
});

CacheBucket bucketForExtension(String ext) {
  final probe = RemoteEntry(name: 'file$ext', path: '/file$ext', isDir: false);
  return switch (probe.kind) {
    FileKind.video => CacheBucket.videos,
    FileKind.archive => CacheBucket.zip,
    FileKind.image => CacheBucket.images,
    _ => CacheBucket.temp,
  };
}

/// 下载并缓存到 `Library/Caches/Vault/*`，绝不写系统相册（需求 §5.3）。
final cachedFileProvider = FutureProvider.family.autoDispose<File, CacheKey>((ref, key) async {
  final client = ref.read(davProvider);
  final cache = ref.read(cacheProvider);
  final file = await cache.fileFor(
    bucketForExtension(key.ext),
    remotePath: key.path,
    displayName: key.name,
    etag: key.etag,
    ext: key.ext.startsWith('.') ? key.ext.substring(1) : key.ext,
  );
  if (await file.exists() && await file.length() > 0) {
    await cache.touch(file);
    return file;
  }
  final scratch = File('${file.path}.part');
  await client.download(key.path, scratch.path);
  await scratch.rename(file.path);
  await cache.enforceLimit(ref.read(settingsProvider).cacheLimitMB);
  return file;
});

/// 图片列表的前后预加载：进目录/翻页时把附近若干张拉进沙盒（需求 §3.2）。
const preloadRadius = 5;

void preloadImages(WidgetRef ref, List<RemoteEntry> images, int index) {
  if (!ref.read(settingsProvider).preloadEnabled) return;
  if (images.isEmpty) return;
  final start = (index - preloadRadius).clamp(0, images.length - 1);
  final end = (index + preloadRadius).clamp(0, images.length - 1);
  for (var i = start; i <= end; i++) {
    final entry = images[i];
    if (entry.kind != FileKind.image) continue;
    // 预加载失败不影响当前这张，静默忽略。
    unawaited(
      ref.read(cachedFileProvider(cacheKeyFor(entry)).future).then((_) {}).catchError((Object _) {}),
    );
  }
}

/// 压缩包：只 Range 读中央目录，列条目。
final remoteZipProvider = FutureProvider.family.autoDispose<RemoteZip, ZipKey>((ref, key) async {
  final client = ref.read(davProvider);
  return RemoteZip.open(client, key.path, key.size);
});

/// 压缩包内条目按需解压到 temp，并限制单文件大小。
final zipEntryFileProvider = FutureProvider.family.autoDispose<File, ZipEntryKey>((ref, key) async {
  final client = ref.read(davProvider);
  final cache = ref.read(cacheProvider);
  final dot = key.entry.lastIndexOf('.');
  final ext = dot < 0 ? 'bin' : key.entry.substring(dot + 1).toLowerCase();
  final file = await cache.fileFor(
    CacheBucket.temp,
    remotePath: '${key.archive}::${key.entry}',
    displayName: key.entry.split('/').last,
    etag: '${key.archiveSize}',
    ext: ext,
  );
  if (await file.exists() && await file.length() > 0) {
    await cache.touch(file);
    return file;
  }
  final zip = await ref.read(remoteZipProvider((path: key.archive, size: key.archiveSize)).future);
  final entry = zip.entries.firstWhere((e) => e.name == key.entry);
  final bytes = await RemoteZip.extract(client, key.archive, entry);
  await file.writeAsBytes(bytes, flush: true);
  await cache.enforceLimit(ref.read(settingsProvider).cacheLimitMB);
  return file;
});
