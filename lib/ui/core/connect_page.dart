import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/core/windows_autostart.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'connections_page.dart';
import 'design.dart';
import 'format.dart';
import 'home_stats.dart';
import 'profile_options.dart';
import 'profiles_page.dart';
import 'tools_pages.dart';

/// 首页：连接状态和最常用的开关，打开就能看完
class HomePage extends StatelessWidget {
  static const double _twoColumns = 820;

  final Configuration configuration;

  /// 跳到其他入口，下标见 ShellTab
  final ValueChanged<int>? onOpenTab;

  const HomePage({super.key, required this.configuration, this.onOpenTab});

  void _open(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: manager,
          builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
            final connection = [
              _ConnectionCard(manager, onOpenNodes: () => onOpenTab?.call(1)),
              const SizedBox(height: AppTheme.gap),
              _profile(context, manager),
            ];
            final controls = [
              _switches(context, manager),
              if (manager.isRunning) ...[
                const SizedBox(height: AppTheme.gap),
                HomeStats(manager, configuration),
              ],
              const SizedBox(height: AppTheme.gap),
              _shortcuts(context, manager),
            ];
            final banner = [
              if (manager.needsReload) ...[
                Panel(children: [
                  InfoRow(
                    icon: Icons.refresh,
                    iconColor: Tone.warn,
                    title: '配置已更新',
                    subtitle: '重新加载后生效，现有连接会断开',
                    onTap: manager.reloadConfig,
                  ),
                ]),
                const SizedBox(height: AppTheme.gap),
              ],
            ];
            if (constraints.maxWidth >= _twoColumns) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(children: [
                  ...banner,
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(children: connection)),
                    const SizedBox(width: AppTheme.gap),
                    Expanded(child: Column(children: controls)),
                  ]),
                ]),
              );
            }
            return ContentColumn(children: [
              const SizedBox(height: 10),
              ...banner,
              ...connection,
              const SizedBox(height: AppTheme.gap),
              ...controls,
            ]);
          }),
        ),
      ),
    );
  }

  Widget _profile(BuildContext context, CoreManager manager) {
    final profile = manager.activeProfile;
    if (profile == null) {
      return Panel(children: [
        InfoRow(
          icon: Icons.add,
          title: '添加配置',
          subtitle: '粘贴订阅链接或配置内容',
          onTap: () => _open(context, const AddProfilePage()),
        ),
      ]);
    }
    return Panel(children: [
      InkWell(
        onTap: () => _open(context, const ProfilesPage()),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(children: [
            Expanded(child: ProfileSummary(profile)),
            if (profile.isSubscription) _UpdateButton(manager, profile),
          ]),
        ),
      ),
    ]);
  }

  Widget _switches(BuildContext context, CoreManager manager) {
    final settings = manager.settings;
    final count = HostFilter.whitelist.list.length;
    return Panel(children: [
      InfoRow(
        icon: Icons.lock_open,
        iconColor: Tone.good,
        title: 'HTTPS 解密',
        subtitle: count == 0 ? '还没有要解密的域名' : '$count 个域名',
        chevron: false,
        onTap: () => onOpenTab?.call(3),
        trailing: Switch(value: settings.capture, onChanged: manager.setCapture),
      ),
      if (Platform.isWindows) ...[
        SwitchRow(
          icon: Icons.settings_ethernet,
          iconColor: Tone.teal,
          title: '系统代理',
          subtitle: settings.tun ? 'TUN 开启时不需要' : 'HTTP 和 SOCKS 端口 ${settings.mixedPort}',
          value: settings.systemProxy && !settings.tun,
          onChanged: settings.tun ? null : manager.setSystemProxy,
        ),
        SwitchRow(
          icon: Icons.vpn_lock_outlined,
          iconColor: Tone.violet,
          title: 'TUN 模式',
          subtitle: '接管所有程序的流量，需要管理员权限',
          value: settings.tun,
          onChanged: (value) => _setTun(context, manager, value),
        ),
      ],
      InfoRow(
        icon: Icons.alt_route,
        iconColor: Theme.of(context).colorScheme.primary,
        title: '分流',
        subtitle: '${settings.groups.where((e) => e.enabled).length} 组规则',
        onTap: () => onOpenTab?.call(2),
      ),
    ]);
  }

  Future<void> _setTun(BuildContext context, CoreManager manager, bool value) async {
    if (value && !WindowsAdmin.isAdmin()) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('TUN 模式'),
          content: const Text('TUN 模式需要管理员权限，请以管理员身份重新启动 RsProxy。'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
        ),
      );
      return;
    }
    manager.settings.tun = value;
    await manager.applySettings();
  }

  Widget _shortcuts(BuildContext context, CoreManager manager) {
    final running = manager.isRunning;
    return Panel(padding: const EdgeInsets.symmetric(vertical: 6), children: [
      Row(children: [
        _Shortcut(Icons.add_circle_outline, '添加配置', () => _open(context, const AddProfilePage())),
        _Shortcut(Icons.lan_outlined, '连接',
            running ? () => _open(context, ConnectionsPage(configuration: configuration)) : null),
        _Shortcut(Icons.health_and_safety_outlined, '网络检测', () => _open(context, const NetworkCheckPage())),
        _Shortcut(Icons.speed, '测速', running ? () => _open(context, const SpeedTestPage()) : null),
      ]),
    ]);
  }
}

