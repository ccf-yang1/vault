import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'webdav_client.dart';

class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.flags,
    this.modified,
  });

  /// ZIP 内部路径，`/` 分隔；虚拟目录以 `/` 结尾。
  final String name;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int flags;
  final DateTime? modified;

  bool get isDir => name.endsWith('/');

  String get displayName {
    var n = isDir ? name.substring(0, name.length - 1) : name;
    final slash = n.lastIndexOf('/');
    return slash < 0 ? n : n.substring(slash + 1);
  }

  bool get isEncrypted => flags & 0x1 != 0;
}

class ZipFailure implements Exception {
  ZipFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 只读远程 ZIP：Range 读中央目录列条目，点开哪个解压哪个（需求 §3.5）。
class RemoteZip {
  RemoteZip({required this.path, required this.totalSize, required this.entries});

  final String path;
  final int totalSize;
  final List<ZipEntry> entries;

  static const _eocdSig = 0x06054b50;
  static const _eocd64LocatorSig = 0x07064b50;
  static const _eocd64Sig = 0x06064b50;
  static const _centralSig = 0x02014b50;
  static const _localSig = 0x04034b50;
  static const _zip64ExtraId = 0x0001;
  static const _maxComment = 65535;

  /// 单文件解压上限，防止「点开一个 8 GB 的条目」把内存打爆。
  static const maxEntryBytes = 300 * 1024 * 1024;

  static const storeMethod = 0;
  static const deflateMethod = 8;

  static Future<RemoteZip> open(WebDavClient client, String path, int totalSize) async {
    if (totalSize < 22) throw ZipFailure('文件太小，不是有效的 ZIP');
    final tailLength = totalSize < 22 + _maxComment ? totalSize : 22 + _maxComment;
    final tail = await client.readRange(path, totalSize - tailLength, totalSize - 1);
    final eocdAt = _findSignature(tail, _eocdSig);
    if (eocdAt < 0) throw ZipFailure('没找到 ZIP 结束记录，文件可能已损坏');

    final view = ByteData.sublistView(tail);
    var totalEntries = view.getUint16(eocdAt + 10, Endian.little);
    var cdSize = view.getUint32(eocdAt + 12, Endian.little);
    var cdOffset = view.getUint32(eocdAt + 16, Endian.little);

    if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF || totalEntries == 0xFFFF) {
      // ZIP64：EOCD 前 20 字节是 locator，指向真正的 ZIP64 EOCD 记录。
      final locatorAt = eocdAt - 20;
      if (locatorAt < 0 || _u32(tail, locatorAt) != _eocd64LocatorSig) {
        throw ZipFailure('ZIP64 记录缺失或不完整');
      }
      final eocd64At = _u64(tail, locatorAt + 8);
      final head = await client.readRange(path, eocd64At, eocd64At + 55);
      if (_u32(head, 0) != _eocd64Sig) throw ZipFailure('ZIP64 结束记录损坏');
      totalEntries = _u64(head, 16);
      cdSize = _u64(head, 32);
      cdOffset = _u64(head, 40);
    }

    if (cdSize <= 0 || cdOffset + cdSize > totalSize) throw ZipFailure('中央目录越界');
    final cd = await client.readRange(path, cdOffset, cdOffset + cdSize - 1);
    return RemoteZip(path: path, totalSize: totalSize, entries: parseCentralDirectory(cd));
  }

  /// 纯函数，便于离线单测。
  static List<ZipEntry> parseCentralDirectory(Uint8List cd) {
    final view = ByteData.sublistView(cd);
    final out = <ZipEntry>[];
    var at = 0;
    while (at + 46 <= cd.length && _u32(cd, at) == _centralSig) {
      final flags = view.getUint16(at + 8, Endian.little);
      final method = view.getUint16(at + 10, Endian.little);
      final dosTime = view.getUint16(at + 12, Endian.little);
      final dosDate = view.getUint16(at + 14, Endian.little);
      var compressed = view.getUint32(at + 20, Endian.little);
      var uncompressed = view.getUint32(at + 24, Endian.little);
      final nameLength = view.getUint16(at + 28, Endian.little);
      final extraLength = view.getUint16(at + 30, Endian.little);
      final commentLength = view.getUint16(at + 32, Endian.little);
      var localOffset = view.getUint32(at + 42, Endian.little);

      final nameStart = at + 46;
      final nameEnd = nameStart + nameLength;
      if (nameEnd > cd.length) break;
      final name = utf8.decode(Uint8List.sublistView(cd, nameStart, nameEnd), allowMalformed: true);
      final extraStart = nameEnd;

      // ZIP64 扩展信息：按 (原始大小, 压缩后大小, 本地头偏移) 的固定顺序，
      // 只补那些原值取到 0xFFFFFFFF 的字段。
      if (uncompressed == 0xFFFFFFFF || compressed == 0xFFFFFFFF || localOffset == 0xFFFFFFFF) {
        final wide = zip64Extra(cd, extraStart, extraLength);
        var slot = 0;
        if (uncompressed == 0xFFFFFFFF && slot < wide.length) uncompressed = wide[slot++];
        if (compressed == 0xFFFFFFFF && slot < wide.length) compressed = wide[slot++];
        if (localOffset == 0xFFFFFFFF && slot < wide.length) localOffset = wide[slot];
      }

      out.add(
        ZipEntry(
          name: name,
          method: method,
          compressedSize: compressed,
          uncompressedSize: uncompressed,
          localHeaderOffset: localOffset,
          flags: flags,
          modified: dosToDateTime(dosDate, dosTime),
        ),
      );
      at = extraStart + extraLength + commentLength;
    }
    return out;
  }

