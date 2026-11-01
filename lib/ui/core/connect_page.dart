import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_service.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'decrypt_domains_page.dart';
import 'format.dart';
import 'more_page.dart';
import 'nodes_page.dart';
import 'profiles_page.dart';
import 'rule_groups_page.dart';

/// 首页：一屏看完连接状态，常用操作都在这里，其余收进二级页面
class ConnectPage extends StatefulWidget {
  final ProxyServer proxyServer;

  const ConnectPage({super.key, required this.proxyServer});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final Future<void> _ready = CoreService.start(widget.proxyServer).then((_) {
    final pending = CoreManager.instance.pendingImport;
    pending.addListener(_openPendingImport);
    _openPendingImport();
  });

  @override
  void initState() {
    super.initState();
    _ready.ignore();
  }

  @override
  void dispose() {
    if (CoreManager.isReady) CoreManager.instance.pendingImport.removeListener(_openPendingImport);
    super.dispose();
  }

  void _openPendingImport() {
    final pending = CoreManager.instance.pendingImport;
    final link = pending.value;
    if (link == null || !mounted) return;
    pending.value = null;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AddProfilePage(initialContent: link.url, initialName: link.name, outboundDns: link.outboundDns),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snapshot.error}')));
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListenableBuilder(
              listenable: CoreManager.instance,
              builder: (context, _) => _ConnectView(CoreManager.instance, widget.proxyServer),
            );
          },
        ),
      ),
    );
  }
}

class _ConnectView extends StatelessWidget {
  final CoreManager manager;
  final ProxyServer proxyServer;

  const _ConnectView(this.manager, this.proxyServer);

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 16), children: [
          _PowerButton(manager),
          const SizedBox(height: 24),
          if (manager.needsReload) ...[
            _Section(children: [
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('配置已更新'),
                subtitle: const Text('重新加载后生效，现有连接会断开'),
                onTap: manager.reloadConfig,
              ),
            ]),
            const SizedBox(height: 12),
          ],
          _Section(children: [
            _nodeTile(context),
          ]),
          const SizedBox(height: 12),
          SegmentedButton<RouteMode>(
            segments: const [
              ButtonSegment(value: RouteMode.rule, label: Text('规则')),
              ButtonSegment(value: RouteMode.global, label: Text('全局')),
            ],
            selected: {manager.settings.mode},
            showSelectedIcon: false,
            onSelectionChanged: (value) => manager.setMode(value.first),
          ),
          const SizedBox(height: 12),
          _Section(children: [_profileTile(context)]),
          const SizedBox(height: 12),
          _Section(children: [
            _decryptTile(context),
            ListTile(
              title: const Text('分流'),
              subtitle: Text('${manager.settings.groups.where((e) => e.enabled).length} 组规则'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, const RuleGroupsPage()),
            ),
            if (Platform.isWindows)
              SwitchListTile(
                title: const Text('系统代理'),
                value: manager.settings.systemProxy,
                onChanged: manager.setSystemProxy,
              ),
            ListTile(
              title: const Text('更多'),
              subtitle: const Text('连接、测速、备份、高级设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, MorePage(configuration: proxyServer.configuration)),
            ),
          ]),
          if (manager.isRunning) ...[
            const SizedBox(height: 16),
            _TrafficLine(manager.api),
          ],
        ]),
      ),
    );
  }

  Widget _nodeTile(BuildContext context) {
    final selected = manager.selectedNode;
    final delay = selected == null ? null : manager.delays[selected];
    return ListTile(
      leading: const Icon(Icons.public),
      title: Text(nodeLabel(selected), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: manager.activeProfile == null ? const Text('没有配置时所有流量直连') : Text('${manager.nodes.length} 个节点'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (delay != null) Text('$delay ms', style: TextStyle(color: delayColor(context, delay))),
        const Icon(Icons.chevron_right),
      ]),
      onTap: () => _open(context, const NodesPage()),
    );
  }

  Widget _profileTile(BuildContext context) {
    final profile = manager.activeProfile;
    if (profile == null) {
      return ListTile(
        leading: const Icon(Icons.add),
        title: const Text('添加配置'),
        subtitle: const Text('粘贴订阅链接或配置内容'),
        onTap: () => _open(context, const AddProfilePage()),
      );
    }
    return InkWell(
      onTap: () => _open(context, const ProfilesPage()),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: ProfileSummary(profile),
      ),
    );
  }

  Widget _decryptTile(BuildContext context) {
    final count = HostFilter.whitelist.list.length;
    return ListTile(
      title: const Text('HTTPS 解密'),
      subtitle: Text(count == 0 ? '点这里添加要解密的域名' : '$count 个域名'),
      onTap: () => _open(context, DecryptDomainsPage(configuration: proxyServer.configuration)),
      trailing: Switch(value: manager.settings.capture, onChanged: manager.setCapture),
    );
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
        const SizedBox(height: 8),
        LinearProgressIndicator(value: (info.used / info.total).clamp(0, 1).toDouble(), minHeight: 4),
        const SizedBox(height: 6),
        Text(
          '${formatBytes(info.used)} / ${formatBytes(info.total)}'
          '${info.expire == null ? '' : ' · ${formatDate(info.expire!)} 到期'}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    ]);
  }
}

class _Section extends StatelessWidget {
  final List<Widget> children;

  const _Section({required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _PowerButton extends StatelessWidget {
  final CoreManager manager;

  const _PowerButton(this.manager);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = manager.state;
    final running = state == CoreState.running;
    final busy = state == CoreState.starting || state == CoreState.stopping;
    final color = running ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest;
    final label = switch (state) {
      CoreState.stopped => '未连接',
      CoreState.starting => '正在连接',
      CoreState.running => '已连接',
      CoreState.stopping => '正在断开',
    };

    return Column(children: [
      Semantics(
        button: true,
        label: running ? '断开' : '连接',
        child: Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: busy ? null : (running ? manager.disconnect : manager.connect),
            child: SizedBox(
              width: 112,
              height: 112,
              child: busy
                  ? const Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(strokeWidth: 3))
                  : Icon(Icons.power_settings_new,
                      size: 48, color: running ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(label, style: theme.textTheme.titleMedium),
      if (manager.lastError != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(manager.lastError!,
              textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
        ),
    ]);
  }
}

/// 实时速度。App 进后台时断开订阅：iOS 上这条连接一直占着内核的内存，也让解密时的主 App 多醒
class _TrafficLine extends StatefulWidget {
  final ClashApi api;

  const _TrafficLine(this.api);

  @override
  State<_TrafficLine> createState() => _TrafficLineState();
}

class _TrafficLineState extends State<_TrafficLine> with WidgetsBindingObserver {
  StreamSubscription<TrafficSample>? _subscription;
  TrafficSample _sample = const TrafficSample(0, 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
  }

  void _subscribe() {
    _subscription ??= widget.api.traffic().listen((sample) {
      if (mounted) setState(() => _sample = sample);
    }, onError: (_) {});
  }

  void _unsubscribe() {
    _subscription?.cancel();
    _subscription = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    state == AppLifecycleState.resumed ? _subscribe() : _unsubscribe();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '↑ ${formatBytes(_sample.up)}/s    ↓ ${formatBytes(_sample.down)}/s',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// 节点 tag 的显示名
String nodeLabel(String? tag) => switch (tag) {
      null || 'auto' => '自动选择',
      'direct' => '直连',
      _ => tag,
    };

Color delayColor(BuildContext context, int delay) {
  if (delay < 200) return Colors.green;
  if (delay < 500) return Colors.orange;
  return Theme.of(context).colorScheme.error;
}
