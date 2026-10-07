import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// 主题模式 → 调色板。
VaultPalette paletteFor(VaultThemeMode mode) => switch (mode) {
      VaultThemeMode.dark => VaultPalette.dark,
      VaultThemeMode.light => VaultPalette.light,
      VaultThemeMode.deepBlue => VaultPalette.deepBlue,
    };

/// 三套调色板：深色（默认，逐字节沿用 ui.html 的既有取值）、浅色、深蓝。
///
/// 深蓝蓝本取自音频播放页那套 navy 极简风。切主题时把选中调色板塞进 [_active]，
/// 下面 [VaultColors] 的同名 getter 就实时返回对应色值——所以全站用的语义色
/// 一处换、处处换，而各页面里那些「不随主题走的沉浸色」（如播放器 navy 背景）
/// 仍写死不动。
@immutable
class VaultPalette {
  const VaultPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.field,
    required this.line,
    required this.line2,
    required this.text,
    required this.textBright,
    required this.muted,
    required this.dim,
    required this.accent,
    required this.accentEnd,
    required this.accentText,
    required this.purple,
    required this.purpleSoft,
    required this.purpleDeep,
    required this.green,
    required this.orange,
    required this.blue,
    required this.danger,
    required this.dangerSoft,
    required this.dangerBg,
    required this.chevron,
    required this.subtle,
    required this.fieldFill,
    required this.segActive,
    required this.outline,
  });

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color field;
  final Color line;
  final Color line2;
  final Color text;
  final Color textBright;
  final Color muted;
  final Color dim;
  final Color accent;
  final Color accentEnd;
  final Color accentText;
  final Color purple;
  final Color purpleSoft;
  final Color purpleDeep;
  final Color green;
  final Color orange;
  final Color blue;
  final Color danger;
  final Color dangerSoft;
  final Color dangerBg;
  final Color chevron;
  final Color subtle;
  final Color fieldFill;
  final Color segActive;
  final Color outline;

  /// 默认深色：与旧 `VaultColors` 常量逐值相同，深色模式零回归。
  static const dark = VaultPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF0E0F11),
    surface: Color(0xFF16181C),
    surface2: Color(0xFF1E2126),
    field: Color(0xFF15171B),
    line: Color(0x12FFFFFF),
    line2: Color(0x21FFFFFF),
    text: Color(0xFFE7E8EA),
    textBright: Color(0xFFF0F1F3),
    muted: Color(0xFF8A9099),
    dim: Color(0xFF5C626A),
    accent: Color(0xFF5E7CE2),
    accentEnd: Color(0xFF4B63C6),
    accentText: Color(0xFF9EB0F2),
    purple: Color(0xFFA98CD8),
    purpleSoft: Color(0xFFB39CE0),
    purpleDeep: Color(0xFF8E7CC3),
    green: Color(0xFF5FA98A),
    orange: Color(0xFFD8A05F),
    blue: Color(0xFF6E8EE8),
    danger: Color(0xFFE0736A),
    dangerSoft: Color(0xFFF0C6C2),
    dangerBg: Color(0xFF3A2325),
    chevron: Color(0xFF3A3F46),
    subtle: Color(0xFF4A5058),
    fieldFill: Color(0xFF15171B),
    segActive: Color(0xFF252932),
    outline: Color(0xFF454B53),
  );

  /// 浅色：白底、深字，强调色压深一档保证对比度。
  static const light = VaultPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEDEFF2),
    field: Color(0xFFF1F3F6),
    line: Color(0x14000000),
    line2: Color(0x22000000),
    text: Color(0xFF1E2228),
    textBright: Color(0xFF12151A),
    muted: Color(0xFF5B626C),
    dim: Color(0xFF9099A3),
    accent: Color(0xFF4B63C6),
    accentEnd: Color(0xFF3C52B0),
    accentText: Color(0xFF3B52B8),
    purple: Color(0xFF7E5FB0),
    purpleSoft: Color(0xFF8E7CC3),
    purpleDeep: Color(0xFF6C4FA0),
    green: Color(0xFF3E8567),
    orange: Color(0xFFB67B2E),
    blue: Color(0xFF3F63C9),
    danger: Color(0xFFC6483F),
    dangerSoft: Color(0xFFE7A9A3),
    dangerBg: Color(0xFFF6DDD9),
    chevron: Color(0xFFB4B9C1),
    subtle: Color(0xFF9AA0A8),
    fieldFill: Color(0xFFEDEFF2),
    segActive: Color(0xFFE3E6EB),
    outline: Color(0xFFCBD0D7),
  );

  /// 深蓝：navy 底 + 柔蓝强调，取音频页那套灰青/柔蓝观感铺到全站。
  static const deepBlue = VaultPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF0C1620),
    surface: Color(0xFF10233A),
    surface2: Color(0xFF17304B),
    field: Color(0xFF0E1E30),
    line: Color(0x1A7FA6E0),
    line2: Color(0x2E7FA6E0),
    text: Color(0xFFDCE6F2),
    textBright: Color(0xFFF1F6FC),
    muted: Color(0xFF8296B4),
    dim: Color(0xFF5A6E88),
    accent: Color(0xFF5E7CE2),
    accentEnd: Color(0xFF4B63C6),
    accentText: Color(0xFF7FA6E0),
    purple: Color(0xFF9FB0C9),
    purpleSoft: Color(0xFFB0C2DC),
    purpleDeep: Color(0xFF7FA6E0),
    green: Color(0xFF5FA98A),
    orange: Color(0xFFD8A05F),
    blue: Color(0xFF6E8EE8),
    danger: Color(0xFFE0736A),
    dangerSoft: Color(0xFFE4A9A3),
    dangerBg: Color(0xFF2A2230),
    chevron: Color(0xFF3B4E66),
    subtle: Color(0xFF4A556B),
    fieldFill: Color(0xFF0E1E30),
    segActive: Color(0xFF17304B),
    outline: Color(0xFF2C425C),
  );
}

