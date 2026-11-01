import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/windows_autostart.dart';

import 'design.dart';

/// 改完离开页面时保存一次：这些选项都要重载内核才生效，会断开现有连接
mixin _SaveOnLeave<T extends StatefulWidget> on State<T> {
  final CoreManager manager = CoreManager.instance;
  bool changed = false;

  CoreSettings get settings => manager.settings;

  void change(VoidCallback update) {
    setState(() {
      update();
      changed = true;
    });
  }

  @override
  void dispose() {
    if (changed) manager.applySettings();
    super.dispose();
  }

  void show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> askText(String title, String initial, {bool number = false, bool obscure = false}) async {
    final controller = TextEditingController(text: initial);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          obscureText: obscure,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return text;
  }

  Future<void> editNumber(String title, int current, int low, int high, void Function(int) apply) async {
    final value = int.tryParse(await askText(title, current > 0 ? '$current' : '', number: true) ?? '');
    if (value != null) change(() => apply(value.clamp(low, high)));
  }
}

/// 给所有节点统一加的 TLS 和多路复用选项
class NodeTuningPage extends StatefulWidget {
  const NodeTuningPage({super.key});

  @override
  State<NodeTuningPage> createState() => _NodeTuningPageState();
}

class _NodeTuningPageState extends State<NodeTuningPage> with _SaveOnLeave {
  NodeTuning get _tuning => settings.tuning;

  Widget _number(String title, int value, void Function(int) apply, {String? subtitle, int low = 0, int high = 65535, bool enabled = true}) {
    return ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Text(value > 0 ? '$value' : '未设置'),
      onTap: enabled ? () => editNumber(title, value, low, high, apply) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tuning = _tuning;
    final mux = tuning.muxEnabled;
    return Scaffold(
      appBar: AppBar(title: const Text('TLS 和多路复用')),
      body: SettingsList(children: [
        const SectionLabel('TLS'),
        SwitchListTile(
          title: const Text('跳过证书验证'),
          subtitle: const Text('节点证书过期或自签时才打开。打开后无法发现中间人'),
          value: tuning.tlsInsecure,
          onChanged: (value) => change(() => tuning.tlsInsecure = value),
        ),
        SwitchListTile(
          title: const Text('TLS 记录分片'),
          subtitle: const Text('绕过按明文匹配的简单过滤，速度影响小，建议先试这个'),
          value: tuning.tlsRecordFragment,
          onChanged: (value) => change(() => tuning.tlsRecordFragment = value),
        ),
        SwitchListTile(
          title: const Text('TLS 分片'),
          subtitle: const Text('拆分握手包，速度影响较大。只对 VMess、VLESS、Trojan 这类 TCP 协议生效'),
          value: tuning.tlsFragment,
          onChanged: (value) => change(() => tuning.tlsFragment = value),
        ),
        _number('分片等待（毫秒）', tuning.fragmentDelayMs, (e) => tuning.fragmentDelayMs = e,
            subtitle: '内核测不出等待时间时才用，留空用默认值', high: 1000, enabled: tuning.tlsFragment),
        const SectionLabel('多路复用'),
        SwitchListTile(
          title: const Text('启用'),
          subtitle: const Text('多条连接共用一条隧道，握手慢的节点会快一些。节点要支持才行'),
          value: mux,
          onChanged: (value) => change(() => tuning.muxEnabled = value),
        ),
        ListTile(
          enabled: mux,
          title: const Text('协议'),
          trailing: DropdownButton<String>(
            value: tuning.muxProtocol,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 'h2mux', child: Text('h2mux')),
              DropdownMenuItem(value: 'smux', child: Text('smux')),
              DropdownMenuItem(value: 'yamux', child: Text('yamux')),
            ],
            onChanged: mux ? (value) => change(() => tuning.muxProtocol = value!) : null,
          ),
        ),
        SwitchListTile(
          title: const Text('填充'),
          value: tuning.muxPadding,
          onChanged: mux ? (value) => change(() => tuning.muxPadding = value) : null,
        ),
        _number('最大流数', tuning.muxMaxStreams, (e) => tuning.muxMaxStreams = e,
            subtitle: '填了这项，下面两项不生效，内核规定它们不能同时用', high: 256, enabled: mux),
        _number('最大连接数', tuning.muxMaxConnections, (e) => tuning.muxMaxConnections = e,
            high: 256, enabled: mux && tuning.muxMaxStreams == 0),
        _number('最小流数', tuning.muxMinStreams, (e) => tuning.muxMinStreams = e,
            high: 256, enabled: mux && tuning.muxMaxStreams == 0),
        SwitchListTile(
          title: const Text('Brutal'),
          subtitle: const Text('按固定速率发送，服务端要装 Brutal 内核模块'),
          value: tuning.muxBrutal,
          onChanged: mux ? (value) => change(() => tuning.muxBrutal = value) : null,
        ),
        _number('上行（Mbps）', tuning.muxUpMbps, (e) => tuning.muxUpMbps = e, low: 1, high: 100000, enabled: mux && tuning.muxBrutal),
        _number('下行（Mbps）', tuning.muxDownMbps, (e) => tuning.muxDownMbps = e, low: 1, high: 100000, enabled: mux && tuning.muxBrutal),
        for (final type in NodeTuning.muxCapableTypes)
          CheckboxListTile(
            title: Text('对 $type 生效'),
            subtitle: type == 'vless' ? const Text('用了 flow 的节点不生效') : null,
            value: tuning.muxTypes.contains(type),
            onChanged: mux ? (value) => change(() => value == true ? tuning.muxTypes.add(type) : tuning.muxTypes.remove(type)) : null,
          ),
      ]),
    );
  }
}

