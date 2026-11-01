import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'connect_page.dart';
import 'format.dart';

/// 测当前节点的下载速度
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({super.key});

  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends State<SpeedTestPage> {
  bool _running = false;
  double? _speed;
  String? _error;

  Future<void> _start() async {
    final proxy = CoreManager.instance.proxyAddress;
    if (proxy == null) return;
    setState(() {
      _running = true;
      _speed = null;
      _error = null;
    });
    try {
      final speed = await CoreTools.downloadSpeed(proxy, onProgress: (value) {
        if (mounted) setState(() => _speed = value);
      });
      if (mounted) setState(() => _speed = speed);
    } catch (e) {
      if (mounted) setState(() => _error = '测速失败：$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speed = _speed;
    return Scaffold(
      appBar: AppBar(title: const Text('测速')),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(nodeLabel(CoreManager.instance.selectedNode), style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Text(speed == null ? '—' : '${formatBytes(speed.toInt())}/s', style: theme.textTheme.displaySmall),
          if (speed != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${(speed * 8 / 1000000).toStringAsFixed(1)} Mbps', style: theme.textTheme.bodyMedium),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _running ? null : _start, child: Text(_running ? '测试中' : '开始')),
        ]),
      ),
    );
  }
}

/// 查一个域名会走哪条规则
class RuleCheckPage extends StatefulWidget {
  const RuleCheckPage({super.key});

  @override
  State<RuleCheckPage> createState() => _RuleCheckPageState();
}

class _RuleCheckPageState extends State<RuleCheckPage> {
  final TextEditingController _domain = TextEditingController();
  bool _checking = false;
  String? _result;

  @override
  void dispose() {
    _domain.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final manager = CoreManager.instance;
    final domain = _domain.text.trim().replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    if (domain.isEmpty) return;

    setState(() {
      _checking = true;
      _result = null;
    });
    String result;
    try {
      final match = await CoreTools.matchRule(manager.api, manager.settings.upstreamPort, domain);
      final decrypted = manager.settings.capture && HostFilter.whitelist.list.any((rule) => rule.hasMatch(domain));
      result = match == null
          ? '没有查到结果'
          : '走 ${nodeLabel(match.outbound)}\n命中规则：${match.rule.isEmpty ? '默认' : match.rule}'
              '${decrypted ? '\n这个域名会先经过解密' : ''}';
    } catch (e) {
      result = '检测失败：$e';
    }
    if (mounted) {
      setState(() {
        _checking = false;
        _result = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('规则检测')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _domain,
          autocorrect: false,
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _check(),
          decoration: const InputDecoration(hintText: '输入域名，如 www.google.com', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _checking ? null : _check, child: Text(_checking ? '检测中' : '检测')),
        if (_result != null) ...[
          const SizedBox(height: 20),
          SelectableText(_result!, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ]),
    );
  }
}

/// 上不了网时，看看断在哪一段
class NetworkCheckPage extends StatefulWidget {
  const NetworkCheckPage({super.key});

  @override
  State<NetworkCheckPage> createState() => _NetworkCheckPageState();
}

class _NetworkCheckPageState extends State<NetworkCheckPage> {
  List<CheckResult>? _results;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final manager = CoreManager.instance;
    final proxy = manager.proxyAddress;
    if (proxy == null) return;
    setState(() {
      _running = true;
      _results = null;
    });
    final results = await CoreTools.networkCheck(manager.api, proxy, testUrl: manager.settings.testUrl);
    if (mounted) {
      setState(() {
        _running = false;
        _results = results;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(title: const Text('网络检测'), actions: [
        IconButton(tooltip: '重新检测', icon: const Icon(Icons.refresh), onPressed: _running ? null : _run),
      ]),
      body: results == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              for (final result in results)
                ListTile(
                  leading: Icon(result.passed ? Icons.check_circle : Icons.cancel,
                      color: result.passed ? Colors.green : Theme.of(context).colorScheme.error),
                  title: Text(result.name),
                  subtitle: result.detail == null || result.detail!.isEmpty ? null : Text(result.detail!),
                  trailing: result.elapsed == null ? null : Text('${result.elapsed!.inMilliseconds} ms'),
                ),
            ]),
    );
  }
}
