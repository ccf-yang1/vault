import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:xml/xml.dart';

import '../core/models.dart';

enum WebDavErrorKind {
  badConfig,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  insufficientStorage,
  timeout,
  tls,
  canceled,
  rangeUnsupported,
  notWebDavRoot,
  tooManyAttempts,
  schemeMismatch,
  writeDisabled,
  localNetworkBlocked,
  server,
  network,
}

/// 需求 §8：错误要能说人话，连接页和设置页直接展示 [message]。
class WebDavError implements Exception {
  WebDavError(this.kind, {this.statusCode, this.detail});

  final WebDavErrorKind kind;
  final int? statusCode;
  final String? detail;

  String get message => switch (kind) {
        WebDavErrorKind.badConfig => '地址格式不对，请填写完整 URL，例如 http://192.168.1.100:5244/dav',
        WebDavErrorKind.unauthorized => '用户名或密码错误',
        WebDavErrorKind.forbidden => '已登录，但这个账号没有读取这里的权限（OpenList 后台的用户权限里勾上 WebDAV 读取）',
        WebDavErrorKind.notFound => '路径不存在，可能已被移动或重命名',
        WebDavErrorKind.conflict => '上级目录不存在或不可写',
        WebDavErrorKind.insufficientStorage => '服务器空间不足',
        WebDavErrorKind.timeout => '连接超时，检查服务器是否在运行',
        WebDavErrorKind.tls => '证书不受信任（自签或已过期）。如果这台服务器是明文服务，地址请用 http:// 开头',
        WebDavErrorKind.canceled => '已取消',
        WebDavErrorKind.rangeUnsupported => '服务器不支持分段请求',
        WebDavErrorKind.notWebDavRoot => '这个地址不是 WebDAV 入口。OpenList 要填到 /dav，例如 http://192.168.1.100:5244/dav',
        // OpenList / Alist 的 WebDAV 中间件按 IP 计数，5 次失败锁 5 分钟（server/webdav.go）。
        WebDavErrorKind.tooManyAttempts => '连续失败次数太多，服务器把这个 IP 临时锁了 5 分钟，先等一会儿再试',
        WebDavErrorKind.schemeMismatch => '这个端口像是明文 HTTP 服务，请把地址改成 http:// 开头',
        // OpenList / Alist 把 WebDAV 的读和写分成两档权限，新建用户默认只给读（server/webdav.go）。
        WebDavErrorKind.writeDisabled => '这个账号只能看不能传，请在 OpenList 后台的用户权限里勾上 WebDAV 写入',
        // iOS 从 14 起在系统层拦掉没有「本地网络」权限的局域网直连，报出来只是普通 socket 失败。
        WebDavErrorKind.localNetworkBlocked => 'iPhone 不允许这个 App 访问局域网。请到 设置 → 隐私与安全性 → 本地网络 里打开 Vault，然后彻底关掉 App 再试一次',
        WebDavErrorKind.server => '服务器错误${statusCode == null ? '' : ' ($statusCode)'}',
        WebDavErrorKind.network => '无法连接服务器${statusCode == null ? '' : ' (HTTP $statusCode)'}',
      };