/// 当前生效调色板。App 根部在 build 前写入，随后所有 getter 读它。
VaultPalette _active = VaultPalette.dark;

/// 设置某套调色板为当前（切主题时调用）。
void setActivePalette(VaultPalette palette) => _active = palette;

/// 读取当前调色板（给 [buildVaultTheme] 用）。
VaultPalette get activePalette => _active;

/// 全站语义色入口。历史上是 `static const`，现改为读取 [_active] 的 getter，
/// 从而随主题实时变化；调用点因此不能再包在 `const` 里。
abstract final class VaultColors {
  static Brightness get brightness => _active.brightness;
  static Color get bg => _active.bg;
  static Color get surface => _active.surface;
  static Color get surface2 => _active.surface2;
  static Color get field => _active.field;
  static Color get line => _active.line;
  static Color get line2 => _active.line2;
  static Color get text => _active.text;
  static Color get textBright => _active.textBright;
  static Color get muted => _active.muted;
  static Color get dim => _active.dim;
  static Color get accent => _active.accent;
  static Color get accentEnd => _active.accentEnd;
  static Color get accentText => _active.accentText;
  static Color get purple => _active.purple;
  static Color get purpleSoft => _active.purpleSoft;
  static Color get purpleDeep => _active.purpleDeep;
  static Color get green => _active.green;
  static Color get orange => _active.orange;
  static Color get blue => _active.blue;
  static Color get danger => _active.danger;
  static Color get dangerSoft => _active.dangerSoft;
  static Color get dangerBg => _active.dangerBg;
  static Color get chevron => _active.chevron;
  static Color get subtle => _active.subtle;
  static Color get fieldFill => _active.fieldFill;
  static Color get segActive => _active.segActive;
  static Color get outline => _active.outline;
}

/// ui.html 的圆角常量，与颜色无关，保持 const。
abstract final class VaultRadius {
  static const card = 14.0;
  static const field = 12.0;
  static const noteField = 13.0;
  static const tile = 11.0;
  static const button = 14.0;
}

ThemeData buildVaultTheme(VaultPalette pal) {
  final scheme = ColorScheme.fromSeed(seedColor: pal.accent, brightness: pal.brightness).copyWith(
    primary: pal.accent,
    onPrimary: Colors.white,
    surface: pal.surface,
    onSurface: pal.text,
    error: pal.danger,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: pal.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: pal.bg,
    canvasColor: pal.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: pal.line,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: pal.accent,
      selectionColor: pal.accent.withValues(alpha: 0.25),
      selectionHandleColor: pal.accent,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: pal.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: pal.textBright,
        letterSpacing: -0.1,
      ),
    ),
    textTheme: TextTheme(
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: pal.textBright),
      bodyMedium: TextStyle(fontSize: 13.5, color: pal.text),
      bodySmall: TextStyle(fontSize: 12.5, color: pal.muted),
    ),
  );
}

/// 深色界面配浅色状态栏图标，浅色界面配深色图标，所有页面共用。
class VaultAnnotatedRegion extends StatelessWidget {
  const VaultAnnotatedRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = _active.brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: _active.bg,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      child: child,
    );
  }
}
