import 'dart:io';

/// 「仅 Wi-Fi 上传」的判定（需求 §3.6）。
///
/// iOS 上 Wi-Fi 固定是 `en0`，蜂窝是 `pdp_ip0`；不额外引 connectivity 插件，
/// 直接看网卡名。判定不出来时返回 true，宁可多放行也不要卡死上传。
Future<bool> isOverWifi() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    var hasCellular = false;
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (name == 'en0') return true;
      if (name.startsWith('pdp')) hasCellular = true;
    }
    return !hasCellular;
  } on Object {
    return true;
  }
}
