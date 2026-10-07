import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'icons.dart';
import 'theme.dart';

/// 设置页卡片：`margin:0 16 / background #15171B / border line / radius 14`。
class VaultCard extends StatelessWidget {
  const VaultCard({
    required this.children,
    this.padding = EdgeInsets.zero,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.borderColor,
    this.background,
    super.key,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? borderColor;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: background ?? VaultColors.field,
        borderRadius: BorderRadius.circular(VaultRadius.card),
        border: Border.all(color: borderColor ?? VaultColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: VaultColors.dim,
            letterSpacing: 0.7,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
}

/// 36x36 的图标按钮，对应 `.icon-btn`。
class IconBtn extends StatelessWidget {
  const IconBtn({
    required this.icon,
    this.onTap,
    this.color,
    this.size = 19,
    this.tooltip,
    super.key,
  });

  final String icon;
  final VoidCallback? onTap;
  final Color? color;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(child: VIcon(icon, size: size, color: color ?? VaultColors.muted)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// `.btn-primary`：180° 渐变 + 主色投影。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    this.onPressed,
    this.loading = false,
    this.compact = false,
    this.color,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final bool compact;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(compact ? 12 : VaultRadius.button),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color ?? VaultColors.accent, (color == null ? VaultColors.accentEnd : color!.withValues(alpha: 0.82))],
          ),
          boxShadow: [
            BoxShadow(
              color: (color ?? VaultColors.accent).withValues(alpha: 0.5),
              blurRadius: 26,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(compact ? 12 : VaultRadius.button),
            onTap: enabled ? onPressed : null,
            child: Container(
              height: compact ? 40 : 50,
              padding: EdgeInsets.symmetric(horizontal: compact ? 26 : 16),
              alignment: Alignment.center,
              child: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        fontSize: compact ? 14 : 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.4,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({required this.label, this.onPressed, this.color, super.key});

  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VaultColors.line2),
        ),
        child: Text(label, style: TextStyle(fontSize: 13.5, color: color ?? VaultColors.muted)),
      ),
    );
  }
}

/// 连接页 / 设置页的输入框，对应 `.field`。
class VaultTextField extends StatelessWidget {
  const VaultTextField({
    required this.label,
    required this.icon,
    required this.controller,
    this.obscure = false,
    this.placeholder,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onSubmitted,
    this.enabled = true,
    this.showClear = false,
    this.onCleared,
    super.key,
  });

  final String label;
  final String icon;
  final TextEditingController controller;
  final bool obscure;
  final String? placeholder;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;

  /// 有内容时框尾显示一个清空按钮；点它清空这行并回调 [onCleared]。
  final bool showClear;
  final VoidCallback? onCleared;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: VaultColors.dim, letterSpacing: 0.25),
          ),
        ),
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: VaultColors.field,
            borderRadius: BorderRadius.circular(VaultRadius.field),
            border: Border.all(color: VaultColors.line),
          ),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, child) {
              final showX = showClear && value.text.isNotEmpty;
              return Row(
                children: [
                  VIcon(icon, size: 15, color: VaultColors.dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      obscureText: obscure,
                      enabled: enabled,
                      keyboardType: keyboardType,
                      autofillHints: autofillHints,
                      textInputAction: textInputAction ?? (onSubmitted == null ? TextInputAction.done : TextInputAction.next),
                      onSubmitted: onSubmitted,
                      style: TextStyle(fontSize: 13.5, color: VaultColors.text),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: placeholder,
                        hintStyle: TextStyle(fontSize: 13.5, color: VaultColors.subtle),
                      ),
                    ),
                  ),
                  if (showX)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        controller.clear();
                        onCleared?.call();
                      },
                      child: Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: VIcon('close', size: 15, color: VaultColors.subtle),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 15),
      ],
    );
  }
}

/// 连接页的开关行（带边框卡片），对应 `.toggle-row`。
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: VaultColors.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VaultColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: VaultColors.text)),
                const SizedBox(height: 3),
                Text(subtitle, style: TextStyle(fontSize: 11, color: VaultColors.dim, height: 1.5)),
              ],
            ),
          ),
          VaultSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 40x24 的 iOS 风格开关，配色取自 ui.html 的 `.switch`。
class VaultSwitch extends StatelessWidget {
  const VaultSwitch({required this.value, required this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 40,
        height: 24,
        decoration: BoxDecoration(
          color: value ? const Color(0x805E7CE2) : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.all(2.5),
            child: Container(
              width: 19,
              height: 19,
              decoration: BoxDecoration(
                color: value ? Colors.white : VaultColors.muted,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.hm-badge`：隐藏模式的小徽章。
class HmBadge extends StatelessWidget {
  const HmBadge({required this.text, this.icon = 'dot', this.dense = false, super.key});

  final String text;
  final String icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 7, vertical: 3),
      decoration: BoxDecoration(
        color: VaultColors.purple.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VaultColors.purple.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          VIcon(icon, size: dense ? 9 : 10, color: VaultColors.purpleSoft),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontSize: dense ? 9 : 9.5, color: VaultColors.purpleSoft, letterSpacing: 0.4),
          ),
        ],
      ),
    );
  }
}

/// 底部三 Tab：高度 72，其中底部 18 留给 home 指示条。
class VaultBottomBar extends StatelessWidget {
  const VaultBottomBar({required this.index, required this.onSelect, super.key});

  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    (label: '浏览', activeIcon: 'folder', idleIcon: 'folderLine'),
    (label: '上传', activeIcon: 'upload', idleIcon: 'upload'),
    (label: '设置', activeIcon: 'gear', idleIcon: 'gear'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Color(0xF0121417),
        border: Border(top: BorderSide(color: VaultColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Row(
              children: [
                for (var i = 0; i < _items.length; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onSelect(i);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          VIcon(
                            i == index ? _items[i].activeIcon : _items[i].idleIcon,
                            size: 25,
                            color: i == index ? VaultColors.accent : VaultColors.dim,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _items[i].label,
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 0.3,
                              fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
                              color: i == index ? VaultColors.accent : VaultColors.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一的浅色 snackbar，用来报「人话」错误。
void showVaultToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: error ? const Color(0xFF2A1E21) : VaultColors.surface2,
        duration: Duration(milliseconds: error ? 3200 : 2000),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(
          children: [
            VIcon(error ? 'shield' : 'check', size: 15, color: error ? VaultColors.danger : VaultColors.green),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: TextStyle(fontSize: 12.5, color: error ? VaultColors.dangerSoft : VaultColors.text, height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
}

/// 顶部标题栏，`.appbar`：高 52。
class VaultAppBar extends StatelessWidget implements PreferredSizeWidget {
  const VaultAppBar({
    required this.title,
    this.actions = const [],
    this.leading,
    this.subtitle,
    super.key,
  });

  final String title;
  final List<Widget> actions;
  final Widget? leading;
  final String? subtitle;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          if (leading != null)
            Padding(padding: const EdgeInsets.only(left: 4), child: leading)
          else
            const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: VaultColors.textBright)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(subtitle!, style: TextStyle(fontSize: 10.5, color: VaultColors.dim)),
                  ),
              ],
            ),
          ),
          ...actions,
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

/// 空态 / 错误态占位。
class VaultEmpty extends StatelessWidget {
  const VaultEmpty({required this.icon, required this.title, this.action, super.key});

  final String icon;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            VIcon(icon, size: 30, color: VaultColors.chevron),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: VaultColors.muted)),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}