/// 让局域网里的其他设备通过这台设备上网
class NetworkSharePage extends StatefulWidget {
  const NetworkSharePage({super.key});

  @override
  State<NetworkSharePage> createState() => _NetworkSharePageState();
}

class _NetworkSharePageState extends State<NetworkSharePage> with _SaveOnLeave {
  List<String> _addresses = const [];

  @override
  void initState() {
    super.initState();
    CoreTools.lanAddresses().then((value) {
      if (mounted) setState(() => _addresses = value);
    }).catchError((_) {});
  }

  Future<void> _setEnabled(bool value) async {
    change(() => settings.lanEnabled = value);
    if (!Platform.isWindows) return;
    if (!WindowsAdmin.isAdmin()) {
      if (value) show('Windows 防火墙可能会弹窗询问，请点允许');
      return;
    }
    if (value) {
      await WindowsFirewall.allow();
    } else {
      await WindowsFirewall.remove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = settings.lanEnabled;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网络共享')),
      body: SettingsList(children: [
        SwitchListTile(
          title: const Text('允许局域网连接'),
          subtitle: const Text('其他设备把代理设成下面的地址，就能通过这台设备上网'),
          value: enabled,
          onChanged: _setEnabled,
        ),
        if (enabled)
          for (final address in _addresses) ...[
            ListTile(dense: true, title: SelectableText('$address:${settings.lanPort}'), subtitle: const Text('按分流规则')),
            ListTile(dense: true, title: SelectableText('$address:${settings.lanGlobalPort}'), subtitle: const Text('全部走代理')),
          ],
        ListTile(
          enabled: enabled,
          title: const Text('用户名'),
          trailing: Text(settings.lanUsername.isEmpty ? '未设置' : settings.lanUsername),
          onTap: enabled
              ? () async {
                  final text = await askText('局域网用户名', settings.lanUsername);
                  if (text != null) change(() => settings.lanUsername = text);
                }
              : null,
        ),
        ListTile(
          enabled: enabled,
          title: const Text('密码'),
          subtitle: const Text('用户名和密码都填才生效，公共网络下建议设置'),
          trailing: Text(settings.lanPassword.isEmpty ? '未设置' : '已设置'),
          onTap: enabled
              ? () async {
                  final text = await askText('局域网密码', settings.lanPassword, obscure: true);
                  if (text != null) change(() => settings.lanPassword = text);
                }
              : null,
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('没设账号时，同一网络里的任何设备都能用你的节点。', style: theme.textTheme.bodySmall),
        ),
      ]),
    );
  }
}

