import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

String _s(String inner, {double w = 1.7}) =>
    '<svg viewBox="0 0 24 24"><g fill="none" stroke="#000" stroke-width="$w" '
    'stroke-linecap="round" stroke-linejoin="round">$inner</g></svg>';

String _f(String d) => '<svg viewBox="0 0 24 24"><path fill="#000" d="$d"/></svg>';

const _folderPath = 'M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.6 2.2h8.2A2.5 2.5 0 0 1 21 9.7v7.8'
    'a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5v-10Z';

/// ui.html 里的图标是内联 SVG path，这里原样搬过来，保证视觉一致。
final Map<String, String> _svg = {
  'brand': _s('<path d="$_folderPath"/><path d="M12 11v4.5M9.8 13.2 12 15.5l2.2-2.3"/>', w: 1.6),
  'folder': _f(_folderPath),
  'folderLine': _s('<path d="$_folderPath"/>'),
  'image': _s('<rect x="3.5" y="4.5" width="17" height="15" rx="2.4"/>'
      '<circle cx="8.6" cy="9.6" r="1.5"/>'
      '<path d="m4 17 4.6-4.4a1.6 1.6 0 0 1 2.2 0L15 16.4l1.6-1.4a1.6 1.6 0 0 1 2.1 0L20.5 17"/>'),
  'video': _s('<rect x="3" y="5.5" width="13" height="13" rx="2.4"/><path d="m16 11 5-3v8l-5-3v-2Z"/>'),
  'zip': _s('<path d="M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5H5'
      'A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5Z"/>'
      '<path d="M11 4.5v2.2M13 6.7v2.2M11 8.9v2.2M13 11.1v2.2"/>'
      '<rect x="10.4" y="14.2" width="3.2" height="3.6" rx="1"/>'),
  'lock': _s('<rect x="4" y="10" width="16" height="10" rx="2.4"/><path d="M8 10V7.5a4 4 0 0 1 8 0V10"/>'),
  'lockBold': _s('<rect x="4" y="10" width="16" height="10" rx="2.4"/><path d="M8 10V7.5a4 4 0 0 1 8 0V10"/>', w: 2),
  'eye': _s('<path d="M2 12s3.6-6 10-6 10 6 10 6-3.6 6-10 6-10-6-10-6Z"/><circle cx="12" cy="12" r="2.8"/>'),
  'eyeOff': _s('<path d="M4 4.5l16 15.5"/>'
      '<path d="M10.2 6.2A9.8 9.8 0 0 1 12 6c6.4 0 10 6 10 6a17.6 17.6 0 0 1-3.4 4.1"/>'
      '<path d="M6.6 8.4A16.9 16.9 0 0 0 2 12s3.6 6 10 6a9.9 9.9 0 0 0 3.8-.7"/>'
      '<path d="M9.9 10.2a2.8 2.8 0 0 0 3.9 3.9"/>'),
  'chevron': _s('<path d="m9 5 7 7-7 7"/>', w: 2),
  'search': _s('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.6-3.6"/>', w: 1.8),
  'gear': _s('<circle cx="12" cy="12" r="3"/>'
      '<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
      w: 1.7),
  'download': _s('<path d="M12 4v11"/><path d="m7.5 11 4.5 4.5 4.5-4.5"/>'
      '<path d="M4.5 15.5V18a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5v-2.5"/>', w: 1.8),
  'upload': _s('<path d="M12 16V4"/><path d="m7.5 8.5 4.5-4.5 4.5 4.5"/>'
      '<path d="M4.5 15v3.5A1.5 1.5 0 0 0 6 20h12a1.5 1.5 0 0 0 1.5-1.5V15"/>', w: 1.8),
  'cloudUp': _s('<path d="M17 17.5a4 4 0 0 0 .4-8 5.6 5.6 0 0 0-10.8-1.3A4.2 4.2 0 0 0 7 17.5"/>'
      '<path d="M12 12v7"/><path d="m9.2 14.8 2.8-2.8 2.8 2.8"/>', w: 1.8),
  'shield': _s('<path d="M12 3l7.5 3v6c0 4.6-3.1 8-7.5 9-4.4-1-7.5-4.4-7.5-9V6L12 3Z"/>', w: 1.8),
  'shieldCheck': _s('<path d="M12 3l7.5 3v6c0 4.6-3.1 8-7.5 9-4.4-1-7.5-4.4-7.5-9V6L12 3Z"/>'
      '<path d="m9 12 2 2 4-4"/>', w: 1.8),
  'globe': _s('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.7 2.5 15.3 0 18M12 3c-2.5 2.7-2.5 15.3 0 18"/>'),
  'user': _s('<circle cx="12" cy="8" r="3.6"/><path d="M5 20c0-3.6 3.1-5.6 7-5.6s7 2 7 5.6"/>'),
  'list': _s('<path d="M4 7h16M4 12h16M4 17h10"/>', w: 1.8),
  'dot': _s('<circle cx="12" cy="12" r="3"/>', w: 2.4),
  'check': _s('<path d="m5 12.5 4.5 4.5L19 7.5"/>', w: 2.2),
  'plus': _s('<path d="M12 5v14M5 12h14"/>', w: 1.9),
  'close': _s('<path d="M6 6l12 12M18 6 6 18"/>', w: 1.9),
  'back': _s('<path d="m14 6-6 6 6 6"/>', w: 2),
  'trash': _s('<path d="M4.5 7h15"/><path d="M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7"/>'
      '<path d="M6.5 7l.8 11.5A1.5 1.5 0 0 0 8.8 20h6.4a1.5 1.5 0 0 0 1.5-1.5L17.5 7"/>'),
  'refresh': _s('<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20.5 4v4.5H16"/>'),
  'pause': _s('<path d="M9.5 5.5v13M14.5 5.5v13"/>', w: 2),
  'play': _f('M8 5.4v13.2c0 .8.9 1.3 1.6.9l10.2-6.6a1 1 0 0 0 0-1.7L9.6 4.5A1 1 0 0 0 8 5.4Z'),
  'forward10': _s('<path d="M12 7a5 5 0 1 1-2.2 9.5"/><path d="M9.8 7H12"/>'
      '<path d="M15.5 8.5 18 6l-2.5-2.5"/><path d="M13 16h5"/>', w: 1.7),
  'rewind10': _s('<path d="M12 7a5 5 0 1 0 2.2 9.5"/><path d="M14.2 7H12"/>'
      '<path d="M8.5 8.5 6 6l2.5-2.5"/><path d="M11 16H6"/>', w: 1.7),
  'wifi': _s('<path d="M2.5 9a14 14 0 0 1 19 0"/><path d="M6 12.5a9 9 0 0 1 12 0"/>'
      '<path d="M9.5 16a4.2 4.2 0 0 1 5 0"/><circle cx="12" cy="19.2" r="1"/>'),
  'folderOpen': _s('<path d="M3 8.5A2.5 2.5 0 0 1 5.5 6h3.2l1.6 2.2h8.2A2.5 2.5 0 0 1 21 10.7v6.8'
      'a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5Z"/>'),
  'audio': _s('<path d="M9 17.5V5.5l11-2v11"/><circle cx="6.2" cy="17.6" r="2.8"/><circle cx="17.2" cy="15.6" r="2.8"/>', w: 1.7),
  'more': _s('<circle cx="12" cy="5" r="1.1"/><circle cx="12" cy="12" r="1.1"/><circle cx="12" cy="19" r="1.1"/>', w: 2.2),
  'shuffle': _s('<path d="M16 3.5h4.5V8"/><path d="M4 20 20.5 3.5"/><path d="M20.5 16v4.5H16"/>'
      '<path d="m15 15 5.5 5.5"/><path d="M4 4l5 5"/>', w: 1.7),
  'repeat': _s('<path d="m17 2.5 3.5 3.5L17 9.5"/><path d="M3.5 11V9.5a3.5 3.5 0 0 1 3.5-3.5h13.5"/>'
      '<path d="m7 21.5-3.5-3.5L7 14.5"/><path d="M20.5 13v1.5a3.5 3.5 0 0 1-3.5 3.5H3.5"/>', w: 1.7),
  'sort': _s('<path d="M4 6.5h11M4 12h8M4 17.5h5"/><path d="M18 8.5v10"/><path d="m15 15.5 3 3.5 3-3.5"/>', w: 1.7),
  'queue': _s('<path d="M4 6.5h12M4 12h12M4 17.5h8"/><path d="M18 13.5v6"/><path d="m15.8 17 2.2 2.5 2.2-2.5"/>', w: 1.7),
  'drag': _s('<path d="M5 8h14M5 12h14M5 16h14"/>', w: 1.9),
  'palette': _s('<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10c1.1 0 2-.9 2-2 0-.51-.19-.99-.52-1.35-.31-.34-.5-.79-.5-1.3 0-1.1.9-2 2-2h2.34C20.4 15.35 22 13.07 22 10.5 22 5.81 17.52 2 12 2z"/>'
      '<circle cx="6.5" cy="12" r="1.1"/><circle cx="8.5" cy="7.5" r="1.1"/><circle cx="14.5" cy="7.5" r="1.1"/><circle cx="17" cy="11" r="1.1"/>', w: 1.6),
  'doc': _s('<path d="M14 3.5H7.5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8z"/>'
      '<path d="M14 3.5V8h4.5"/><path d="M9 13h6M9 16.5h6"/>', w: 1.7),
  'fullscreen': _s('<path d="M4 9V4h5"/><path d="M20 9V4h-5"/><path d="M4 15v5h5"/><path d="M20 15v5h-5"/>', w: 1.9),
  'exitFullscreen': _s('<path d="M9 4v5H4"/><path d="M15 4v5h5"/><path d="M9 20v-5H4"/><path d="M15 20v-5h5"/>', w: 1.9),
};

/// 与 ui.html 同源的单色图标。
class VIcon extends StatelessWidget {
  const VIcon(this.name, {this.size = 19, this.color, super.key});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final src = _svg[name];
    assert(src != null, 'unknown icon: $name');
    return SvgPicture.string(
      src ?? '',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color ?? VaultColors.muted, BlendMode.srcIn),
    );
  }
}
