import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/app_identity.dart';
import 'package:url_launcher/url_launcher.dart';

import 'advanced_page.dart';
import 'backup_page.dart';
import 'connections_page.dart';
import 'design.dart';
import 'dns_page.dart';
import 'home_stats.dart';
import 'logs_pages.dart';
import 'network_pages.dart';
import 'profiles_page.dart';
import 'tools_pages.dart';
import 'tun_page.dart';

/// 设置：所有不常动的功能都在这一页，按用途分组
class SettingsPage extends StatelessWidget {
  final Configuration configuration;
  final AppConfiguration appConfiguration;

  const SettingsPage({super.key, required this.configuration, required this.appConfiguration});

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          Widget entry(IconData icon, Color color, String title, Widget page, {String? subtitle, bool needsConnection = false}) {
            final available = !needsConnection || manager.isRunning;
            return InfoRow(
              icon: icon,
              iconColor: color,
              title: title,
              subtitle: available ? subtitle : '连接后可用',
              enabled: available,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
            );
          }

          return ContentColumn(children: [
            const SectionLabel('网络'),
            Panel(children: [
              entry(Icons.dns_outlined, accent, 'DNS', const DnsPage()),
              entry(Icons.vpn_lock_outlined, Tone.violet, 'TUN', const TunPage()),
              entry(Icons.shield_outlined, Tone.teal, 'TLS 和多路复用', const NodeTuningPage()),
              entry(Icons.share_outlined, Tone.good, '网络共享', const NetworkSharePage()),
              entry(Icons.settings_ethernet, Tone.warn, '端口', const PortsPage()),
            ]),
            const SectionLabel('查看和诊断'),
            Panel(children: [
              entry(Icons.lan_outlined, accent, '连接', ConnectionsPage(configuration: configuration), needsConnection: true),
              entry(Icons.speed, Tone.teal, '测速', const SpeedTestPage(), needsConnection: true),
              entry(Icons.rule, Tone.violet, '规则检测', const RuleCheckPage(), needsConnection: true),
              entry(Icons.health_and_safety_outlined, Tone.good, '网络检测', const NetworkCheckPage()),
              entry(Icons.article_outlined, Tone.warn, '日志', const LogsPage(), needsConnection: true),
              entry(Icons.bar_chart, accent, '统计', const StatisticsPage()),
              InfoRow(
                icon: Icons.travel_explore,
                iconColor: Tone.bad,
                title: 'DNS 泄露检测',
                subtitle: '在浏览器里打开检测网站',
                onTap: () => launchUrl(Uri.parse('https://browserleaks.com/dns'), mode: LaunchMode.externalApplication),
              ),
              InfoRow(
                icon: Icons.policy_outlined,
                iconColor: Tone.bad,
                title: '代理泄露检测',
                subtitle: '在浏览器里打开检测网站',
                onTap: () => launchUrl(Uri.parse('https://ipleak.net'), mode: LaunchMode.externalApplication),
              ),
            ]),
            const SectionLabel('配置和数据'),
            Panel(children: [
              entry(Icons.folder_open_outlined, Tone.teal, '我的配置', const ProfilesPage()),
              entry(Icons.cloud_sync_outlined, accent, '备份与同步', BackupPage(configuration: configuration)),
            ]),
            const SectionLabel('通用'),
            Panel(children: [
              entry(Icons.palette_outlined, Tone.violet, '外观', AppearancePage(appConfiguration: appConfiguration)),
              entry(Icons.dashboard_customize_outlined, Tone.teal, '首页显示', const HomeStatsPage()),
              entry(Icons.tune, Tone.warn, '高级设置', const AdvancedPage()),
              entry(Icons.info_outline, accent, '关于', const AboutPage()),
            ]),
          ]);
        },
      ),
    );
  }
}

/// 主题和强调色
class AppearancePage extends StatelessWidget {
  final AppConfiguration appConfiguration;

  const AppearancePage({super.key, required this.appConfiguration});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appConfiguration.globalChange,
      builder: (context, _, __) => AppPage(title: '外观', children: [
        const SectionLabel('主题'),
        Panel(padding: const EdgeInsets.all(12), children: [
          PillSwitch<ThemeMode>(
            options: const {ThemeMode.system: '跟随系统', ThemeMode.light: '浅色', ThemeMode.dark: '深色'},
            value: appConfiguration.themeMode,
            onChanged: (value) => appConfiguration.themeMode = value,
          ),
        ]),
        const SectionLabel('强调色'),
        Panel(padding: const EdgeInsets.all(14), children: [
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final entry in ColorMapping.colors.entries)
              _ColorDot(
                color: entry.value,
                name: entry.key,
                selected: appConfiguration.themeColor == entry.value,
                onTap: () => appConfiguration.setThemeColor = entry.key,
              ),
          ]),
        ]),
      ]),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _ColorDot({required this.color, required this.name, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: selected ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
        ),
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    void open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

    return AppPage(title: '关于', children: [
      const SizedBox(height: 12),
      Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.asset('assets/icon.png', width: 76, height: 76),
        ),
      ),
      const SizedBox(height: 12),
      Text('RsProxy',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: palette.ink)),
      const SizedBox(height: 4),
      Text('版本 ${AppConfiguration.version}', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: palette.muted)),
      const SizedBox(height: 20),
      Panel(children: [
        InfoRow(title: 'GitHub', onTap: () => open(AppIdentity.repositoryUrl)),
        InfoRow(title: '问题反馈', onTap: () => open('${AppIdentity.repositoryUrl}/issues')),
      ]),
      const SectionLabel('开源组件'),
      Panel(children: [
        InfoRow(title: AppIdentity.upstreamName, subtitle: 'Apache-2.0，解密和抓包部分', onTap: () => open(AppIdentity.upstreamUrl)),
        InfoRow(title: 'sing-box', subtitle: 'GPL-3.0，代理内核', onTap: () => open('https://github.com/SagerNet/sing-box')),
      ]),
    ]);
  }
}
