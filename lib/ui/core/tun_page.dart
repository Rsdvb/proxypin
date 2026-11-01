import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/windows_autostart.dart';

/// TUN 设置。iOS 始终走 TUN，所以没有总开关
class TunPage extends StatefulWidget {
  const TunPage({super.key});

  @override
  State<TunPage> createState() => _TunPageState();
}

class _TunPageState extends State<TunPage> {
  final CoreManager _manager = CoreManager.instance;
  bool _changed = false;

  CoreSettings get _settings => _manager.settings;

  TunSettings get _tun => _settings.tunSettings;

  /// Windows 上 TUN 可以关，关着时下面的选项都不能改
  bool get _enabled => !Platform.isWindows || _settings.tun;

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  @override
  void dispose() {
    if (_changed) _manager.applySettings();
    super.dispose();
  }

  Future<void> _setTun(bool value) async {
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
    _change(() => _settings.tun = value);
  }

  Widget _text(String label, String value, String hint, ValueChanged<String> onChanged, {TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextFormField(
        initialValue: value,
        enabled: _enabled,
        autocorrect: false,
        keyboardType: keyboard,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: true),
        onChanged: onChanged,
      ),
    );
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged, {String? tip}) {
    return SwitchListTile(
      title: Text(title),
      subtitle: tip == null ? null : Text(tip),
      value: value,
      onChanged: _enabled ? (changed) => _change(() => onChanged(changed)) : null,
    );
  }

  Future<void> _openExclude() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RouteExcludePage()));
    if (mounted) setState(() => _changed = true);
  }

  @override
  Widget build(BuildContext context) {
    final tun = _tun;
    return Scaffold(
      appBar: AppBar(title: const Text('TUN')),
      body: ListView(children: [
        if (Platform.isWindows)
          SwitchListTile(
            title: const Text('TUN 模式'),
            subtitle: const Text('接管系统所有流量，此模式下无需开启系统代理'),
            value: _settings.tun,
            onChanged: _setTun,
          ),
        _text('IPv4', tun.ipv4Address, '${TunSettings.defaultIpv4}（/24-/30）', (value) {
          final address = TunSettings.normalizeIpv4(value);
          if (address != null) _changed = true;
          if (address != null) tun.ipv4Address = address;
        }),
        _text('IPv6', tun.ipv6Address, '${TunSettings.defaultIpv6}（/64-/126）', (value) {
          final address = TunSettings.normalizeIpv6(value);
          if (address != null) _changed = true;
          if (address != null) tun.ipv6Address = address;
        }),
        _text('环回地址', tun.loopbackAddress, '10.7.0.1', (value) {
          tun.loopbackAddress = value.trim();
          _changed = true;
        }),
        _text('UDP 超时（秒）', '${tun.udpTimeoutSeconds}', '300', (value) {
          final seconds = int.tryParse(value);
          if (seconds == null) return;
          tun.udpTimeoutSeconds = seconds.clamp(5, 365 * 86400);
          _changed = true;
        }, keyboard: TextInputType.number),
        _text('MTU', '${tun.mtu}', '4064', (value) {
          tun.mtu = int.tryParse(value) ?? 4064;
          _changed = true;
        }, keyboard: TextInputType.number),
        ListTile(
          title: const Text('网络栈'),
          subtitle: Platform.isIOS ? const Text('iOS 只能使用 gvisor') : null,
          trailing: Platform.isIOS
              ? const Text('gvisor')
              : DropdownButton<String>(
                  value: tun.stack,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'mixed', child: Text('mixed')),
                    DropdownMenuItem(value: 'system', child: Text('system')),
                    DropdownMenuItem(value: 'gvisor', child: Text('gvisor')),
                  ],
                  onChanged: _enabled
                      ? (value) {
                          if (value != null) _change(() => tun.stack = value);
                        }
                      : null,
                ),
        ),
        if (Platform.isWindows) _switch('自动路由', tun.autoRoute, (value) => tun.autoRoute = value),
        _switch('严格路由', tun.strictRoute, (value) => tun.strictRoute = value, tip: '如果开启共享后，其他设备无法接入此设备，请尝试关闭'),
        ListTile(
          enabled: _enabled,
          title: const Text('排除地址段'),
          subtitle: const Text('排除地址段的流量将不再进入 TUN'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _enabled ? _openExclude : null,
        ),
        if (Platform.isIOS) ...[
          const Divider(height: 1),
          _switch('附加 HTTP 代理到 VPN', tun.appendHttpProxy, (value) => tun.appendHttpProxy = value,
              tip: '一些 App 会绕过虚拟网卡直连 HTTP 代理'),
          _switch('默认路由', tun.defaultRoute, (value) => tun.defaultRoute = value),
          _switch('includeAllNetworks', tun.includeAllNetworks, (value) => tun.includeAllNetworks = value, tip: 'iOS 14.0+'),
          _switch('excludeLocalNetworks', tun.excludeLocalNetworks, (value) => tun.excludeLocalNetworks = value, tip: 'iOS 14.2+'),
          _switch('excludeCellularServices', tun.excludeCellularServices, (value) => tun.excludeCellularServices = value,
              tip: 'iOS 16.4+'),
          _switch('excludeAPNs', tun.excludeApns, (value) => tun.excludeApns = value, tip: 'iOS 16.4+'),
          _switch('excludeDeviceCommunication', tun.excludeDeviceCommunication, (value) => tun.excludeDeviceCommunication = value,
              tip: 'iOS 17.4+'),
          _switch('enforceRoutes', tun.enforceRoutes, (value) => tun.enforceRoutes = value, tip: 'iOS 14.2+'),
          const ListTile(dense: true, title: Text('这一组选项由系统执行，要重新连接才生效')),
        ],
      ]),
    );
  }
}

