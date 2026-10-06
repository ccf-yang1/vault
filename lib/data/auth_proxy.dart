import 'dart:io';

import 'package:dio/dio.dart';

import 'webdav_client.dart';

/// 127.0.0.1 本地回环代理。
///
/// `video_player` 走 AVFoundation，无法给 URL 附带 `Authorization` 头，而
/// WebDAV 必须带；同时播放器拖进度条依赖 HTTP Range。这里把两者都补上：
/// 播放器请求本地端口，代理带上认证头转发到 WebDAV 并把 Range / Content-Range
/// 原样回传，实现「边播边预取」而不必先下完（需求 §3.4）。
class AuthProxy {
  AuthProxy(this.client);

  final WebDavClient client;

  HttpServer? _server;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(hours: 6),
      responseType: ResponseType.stream,
      followRedirects: true,
      maxRedirects: 5,
    ),
  );

  Future<String> start() async {
    final existing = _server;
    if (existing != null) return 'http://127.0.0.1:${existing.port}';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object _) {});
    return 'http://127.0.0.1:${server.port}';
  }

  /// 播放地址：路径放在 query 里，避免多级路径在本地端口上歧义。
  Future<Uri> urlFor(String remotePath) async {
    final base = await start();
    return Uri.parse('$base/stream?p=${Uri.encodeComponent(remotePath)}');
  }

  Future<void> _handle(HttpRequest request) async {
    final remotePath = request.uri.queryParameters['p'] ?? '';
    final response = request.response;
    if (remotePath.isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    try {
      final res = await _dio.get<ResponseBody>(
        client.urlFor(remotePath).toString(),
        options: Options(
          method: request.method == 'HEAD' ? 'HEAD' : 'GET',
          responseType: ResponseType.stream,
          headers: {
            'Authorization': client.authHeader,
            if (range != null) HttpHeaders.rangeHeader: range,
          },
          // 4xx/5xx 原样转给播放器，让它自己报错，而不是代理抛异常。
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final status = res.statusCode ?? HttpStatus.badGateway;
      final body = res.data?.stream;
      if (status >= 400 || body == null) {
        response.statusCode = status;
        await response.close();
        return;
      }
      response.statusCode = status;
      final headers = res.headers;
      void copy(String name) {
        final value = headers.value(name);
        if (value != null) response.headers.set(name, value);
      }

      copy(HttpHeaders.contentTypeHeader);
      copy(HttpHeaders.contentRangeHeader);
      final length = res.data?.contentLength;
      if (length != null && length > 0) {
        response.headers.set(HttpHeaders.contentLengthHeader, '$length');
      } else {
        copy(HttpHeaders.contentLengthHeader);
      }
      if (response.headers.value(HttpHeaders.acceptRangesHeader) == null) {
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.addStream(body);
      await response.close();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      response.statusCode = status ?? HttpStatus.badGateway;
      await response.close();
    } on Object {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
    _dio.close(force: true);
  }
}
