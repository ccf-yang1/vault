import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 假 WebDAV 服务器：内存文件系统 + PROPFIND / Range GET / PUT / MKCOL / HEAD。
///
/// 用真实 HTTP 而不是 mock Dio 适配器，是为了把「dio 的 Options / method、
/// href 前缀剥离、207 解析」这些真会出错的地方一起覆盖掉。
class MockWebDav {
  MockWebDav({
    this.username = 'reader',
    this.password = 'secret',
    this.prefix = '/dav',
  });

  final String username;
  final String password;
  final String prefix;

  final Map<String, Uint8List> files = {};
  final Set<String> dirs = {};
  int? requireAuthStatus;
  bool ignoreRange = false;

  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle);
    return 'http://127.0.0.1:${server.port}';
  }

  String get baseUrl => 'http://127.0.0.1:${_server!.port}$prefix';

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  String get expectedAuth => 'Basic ${base64Encode(latin1.encode('$username:$password'))}';

  void _handle(HttpRequest request) async {
    final res = request.response;
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (requireAuthStatus != null) {
      res.statusCode = requireAuthStatus!;
      await res.close();
      return;
    }
    if (auth != expectedAuth) {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }

    final raw = Uri.decodeFull(request.uri.path);
    final path = raw.startsWith(prefix) ? _norm(raw.substring(prefix.length)) : _norm(raw);
    final method = request.method;

    if (method == 'PROPFIND') {
      await _propfind(res, path);
      return;
    }
    if (method == 'HEAD') {
      final data = files[path];
      if (data == null) {
        res.statusCode = HttpStatus.notFound;
      } else {
        res.contentLength = data.length;
      }
      await res.close();
      return;
    }
    if (method == 'GET') {
      final data = files[path];
      if (data == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && !ignoreRange) {
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);
          final slice = Uint8List.sublistView(data, start, end + 1 > data.length ? data.length : end + 1);
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$start+${slice.length - 1}/${data.length}');
          res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          res.contentLength = slice.length;
          res.add(slice);
          await res.close();
          return;
        }
      }
      res.contentLength = data.length;
      res.add(data);
      await res.close();
      return;
    }
    if (method == 'MKCOL') {
      if (dirs.contains(path)) {
        res.statusCode = HttpStatus.methodNotAllowed;
      } else {
        dirs.add(path);
        res.statusCode = HttpStatus.created;
      }
      await res.close();
      return;
    }
    if (method == 'PUT') {
      final bytes = await _readBody(request);
      files[path] = bytes;
      res.statusCode = HttpStatus.created;
      await res.close();
      return;
    }
    res.statusCode = HttpStatus.methodNotAllowed;
    await res.close();
  }

  static Future<Uint8List> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await request.forEach(builder.add);
    return builder.toBytes();
  }

  static String _norm(String path) {
    var p = path;
    if (p.isEmpty || p == '/') return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// 列出 `path` 的直接子项（含自身），用 `D:` 前缀，客户端必须按 localName 解析。
  Future<void> _propfind(HttpResponse res, String path) async {
    List<String> segments(String p) => p.split('/').where((s) => s.isNotEmpty).toList();
    final base = segments(path);
    final subDirs = <String>{...dirs.where((d) => d != path && segments(d).length == base.length + 1 && _under(d, path))};
    final subFiles = <String>[];
    for (final key in files.keys) {
      if (!_under(key, path)) continue;
      if (segments(key).length == base.length + 1) {
        subFiles.add(key);
      } else {
        final deeper = '/${segments(key).take(base.length + 1).join('/')}';
        if (!subFiles.contains(deeper)) subDirs.add(deeper);
      }
    }

    final buffer = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<D:multistatus xmlns:D="DAV:">')
      ..write(_responseXml(path, isDir: true));
    for (final dir in subDirs) {
      buffer.write(_responseXml(dir, isDir: true));
    }
    for (final child in subFiles) {
      buffer.write(_responseXml(child, isDir: false));
    }
    buffer.write('</D:multistatus>');

    res.statusCode = 207;
    res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
    res.write(buffer.toString());
    await res.close();
  }

  static bool _under(String key, String path) =>
      path == '/' ? key.length > 1 : key.startsWith('$path/');

  String _responseXml(String path, {required bool isDir}) {
    final name = path == '/' ? '' : path.substring(path.lastIndexOf('/') + 1);
    final href = path == '/' ? '$prefix/' : '$prefix${_enc(path)}';
    final size = isDir ? 0 : files[path]?.length ?? 0;
    final type = isDir
        ? '<D:resourcetype><D:collection/></D:resourcetype>'
        : '<D:resourcetype/>';
    return '<D:response>'
        '<D:href>$href</D:href>'
        '<D:propstat><D:prop>'
        '<D:displayname>${_esc(name)}</D:displayname>'
        '$type'
        '<D:getcontentlength>$size</D:getcontentlength>'
        '<D:getetag>"et-$name"</D:getetag>'
        '<D:getlastmodified>Tue, 11 Jun 2024 08:00:00 GMT</D:getlastmodified>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
        '</D:response>';
  }

  static String _esc(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// 规范服务端会把 href 按段 percent-encode（displayname 才是原文）。
  static String _enc(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');
}
