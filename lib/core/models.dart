/// 数据模型：与需求文档 §7 一一对应。
library;

enum StorageType {
  webdav('WebDAV'),
  openlist('OpenList');

  const StorageType(this.label);
  final String label;

  static StorageType fromName(String? name) =>
      values.firstWhere((t) => t.name == name, orElse: () => webdav);
}

enum FileKind { folder, image, video, audio, archive, other }

class ConnectionConfig {
  const ConnectionConfig({
    required this.type,
    required this.baseUrl,
    required this.username,
    required this.password,
    this.remember = true,
  });

  final StorageType type;
  final String baseUrl;
  final String username;
  final String password;
  final bool remember;

  ConnectionConfig copyWith({
    StorageType? type,
    String? baseUrl,
    String? username,
    String? password,
    bool? remember,
  }) =>
      ConnectionConfig(
        type: type ?? this.type,
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        remember: remember ?? this.remember,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
        'remember': remember,
      };

  static ConnectionConfig fromJson(Map<String, dynamic> json) => ConnectionConfig(
        type: StorageType.fromName(json['type'] as String?),
        baseUrl: (json['baseUrl'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
        remember: (json['remember'] as bool?) ?? true,
      );

  /// 设置页展示用：去掉协议前缀和尾部斜杠。
  String get displayHost {
    var s = baseUrl.trim();
    for (final p in ['https://', 'http://']) {
      if (s.startsWith(p)) s = s.substring(p.length);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.mimeType,
    this.modified,
    this.etag,
  });

  final String name;

  /// 相对 WebDAV 根的绝对路径，始终以 `/` 开头；目录不带尾部斜杠。
  final String path;
  final bool isDir;
  final int size;
  final String? mimeType;
  final DateTime? modified;
  final String? etag;

  FileKind get kind {
    if (isDir) return FileKind.folder;
    final ext = extension.toLowerCase();
    if (_imageExts.contains(ext)) return FileKind.image;
    if (_videoExts.contains(ext)) return FileKind.video;
    if (_audioExts.contains(ext)) return FileKind.audio;
    if (_archiveExts.contains(ext)) return FileKind.archive;
    return FileKind.other;
  }

  /// iOS 原生解码器放不了的音频容器：打开音频页就直接提示，不初始化播放器。
  bool get isIosUnsupportedAudio {
    if (kind != FileKind.audio) return false;
    return const {'.wma', '.asf', '.ra', '.rm', '.aiff', '.aif'}.contains(extension);
  }

  /// just_audio（AVFoundation）在 iOS 上可播的常见格式。
  bool get isNativePlayableAudio => kind == FileKind.audio && !isIosUnsupportedAudio;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot).toLowerCase();
  }

  static const _imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif', '.bmp', '.tiff', '.tif', '.avif'};
  static const _videoExts = {'.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi', '.flv', '.wmv', '.ts', '.3gp'};
  static const _audioExts = {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.oga', '.opus', '.wma', '.asf', '.aiff', '.aif', '.mka'};
  static const _archiveExts = {'.zip', '.rar', '.7z', '.tar', '.gz', '.tgz'};

  bool get isZip => extension == '.zip';
}

class HiddenEntry {
  const HiddenEntry({required this.path, required this.name, required this.hiddenAt});

  /// 完整远程路径，避免同名目录混淆（需求 §4.2）。
  final String path;
  final String name;
  final DateTime hiddenAt;

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'hiddenAt': hiddenAt.toIso8601String(),
      };

  static HiddenEntry fromJson(Map<String, dynamic> json) => HiddenEntry(
        path: json['path'] as String,
        name: json['name'] as String,
        hiddenAt: DateTime.tryParse(json['hiddenAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class AppSettings {
  const AppSettings({
    this.preloadEnabled = true,
    this.cacheLimitMB = 500,
    this.wifiOnlyUpload = false,
    this.recentDays = 7,
  });

  final bool preloadEnabled;
  final int cacheLimitMB;
  final bool wifiOnlyUpload;
  final int recentDays;

  AppSettings copyWith({
    bool? preloadEnabled,
    int? cacheLimitMB,
    bool? wifiOnlyUpload,
    int? recentDays,
  }) =>
      AppSettings(
        preloadEnabled: preloadEnabled ?? this.preloadEnabled,
        cacheLimitMB: cacheLimitMB ?? this.cacheLimitMB,
        wifiOnlyUpload: wifiOnlyUpload ?? this.wifiOnlyUpload,
        recentDays: recentDays ?? this.recentDays,
      );
}

enum UploadStatus { queued, running, done, failed, canceled }

class UploadTask {
  UploadTask({
    required this.localAssetId,
    required this.fileName,
    required this.remotePath,
    this.status = UploadStatus.queued,
    this.progress = 0,
    this.error,
  });

  final String localAssetId;
  String fileName;
  String remotePath;
  UploadStatus status;
  double progress;
  String? error;

  bool get isFinished => status == UploadStatus.done || status == UploadStatus.canceled;
}

/// 目录路径工具：远程路径统一以 `/` 开头、目录不带尾斜杠。
abstract final class RemotePath {
  static String normalize(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String join(String dir, String name) {
    final d = normalize(dir);
    if (d == '/') return '/$name';
    return '$d/$name';
  }

  static String parent(String path) {
    final p = normalize(path);
    if (p == '/') return '/';
    final i = p.lastIndexOf('/');
    if (i <= 0) return '/';
    return p.substring(0, i);
  }

  static List<String> breadcrumbs(String path) {
    final p = normalize(path);
    if (p == '/') return ['/'];
    final parts = p.split('/').where((s) => s.isNotEmpty).toList();
    final out = <String>['/'];
    var acc = '';
    for (final part in parts) {
      acc = '$acc/$part';
      out.add(acc);
    }
    return out;
  }

  static String nameOf(String path) {
    final p = normalize(path);
    if (p == '/') return '根目录';
    return p.substring(p.lastIndexOf('/') + 1);
  }
}
