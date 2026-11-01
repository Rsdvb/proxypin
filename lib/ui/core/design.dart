import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/chinese_font.dart';

/// 界面的颜色。除了强调色，所有页面都从这里取，深浅色才能一起对
class Palette {
  final Color canvas;
  final Color panel;
  final Color sunken;
  final Color line;
  final Color ink;
  final Color muted;
  final Color faint;

  const Palette._(this.canvas, this.panel, this.sunken, this.line, this.ink, this.muted, this.faint);

  static const Palette light = Palette._(
    Color(0xFFF4F5F7),
    Colors.white,
    Color(0xFFEEF0F3),
    Color(0xFFE4E6EA),
    Color(0xFF15181D),
    Color(0xFF666D78),
    Color(0xFF99A0AA),
  );

  static const Palette dark = Palette._(
    Color(0xFF0F1114),
    Color(0xFF181B20),
    Color(0xFF21252B),
    Color(0xFF2B3038),
    Color(0xFFECEEF1),
    Color(0xFF9CA3AE),
    Color(0xFF6D7481),
  );

  static Palette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 状态色
abstract final class Tone {
  static const Color good = Color(0xFF16A34A);
  static const Color warn = Color(0xFFE08600);
  static const Color bad = Color(0xFFE5484D);
  static const Color violet = Color(0xFF7C5CFC);
  static const Color teal = Color(0xFF0E9F9A);
}

abstract final class AppTheme {
  static const double radius = 14;
  static const double gap = 12;

  static ThemeData build(Brightness brightness, Color accent, {String? fontFamily}) {
    final dark = brightness == Brightness.dark;
    final palette = dark ? Palette.dark : Palette.light;
    final primary = dark ? Color.lerp(accent, Colors.white, 0.14)! : accent;

    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      surface: palette.panel,
      onSurface: palette.ink,
      onSurfaceVariant: palette.muted,
      outline: palette.line,
      outlineVariant: palette.line,
      surfaceContainerLowest: palette.canvas,
      surfaceContainerLow: palette.canvas,
      surfaceContainer: palette.panel,
      surfaceContainerHigh: palette.panel,
      surfaceContainerHighest: palette.sunken,
      error: Tone.bad,
      surfaceTint: Colors.transparent,
    );

    // 用下划线类型，标签才会落在底色里面，而不是骑在边上
    final field = UnderlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none);
    final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme, fontFamily: fontFamily);
    final text = base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontSize: 22, fontWeight: FontWeight.w700, color: palette.ink, height: 1.25),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: palette.ink, height: 1.3),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: palette.ink, height: 1.3),
      titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: palette.ink, height: 1.3),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 14.5, color: palette.ink, height: 1.35),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13.5, color: palette.ink, height: 1.35),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, color: palette.muted, height: 1.35),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600),
    );

    final theme = base.copyWith(
      scaffoldBackgroundColor: palette.canvas,
      canvasColor: palette.panel,
      dividerColor: palette.line,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: palette.canvas,
        foregroundColor: palette.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        toolbarHeight: 52,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: palette.ink, size: 22),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minTileHeight: 52,
        minVerticalPadding: 8,
        horizontalTitleGap: 12,
        minLeadingWidth: 22,
        iconColor: palette.muted,
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall,
      ),
      dividerTheme: DividerThemeData(color: palette.line, thickness: 0.6, space: 0.6),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.sunken,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: TextStyle(color: palette.faint, fontSize: 13.5),
        labelStyle: TextStyle(color: palette.muted, fontSize: 13.5),
        floatingLabelStyle: TextStyle(color: palette.muted, fontSize: 13),
        border: field,
        enabledBorder: field,
        disabledBorder: field,
        focusedBorder: field.copyWith(borderSide: BorderSide(color: primary, width: 1.4)),
        errorBorder: field.copyWith(borderSide: const BorderSide(color: Tone.bad)),
        focusedErrorBorder: field.copyWith(borderSide: const BorderSide(color: Tone.bad, width: 1.4)),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        thumbIcon: WidgetStateProperty.all(const Icon(null)),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled) ? palette.panel.withValues(alpha: 0.7) : Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          final on = states.contains(WidgetState.selected);
          if (states.contains(WidgetState.disabled)) {
            return (on ? primary : palette.sunken).withValues(alpha: 0.4);
          }
          return on ? primary : (dark ? palette.line : const Color(0xFFD6D9DF));
        }),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: palette.sunken,
        selectedColor: primary.withValues(alpha: 0.14),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: text.bodyMedium,
        showCheckmark: false,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          side: WidgetStateProperty.all(BorderSide(color: palette.line)),
          shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: text.labelLarge,
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.panel,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 560),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: palette.line)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        width: Platform.isWindows ? 420 : null,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: palette.ink, borderRadius: BorderRadius.circular(6)),
        textStyle: TextStyle(color: palette.panel, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 58,
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(size: 23, color: states.contains(WidgetState.selected) ? primary : palette.muted)),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11,
              color: states.contains(WidgetState.selected) ? primary : palette.muted,
              fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            )),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(5),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.all(palette.faint.withValues(alpha: 0.5)),
      ),
    );
    return Platform.isWindows ? theme.useSystemChineseFont() : theme;
  }
}

