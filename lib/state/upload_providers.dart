import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/models.dart';
import '../data/network_info.dart';
import '../data/vault_cache.dart';
import '../data/webdav_client.dart';
import 'session_providers.dart';

/// 相册权限：`limited` 在 iOS 上算可用（只能选用户挑出来的那些）。
bool permissionGranted(PermissionState state) =>
    state == PermissionState.authorized || state == PermissionState.limited;

class DayBucket {
  DayBucket({required this.day, required this.assets});

  final DateTime day;
  final List<AssetEntity> assets;
}

/// 相册按创建时间倒序、每天一组（需求 §3.6 的「今天 · 6月12日」）。
List<DayBucket> groupByDay(List<AssetEntity> assets) {
  final buckets = <DateTime, List<AssetEntity>>{};
  for (final asset in assets) {
    final key = DateTime(asset.createDateTime.year, asset.createDateTime.month, asset.createDateTime.day);
    buckets.putIfAbsent(key, () => <AssetEntity>[]).add(asset);
  }
  final ordered = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final day in ordered) DayBucket(day: day, assets: buckets[day]!)];
}

List<AssetEntity> withinRecentDays(List<AssetEntity> assets, int days, {DateTime? now}) {
  final moment = now ?? DateTime.now();
  final since = DateTime(moment.year, moment.month, moment.day).subtract(Duration(days: days - 1));
  return assets.where((a) => !a.createDateTime.isBefore(since)).toList();
}

class UploadState {
  const UploadState({
    this.permission = PermissionState.notDetermined,
    this.loading = false,
    this.assets = const [],
    this.sizes = const {},
    this.selected = const {},
    this.tasks = const [],
    this.uploading = false,
    this.message,
  });

  final PermissionState permission;
  final bool loading;
  final List<AssetEntity> assets;
  final Map<String, int> sizes;
  final Set<String> selected;
  final List<UploadTask> tasks;
  final bool uploading;
  final String? message;

  UploadState copyWith({
    PermissionState? permission,
    bool? loading,
    List<AssetEntity>? assets,
    Map<String, int>? sizes,
    Set<String>? selected,
    List<UploadTask>? tasks,
    bool? uploading,
    String? message,
  }) =>
      UploadState(
        permission: permission ?? this.permission,
        loading: loading ?? this.loading,
        assets: assets ?? this.assets,
        sizes: sizes ?? this.sizes,
        selected: selected ?? this.selected,
        tasks: tasks ?? this.tasks,
        uploading: uploading ?? this.uploading,
        message: message,
      );

  int get selectedBytes {
    var total = 0;
    for (final id in selected) {
      total += sizes[id] ?? 0;
    }
    return total;
  }

  int get doneCount => tasks.where((t) => t.status == UploadStatus.done).length;
  int get failedCount => tasks.where((t) => t.status == UploadStatus.failed).length;

  double get overallProgress {
    if (tasks.isEmpty) return 0;
    var sum = 0.0;
    for (final task in tasks) {
      sum += task.status == UploadStatus.done ? 1.0 : task.progress.clamp(0.0, 1.0);
    }
    return sum / tasks.length;
  }

  List<UploadTask> get failedTasks => tasks.where((t) => t.status == UploadStatus.failed).toList();
}

class UploadController extends Notifier<UploadState> {
  static const _maxAssets = 1500;

  CancelToken? _token;

  @override
  UploadState build() {
    ref.onDispose(() => _token?.cancel('页面销毁'));
    return const UploadState();
  }

