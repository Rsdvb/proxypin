import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/connection_log.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'connect_page.dart';
import 'format.dart';
import 'rule_group_edit_page.dart';

/// 连接列表。看到某个域名想抓包或想分流时，点一下就能加，不用再手动输入
class ConnectionsPage extends StatefulWidget {
  final Configuration configuration;

  const ConnectionsPage({super.key, required this.configuration});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  static const Duration _refreshInterval = Duration(seconds: 1);
  static const Map<ConnectionSort, String> _sortLabels = {
    ConnectionSort.none: '排序：默认',
    ConnectionSort.downloadSpeed: '排序：下载速度',
    ConnectionSort.uploadSpeed: '排序：上传速度',
    ConnectionSort.download: '排序：下载量',
    ConnectionSort.upload: '排序：上传量',
  };

  final CoreManager _manager = CoreManager.instance;
  late final ClashApi _api = _manager.api;
  final ConnectionLog _log = ConnectionLog();
  final ConnectionFilter _filter = ConnectionFilter();
  final Stopwatch _sinceLast = Stopwatch()..start();
  Timer? _timer;
  ConnectionSort _sort = ConnectionSort.none;
  int _active = 0;
  String _keyword = '';
  bool _loaded = false;
  bool _paused = false;
  bool _refreshing = false;
  bool _whitelistChanged = false;
  bool _rulesChanged = false;

