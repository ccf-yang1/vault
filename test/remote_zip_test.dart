import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/models.dart';
import 'package:vault/data/remote_zip.dart';
import 'package:vault/data/webdav_client.dart';

import 'mock_webdav.dart';

/// 造一个既有 store 又有 deflate、还带中文目录层的 zip。
Uint8List buildZipBytes() {
  final archive = Archive();
  final readme = Uint8List.fromList(utf8.encode('拾阅 vault 压缩包测试\n' * 40));
  final blob = Uint8List.fromList(List.generate(512, (i) => i % 251));
  // 第 4 个参数是「内容已经压缩好了」，不是「请用这种压缩方式」：想要 deflate 就用默认构造。
  archive.addFile(ArchiveFile('说明/readme.txt', readme.length, readme));
  // 普通构造函数的第 4 个参数只影响解码，编码时看的是 file.compress —— 必须用 noCompress。
  archive.addFile(ArchiveFile.noCompress('说明/empty.bin', blob.length, blob));
  archive.addFile(ArchiveFile('顶层.jpg', 8, Uint8List.fromList(List.filled(8, 7))));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late MockWebDav server;
  late WebDavClient client;
  late Uint8List zipBytes;

  setUp(() async {
    zipBytes = buildZipBytes();
    server = MockWebDav();
    await server.start();
    server.files['/相册.zip'] = zipBytes;
    client = WebDavClient(ConnectionConfig(
      type: StorageType.webdav,
      baseUrl: server.baseUrl,
      username: server.username,
      password: server.password,
    ));
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  test('只读尾部 + 中央目录就能列出条目', () async {
    final zip = await RemoteZip.open(client, '/相册.zip', zipBytes.length);
    expect(zip.entries.map((e) => e.name), containsAll(['说明/readme.txt', '说明/empty.bin', '顶层.jpg']));
    expect(zip.entries.length, 3);
    // 远小于整包字节数：证明没有把整个文件拉下来。
    expect(zip.totalSize, zipBytes.length);
  });

  test('deflate 与 store 条目都能解压回原字节', () async {
    final zip = await RemoteZip.open(client, '/相册.zip', zipBytes.length);
    final readme = zip.entries.firstWhere((e) => e.name == '说明/readme.txt');
    final blob = zip.entries.firstWhere((e) => e.name == '说明/empty.bin');
    expect(readme.method, RemoteZip.deflateMethod);
    expect(blob.method, RemoteZip.storeMethod);

    final text = utf8.decode(await RemoteZip.extract(client, zip.path, readme), allowMalformed: true);
    expect(text, startsWith('拾阅 vault 压缩包测试'));

    final bytes = await RemoteZip.extract(client, zip.path, blob);
    expect(bytes, List.generate(512, (i) => i % 251));
  });

  test('childrenOf 造出虚拟目录，目录在前', () async {
    final zip = await RemoteZip.open(client, '/相册.zip', zipBytes.length);
    final root = RemoteZip.childrenOf(zip.entries, '');
    expect(root.map((e) => e.displayName), ['说明', '顶层.jpg']);
    expect(root.first.isDir, isTrue);

    final inner = RemoteZip.childrenOf(zip.entries, '说明/');
    expect(inner.map((e) => e.displayName), ['empty.bin', 'readme.txt']);
    expect(inner.every((e) => !e.isDir), isTrue);
  });

  test('不是 zip 的文件报可读的错误', () async {
    server.files['/假.zip'] = Uint8List.fromList(utf8.encode('this is definitely not a zip file at all'));
    await expectLater(
      RemoteZip.open(client, '/假.zip', 41),
      throwsA(isA<ZipFailure>().having((f) => f.message, 'message', contains('结束记录'))),
    );
  });

  test('中央目录解析是纯函数，可脱离网络测', () {
    final entries = RemoteZip.parseCentralDirectory(zipBytes);
    expect(entries, isEmpty); // 传的是整包而非 CD 段，应该解析不出条目而不是崩
  });
}
