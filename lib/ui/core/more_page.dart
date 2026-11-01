import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';

import 'advanced_page.dart';
import 'backup_page.dart';
import 'connections_page.dart';
import 'dns_page.dart';
import 'tools_pages.dart';
import 'tun_page.dart';

/// 不常用的功能都在这里，首页只留连接相关的东西
class MorePage extends StatelessWidget {
  final Configuration configuration;

  const MorePage({super.key, required this.configuration});

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;

    Widget entry(IconData icon, String title, Widget page, {bool needsConnection = false}) {
      final available = !needsConnection || manager.isRunning;
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: available ? null : const Text('连接后可用'),
        enabled: available,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListView(children: [
        entry(Icons.lan_outlined, '连接', ConnectionsPage(configuration: configuration), needsConnection: true),
        entry(Icons.speed, '测速', const SpeedTestPage(), needsConnection: true),
        entry(Icons.alt_route, '规则检测', const RuleCheckPage(), needsConnection: true),
        entry(Icons.health_and_safety_outlined, '网络检测', const NetworkCheckPage(), needsConnection: true),
        const Divider(height: 1),
        entry(Icons.dns_outlined, 'DNS', const DnsPage()),
        entry(Icons.vpn_lock_outlined, 'TUN', const TunPage()),
        const Divider(height: 1),
        entry(Icons.cloud_sync_outlined, '备份与同步', BackupPage(configuration: configuration)),
        entry(Icons.tune, '高级设置', const AdvancedPage()),
      ]),
    );
  }
}
