import 'package:dio/dio.dart';

/// 盒子云盘缓存服务（box-cache-api）：把云端目录增量拉到盒子本地盘。
///
/// 服务只听内网、无鉴权，Base URL 由当前 WebDAV 地址推导（同主机、`:9000`、`/api/cache`）。
/// 文档里三个反直觉的点都照做：建任务成功是 `202`；任务视图**不带 `ok` 字段**（成功看
/// HTTP 状态码、结果看 `state`）；所有进度字段都可能整个缺失（服务端把 null 省略掉），
/// 所以解析一律按「可能不存在」处理。
enum CacheState {
  queued,
  running,
  done,
  failed,
  canceled,
  interrupted;

  bool get isActive => this == queued || this == running;
  bool get isFinal => !isActive;

  String get label => switch (this) {
        CacheState.queued => '排队中',
        CacheState.running => '同步中',
        CacheState.done => '已完成',
        CacheState.failed => '失败',
        CacheState.canceled => '已取消',
        CacheState.interrupted => '被打断',
      };

  /// 盒子那边加了新状态时按「失败」显示，总好于解析崩掉。
  static CacheState parse(String? raw) =>
      CacheState.values.firstWhere((e) => e.name == raw, orElse: () => CacheState.failed);
}

/// 任务视图。字段全部可缺失，故除 id/src/sub/to/dest/state 外都可为 null。
class CacheTask {
  CacheTask({
    required this.id,
    required this.src,
    required this.sub,
    required this.to,
    required this.dest,
    required this.state,
    this.error,
    this.createdAt,
    this.totalBytes,
    this.totalFiles,
    this.doneBytes,
    this.doneFiles,
    this.pct,
    this.speedBps,
    this.etaS,
    this.cancelRequested = false,
    this.queuePos,
    this.freeGb,
    this.webUrl,
    this.davUrl,
  });

  factory CacheTask.fromJson(Map<String, dynamic> json) => CacheTask(
        id: json['id'] as String,
        src: json['src'] as String,
        sub: json['sub'] as String,
        to: json['to'] as String,
        dest: json['dest'] as String,
        state: CacheState.parse(json['state'] as String?),
        error: json['error'] as String?,
        createdAt: _int(json['created_at']),
        totalBytes: _int(json['total_bytes']),
        totalFiles: _int(json['total_files']),
        doneBytes: _int(json['done_bytes']),
        doneFiles: _int(json['done_files']),
        pct: _double(json['pct']),
        speedBps: _int(json['speed_bps']),
        etaS: _int(json['eta_s']),
        cancelRequested: json['cancel'] == true,
        queuePos: _int(json['queue_pos']),
        freeGb: _double(json['free_gb']),
        webUrl: json['web_url'] as String?,
        davUrl: json['dav_url'] as String?,
      );

  final String id;
  final String src;
  final String sub;
  final String to;
  final String dest;
  final CacheState state;

  /// 服务端已经翻译成人话的中文，App 可以直接显示。
  final String? error;
  final int? createdAt;
  final int? totalBytes;
  final int? totalFiles;
  final int? doneBytes;
  final int? doneFiles;

  /// 0~100，一位小数。云端总量估不出来、或后台还没做过第一次采样时该字段不存在，
  /// 所以只当进度条用，别拿它做算术，收尾一律看 [state]。
  final double? pct;
  final int? speedBps;
  final int? etaS;

  /// `true` = 已受理取消、正在收尾，此时 `state` 可能还是 running。
  final bool cancelRequested;
  final int? queuePos;
  final double? freeGb;

  /// 只有 create / status / estimate / dirs 的响应里有，`GET /tasks/{id}` 没有。
  final String? webUrl;
  final String? davUrl;
}

/// `GET /health`：判断盒子有没有能力干活，以及有哪些落点。
class BoxHealth {
  BoxHealth({
    required this.rcloneReady,
    required this.scriptExists,
    required this.targets,
    this.runningCount = 0,
    this.queuedCount = 0,
  });