  static WebDavError from(DioException e, {bool lanTarget = false}) {
    if (e.type == DioExceptionType.cancel) return WebDavError(WebDavErrorKind.canceled);
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return WebDavError(WebDavErrorKind.timeout, detail: e.message);
    }
    if (e.error is HandshakeException) {
      final text = e.error.toString();
      final isCert = text.toLowerCase().contains('certificate') || text.contains('x509');
      // 不是证书问题却握手失败，基本都是拿 https 去连明文端口。
      return WebDavError(isCert ? WebDavErrorKind.tls : WebDavErrorKind.schemeMismatch, detail: text);
    }
    if (e.error is SocketException) {
      final text = e.error.toString();
      // 「本地网络」权限被拒时 iOS 不会给任何权限错误，只让 connect() 以
      // Network is down / No route to host / Operation not permitted 失败。
      final denied = lanTarget &&
          (text.contains('Network is down') ||
              text.contains('No route to host') ||
              text.contains('Operation not permitted'));
      return WebDavError(
        denied ? WebDavErrorKind.localNetworkBlocked : WebDavErrorKind.network,
        detail: text,
      );
    }
    final code = e.response?.statusCode;
    if (code != null) return fromStatus(code, body: e.response?.data);
    return WebDavError(WebDavErrorKind.network, detail: e.message);
  }

  static WebDavError fromStatus(int code, {Object? body}) {
    final kind = switch (code) {
      401 => WebDavErrorKind.unauthorized,
      403 => WebDavErrorKind.forbidden,
      404 => WebDavErrorKind.notFound,
      405 || 409 => WebDavErrorKind.conflict,
      416 => WebDavErrorKind.rangeUnsupported,
      429 => WebDavErrorKind.tooManyAttempts,
      507 => WebDavErrorKind.insufficientStorage,
      >= 500 => WebDavErrorKind.server,
      _ => WebDavErrorKind.network,
    };
    return WebDavError(kind, statusCode: code, detail: body?.toString());
  }

  /// 写请求（PUT / MKCOL）撞到的 403 基本都是「没开 WebDAV 写入」，
  /// 跟读不到混成一句话会让人反复改密码。
  static WebDavError forWrite(WebDavError e) => e.kind == WebDavErrorKind.forbidden
      ? WebDavError(WebDavErrorKind.writeDisabled, statusCode: e.statusCode, detail: e.detail)
      : e;
}

/// v1 只走 WebDAV 协议：OpenList 也连它的 `/dav` 入口（需求 §1 处理原则）。
///
/// 认证头每次主动带上，不做 challenge 往返 —— OpenList / Alist 的 WebDAV 对
/// 401 重试的支持不稳定，PROPFIND 尤其明显。
class WebDavClient {
  WebDavClient(
    this.config, {
    Dio? dio,
    bool allowInsecureCertificate = false,
  }) : _allowInsecure = allowInsecureCertificate {
    _dio = dio ?? _buildDio();
  }

  final ConnectionConfig config;
  final bool _allowInsecure;
  late final Dio _dio;

