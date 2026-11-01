import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/windows_autostart.dart';

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

  CoreSettings get _settings => _manager.settings;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WindowsAutostart.isEnabled().then((value) {
        if (mounted) setState(() => _autostart = value);
      });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置')),
      body: ListView(children: [
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
        if (Platform.isWindows)
          SwitchListTile(
            title: const Text('开机自启'),
            value: _autostart,
            onChanged: (value) async {
              await WindowsAutostart.setEnabled(value);
              if (mounted) setState(() => _autostart = value);
            },
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _testUrl,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: '延迟测试地址', helperText: '测节点延迟时访问的网址', border: OutlineInputBorder()),
          ),
        ),
      ]),
    );
  }
}