  factory BoxHealth.fromJson(Map<String, dynamic> json) {
    final targets = <String>[];
    final map = json['targets'];
    if (map is Map) {
      map.forEach((key, value) {
        // 目录不存在的落点提交了也是失败，不列给用户。
        if (value is Map && value['dir_exists'] == true) targets.add('$key');
      });
    }
    return BoxHealth(
      rcloneReady: json['rclone'] == true,
      scriptExists: json['script_exists'] == true,
      targets: targets,
      runningCount: _int(json['running']) ?? (json['running'] is List ? (json['running'] as List).length : 0),
      queuedCount: _int(json['queued']) ?? 0,
    );
  }

  final bool rcloneReady;
  final bool scriptExists;
  final List<String> targets;
  final int runningCount;
  final int queuedCount;

  bool get ready => rcloneReady && scriptExists;
}

/// `POST /estimate`：提交前问一嘴多大、装不装得下。
class CacheEstimate {
  CacheEstimate({
    this.cloudBytes,
    this.cloudFiles,
    this.cachedBytes,
    this.needGb,
    this.freeGb,
    this.willFit,
  });

  factory CacheEstimate.fromJson(Map<String, dynamic> json) => CacheEstimate(
        cloudBytes: _int(json['cloud_bytes']),
        cloudFiles: _int(json['cloud_files']),
        cachedBytes: _int(json['cached_bytes']),
        needGb: _double(json['need_gb']),
        freeGb: _double(json['free_gb']),
        // 云端估不出大小时它是 null，既不是 true 也不是 false，别当成「装得下」。
        willFit: json['will_fit'] is bool ? json['will_fit'] as bool : null,
      );

  final int? cloudBytes;
  final int? cloudFiles;
  final int? cachedBytes;
  final double? needGb;
  final double? freeGb;
  final bool? willFit;
}

/// 统一错误体 `{"ok":false,"error":{"code":..,"message":..}}`。
/// message 是服务端给人看的中文；它没给（网络层失败、客户端超时）时按 code 补一句。
class BoxCacheError implements Exception {
  BoxCacheError(this.status, this.code, this.message);

  factory BoxCacheError.fromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return BoxCacheError(
        e.response?.statusCode ?? 0,
        (err['code'] ?? 'internal').toString(),
        (err['message'] ?? '').toString(),
      );
    }
    // 路径拼错时是 Caddy 的空 404（没进缓存服务），根本没有 JSON 错误体。
    if (e.response?.statusCode == 404) return BoxCacheError(404, 'not_found', '');
    if (e.type == DioExceptionType.connectionTimeout) return BoxCacheError(0, 'connect_timeout', '');
    if (e.type == DioExceptionType.receiveTimeout) return BoxCacheError(0, 'client_timeout', '');
    return BoxCacheError(e.response?.statusCode ?? 0, 'network', '');
  }

  final int status;
  final String code;
  final String message;

  String get humanMessage => message.isNotEmpty
      ? message
      : switch (code) {
          'client_timeout' => '盒子很久没回话，但任务多半已经提交上了。先去设置的任务列表点「查询状态」，别重复提交。',
          'connect_timeout' => '连不上盒子的缓存服务（:9000）。确认手机和盒子在同一个局域网。',
          'network' => '连不上盒子的缓存服务（:9000）。确认手机和盒子在同一个局域网。',
          'not_found' => '没找到缓存服务接口，地址或前缀不对。',
          'no_task' => '盒子上已经没有这条任务记录（记录只留最近 200 条，可能被清理了）。',
          'already_active' => '这个目录已经在盒子的任务里了。',
          'src_not_found' => '云盘里找不到这个目录，或云盘授权过期了。',
          'no_space' => '盒子空间不够（要留至少 20 GiB 余量），先清理本地缓存。',
          'not_finished' => '任务还在跑，删不掉记录。',
          'bad_src' => '这个目录名不能用于离线下载（含非法字符）。',
          'too_long_src' => '目录路径太长（超过 300 字符）。',
          'bad_target' => '落点不对。',
          'internal' => '盒子端出了意外错误。',
          _ => '请求失败（$code${status == 0 ? '' : ' HTTP $status'}）',
        };
}

/// 设置页任务列表要显示的东西，也是 App 重启后续查的唯一依据
/// （任务 id 必须持久化，盒子端跑几十分钟期间 App 早就被杀了）。
class CacheTaskRecord {
  CacheTaskRecord({
    required this.id,
    required this.src,
    required this.sub,
    required this.to,
    required this.createdAt,
    this.state,
    this.error,
    this.totalBytes,
    this.doneBytes,
    this.pct,
    this.speedBps,
    this.etaS,
    this.webUrl,
    this.davUrl,
  });