  /// WebDAV 根：baseUrl 本身，所有远程路径都相对它拼接。
  late final Uri _base = Uri.parse(normalizeBase(config.baseUrl, config.type));

  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// 把用户手打的地址变成真正能用的 WebDAV 根。
  ///
  /// 有两件事必须替用户做掉，否则「明明正确的地址」会一路 405 / 握手失败，
  /// 看上去就跟密码错一样：
  /// 1. 省略协议时，IP / localhost / .local 这类内网地址走 http，其余走 https；
  /// 2. 选了 OpenList 就补上 `/dav`，它的所有 WebDAV 路由都挂在这个前缀下。
  static String normalizeBase(String raw, [StorageType type = StorageType.webdav]) {
    var s = raw.trim();
    if (s.isEmpty) throw WebDavError(WebDavErrorKind.badConfig);
    // 中间有空白的从来不是合法 URL，Uri.parse 却会把它们percent 编码后将就解析出来。
    if (s.contains(RegExp(r'\s'))) throw WebDavError(WebDavErrorKind.badConfig);
    if (!_scheme.hasMatch(s)) s = '${_looksLikeLan(s) ? 'http' : 'https'}://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw WebDavError(WebDavErrorKind.badConfig);
    }
    var path = uri.path;
    if (type == StorageType.openlist && (path.isEmpty || path == '/')) path = '/dav';
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return uri.replace(path: path).toString();
  }

  static bool _looksLikeLan(String url) {
    var authority = url.replaceFirst(_scheme, '').split('/').first;
    if (authority.contains('@')) authority = authority.substring(authority.lastIndexOf('@') + 1);
    if (authority.startsWith('[')) return true; // IPv6 字面量
    final colon = authority.lastIndexOf(':');
    final hasPort = colon > 0 && int.tryParse(authority.substring(colon + 1)) != null;
    final host = hasPort ? authority.substring(0, colon) : authority;
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
        host == 'localhost' ||
        host.endsWith('.local');
  }

  /// 目标是不是局域网地址：决定 socket 失败要不要报成「本地网络权限被拒」。
  bool get targetsLocalNetwork => _looksLikeLan(config.baseUrl);

  WebDavError _err(DioException e) => WebDavError.from(e, lanTarget: targetsLocalNetwork);

  String get authHeader =>
      'Basic ${base64Encode(latin1.encode('${config.username}:${config.password}'))}';
  /// 服务器前缀（例如 `/dav`），PROPFIND 的 href 需要把它剥掉。
  String get hostBasePath {
    final segs = _base.pathSegments.where((s) => s.isNotEmpty);
    if (segs.isEmpty) return '';
    return '/${segs.join('/')}';
  }

  Uri urlFor(String path) {
    final segs = <String>[
      ..._base.pathSegments.where((s) => s.isNotEmpty),
      ...RemotePath.normalize(path).split('/').where((s) => s.isNotEmpty),
    ];
    return _base.replace(pathSegments: segs);
  }

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
        headers: {'Authorization': authHeader},
      ),
    );
    final adapter = dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter && _allowInsecure) {
      adapter.createHttpClient = () => HttpClient()
        ..badCertificateCallback = (_, __, ___) => true;
    }
    return dio;
  }

  static const _streamTimeout = Duration(hours: 6);

  Options _options({
    required String method,
    Duration? receiveTimeout,
    Map<String, dynamic>? headers,
    ResponseType? responseType,
    bool Function(int? status)? validateStatus,
  }) =>
      Options(
        method: method,
        sendTimeout: _streamTimeout,
        receiveTimeout: receiveTimeout ?? const Duration(seconds: 30),
        responseType: responseType ?? ResponseType.plain,
        headers: {'Authorization': authHeader, if (headers != null) ...headers},
        validateStatus: validateStatus ?? _okStatus,
      );

  static bool _okStatus(int? status) => status != null && status >= 200 && status < 400;

  Future<List<RemoteEntry>> list(String path) async {
    final target = RemotePath.normalize(path);
    Response<dynamic> res;
    try {
      res = await _dio.request<dynamic>(
        urlFor(target).toString(),
        data: _propfindBody,
        options: _options(
          method: 'PROPFIND',
          headers: const {
            'Content-Type': 'application/xml; charset=utf-8',
            'Depth': '1',
          },
          // 状态码要自己判（405 是「地址不对」的重要线索），别让 dio 提前抛掉。
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } on DioException catch (e) {
      throw _err(e);
    }
    final status = res.statusCode ?? 0;
    if (status != 207 && status != 200) {
      // 漏掉 /dav 时 PROPFIND 会打到 OpenList 的 API 根，被 gin 拒成 405/404/400 ——
      // 这是地址填错，不是「上级目录不可写」。子目录的 404 仍然按路径不存在报。
      if (target == '/' && (status == 400 || status == 404 || status == 405)) {
        throw WebDavError(WebDavErrorKind.notWebDavRoot, statusCode: status, detail: res.data?.toString());
      }
      throw WebDavError.fromStatus(status, body: res.data);
    }
    return parseMultistatus(res.data?.toString() ?? '', basePath: target, hostBase: hostBasePath);
  }

  static const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:getcontentlength/>
    <d:getcontenttype/>
    <d:getetag/>
    <d:getlastmodified/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>''';

  /// 解析 207 Multi-Status。纯函数，可离线单测。
  static List<RemoteEntry> parseMultistatus(
    String xmlBody, {
    required String basePath,
    required String hostBase,
  }) {
    if (xmlBody.trim().isEmpty) return const [];
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlBody);
    } on XmlException {
      // 200 + 网页而不是 207 XML：几乎一定是打到了站点根，不是 WebDAV 入口。
      throw WebDavError(WebDavErrorKind.notWebDavRoot, detail: 'PROPFIND 响应不是合法 XML');
    }
    // 登录页 / 门户 / OpenList 前端本身都是合法 XML，能一路解析成「空目录」，
    // 所以必须确认根节点确实是 multistatus 才算数。
    if (doc.rootElement.name.local.toLowerCase() != 'multistatus') {
      throw WebDavError(
        WebDavErrorKind.notWebDavRoot,
        detail: '响应根节点是 <${doc.rootElement.name.local}>，不是 WebDAV 目录列表',
      );
    }
    final base = RemotePath.normalize(basePath);
    final out = <RemoteEntry>[];
    for (final response in _elementsByName(doc, 'response')) {
      final href = _first(response, 'href')?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      final entry = entryFromHref(
        href,
        hostBase: hostBase,
        nameHint: _first(response, 'displayname')?.innerText,
        isDir: _elementsByName(response, 'collection').isNotEmpty,
        sizeText: _first(response, 'getcontentlength')?.innerText,
        mime: _first(response, 'getcontenttype')?.innerText,
        etag: _first(response, 'getetag')?.innerText,
        lastModified: _first(response, 'getlastmodified')?.innerText,
      );
      if (entry == null) continue;
      if (entry.path == base) continue; // 目录自身，不算子项
      if (entry.name.startsWith('.')) continue;
      out.add(entry);
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  static RemoteEntry? entryFromHref(
    String rawHref, {
    required String hostBase,
    String? nameHint,
    bool isDir = false,
    String? sizeText,
    String? mime,
    String? etag,
    String? lastModified,
  }) {
    var href = rawHref.trim();
    if (href.contains('://')) href = Uri.parse(href).path;
    href = _decodeHref(href);
    var rel = href;
    if (hostBase.isNotEmpty && hostBase != '/') {
      final prefix = hostBase.endsWith('/') ? hostBase : '$hostBase/';
      if (href.startsWith(prefix)) {
        rel = '/${href.substring(prefix.length)}';
      } else if (href == hostBase || href == '$hostBase/') {
        rel = '/';
      }
    }
    rel = RemotePath.normalize(rel);
    final name = RemotePath.nameOf(rel);
    final display = (nameHint ?? '').trim();
    return RemoteEntry(
      name: (display.isEmpty || display.contains('/') || rel == '/') ? name : display,
      path: rel,
      isDir: isDir,
      size: isDir ? 0 : (int.tryParse((sizeText ?? '').trim()) ?? 0),
      mimeType: (mime == null || mime.isEmpty) ? null : mime,
      modified: parseHttpDate(lastModified),
      etag: (etag == null || etag.isEmpty) ? null : etag,
    );
  }

  /// href 按 RFC 应是 percent-encoded，但部分 Alist / OpenList 版本直接吐未编码
  /// 的 UTF-8，`Uri.decodeFull` 对后者会抛 ArgumentError —— 原样返回更安全。
  static String _decodeHref(String href) {
    if (href.codeUnits.every((unit) => unit < 0x80)) {
      try {
        return Uri.decodeFull(href);
      } on ArgumentError {
        return href;
      }
    }
    return href;
  }

  static DateTime? parseHttpDate(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;
    try {
      return HttpDate.parse(s);
    } on FormatException {
      try {
        return DateTime.parse(s);
      } on FormatException {
        return null;
      }
    }
  }

  static List<XmlElement> _elementsByName(XmlNode root, String localName) {
    final out = <XmlElement>[];
    void visit(XmlNode node) {
      if (node is XmlElement && node.name.local == localName) out.add(node);
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(root);
    return out;
  }

  static XmlElement? _first(XmlElement parent, String localName) {
    for (final node in parent.descendants) {
      if (node is XmlElement && node.name.local == localName) return node;
    }
    return null;
  }

  Future<bool> exists(String path) async {
    try {
      await _dio.request<dynamic>(
        urlFor(path).toString(),
        options: _options(method: 'HEAD', receiveTimeout: const Duration(seconds: 15)),
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404 || code == 405 || code == 400 || code == 403) return false;
      throw _err(e);
    }
  }

  Future<void> createDirectory(String path) async {
    try {
      final res = await _dio.request<dynamic>(
        urlFor(path).toString(),
        options: _options(
          method: 'MKCOL',
          receiveTimeout: const Duration(seconds: 20),
          // 目录已存在要当成成功，所以 4xx 得先进到 res.statusCode 再判。
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final code = res.statusCode ?? 0;
      if (code == 201 || code == 204 || code == 200 || code == 405) return;
      throw WebDavError.forWrite(WebDavError.fromStatus(code, body: res.data));
    } on DioException catch (e) {
      throw WebDavError.forWrite(_err(e));
    }
  }

  /// 读取字节区间：ZIP 中央目录、按需解压都靠它。
  Future<Uint8List> readRange(String path, int start, int end) async {
    try {
      final res = await _dio.get<List<int>>(
        urlFor(path).toString(),
        options: _options(
          method: 'GET',
          receiveTimeout: _streamTimeout,
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=$start-$end'},
        ),
      );
      final code = res.statusCode ?? 0;
      final bytes = res.data == null ? Uint8List(0) : Uint8List.fromList(res.data!);
      if (code == 206) return bytes;
      if (code == 200) {
        // 服务器忽略了 Range：只能把整段切出来，超大文件直接判定不支持。
        if (bytes.length <= start) throw WebDavError(WebDavErrorKind.rangeUnsupported);
        return bytes.sublist(start, end < bytes.length ? end + 1 : bytes.length);
      }
      throw WebDavError.fromStatus(code);
    } on DioException catch (e) {
      throw _err(e);
    }
  }

  Future<void> download(
    String path,
    String destination, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      await _dio.download(
        urlFor(path).toString(),
        destination,
        cancelToken: cancelToken,
        options: _options(method: 'GET', responseType: ResponseType.stream),
        onReceiveProgress: onProgress,
      );
    } on DioException catch (e) {
      throw _err(e);
    }
  }

  /// WebDAV PUT。
  Future<void> uploadFile(
    File source,
    String destination, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final length = await source.length();
    try {
      await _dio.put(
        urlFor(destination).toString(),
        data: source.openRead(),
        cancelToken: cancelToken,
        onSendProgress: onProgress,
        options: _options(
          method: 'PUT',
          headers: {
            Headers.contentLengthHeader: length,
            'Content-Type': mimeTypeFor(destination),
          },
        ),
      );
    } on DioException catch (e) {
      throw WebDavError.forWrite(_err(e));
    }
  }

  /// 重名默认追加 `_1`、`_2`（需求 §3.6）。
  Future<String> resolveUniquePath(String directory, String fileName) async {
    var candidate = RemotePath.join(directory, fileName);
    if (!await exists(candidate)) return candidate;
    final dot = fileName.lastIndexOf('.');
    final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
    final ext = dot <= 0 ? '' : fileName.substring(dot);
    for (var i = 1; i < 200; i++) {
      candidate = RemotePath.join(directory, '${stem}_$i$ext');
      if (!await exists(candidate)) return candidate;
    }
    throw WebDavError(WebDavErrorKind.conflict, detail: '同名文件过多');
  }

  void close() => _dio.close(force: true);
}

final Map<String, String> _mimeMap = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif',
  '.webp': 'image/webp', '.heic': 'image/heic', '.heif': 'image/heif', '.bmp': 'image/bmp',
  '.tif': 'image/tiff', '.tiff': 'image/tiff', '.avif': 'image/avif',
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mov': 'video/quicktime', '.mkv': 'video/x-matroska',
  '.webm': 'video/webm', '.avi': 'video/x-msvideo', '.3gp': 'video/3gpp',
  '.zip': 'application/zip', '.rar': 'application/x-rar-compressed', '.7z': 'application/x-7z-compressed',
  '.tar': 'application/x-tar', '.gz': 'application/gzip',
  '.pdf': 'application/pdf', '.txt': 'text/plain; charset=utf-8',
};

String mimeTypeFor(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
  return _mimeMap[ext] ?? 'application/octet-stream';
}