  /// 把某个虚拟目录下的条目分成子目录和文件，目录优先、名称不区分大小写排序。
  static List<ZipEntry> childrenOf(List<ZipEntry> all, String prefix) {
    final files = <ZipEntry>[];
    final folders = <String, ZipEntry>{};
    for (final entry in all) {
      if (!entry.name.startsWith(prefix)) continue;
      final relative = entry.name.substring(prefix.length);
      if (relative.isEmpty) continue;
      final slash = relative.indexOf('/');
      if (slash < 0) {
        if (!entry.isDir) files.add(entry);
        continue;
      }
      if (slash == relative.length - 1) continue; // 目录自身
      final folderName = relative.substring(0, slash + 1);
      folders.putIfAbsent(
        folderName,
        () => ZipEntry(
          name: '$prefix$folderName',
          method: 0,
          compressedSize: 0,
          uncompressedSize: 0,
          localHeaderOffset: -1,
          flags: 0,
          modified: entry.modified,
        ),
      );
    }
    final orderedFolders = folders.values.toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    files.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return [...orderedFolders, ...files];
  }

  /// 按需解压单个条目：`store` 直接取字节，`deflate` 走 raw inflate。
  static Future<Uint8List> extract(WebDavClient client, String archivePath, ZipEntry entry) async {
    if (entry.isDir) throw ZipFailure('目录不能解压');
    if (entry.localHeaderOffset < 0) throw ZipFailure('条目信息不完整');
    if (entry.isEncrypted) throw ZipFailure('该压缩包有密码，暂不支持');
    if (entry.uncompressedSize > maxEntryBytes) {
      throw ZipFailure('单个文件超过 ${maxEntryBytes ~/ (1024 * 1024)} MB，不预览');
    }
    if (entry.compressedSize <= 0 && entry.method != 0) throw ZipFailure('条目大小未知，无法解压');

    final header = await client.readRange(archivePath, entry.localHeaderOffset, entry.localHeaderOffset + 29);
    if (header.length < 30 || _u32(header, 0) != _localSig) throw ZipFailure('本地文件头损坏');
    final view = ByteData.sublistView(header);
    final dataStart = entry.localHeaderOffset + 30 + view.getUint16(26, Endian.little) + view.getUint16(28, Endian.little);
    final raw =
        await client.readRange(archivePath, dataStart, dataStart + entry.compressedSize - 1);

    switch (entry.method) {
      case storeMethod:
        return raw;
      case deflateMethod:
        final bytes = Inflate(raw, entry.uncompressedSize).getBytes();
        return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      default:
        throw ZipFailure('不支持的压缩方式（method ${entry.method}）');
    }
  }

  static int _u32(Uint8List bytes, int at) => ByteData.sublistView(bytes).getUint32(at, Endian.little);

  static int _u64(Uint8List bytes, int at) {
    final view = ByteData.sublistView(bytes);
    return view.getUint32(at, Endian.little) | (view.getUint32(at + 4, Endian.little) << 32);
  }

  static List<int> zip64Extra(Uint8List cd, int extraStart, int extraLength) {
    final out = <int>[];
    final view = ByteData.sublistView(cd);
    final limit = extraStart + extraLength;
    var at = extraStart;
    while (at + 4 <= limit) {
      final id = view.getUint16(at, Endian.little);
      final size = view.getUint16(at + 2, Endian.little);
      final blockEnd = at + 4 + size;
      if (blockEnd > limit) break;
      if (id == _zip64ExtraId) {
        var cursor = at + 4;
        while (cursor + 8 <= blockEnd) {
          out.add(_u64(cd, cursor));
          cursor += 8;
        }
        return out;
      }
      at = blockEnd;
    }
    return out;
  }

  /// ZIP 存的是 MS-DOS 时间戳。
  static DateTime? dosToDateTime(int date, int time) {
    if (date == 0) return null;
    final year = ((date >> 9) & 0x3f) + 1980;
    final month = (date >> 5) & 0x0f;
    final day = date & 0x1f;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day, (time >> 11) & 0x1f, (time >> 5) & 0x3f, (time & 0x1f) * 2);
  }

  static int _findSignature(Uint8List bytes, int signature) {
    final a = signature & 0xff;
    final b = (signature >> 8) & 0xff;
    final c = (signature >> 16) & 0xff;
    final d = (signature >> 24) & 0xff;
    for (var i = bytes.length - 4; i >= 0; i--) {
      if (bytes[i] == a && bytes[i + 1] == b && bytes[i + 2] == c && bytes[i + 3] == d) return i;
    }
    return -1;
  }
}
