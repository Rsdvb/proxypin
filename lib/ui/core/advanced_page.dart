import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';

/// 不常改的连接设置。默认值就能用，所以不放在首页
class AdvancedPage extends StatefulWidget {
  const AdvancedPage({super.key});

  @override
  State<AdvancedPage> createState() => _AdvancedPageState();
}

class _AdvancedPageState extends State<AdvancedPage> {
  final CoreManager _manager = CoreManager.instance;
  late final TextEditingController _remoteDns = TextEditingController(text: _manager.settings.remoteDns);
  late final TextEditingController _directDns = TextEditingController(text: _manager.settings.directDns);
  late final TextEditingController _testUrl = TextEditingController(text: _manager.settings.testUrl);
  late bool _fakeIp = _manager.settings.fakeIp;
  late bool _ipv6 = _manager.settings.ipv6;

  @override
  void dispose() {
    _remoteDns.dispose();
    _directDns.dispose();
    _testUrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _manager.saveAdvanced(
      remoteDns: _remoteDns.text.trim(),
      directDns: _directDns.text.trim(),
      testUrl: _testUrl.text.trim(),
      fakeIp: _fakeIp,
      ipv6: _ipv6,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Widget _field(TextEditingController controller, String label, String helper) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        autocorrect: false,
        decoration: InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置'), actions: [
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _field(_remoteDns, '远程 DNS', '走节点查询，如 https://1.1.1.1/dns-query'),
        _field(_directDns, '直连 DNS', '查询国内域名，local 表示系统 DNS，也可填 223.5.5.5'),
        _field(_testUrl, '延迟测试地址', '测节点延迟时访问的网址'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fake IP'),
          subtitle: const Text('TUN 模式下更快，也不容易泄露 DNS'),
          value: _fakeIp,
          onChanged: (value) => setState(() => _fakeIp = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('IPv6'),
          value: _ipv6,
          onChanged: (value) => setState(() => _ipv6 = value),
        ),
      ]),
    );
  }
}
