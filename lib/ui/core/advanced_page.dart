import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/single_instance.dart';
import 'package:proxypin/core/windows_autostart.dart';
import 'package:proxypin/ui/configuration.dart';

import 'design.dart';

/// 不常改的连接设置。默认值就能用，所以不放在首页
class AdvancedPage extends StatefulWidget {
  const AdvancedPage({super.key});

  @override
  State<AdvancedPage> createState() => _AdvancedPageState();
}

class _AdvancedPageState extends State<AdvancedPage> {
  final CoreManager _manager = CoreManager.instance;
  late final TextEditingController _testUrl = TextEditingController(text: _manager.settings.testUrl);
  bool _autostart = false;
  bool _changed = false;
  final Map<String, bool> _schemes = {};

  CoreSettings get _settings => _manager.settings;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WindowsAutostart.isEnabled().then((value) {
        if (mounted) setState(() => _autostart = value);
      });
      for (final scheme in WindowsSchemes.supported) {
        WindowsSchemes.isRegistered(scheme).then((value) {
          if (mounted) setState(() => _schemes[scheme] = value);
        });
      }
    }
  }

  @override
  void dispose() {
    final url = _testUrl.text.trim();
    if (url.isNotEmpty && url != _settings.testUrl) {
      _settings.testUrl = url;
      _changed = true;
    }
    _testUrl.dispose();
    if (_changed) _manager.applySettings();
    super.dispose();
  }

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  Future<void> _setScheme(String scheme, bool enabled) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WindowsSchemes.setRegistered(scheme, enabled);
      if (mounted) setState(() => _schemes[scheme] = enabled);
    } on ProcessException {
      messenger.showSnackBar(SnackBar(content: Text('$scheme:// 链接设置失败')));
    }
  }

  Future<void> _pickRawConfig() async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    if (file == null) return;
    try {
      await _manager.useRawConfig(file.name, utf8.decode(await file.readAsBytes()));
      if (mounted) setState(() {});
    } on FormatException {
      messenger.showSnackBar(const SnackBar(content: Text('这不是 sing-box 配置文件')));
    }
  }

  Future<void> _clearRawConfig() async {
    await _manager.useRawConfig(null, null);
    if (mounted) setState(() {});
  }

  Future<void> _openBypass() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BypassDomainsPage()));
    if (mounted) setState(() => _changed = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置')),
      body: SettingsList(children: [
        ListTile(
          title: const Text('IPv6'),
          subtitle: const Text('节点没有 IPv6 时开启反而容易连不上'),
          trailing: DropdownButton<IpStrategy>(
            value: _settings.ipStrategy,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: IpStrategy.ipv4Only, child: Text('禁用')),
              DropdownMenuItem(value: IpStrategy.preferIpv4, child: Text('启用')),
              DropdownMenuItem(value: IpStrategy.preferIpv6, child: Text('优先')),
              DropdownMenuItem(value: IpStrategy.ipv6Only, child: Text('仅 IPv6')),
            ],
            onChanged: (value) {
              if (value != null) _change(() => _settings.ipStrategy = value);
            },
          ),
        ),
        SwitchListTile(
          title: const Text('打开 App 时自动连接'),
          value: _settings.autoConnect,
          onChanged: (value) => _change(() => _settings.autoConnect = value),
        ),
        ListTile(
          title: const Text('使用原始 sing-box 配置'),
          subtitle: Text(_settings.rawConfigName.isEmpty
              ? '选一个配置文件直接运行，RsProxy 的分流和解密都不再生效'
              : '正在使用 ${_settings.rawConfigName}'),
          trailing: _settings.rawConfigName.isEmpty
              ? const Icon(Icons.chevron_right)
              : IconButton(tooltip: '清除', icon: const Icon(Icons.close), onPressed: _clearRawConfig),
          onTap: _pickRawConfig,
        ),
        if (Platform.isWindows) ...[
          SwitchListTile(
            title: const Text('开机自启'),
            value: _autostart,
            onChanged: (value) async {
              await WindowsAutostart.setEnabled(value);
              if (mounted) setState(() => _autostart = value);
            },
          ),
          SwitchListTile(
            title: const Text('启动后隐藏窗口'),
            subtitle: const Text('只留托盘图标，点图标打开'),
            value: AppConfiguration.current?.hideAfterLaunch ?? false,
            onChanged: (value) {
              setState(() => AppConfiguration.current?.hideAfterLaunch = value);
              AppConfiguration.current?.flushConfig();
            },
          ),
          for (final scheme in WindowsSchemes.supported)
            SwitchListTile(
              title: Text('处理 $scheme:// 链接'),
              subtitle: const Text('网页上的一键导入会打开 RsProxy'),
              value: _schemes[scheme] ?? false,
              onChanged: (value) => _setScheme(scheme, value),
            ),
        ],
        if (Platform.isWindows) ...[
          SwitchListTile(
            title: const Text('允许绕过系统代理'),
            value: _settings.proxyBypass,
            onChanged: (value) => _change(() => _settings.proxyBypass = value),
          ),
          ListTile(
            enabled: _settings.proxyBypass,
            title: const Text('绕过的域名'),
            subtitle: Text('${_settings.bypassDomains.length} 条'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _settings.proxyBypass ? _openBypass : null,
          ),
        ],
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _testUrl,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: '延迟测试地址', helperText: '测节点延迟时访问的网址'),
          ),
        ),
      ]),
    );
  }
}

/// 代理设置绕过的域名，Windows 的系统代理和 iOS 的 HTTP 代理共用
class BypassDomainsPage extends StatefulWidget {
  const BypassDomainsPage({super.key});

  @override
  State<BypassDomainsPage> createState() => _BypassDomainsPageState();
}

class _BypassDomainsPageState extends State<BypassDomainsPage> {
  final CoreSettings _settings = CoreManager.instance.settings;
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final text = _input.text.trim();
    if (text.isEmpty || _settings.bypassDomains.contains(text)) return;
    setState(() {
      _settings.bypassDomains = [..._settings.bypassDomains, text];
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('绕过的域名'), actions: [
        TextButton(
          onPressed: () => setState(() => _settings.bypassDomains = [...CoreSettings.defaultBypassDomains]),
          child: const Text('恢复默认'),
        ),
      ]),
      body: SettingsList(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _input,
            autocorrect: false,
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(
              hintText: '*.example.com',
              isDense: true,
              suffixIcon: IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
            ),
          ),
        ),
        for (final domain in _settings.bypassDomains)
          ListTile(
            title: Text(domain),
            trailing: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => setState(() {
                _settings.bypassDomains = _settings.bypassDomains.where((e) => e != domain).toList();
              }),
            ),
          ),
      ]),
    );
  }
}