  factory CacheTaskRecord.fromTask(CacheTask task) => CacheTaskRecord(
        id: task.id,
        src: task.src,
        sub: task.sub,
        to: task.to,
        createdAt: task.createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        state: task.state,
        error: task.error,
        totalBytes: task.totalBytes,
        doneBytes: task.doneBytes,
        pct: task.pct,
        speedBps: task.speedBps,
        etaS: task.etaS,
        webUrl: task.webUrl,
        davUrl: task.davUrl,
      );

  factory CacheTaskRecord.fromJson(Map<String, dynamic> json) => CacheTaskRecord(
        id: json['id'] as String,
        src: (json['src'] ?? '') as String,
        sub: (json['sub'] ?? '') as String,
        to: (json['to'] ?? 'local') as String,
        createdAt: _int(json['created_at']) ?? 0,
        state: json['state'] == null ? null : CacheState.parse('${json['state']}'),
        error: json['error'] as String?,
        totalBytes: _int(json['total_bytes']),
        doneBytes: _int(json['done_bytes']),
        pct: _double(json['pct']),
        speedBps: _int(json['speed_bps']),
        etaS: _int(json['eta_s']),
        webUrl: json['web_url'] as String?,
        davUrl: json['dav_url'] as String?,
      );

  final String id;
  final String src;
  final String sub;
  final String to;

  /// 秒级时间戳（接口给的就是秒，别按毫秒格式化）。
  final int createdAt;

  /// 还没查到过状态时是 null。
  final CacheState? state;
  final String? error;
  final int? totalBytes;
  final int? doneBytes;
  final double? pct;
  final int? speedBps;
  final int? etaS;
  final String? webUrl;
  final String? davUrl;

  bool get isActive => state?.isActive ?? false;

  /// 列表一行显示的目录名：云端路径的最后一段。
  String get name {
    final trimmed = src.endsWith('/') ? src.substring(0, src.length - 1) : src;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }

  CacheTaskRecord withTask(CacheTask task) => CacheTaskRecord(
        id: id,
        src: src,
        sub: sub,
        to: to,
        createdAt: createdAt,
        state: task.state,
        error: task.error,
        totalBytes: task.totalBytes ?? totalBytes,
        doneBytes: task.doneBytes ?? doneBytes,
        pct: task.pct ?? pct,
        speedBps: task.speedBps ?? speedBps,
        etaS: task.etaS ?? etaS,
        // `GET /tasks/{id}` 没有 URL 字段，所以只在新值非空时覆盖。
        webUrl: task.webUrl ?? webUrl,
        davUrl: task.davUrl ?? davUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'src': src,
        'sub': sub,
        'to': to,
        'created_at': createdAt,
        if (state != null) 'state': state!.name,
        if (error != null) 'error': error,
        if (totalBytes != null) 'total_bytes': totalBytes,
        if (doneBytes != null) 'done_bytes': doneBytes,
        if (pct != null) 'pct': pct,
        if (speedBps != null) 'speed_bps': speedBps,
        if (etaS != null) 'eta_s': etaS,
        if (webUrl != null) 'web_url': webUrl,
        if (davUrl != null) 'dav_url': davUrl,
      };
}

/// 离线下载用的云端路径：剥掉浏览路径的第一层，那一层是云盘挂载目录本身
/// （例如 `/aliyun/来自分享/高中` → `来自分享/高中`）。接口要求不带前导 `/`，
/// 含 `..` 之类会被 400 拒掉，这里先自己拦掉。
String? cacheSrcFor(String webDavPath) {
  final segments = webDavPath.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) return null;
  final body = segments.skip(1).join('/');
  if (body.isEmpty || body == '/' || body.length > 300) return null;
  return body;
}

/// 本地缓存目录名。缺省会只取最后一段，两个不同目录的最后一段同名时
/// 会落到同一个 dest，而 `rclone sync` 会把前一份的内容删掉；所以这里用整段
/// 安全化形式（`来自分享/高中` → `来自分享__高中`），并且把接口禁止的字符去掉。
String cacheSubFor(String src) {
  final trimmed = src.endsWith('/') ? src.substring(0, src.length - 1) : src;
  return trimmed.replaceAll('/', '__').replaceAll(RegExp(r'''["'`$\\]'''), '_');
}

