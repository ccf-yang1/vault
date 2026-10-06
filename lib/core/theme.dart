import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ui.html 中 `:root` 的颜色变量，逐个对应，不要在此之外新增色值。
abstract final class VaultColors {
  static const bg = Color(0xFF0E0F11);
  static const surface = Color(0xFF16181C);
  static const surface2 = Color(0xFF1E2126);
  static const field = Color(0xFF15171B);

  /// rgba(255,255,255,.07) / .13
  static const line = Color(0x12FFFFFF);
  static const line2 = Color(0x21FFFFFF);

  static const text = Color(0xFFE7E8EA);
  static const muted = Color(0xFF8A9099);
  static const dim = Color(0xFF5C626A);

  static const accent = Color(0xFF5E7CE2);
  static const accentEnd = Color(0xFF4B63C6);
  static const accentText = Color(0xFF9EB0F2);
  static const purple = Color(0xFFA98CD8);
  static const purpleSoft = Color(0xFFB39CE0);
  static const purpleDeep = Color(0xFF8E7CC3);
  static const green = Color(0xFF5FA98A);
  static const orange = Color(0xFFD8A05F);
  static const blue = Color(0xFF6E8EE8);
}

abstract final class VaultRadius {
  static const card = 14.0;
  static const field = 12.0;
  static const noteField = 13.0;
  static const tile = 11.0;
  static const button = 14.0;
}

ThemeData buildVaultTheme() {
  const scheme = ColorScheme.dark(
    primary: VaultColors.accent,
    onPrimary: Colors.white,
    surface: VaultColors.surface,
    onSurface: VaultColors.text,
    error: Color(0xFFE0736A),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: VaultColors.bg,
    canvasColor: VaultColors.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: VaultColors.line,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: VaultColors.accent,
      selectionColor: Color(0x405E7CE2),
      selectionHandleColor: VaultColors.accent,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: VaultColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Color(0xFFEDEEF0),
        letterSpacing: -0.1,
      ),
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFFF0F1F3)),
      bodyMedium: TextStyle(fontSize: 13.5, color: VaultColors.text),
      bodySmall: TextStyle(fontSize: 12.5, color: VaultColors.muted),
    ),
  );
}

/// 深色界面 + 浅色状态栏图标，所有页面共用。
class VaultAnnotatedRegion extends StatelessWidget {
  const VaultAnnotatedRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: child,
    );
  }
}
