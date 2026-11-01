import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_manager.dart';

import 'format.dart';

/// 内核日志。只在这个页面开着时才订阅，平时不占内存
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const int _maxLines = 1000;
  static const List<String> _levels = ['error', 'warn', 'info', 'debug', 'trace'];

  final CoreManager _manager = CoreManager.instance;
  final List<CoreLog> _lines = [];
  StreamSubscription<CoreLog>? _subscription;
  String _keyword = '';
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _subscription?.cancel();
    _subscription = _manager.api.logs(level: _manager.settings.logLevel).listen((line) {
      if (_paused || !mounted) return;
      setState(() {
        _lines.add(line);
        if (_lines.length > _maxLines) _lines.removeAt(0);
      });
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// 级别在内核配置里，改了要重载才生效
  Future<void> _setLevel(String level) async {
    _manager.settings.logLevel = level;
    await _manager.applySettings();
    if (mounted) setState(_subscribe);
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _lines.map((e) => '[${e.level}] ${e.message}').join('\n')));
    messenger.showSnackBar(const SnackBar(content: Text('已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyword = _keyword.toLowerCase();
    final lines = keyword.isEmpty ? _lines : _lines.where((e) => e.message.toLowerCase().contains(keyword)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('日志'), actions: [
        DropdownButton<String>(
          value: _manager.settings.logLevel,
          underline: const SizedBox.shrink(),
          items: [for (final level in _levels) DropdownMenuItem(value: level, child: Text(level))],
          onChanged: (value) => _setLevel(value!),
        ),
        IconButton(
          tooltip: _paused ? '开始' : '暂停',
          icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
          onPressed: () => setState(() => _paused = !_paused),
        ),
        IconButton(tooltip: '复制', icon: const Icon(Icons.copy), onPressed: _copy),
        IconButton(tooltip: '清空', icon: const Icon(Icons.delete_outline), onPressed: () => setState(_lines.clear)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(hintText: '搜索', prefixIcon: Icon(Icons.search), isDense: true, border: OutlineInputBorder()),
            onChanged: (value) => setState(() => _keyword = value.trim()),
          ),
        ),
        Expanded(
          child: lines.isEmpty
              ? Center(child: Text('还没有日志。级别调到 info 能看到每条连接', style: theme.textTheme.bodySmall))
              : ListView.builder(
                  reverse: true,
                  itemCount: lines.length,
                  itemBuilder: (context, index) {
                    final line = lines[lines.length - 1 - index];
                    final failed = line.level == 'error' || line.level == 'fatal';
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                      child: SelectableText(
                        line.message,
                        style: theme.textTheme.bodySmall?.copyWith(color: failed ? theme.colorScheme.error : null),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// 每天用了多少流量。只记总量，不记访问了什么
class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key});

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  final CoreManager _manager = CoreManager.instance;

  @override
  Widget build(BuildContext context) {
    final settings = _manager.settings;
    final theme = Theme.of(context);
    final days = _manager.trafficStats.days;
    final upload = days.fold<int>(0, (sum, day) => sum + day.upload);
    final download = days.fold<int>(0, (sum, day) => sum + day.download);
    return Scaffold(
      appBar: AppBar(title: const Text('统计'), actions: [
        IconButton(
          tooltip: '清空',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            await _manager.clearTrafficStats();
            if (mounted) setState(() {});
          },
        ),
      ]),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('启用统计'),
          subtitle: const Text('每分钟记一次总量，只记流量大小，不记访问了什么'),
          value: settings.statsEnabled,
          onChanged: (value) async {
            await _manager.setStatsEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          enabled: settings.statsEnabled,
          title: const Text('保留天数'),
          trailing: DropdownButton<int>(
            value: settings.statsDays,
            underline: const SizedBox.shrink(),
            items: [for (final days in const [1, 7, 14, 30]) DropdownMenuItem(value: days, child: Text('$days 天'))],
            onChanged: settings.statsEnabled
                ? (value) {
                    setState(() => settings.statsDays = value!);
                    _manager.saveUiSettings();
                  }
                : null,
          ),
        ),
        const Divider(),
        ListTile(
          title: const Text('合计'),
          trailing: Text('↑ ${formatBytes(upload)}  ↓ ${formatBytes(download)}'),
        ),
        for (final day in days)
          ListTile(
            dense: true,
            title: Text(day.date),
            trailing: Text('↑ ${formatBytes(day.upload)}  ↓ ${formatBytes(day.download)}', style: theme.textTheme.bodySmall),
          ),
      ]),
    );
  }
}