class _Shortcut extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _Shortcut(this.icon, this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final color = onTap == null ? palette.faint : palette.ink;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 21, color: onTap == null ? palette.faint : Theme.of(context).colorScheme.primary),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ]),
        ),
      ),
    );
  }
}

/// 首页最上面的大卡片。连上之后变成彩色，一眼能看出状态
class _ConnectionCard extends StatelessWidget {
  final CoreManager manager;
  final VoidCallback onOpenNodes;

  const _ConnectionCard(this.manager, {required this.onOpenNodes});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final state = manager.state;
    final running = state == CoreState.running;
    final ink = running ? Colors.white : palette.ink;
    final soft = running ? Colors.white.withValues(alpha: 0.78) : palette.muted;
    final selected = manager.selectedNode;
    final actual = manager.activeNode;
    final delay = manager.delays[actual ?? selected];
    final label = switch (state) {
      CoreState.stopped => '未连接',
      CoreState.starting => '正在连接',
      CoreState.running => '已连接',
      CoreState.stopping => '正在断开',
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: running ? null : palette.panel,
        gradient: running
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [accent, Color.lerp(accent, const Color(0xFF3A2FB8), 0.55)!],
              )
            : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: running ? Colors.white : palette.faint),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 13, color: soft)),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onOpenNodes,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nodeLabel(selected),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: ink, height: 1.25)),
                const SizedBox(height: 4),
                Text(
                  [
                    if (actual != null) actual,
                    if (delay != null) '$delay ms',
                    if (actual == null) manager.activeProfile == null ? '没有配置时所有流量直连' : '${manager.nodes.length} 个节点',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: soft),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          _PowerButton(manager),
        ]),
        const SizedBox(height: 16),
        PillSwitch<RouteMode>(
          onColor: running,
          options: const {RouteMode.rule: '规则', RouteMode.global: '全局'},
          value: manager.settings.mode,
          onChanged: manager.setMode,
        ),
        if (manager.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SelectableText(manager.lastError!, style: TextStyle(color: running ? Colors.white : Tone.bad, fontSize: 12)),
          ),
      ]),
    );
  }
}

class _PowerButton extends StatelessWidget {
  final CoreManager manager;

  const _PowerButton(this.manager);

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final state = manager.state;
    final running = state == CoreState.running;
    final busy = state == CoreState.starting || state == CoreState.stopping;
    return Semantics(
      button: true,
      label: running ? '断开' : '连接',
      child: Material(
        color: running ? Colors.white.withValues(alpha: 0.2) : accent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: busy ? null : (running ? manager.disconnect : manager.connect),
          child: SizedBox(
            width: 60,
            height: 60,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(19),
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : const Icon(Icons.power_settings_new, size: 28, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 更新订阅，刷新用量和到期时间也靠它：面板没有单独查用量的接口
class _UpdateButton extends StatefulWidget {
  final CoreManager manager;
  final Profile profile;

  const _UpdateButton(this.manager, this.profile);

  @override
  State<_UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<_UpdateButton> {
  bool _updating = false;

  Future<void> _update() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _updating = true);
    try {
      await widget.manager.updateProfile(widget.profile);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeProfileError(e))));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_updating) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(tooltip: '更新', icon: const Icon(Icons.refresh, size: 20), onPressed: _update);
  }
}

/// 配置的名称、用量和到期时间
class ProfileSummary extends StatelessWidget {
  final Profile profile;

  const ProfileSummary(this.profile, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = profile.info;
    final hasUsage = info != null && info.total > 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(profile.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (hasUsage) ...[
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (info.used / info.total).clamp(0, 1).toDouble(),
            minHeight: 5,
            backgroundColor: Palette.of(context).sunken,
          ),
        ),
        const SizedBox(height: 8),
        Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
          TextSpan(
            text: '已用 ${formatBytes(info.used)} / ${formatBytes(info.total)}',
            style: info.used >= info.total ? TextStyle(color: theme.colorScheme.error) : null,
          ),
          if (info.expire != null)
            TextSpan(
              text: ' · ${formatDate(info.expire!)} 到期',
              style: info.expire!.isBefore(DateTime.now().add(const Duration(days: 7)))
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
            ),
        ])),
      ],
    ]);
  }
}

/// 节点 tag 的显示名
String nodeLabel(String? tag) => switch (tag) {
      null || 'auto' => '自动选择',
      'select' => '当前选择',
      'direct' => '直连',
      _ when tag.startsWith(RuleTarget.groupPrefix) => '自动选择 · ${tag.substring(RuleTarget.groupPrefix.length)}',
      _ => tag,
    };

Color delayColor(BuildContext context, int delay) {
  if (delay < 200) return Tone.good;
  if (delay < 500) return Tone.warn;
  return Tone.bad;
}