/// 端口。一般不用改，和别的软件冲突时才来这里
class PortsPage extends StatefulWidget {
  const PortsPage({super.key});

  /// 可用范围外或和其他端口重复时返回原因
  static String? problem(int port, Iterable<int> others) {
    if (port < 2048 || port > 65535) return '端口要在 2048 到 65535 之间';
    return others.contains(port) ? '这个端口已经在用了' : null;
  }

  @override
  State<PortsPage> createState() => _PortsPageState();
}

class _PortsPageState extends State<PortsPage> with _SaveOnLeave {
  List<int> get _all => [
        settings.mixedPort,
        settings.upstreamPort,
        settings.clashPort,
        settings.probePort,
        settings.lanPort,
        settings.lanGlobalPort,
        if (settings.directPort > 0) settings.directPort,
        if (settings.globalPort > 0) settings.globalPort,
      ];

  Future<void> _edit(String title, int current, void Function(int) apply, {bool optional = false}) async {
    final text = await askText(title, current > 0 ? '$current' : '', number: true);
    if (text == null) return;
    if (text.isEmpty) {
      if (optional) change(() => apply(0));
      return;
    }
    final port = int.tryParse(text);
    if (port == null || port == current) return;
    final problem = PortsPage.problem(port, _all);
    if (problem != null) return show(problem);
    change(() => apply(port));
  }

  Widget _port(String title, int value, void Function(int) apply, {String? subtitle, bool optional = false}) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Text(value > 0 ? '$value' : '未开启'),
      onTap: () => _edit(title, value, apply, optional: optional),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = this.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('端口')),
      body: SettingsList(children: [
        _port('代理端口', settings.mixedPort, (e) => settings.mixedPort = e, subtitle: 'HTTP 和 SOCKS，按分流规则走'),
        _port('全部走代理的端口', settings.globalPort, (e) => settings.globalPort = e, subtitle: '留空不开启', optional: true),
        _port('全部直连的端口', settings.directPort, (e) => settings.directPort = e, subtitle: '留空不开启', optional: true),
        _port('局域网端口', settings.lanPort, (e) => settings.lanPort = e),
        _port('局域网全部走代理的端口', settings.lanGlobalPort, (e) => settings.lanGlobalPort = e),
        _port('解密回程端口', settings.upstreamPort, (e) => settings.upstreamPort = e),
        _port('控制端口', settings.clashPort, (e) => settings.clashPort = e),
        _port('测试端口', settings.probePort, (e) => settings.probePort = e),
        if (Platform.isWindows) ...[
          const Divider(),
          ListTile(
            title: const Text('代理端口用户名'),
            trailing: Text(settings.mixedUsername.isEmpty ? '未设置' : settings.mixedUsername),
            onTap: () async {
              final text = await askText('代理端口用户名', settings.mixedUsername);
              if (text != null) change(() => settings.mixedUsername = text);
            },
          ),
          ListTile(
            title: const Text('代理端口密码'),
            subtitle: const Text('两项都填才生效。系统代理不支持账号，要给本机程序单独配置时才用'),
            trailing: Text(settings.mixedPassword.isEmpty ? '未设置' : '已设置'),
            onTap: () async {
              final text = await askText('代理端口密码', settings.mixedPassword, obscure: true);
              if (text != null) change(() => settings.mixedPassword = text);
            },
          ),
        ],
      ]),
    );
  }
}
