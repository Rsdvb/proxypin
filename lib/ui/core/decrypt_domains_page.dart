import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/host_filter.dart';

/// 要解密的域名。名单之外的流量不经过 RsProxy，解密与否都不影响它们的速度
class DecryptDomainsPage extends StatefulWidget {
  final Configuration configuration;

  const DecryptDomainsPage({super.key, required this.configuration});

  @override
  State<DecryptDomainsPage> createState() => _DecryptDomainsPageState();
}

class _DecryptDomainsPageState extends State<DecryptDomainsPage> {
  final TextEditingController _input = TextEditingController();
  bool _changed = false;

  @override
  void dispose() {
    _input.dispose();
    if (_changed) {
      widget.configuration.flushConfig();
      CoreManager.instance.reloadConfig();
    }
    super.dispose();
  }

  void _add() {
    final domain = _input.text.trim();
    if (domain.isEmpty) return;
    setState(() {
      HostFilter.whitelist.add(domain);
      _input.clear();
      _changed = true;
    });
  }

  /// 列表里存的是正则，*.example.com 显示时还原回去
  String _label(RegExp rule) => rule.pattern.replaceAll('.*', '*');

  @override
  Widget build(BuildContext context) {
    final rules = HostFilter.whitelist.list;
    return Scaffold(
      appBar: AppBar(title: const Text('解密的域名')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _input,
            autocorrect: false,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(
              hintText: 'example.com 或 *.example.com',
              isDense: true,
              suffixIcon: IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
            ),
          ),
        ),
        Expanded(
          child: rules.isEmpty
              ? const Center(child: Text('名单为空，不会解密任何流量'))
              : ListView.builder(
                  itemCount: rules.length,
                  itemBuilder: (context, index) => ListTile(
                    title: Text(_label(rules[index])),
                    trailing: IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => setState(() {
                        rules.removeAt(index);
                        _changed = true;
                      }),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}
