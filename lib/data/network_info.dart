import 'dart:io';

/// iOS 的「本地网络」授权框只在 App 主动去连局域网地址那一刻才可能弹，而且有个
/// 老毛病：首次连接若被系统秒拒（ENETUNREACH），有时候根本不弹——用户只会看到
/// 「No route to host」，设置里也找不到这个 App。打开时先往局域网发一个会被立刻
/// 拒掉的 TCP 连接，专门用来把那个框顶出来；连不通不影响任何功能。
Future<void> triggerLocalNetworkPrompt() async {
  for (final host in const ['192.168.1.1', '192.168.1.17']) {
    try {
      final socket = await Socket.connect(host, 80, timeout: const Duration(seconds: 2));
      socket.destroy();
    } on Object {
      // 被拒、超时都无所谓——目的只是触发系统授权框。
    }
  }
}

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