/// 不进 TUN 的地址段
class RouteExcludePage extends StatefulWidget {
  const RouteExcludePage({super.key});

  @override
  State<RouteExcludePage> createState() => _RouteExcludePageState();
}

class _RouteExcludePageState extends State<RouteExcludePage> {
  final TunSettings _tun = CoreManager.instance.settings.tunSettings;
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final text = _input.text.trim();
    if (!RegExp(r'^[\da-fA-F:.]+/\d{1,3}$').hasMatch(text) || _tun.routeExcludeAddresses.contains(text)) return;
    setState(() {
      _tun.routeExcludeAddresses = [..._tun.routeExcludeAddresses, text];
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final on = _tun.routeExclude;
    return Scaffold(
      appBar: AppBar(title: const Text('排除地址段')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('启用'),
          subtitle: Text('${_tun.ipv4Address}\n${_tun.ipv6Address}'),
          value: on,
          onChanged: (value) => setState(() => _tun.routeExclude = value),
        ),
        const Divider(height: 1),
        if (Platform.isWindows)
          SwitchListTile(
            title: const Text('TUN'),
            value: _tun.routeExcludeTun,
            onChanged: on ? (value) => setState(() => _tun.routeExcludeTun = value) : null,
          ),
        SwitchListTile(
          title: const Text('组播'),
          subtitle: const Text('224.0.0.0/4\nff00::/8'),
          value: _tun.routeExcludeMulticast,
          onChanged: on ? (value) => setState(() => _tun.routeExcludeMulticast = value) : null,
        ),
        if (Platform.isIOS)
          SwitchListTile(
            title: const Text('隐藏 VPN 图标'),
            subtitle: const Text('0.0.0.0/31\n::/127\n开启 IPv6 会导致此功能失效'),
            value: _tun.hideVpn,
            onChanged: on ? (value) => setState(() => _tun.hideVpn = value) : null,
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _input,
            enabled: on,
            autocorrect: false,
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(
              hintText: '192.168.0.0/16',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: on ? _add : null),
            ),
          ),
        ),
        for (final address in _tun.routeExcludeAddresses)
          ListTile(
            title: Text(address),
            trailing: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => setState(() {
                _tun.routeExcludeAddresses = _tun.routeExcludeAddresses.where((e) => e != address).toList();
              }),
            ),
          ),
      ]),
    );
  }
}
