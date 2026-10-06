import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/models.dart';
import 'package:vault/data/webdav_client.dart';

import 'mock_webdav.dart';

void main() {
  late MockWebDav server;
  late WebDavClient client;

  ConnectionConfig config() => ConnectionConfig(
        type: StorageType.webdav,
        baseUrl: server.baseUrl,
        username: server.username,
        password: server.password,
      );

  setUp(() async {
    server = MockWebDav();
    await server.start();
    server.files['/旅行/IMG_0001.jpg'] = Uint8List.fromList(List.generate(64, (i) => i));
    server.files['/旅行/movie.mp4'] = Uint8List.fromList(List.generate(120, (i) => (i * 3) % 251));
    server.files['/readme.txt'] = Uint8List.fromList(utf8.encode('hello vault'));
    server.dirs.add('/私人相册');
    client = WebDavClient(config());
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  group('PROPFIND 解析', () {
    test('按 localName 取属性，目录在前、名称排序', () async {
      final entries = await client.list('/');
      expect(entries.map((e) => e.name), ['旅行', '私人相册', 'readme.txt']);
      expect(entries[0].isDir, isTrue);
      expect(entries[2].path, '/readme.txt');
      expect(entries[2].size, 11);
      expect(entries[2].kind, FileKind.other);
      expect(entries[2].modified, isNotNull);
    });

    test('子目录的 href 会剥掉服务器前缀 /dav', () async {
      final entries = await client.list('/旅行');
      expect(entries.map((e) => e.path), ['/旅行/IMG_0001.jpg', '/旅行/movie.mp4']);
      expect(entries.first.kind, FileKind.image);
      expect(entries.last.kind, FileKind.video);
      expect(entries.first.etag, isNotNull);
    });

    test('中文与空格目录名还原', () async {
      server.files['/a b/照片 (1).png'] = Uint8List(1);
      final entries = await client.list('/a b');
      expect(entries.single.name, '照片 (1).png');
      expect(entries.single.path, '/a b/照片 (1).png');
    });

    test('服务端返回未编码 href 也能用（部分 OpenList 版本）', () {
      final entry = WebDavClient.entryFromHref('/dav/私人相册/IMG_1.jpg', hostBase: '/dav');
      expect(entry?.path, '/私人相册/IMG_1.jpg');
    });

    test('隐藏文件不列出来', () async {
      server.files['/.DS_Store'] = Uint8List(1);
      final entries = await client.list('/');
      expect(entries.any((e) => e.name.startsWith('.')), isFalse);
    });
  });

  group('错误映射', () {
    test('401 是用户名或密码错误', () async {
      server.requireAuthStatus = HttpStatus.unauthorized;
      await expectLater(client.list('/'), throwsA(isA<WebDavError>()));
      try {
        await client.list('/');
      } on WebDavError catch (e) {
        expect(e.kind, WebDavErrorKind.unauthorized);
        expect(e.message, contains('密码'));
      }
    });

    test('404 说人话', () {
      final error = WebDavError.fromStatus(HttpStatus.notFound);
      expect(error.kind, WebDavErrorKind.notFound);
      expect(error.message, isNotEmpty);
    });

    // 真机反馈「各种凭据都登录失败」，实际是地址漏了 /dav：PROPFIND 打到站点根被 gin 拒成 405。
    test('漏掉 /dav 时报「地址不对」而不是「目录不可写」', () async {
      final bare = WebDavClient(ConnectionConfig(
        type: StorageType.webdav,
        baseUrl: server.baseUrl.replaceFirst(server.prefix, ''),
        username: server.username,
        password: server.password,
      ));
      addTearDown(bare.close);
      try {
        await bare.list('/');
        fail('应当抛错');
      } on WebDavError catch (e) {
        expect(e.kind, WebDavErrorKind.notWebDavRoot);
        expect(e.message, contains('/dav'));
      }
    });

    test('选了 OpenList 就自动补 /dav', () async {
      final auto = WebDavClient(ConnectionConfig(
        type: StorageType.openlist,
        baseUrl: server.baseUrl.replaceFirst(server.prefix, ''),
        username: server.username,
        password: server.password,
      ));
      addTearDown(auto.close);
      expect(await auto.list('/'), isNotEmpty);
    });

    test('站点返回网页也当成地址填错', () async {
      server.propfindBody = '<html><body>OpenList 前端</body></html>';
      await expectLater(
        client.list('/'),
        throwsA(isA<WebDavError>()
            .having((e) => e.kind, 'kind', WebDavErrorKind.notWebDavRoot)),
      );
    });

    test('429 是 IP 被临时锁定', () async {
      server.propfindStatus = HttpStatus.tooManyRequests;
      await expectLater(
        client.list('/'),
        throwsA(isA<WebDavError>()
            .having((e) => e.kind, 'kind', WebDavErrorKind.tooManyAttempts)
            .having((e) => e.message, 'message', contains('锁'))),
      );
    });
  });

  group('存在性与建目录', () {
    test('HEAD 已存在返回 true', () async {
      expect(await client.exists('/readme.txt'), isTrue);
    });

    test('HEAD 不存在返回 false', () async {
      expect(await client.exists('/nope.txt'), isFalse);
    });

    test('MKCOL 后再建一次吃 405 也算成功', () async {
      await client.createDirectory('/新目录');
      expect(server.dirs, contains('/新目录'));
      await client.createDirectory('/新目录');
    });

    test('重名自动追加 _1', () async {
      final path = await client.resolveUniquePath('/', 'readme.txt');
      expect(path, '/readme_1.txt');
    });
  });

  group('Range 读取', () {
    test('206 返回区间字节', () async {
      final bytes = await client.readRange('/旅行/movie.mp4', 10, 19);
      expect(bytes, isA<Uint8List>());
      expect(bytes.length, 10);
      expect(bytes.first, (10 * 3) % 251);
    });

    test('服务器忽略 Range 时切片', () async {
      server.ignoreRange = true;
      final bytes = await client.readRange('/旅行/movie.mp4', 100, 109);
      expect(bytes.length, 10);
      expect(bytes.first, (100 * 3) % 251);
    });

    test('起点超出文件大小时报不支持', () async {
      server.ignoreRange = true;
      await expectLater(
        client.readRange('/readme.txt', 500, 600),
        throwsA(isA<WebDavError>().having((e) => e.kind, 'kind', WebDavErrorKind.rangeUnsupported)),
      );
    });
  });

  group('上传下载', () {
    test('PUT 写入字节', () async {
      final tmp = File('${Directory.systemTemp.path}/vault-put-test.bin');
      await tmp.writeAsBytes(List.generate(32, (i) => 255 - i));
      await client.uploadFile(tmp, '/旅行/upload.bin', onProgress: (sent, total) {
        expect(total, 32);
        expect(sent, lessThanOrEqualTo(total));
      });
      expect(server.files['/旅行/upload.bin'], hasLength(32));
      await tmp.delete();
    });

    test('download 落盘', () async {
      final tmp = '${Directory.systemTemp.path}/vault-get-${DateTime.now().microsecondsSinceEpoch}.txt';
      await client.download('/readme.txt', tmp);
      expect(utf8.decode(await File(tmp).readAsBytes()), 'hello vault');
      await File(tmp).delete();
    });

    test('只读账号写时 403 报 writeDisabled，而不是笼统 forbidden', () async {
      server.writeStatus = HttpStatus.forbidden;
      final tmp = File('${Directory.systemTemp.path}/vault-readonly.bin');
      await tmp.writeAsBytes([1, 2, 3]);
      await expectLater(
        client.uploadFile(tmp, '/旅行/nope.bin'),
        throwsA(isA<WebDavError>().having((e) => e.kind, 'kind', WebDavErrorKind.writeDisabled)),
      );
      await expectLater(
        client.createDirectory('/新目录'),
        throwsA(isA<WebDavError>().having((e) => e.kind, 'kind', WebDavErrorKind.writeDisabled)),
      );
      // 读路径不受影响
      expect(await client.list('/'), isNotEmpty);
      await tmp.delete();
    });
  });

  test('normalizeBase 允许省略协议，且 urlFor 拼出 /dav 前缀', () {
    expect(WebDavClient.normalizeBase('https://x.test/dav/'), 'https://x.test/dav');
    final c = WebDavClient(ConnectionConfig(
      type: StorageType.openlist,
      baseUrl: 'http://192.0.2.1:5244/dav',
      username: 'admin',
      password: 'p',
    ));
    expect(c.urlFor('/私人相册/a.jpg').toString(), 'http://192.0.2.1:5244/dav/%E7%A7%81%E4%BA%BA%E7%9B%B8%E5%86%8C/a.jpg');
    expect(c.hostBasePath, '/dav');
    expect(c.authHeader, 'Basic ${base64Encode(latin1.encode('admin:p'))}');
    c.close();
  });

  test('省略协议时内网地址走 http，公网域名走 https', () {
    expect(WebDavClient.normalizeBase('192.168.1.100:5244/dav'), 'http://192.168.1.100:5244/dav');
    expect(WebDavClient.normalizeBase('localhost:5244/dav'), 'http://localhost:5244/dav');
    expect(WebDavClient.normalizeBase('nas.local:5244/dav'), 'http://nas.local:5244/dav');
    expect(WebDavClient.normalizeBase('dav.example.com/dav'), 'https://dav.example.com/dav');
    expect(WebDavClient.normalizeBase('[::1]:5244/dav'), 'http://[::1]:5244/dav');
    expect(WebDavClient.normalizeBase('https://192.168.1.100:5244/dav'), 'https://192.168.1.100:5244/dav');
  });

  test('OpenList 类型把站点根补成 /dav，WebDAV 类型不动', () {
    expect(
      WebDavClient.normalizeBase('http://192.168.1.100:5244', StorageType.openlist),
      'http://192.168.1.100:5244/dav',
    );
    expect(
      WebDavClient.normalizeBase('http://192.168.1.100:5244/', StorageType.openlist),
      'http://192.168.1.100:5244/dav',
    );
    expect(
      WebDavClient.normalizeBase('http://192.168.1.100:5244/dav', StorageType.openlist),
      'http://192.168.1.100:5244/dav',
    );
    // 自定义前缀（例如反代到 /openlist/dav）不能被覆盖。
    expect(
      WebDavClient.normalizeBase('http://192.168.1.100:5244/openlist/dav', StorageType.openlist),
      'http://192.168.1.100:5244/openlist/dav',
    );
    expect(WebDavClient.normalizeBase('http://192.168.1.100:5244'), 'http://192.168.1.100:5244');
  });

  test('空地址与没有主机的地址报 badConfig', () {
    for (final bad in ['', '   ', 'http://', 'not a url at all :5244']) {
      expect(
        () => WebDavClient.normalizeBase(bad),
        throwsA(isA<WebDavError>()
            .having((e) => e.kind, 'kind', WebDavErrorKind.badConfig)),
        reason: bad,
      );
    }
  });
}