  /// 内核自己的连接又绕回了内核
  bool _loopback = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_whitelistChanged) widget.configuration.flushConfig();
    if (_rulesChanged) {
      _manager.applySettings();
    } else if (_whitelistChanged) {
      _manager.reloadConfig();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_paused || _refreshing) return;
    _refreshing = true;
    try {
      final snapshot = await _api.connections();
      if (!mounted) return;
      setState(() {
        _log.update(snapshot.connections, _sinceLast.elapsed);
        _sinceLast.reset();
        _active = snapshot.connections.length;
        _loopback = Platform.isWindows && snapshot.connections.any((e) => e.processName == 'sing-box.exe');
        _loaded = true;
      });
    } on Exception {
      if (mounted) setState(() => _loaded = true);
    } finally {
      _refreshing = false;
    }
  }

  /// 组 -> 节点。内核的 chains 是最后一跳在前
  String _outboundOf(CoreConnection connection) {
    final chains = connection.chains;
    if (chains.isEmpty) return '';
    if (chains.length == 1) return nodeLabel(chains.first);
    return '${nodeLabel(chains[1])} -> ${nodeLabel(chains.first)}';
  }

  bool _isDecrypted(String domain) => HostFilter.whitelist.list.any((rule) => rule.hasMatch(domain));

  void _toggleDecrypt(String domain) {
    setState(() {
      if (_isDecrypted(domain)) {
        HostFilter.whitelist.remove(domain);
      } else {
        HostFilter.whitelist.add(domain);
      }
      _whitelistChanged = true;
    });
  }

  /// 选一个分流组，再把这一项带进编辑页。不直接保存：用户通常还想看一眼
  Future<void> _addToRule(String field, String value) async {
    final groups = _manager.settings.groups;
    const creating = -1;
    final chosen = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建分流组'),
              onTap: () => Navigator.pop(context, creating),
            ),
            for (final (index, group) in groups.indexed)
              ListTile(title: Text(group.name), onTap: () => Navigator.pop(context, index)),
          ]),
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    final group = chosen == creating ? null : groups[chosen];
    final result = await Navigator.of(context).push<RuleGroupEdit>(MaterialPageRoute(
      builder: (_) => EditRuleGroupPage(
        group: group,
        otherNames: {for (final other in groups) if (!identical(other, group)) other.name},
        prefill: {field: value},
      ),
    ));
    if (result == null) return;
    final settings = _manager.settings;
    if (result.remove) {
      settings.groups = groups.where((e) => !identical(e, group)).toList();
    } else if (group == null) {
      settings.groups = [result.group!, ...groups];
    } else {
      settings.groups = [for (final item in groups) identical(item, group) ? result.group! : item];
    }
    _rulesChanged = true;
  }

  void _showActions(ConnectionRow row) {
    final connection = row.sample;
    final domain = connection.domain;
    final desktop = Platform.isWindows && connection.processPath.isNotEmpty;

    Widget ruleItem(String label, String field, String value, {String? shown}) => ListTile(
          dense: true,
          title: Text('$label：${shown ?? value}', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.pop(context);
            _addToRule(field, value);
          },
        );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              title: Text(connection.host, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(_outboundOf(connection)),
            ),
            const Divider(height: 1),
            if (domain.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.lock_open),
                title: Text(_isDecrypted(domain) ? '不再解密 $domain' : '解密 $domain', maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  Navigator.pop(context);
                  _toggleDecrypt(domain);
                },
              ),
            if (row.isActive)
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(row.activeIds.length > 1 ? '断开这 ${row.activeIds.length} 条连接' : '断开这条连接'),
                onTap: () {
                  Navigator.pop(context);
                  for (final id in row.activeIds) {
                    _api.closeConnection(id).catchError((_) {});
                  }
                },
              ),
            const Divider(height: 1),
            const ListTile(dense: true, title: Text('加入分流规则')),
            if (domain.isNotEmpty) ruleItem('域名', 'domains', domain),
            if (connection.destination.isNotEmpty) ruleItem('IP', 'ipCidrs', connection.destination),
            if (connection.port.isNotEmpty) ruleItem('端口', 'ports', connection.port),
            if (desktop) ...[
              ruleItem('进程名', 'processNames', connection.processName),
              ruleItem('进程路径', 'processPaths', connection.processPath, shown: connection.processName),
            ],
          ]),
        ),
      ),
    );
  }

  Future<void> _openFilter() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConnectionFilterPage(rows: _log.rows, filter: _filter, outboundOf: _outboundOf),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _copyCsv() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: ConnectionView.toCsv(ConnectionView.sorted(_log.rows, _sort), _outboundOf)));
    messenger.showSnackBar(const SnackBar(content: Text('已复制为 CSV 格式')));
  }

  Future<void> _openMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: Icon(_paused ? Icons.play_arrow : Icons.pause),
            title: Text(_paused ? '开始' : '暂停'),
            onTap: () {
              Navigator.pop(context);
              setState(() => _paused = !_paused);
            },
          ),
          ListTile(
            leading: const Icon(Icons.filter_list),
            title: const Text('过滤'),
            onTap: () {
              Navigator.pop(context);
              _openFilter();
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('拷贝'),
            onTap: () {
              Navigator.pop(context);
              _copyCsv();
            },
          ),
          ListTile(
            leading: const Icon(Icons.clear_all),
            title: const Text('全部断开'),
            onTap: () {
              Navigator.pop(context);
              _api.closeAllConnections().catchError((_) {});
            },
          ),
          const Divider(height: 1),
          for (final entry in _sortLabels.entries)
            ListTile(
              dense: true,
              title: Text(entry.value),
              trailing: _sort == entry.key ? const Icon(Icons.check) : null,
              onTap: () {
                Navigator.pop(context);
                setState(() => _sort = entry.key);
              },
            ),
        ]),
      ),
    );
  }

  Widget _rowTile(ConnectionRow row, int number, DateTime now) {
    final theme = Theme.of(context);
    final connection = row.sample;
    final small = theme.textTheme.bodySmall;
    final domain = connection.domain;
    final speed = TextStyle(fontSize: small?.fontSize, color: Colors.green);
    return InkWell(
      onTap: () => _showActions(row),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 8),
            child: Icon(Icons.circle, size: 8, color: row.isActive ? Colors.green : theme.disabledColor),
          ),
          SizedBox(width: 24, child: Text('$number', style: small)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (domain.isNotEmpty && _isDecrypted(domain))
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.lock_open, size: 14, color: theme.colorScheme.primary),
                  ),
                Expanded(child: Text(ConnectionView.shortHost(connection.host), maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text(ConnectionView.formatDuration(row.durationAt(now)), style: small),
              ]),
              Text.rich(
                TextSpan(style: small, children: [
                  TextSpan(text: '${connection.source} · ${connection.network} '),
                  TextSpan(
                    text: '(${row.activeIds.length}:${row.closed})',
                    style: row.activeIds.length > 100 ? TextStyle(color: theme.colorScheme.error) : null,
                  ),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (connection.processName.isNotEmpty) Text(connection.processName, style: small),
              Text.rich(
                TextSpan(style: small, children: [
                  TextSpan(text: '↑ ${formatBytes(row.upload)} ↓ ${formatBytes(row.download)}'),
                  if (row.uploadSpeed > 0) TextSpan(text: '  ↑ ${formatBytes(row.uploadSpeed)}/s', style: speed),
                  if (row.downloadSpeed > 0) TextSpan(text: '  ↓ ${formatBytes(row.downloadSpeed)}/s', style: speed),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (connection.ruleName.isNotEmpty)
                Text(connection.ruleName, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(_outboundOf(connection), style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final rows = ConnectionView.sorted(
      _log.rows
          .where((e) => _filter.matches(e, _outboundOf))
          .where((e) => _keyword.isEmpty || e.sample.host.toLowerCase().contains(_keyword))
          .toList(),
      _sort,
    );

    return Scaffold(
      appBar: AppBar(title: Text('连接（$_active）'), actions: [
        if (_paused) IconButton(tooltip: '开始', icon: const Icon(Icons.play_arrow), onPressed: () => setState(() => _paused = false)),
        if (!_filter.isEmpty)
          IconButton(tooltip: '已过滤', icon: Icon(Icons.filter_list, color: theme.colorScheme.primary), onPressed: _openFilter),
        IconButton(tooltip: '更多', icon: const Icon(Icons.more_vert), onPressed: _openMenu),
      ]),
      body: Column(children: [
        if (_loopback)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('网络可能出现了回环，请检查网卡设置', style: TextStyle(color: theme.colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
                hintText: '搜索域名', prefixIcon: Icon(Icons.search), isDense: true, border: OutlineInputBorder()),
            onChanged: (value) => setState(() => _keyword = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
                  ? const Center(child: Text('没有连接'))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _rowTile(rows[index], index + 1, now),
                    ),
        ),
      ]),
    );
  }
}

/// 按实际出现过的值过滤连接
class ConnectionFilterPage extends StatefulWidget {
  final List<ConnectionRow> rows;
  final ConnectionFilter filter;
  final String Function(CoreConnection) outboundOf;

  const ConnectionFilterPage({super.key, required this.rows, required this.filter, required this.outboundOf});

  @override
  State<ConnectionFilterPage> createState() => _ConnectionFilterPageState();
}

class _ConnectionFilterPageState extends State<ConnectionFilterPage> {
  final TextEditingController _search = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> _values(String Function(CoreConnection) read) =>
      widget.rows.map((e) => read(e.sample)).where((e) => e.isNotEmpty).toSet().toList()..sort();

  /// 关键词同时按包含和正则匹配，正则写错时只按包含
  bool Function(String) _matcher() {
    final keyword = _keyword.toLowerCase();
    if (keyword.isEmpty) return (_) => true;
    RegExp? regex;
    try {
      regex = RegExp(_keyword, caseSensitive: false);
    } on FormatException {
      regex = null;
    }
    return (value) => value.toLowerCase().contains(keyword) || regex?.hasMatch(value) == true;
  }

  List<Widget> _section(String title, List<String> values, Set<String> chosen, bool Function(String) matches) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final value in values.where(matches))
        CheckboxListTile(
          dense: true,
          title: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
          value: chosen.contains(value),
          onChanged: (selected) => setState(() => selected == true ? chosen.add(value) : chosen.remove(value)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final matches = _matcher();
    return Scaffold(
      appBar: AppBar(title: const Text('过滤'), actions: [
        IconButton(tooltip: '清空', icon: const Icon(Icons.delete_outline), onPressed: () => setState(filter.clear)),
        IconButton(tooltip: '完成', icon: const Icon(Icons.check), onPressed: () => Navigator.of(context).pop()),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: '搜索',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _keyword.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        setState(() => _keyword = '');
                      },
                    ),
            ),
            onChanged: (value) => setState(() => _keyword = value.trim()),
          ),
        ),
        Expanded(
          child: ListView(children: [
            ..._section('tcp/udp', _values((e) => e.network), filter.networks, matches),
            ..._section('域名/IP', _values((e) => e.domain.isNotEmpty ? e.domain : e.destination), filter.hosts, matches),
            ..._section('端口', _values((e) => e.port), filter.ports, matches),
            if (!Platform.isIOS) ..._section('应用', _values((e) => e.processName), filter.apps, matches),
            ..._section('规则', _values((e) => e.ruleName), filter.rules, matches),
            ..._section('出站', _values(widget.outboundOf), filter.outbounds, matches),
          ]),
        ),
      ]),
    );
  }
}