  Future<void> requestPermissionAndLoad() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, message: null);
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permissionGranted(permission)) {
      state = state.copyWith(permission: permission, loading: false);
      return;
    }
    try {
      final paths = await PhotoManager.getAssetPathList(onlyAll: true, type: RequestType.common);
      if (paths.isEmpty) {
        state = state.copyWith(permission: permission, loading: false, assets: const []);
        return;
      }
      final album = paths.first;
      final count = await album.assetCountAsync;
      final assets = await album.getAssetListPaged(
        page: 0,
        size: count > _maxAssets ? _maxAssets : count,
      );
      assets.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      state = state.copyWith(permission: permission, loading: false, assets: assets);
    } on Object catch (e) {
      state = state.copyWith(loading: false, message: '读取相册失败：$e');
    }
  }

  void toggle(AssetEntity asset) {
    final next = state.selected.toSet();
    if (!next.remove(asset.id)) {
      next.add(asset.id);
      _loadSize(asset);
    }
    state = state.copyWith(selected: next);
  }

  Future<void> selectAll(List<AssetEntity> assets) async {
    final next = state.selected.toSet()..addAll(assets.map((a) => a.id));
    state = state.copyWith(selected: next);
    unawaited(_loadSizes(assets));
  }

  /// chips：今天全部 / 最近 N 天，都是「追加选择」，不清掉用户手点的。
  Future<void> selectToday() => selectAll(withinRecentDays(state.assets, 1));

  Future<void> selectRecentDays(int days) async {
    ref.read(settingsProvider.notifier).setRecentDays(days);
    await selectAll(withinRecentDays(state.assets, days));
  }

  Future<void> clearSelection() async => state = state.copyWith(selected: const {});

  Future<void> _loadSizes(List<AssetEntity> assets) async {
    final table = Map<String, int>.from(state.sizes);
    var changed = 0;
    for (final asset in assets) {
      if (table.containsKey(asset.id)) continue;
      try {
        table[asset.id] = await asset.fileSize;
        changed++;
        if (changed % 8 == 0) state = state.copyWith(sizes: Map.of(table));
      } on Object {
        table[asset.id] = 0;
      }
    }
    state = state.copyWith(sizes: Map.of(table));
  }

  void _loadSize(AssetEntity asset) {
    if (state.sizes.containsKey(asset.id)) return;
    unawaited(_loadSizes([asset]));
  }

  void cancelUpload() {
    _token?.cancel('用户取消');
    final tasks = state.tasks;
    for (final task in tasks) {
      if (task.status == UploadStatus.queued || task.status == UploadStatus.running) {
        task.status = UploadStatus.canceled;
      }
    }
    state = state.copyWith(tasks: List.of(tasks), uploading: false);
  }

  Future<void> startUpload(String directory) async {
    if (state.uploading || state.selected.isEmpty) return;
    final settings = ref.read(settingsProvider);
    if (settings.wifiOnlyUpload && !await isOverWifi()) {
      state = state.copyWith(message: '已开启「仅 Wi-Fi 上传」，当前不是 Wi-Fi');
      return;
    }
    final client = ref.read(davProvider);
    final cache = ref.read(cacheProvider);
    final chosen = state.assets.where((a) => state.selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;

    final tasks = [
      for (final asset in chosen)
        UploadTask(
          localAssetId: asset.id,
          fileName: asset.title ?? asset.id,
          remotePath: RemotePath.join(directory, asset.title ?? asset.id),
        ),
    ];
    final byId = {for (final asset in chosen) asset.id: asset};
    final token = CancelToken();
    _token = token;
    state = state.copyWith(tasks: tasks, uploading: true, message: null);

    for (final task in tasks) {
      if (token.isCancelled) {
        task.status = UploadStatus.canceled;
        continue;
      }
      final asset = byId[task.localAssetId]!;
      task.status = UploadStatus.running;
      _notify();
      File? scratch;
      try {
        final origin = await asset.originFile;
        if (origin == null || !await origin.exists()) {
          throw WebDavError(WebDavErrorKind.notFound, detail: '原文件不可读');
        }
        final name = _fileNameFor(asset, origin);
        final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : 'jpg';
        task.fileName = name;
        // 先导出到 App 沙盒临时目录，传完立刻删（需求 §3.6 / §5.3）。
        scratch = await cache.fileFor(
          CacheBucket.temp,
          remotePath: 'local://${asset.id}',
          displayName: name,
          etag: '${asset.createDateTime.millisecondsSinceEpoch}',
          ext: ext,
        );
        await origin.copy(scratch.path);
        final destination = await client.resolveUniquePath(directory, name);
        task.remotePath = destination;
        var lastPercent = -1;
        await client.uploadFile(
          scratch,
          destination,
          cancelToken: token,
          onProgress: (sent, total) {
            if (total <= 0) return;
            task.progress = sent / total;
            final percent = (task.progress * 50).round();
            if (percent != lastPercent) {
              lastPercent = percent;
              _notify();
            }
          },
        );
        task.status = UploadStatus.done;
        task.progress = 1;
      } on DioException catch (e) {
        task.status = e.type == DioExceptionType.cancel ? UploadStatus.canceled : UploadStatus.failed;
        task.error = WebDavError.from(e).message;
      } on WebDavError catch (e) {
        task.status = UploadStatus.failed;
        task.error = e.message;
      } on Object catch (e) {
        task.status = UploadStatus.failed;
        task.error = '$e';
      } finally {
        if (scratch != null) {
          try {
            await scratch.delete();
          } on FileSystemException {
            // 临时文件没删掉不影响结果，下次清缓存会带走。
          }
        }
      }
      _notify();
    }

    _token = null;
    final finished = List.of(state.tasks);
    state = state.copyWith(tasks: finished, uploading: false);
  }

  /// 只重试失败项。
  Future<void> retryFailed() async {
    if (state.uploading) return;
    final failed = state.failedTasks;
    if (failed.isEmpty) return;
    final ids = failed.map((t) => t.localAssetId).toSet();
    state = state.copyWith(
      selected: state.selected.union(ids),
      tasks: state.tasks.where((t) => t.status != UploadStatus.failed).toList(),
    );
    await startUpload(RemotePath.parent(failed.first.remotePath));
  }

  void _notify() => state = state.copyWith(tasks: List.of(state.tasks));

  String _fileNameFor(AssetEntity asset, File origin) {
    final title = (asset.title ?? '').trim();
    if (title.isNotEmpty && title.contains('.')) return title;
    final base = title.isEmpty ? asset.id.substring(0, 8) : title;
    final originExt = origin.path.contains('.') ? origin.path.substring(origin.path.lastIndexOf('.') + 1) : 'jpg';
    return '$base.${originExt.toLowerCase()}';
  }
}

final uploadProvider = NotifierProvider<UploadController, UploadState>(UploadController.new);
