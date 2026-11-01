import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'decrypt_domains_page.dart';
import 'design.dart';

/// 解密页的三个分区
enum CaptureSection { requests, favorites, history }

/// 解密页顶部：开关和名单数量。解密是这个 App 的主要用途，不能藏起来
class CaptureStatusBar extends StatelessWidget {
  final Configuration configuration;

  const CaptureStatusBar({super.key, required this.configuration});

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final count = HostFilter.whitelist.list.length;
        final on = manager.settings.capture;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Panel(children: [
            InfoRow(
              icon: on ? Icons.lock_open : Icons.lock_outline,
              iconColor: on ? Tone.good : Palette.of(context).faint,
              title: on ? 'HTTPS 解密已开启' : 'HTTPS 解密已关闭',
              subtitle: count == 0 ? '还没有域名，点这里添加' : '名单里有 $count 个域名，其余流量不经过解密',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DecryptDomainsPage(configuration: configuration),
              )),
              chevron: false,
              trailing: Switch(value: on, onChanged: manager.setCapture),
            ),
          ]),
        );
      },
    );
  }
}
