import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'format.dart';

/// 当前连接。看到某个域名想抓包时，点一下就能加入解密名单，不用再手动输入
class ConnectionsPage extends StatefulWidget {
  final Configuration configuration;

  const ConnectionsPage({super.key, required this.configuration});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  static const Duration _refreshInterval = Duration(seconds: 2);

  final ClashApi _api = CoreManager.instance.api;
  Timer? _timer;
  List<CoreConnection> _connections = const [];
  String _keyword = '';
  bool _loaded = false;
  bool _whitelistChanged = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_whitelistChanged) {
      widget.configuration.flushConfig();
      CoreManager.instance.reloadConfig();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final snapshot = await _api.connections();
      if (!mounted) return;
      setState(() {
        _connections = snapshot.connections;
        _loaded = true;
      });
    } on Exception {
      if (mounted) setState(() => _loaded = true);
    }
  }

  /// a.example.com:443 -> a.example.com。IP 不能加进解密名单
  static String? _domainOf(String host) {
    final name = host.substring(0, host.lastIndexOf(':').clamp(0, host.length));
    return RegExp(r'^[\d.]+$').hasMatch(name) || name.contains(':') || name.isEmpty ? null : name;
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

  void _showActions(CoreConnection connection) {
    final domain = _domainOf(connection.host);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(connection.host), subtitle: Text(_describe(connection))),
          const Divider(height: 1),
          if (domain != null)
            ListTile(
              leading: const Icon(Icons.lock_open),
              title: Text(_isDecrypted(domain) ? '不再解密 $domain' : '解密 $domain'),
              onTap: () {
                Navigator.pop(context);
                _toggleDecrypt(domain);
              },
            ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('断开这条连接'),
            onTap: () {
              Navigator.pop(context);
              _api.closeConnection(connection.id).catchError((_) {});
            },
          ),
        ]),
      ),
    );
  }

  static String _describe(CoreConnection connection) {
    final outbound = connection.chains.isEmpty ? '' : connection.chains.first;
    return [connection.network, if (outbound.isNotEmpty) outbound, if (connection.rule.isNotEmpty) connection.rule]
        .join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final matching = _connections.where((e) => _keyword.isEmpty || e.host.toLowerCase().contains(_keyword)).toList()
      ..sort((a, b) => (b.upload + b.download).compareTo(a.upload + a.download));

    return Scaffold(
      appBar: AppBar(title: Text('连接（${_connections.length}）'), actions: [
        IconButton(
          tooltip: '全部断开',
          icon: const Icon(Icons.clear_all),
          onPressed: () => _api.closeAllConnections().catchError((_) {}),
        ),
      ]),
      body: Column(children: [
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
              : matching.isEmpty
                  ? const Center(child: Text('没有连接'))
                  : ListView.builder(
                      itemCount: matching.length,
                      itemBuilder: (context, index) {
                        final connection = matching[index];
                        final domain = _domainOf(connection.host);
                        return ListTile(
                          dense: true,
                          leading: domain != null && _isDecrypted(domain)
                              ? Icon(Icons.lock_open, size: 18, color: Theme.of(context).colorScheme.primary)
                              : const SizedBox(width: 18),
                          title: Text(connection.host, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_describe(connection), maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Text(formatBytes(connection.upload + connection.download),
                              style: Theme.of(context).textTheme.bodySmall),
                          onTap: () => _showActions(connection),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