class BoxCacheApi {
  BoxCacheApi(this.baseUrl);

  /// 例：`http://192.168.1.17:9000/api/cache`。前缀差一点就会打到 Caddy 的空 404
  /// （根本没进缓存服务），具体端点都拼在这后面，见文档 §5。
  final String baseUrl;

  static const _exclude = ['*.livp'];

  /// 从 WebDAV 地址推缓存服务地址：同一个主机、端口换成 9000、前缀 /api/cache。
  static String? deriveBaseUrl(String webDavUrl) {
    final uri = Uri.tryParse(webDavUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    // 重新拼而不是 replace：replace 传空 query/fragment 会留下个刺眼的 `?#`。
    return Uri(scheme: uri.scheme, host: uri.host, port: 9000, path: '/api/cache').toString();
  }

  Dio get _dio => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          responseType: ResponseType.json,
        ),
      );

  Future<BoxHealth> health() async {
    try {
      final res = await _dio.get('$baseUrl/health');
      return BoxHealth.fromJson(_map(res.data));
    } on DioException catch (e) {
      throw BoxCacheError.fromDio(e);
    }
  }

  /// 提交前估大小。**问不到就返回 null**（大目录列云端要几分钟），调用方降级成
  /// 「大小未知，仍要缓存吗」，不要把用户卡在估算上。
  Future<CacheEstimate?> estimate({
    required String to,
    required String src,
    String? sub,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final res = await _dio.post(
        '$baseUrl/estimate',
        data: {'to': to, 'src': src, if (sub != null) 'sub': sub},
        options: Options(sendTimeout: timeout, receiveTimeout: timeout),
      );
      return CacheEstimate.fromJson(_map(res.data));
    } on DioException {
      return null;
    }
  }

  /// 建任务。成功是 `202`，此时任务已在跑或排队。
  ///
  /// 大目录服务端要先列一遍云端，最长约 150 秒才回话，所以 [timeout] 给到 90 秒；
  /// **超时绝不能当成失败重发**（盒子那边可能照样把任务跑起来了），
  /// `409 already_active` 也不是错误，转去跟踪那个任务。
  Future<CacheTask> create({
    required String to,
    required String src,
    String? sub,
    List<String> exclude = _exclude,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    try {
      final res = await _dio.post(
        '$baseUrl/tasks',
        data: {'to': to, 'src': src, if (sub != null) 'sub': sub, if (exclude.isNotEmpty) 'exclude': exclude},
        options: Options(receiveTimeout: timeout),
      );
      return CacheTask.fromJson(_map(res.data));
    } on DioException catch (e) {
      final error = BoxCacheError.fromDio(e);
      if (error.code == 'already_active') {
        final active = await activeTask(to: to, src: src, sub: sub);
        if (active != null) return active;
      }
      throw error;
    }
  }

  /// 该 `(to, sub)` 现在排着/跑着的任务，没有就 null。用于恢复进度与吃掉 409。
  Future<CacheTask?> activeTask({required String to, required String src, String? sub}) async {
    try {
      final res = await _dio.get(
        '$baseUrl/status',
        queryParameters: {'to': to, 'src': src, if (sub != null) 'sub': sub},
      );
      final active = _map(res.data)['active_task'];
      return active is Map ? CacheTask.fromJson(Map<String, dynamic>.from(active)) : null;
    } on DioException {
      return null;
    }
  }

  /// 单个任务进度。只在用户点「查询状态」时调，App 不自动轮询。
  Future<CacheTask> task(String id) async {
    try {
      final res = await _dio.get('$baseUrl/tasks/$id');
      return CacheTask.fromJson(_map(res.data));
    } on DioException catch (e) {
      throw BoxCacheError.fromDio(e);
    }
  }

  static Map<String, dynamic> _map(Object? data) => _asMap(data);
}

/// 接口字段全部按「可能不存在」处理，所以取值都走这三个小助手。
Map<String, dynamic> _asMap(Object? data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  throw BoxCacheError(0, 'bad_json', '盒子返回了看不懂的东西');
}

int? _int(Object? value) => value is num ? value.toInt() : null;

double? _double(Object? value) => value is num ? value.toDouble() : null;