/// 卡片：页面上所有内容都分组放在它里面
class Panel extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  const Panel({super.key, required this.children, this.padding});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final rows = <Widget>[];
    for (final child in children) {
      // 输入框自己有底色，再画分隔线就乱了
      if (rows.isNotEmpty && child is! Padding && rows.last is! Padding) {
        rows.add(Divider(height: 0.6, indent: 16, color: palette.line));
      }
      rows.add(child);
    }
    return Material(
      color: palette.panel,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
    );
  }
}

/// 卡片上方的小标题，右边可以放一个操作
class SectionLabel extends StatelessWidget {
  final String text;
  final String? hint;
  final Widget? action;

  const SectionLabel(this.text, {super.key, this.hint, this.action});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(children: [
        Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: palette.muted)),
        if (hint != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(hint!,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: palette.faint)),
          ),
        ] else
          const Spacer(),
        if (action != null) action!,
      ]),
    );
  }
}

/// 带底色的图标
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const IconBadge(this.icon, {super.key, required this.color, this.size = 30});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(icon, size: size * 0.58, color: color),
    );
  }
}

/// 状态标签，比如分流的去向
class Tag extends StatelessWidget {
  final String text;
  final Color color;

  const Tag(this.text, {super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(6)),
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color, height: 1.3)),
    );
  }
}

/// 卡片里的一行
class InfoRow extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool chevron;
  final bool enabled;

  const InfoRow({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.chevron = true,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final tappable = onTap != null && enabled;
    return InkWell(
      onTap: tappable ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(children: [
              if (icon != null) ...[
                IconBadge(icon!, color: iconColor ?? Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, style: TextStyle(fontSize: 14.5, color: palette.ink, height: 1.3)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!, style: TextStyle(fontSize: 12, color: palette.muted, height: 1.35)),
                    ),
                ]),
              ),
              if (trailing != null) ...[const SizedBox(width: 10), trailing!],
              if (chevron && tappable) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 20, color: palette.faint),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// 带开关的一行
class SwitchRow extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SwitchRow({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InfoRow(
      icon: icon,
      iconColor: iconColor,
      title: title,
      subtitle: subtitle,
      chevron: false,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// 两三个选项里选一个
class PillSwitch<T> extends StatelessWidget {
  final Map<T, String> options;
  final T value;
  final ValueChanged<T>? onChanged;

  /// 放在彩色卡片上时用半透明白
  final bool onColor;

  const PillSwitch({super.key, required this.options, required this.value, this.onChanged, this.onColor = false});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final track = onColor ? Colors.white.withValues(alpha: 0.16) : palette.sunken;
    final thumb = onColor ? Colors.white : palette.panel;
    final selectedText = onColor ? Theme.of(context).colorScheme.primary : palette.ink;
    final idleText = onColor ? Colors.white.withValues(alpha: 0.85) : palette.muted;
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(11)),
      child: Row(children: [
        for (final option in options.entries)
          Expanded(
            child: Semantics(
              button: true,
              selected: option.key == value,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onChanged == null ? null : () => onChanged!(option.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: option.key == value ? thumb : Colors.transparent,
                    borderRadius: BorderRadius.circular(8.5),
                  ),
                  child: Text(option.value,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: option.key == value ? FontWeight.w600 : FontWeight.w400,
                        color: option.key == value ? selectedText : idleText,
                      )),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// 二级页面：标题栏 + 居中的内容列。Windows 窗口再宽，表单也不会被拉得很长
class AppPage extends StatelessWidget {
  static const double contentWidth = 680;

  final String title;
  final List<Widget> actions;
  final List<Widget> children;

  const AppPage({super.key, required this.title, this.actions = const [], required this.children});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: ContentColumn(children: children),
    );
  }
}

/// 设置类页面：连续的行放进同一张卡片，Divider 和 SectionLabel 把它们分开
class SettingsList extends StatelessWidget {
  final List<Widget> children;

  const SettingsList({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    var rows = <Widget>[];
    void close() {
      if (rows.isEmpty) return;
      blocks.add(Panel(children: rows));
      rows = [];
    }

    for (final child in children) {
      if (child is Divider) {
        close();
        blocks.add(const SizedBox(height: AppTheme.gap));
      } else if (child is SectionLabel) {
        close();
        blocks.add(child);
      } else {
        rows.add(child);
      }
    }
    close();
    return ContentColumn(children: [const SizedBox(height: 4), ...blocks]);
  }
}

/// 限宽、居中、可滚动的内容列
class ContentColumn extends StatelessWidget {
  final List<Widget> children;
  final double maxWidth;

  const ContentColumn({super.key, required this.children, this.maxWidth = AppPage.contentWidth});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: children),
      ),
    );
  }
}
