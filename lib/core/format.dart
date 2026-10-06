/// 展示用的格式化函数，全部按中文习惯来。
library;

String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toInt().toString() : value.toStringAsFixed(decimals);
  return '$text ${units[unit]}';
}

String formatCount(int n) {
  final s = n.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
    buffer.write(s[i]);
  }
  return buffer.toString();
}

String formatClock(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}';
}

String formatDuration(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '${two(minutes)}:${two(seconds)}';
}

DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

String _md(DateTime d) => '${d.month}月${d.day}日';

/// 列表行的时间：今天/昨天用相对说法，7 天内用「N 天前」，更早用日期。
String formatRelativeTime(DateTime? time) {
  if (time == null) return '';
  final now = DateTime.now();
  final days = dayStart(now).difference(dayStart(time)).inDays;
  if (days == 0) {
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '今天';
  }
  if (days == 1) return '昨天';
  if (days < 7) return '$days 天前';
  if (time.year == now.year) return _md(time);
  return '${time.year}年${_md(time)}';
}

/// 上传页的日期分组标题：今天 · 6月12日。
String formatDayLabel(DateTime day) {
  final now = DateTime.now();
  final diff = dayStart(now).difference(dayStart(day)).inDays;
  final label = switch (diff) {
    0 => '今天',
    1 => '昨天',
    _ => diff < 7 ? '$diff 天前' : _md(day),
  };
  return '$label · ${_md(day)}';
}
