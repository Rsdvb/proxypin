import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/dns_catalog.dart';
import 'package:proxypin/core/dns_probe.dart';
import 'package:proxypin/core/rule_group.dart';

/// DNS 设置。直接改设置对象，离开页面时保存一次，运行中会重载内核
class DnsPage extends StatefulWidget {
  const DnsPage({super.key});

  @override
  State<DnsPage> createState() => _DnsPageState();
}

class _DnsPageState extends State<DnsPage> {
  final CoreManager _manager = CoreManager.instance;
  bool _changed = false;

  DnsSettings get _dns => _manager.settings.dns;

  TunSettings get _tun => _manager.settings.tunSettings;

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

  Future<void> _push(Widget page) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    setState(() {
      if (changed == true) _changed = true;
    });
  }

  Future<void> _editTestDomain() async {
    final text = await _askText('测试域名', _dns.testDomain);
    if (text == null) return;
    if (!RuleChecks.isDomain(text) || !text.contains('.')) {
      _show('无效的域名');
      return;
    }
    _change(() => _dns.testDomain = text);
  }

  Future<void> _editTtl() async {
    final text = await _askText('TTL（秒），留空保持原样', _dns.ttl?.toString() ?? '', number: true, allowEmpty: true);
    if (text == null) return;
    final value = int.tryParse(text);
    _change(() => _dns.ttl = value?.clamp(DnsSettings.minTtl, DnsSettings.maxTtl));
  }

  Future<String?> _askText(String title, String initial, {bool number = false, bool allowEmpty = false}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          keyboardType: number ? TextInputType.number : TextInputType.text,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return result == null || (result.isEmpty && !allowEmpty) ? null : result;
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _reset() {
    _change(() {
      _dns
        ..resolver = DnsCatalog.local
        ..outbound = DnsCatalog.local
        ..direct = DnsCatalog.local
        ..proxy = DnsSettings.defaultProxy;
    });
    _show('已恢复默认服务器');
  }

  Widget _server(String title, String tip, String value, DnsRole role, {bool enabled = true}) {
    return ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: Text('$tip\n$value', maxLines: 3, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _push(DnsServerPage(title: title, role: role)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dns = _dns;
    final hijack = _tun.hijackDns;
    return Scaffold(
      appBar: AppBar(title: const Text('DNS')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('TUN HijackDNS'),
          subtitle: const Text('关闭后，来自 TUN 的 DNS 请求会被直接转发给对应的 DNS 服务器'),
          value: hijack,
          onChanged: (value) => _change(() => _tun.hijackDns = value),
        ),
        SwitchListTile(
          title: const Text('解析入站域名'),
          subtitle: const Text('某些没有分流规则的域名要解析后才可能命中基于 IP 的规则，影响本地代理端口的入站请求'),
          value: dns.inboundDomainResolve,
          onChanged: (value) => _change(() => dns.inboundDomainResolve = value),
        ),
        ListTile(
          title: const Text('静态 IP'),
          subtitle: Text(dns.staticIp ? '已开启，${dns.staticIps.length} 条' : '未开启'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(const StaticIpPage()),
        ),
        ListTile(title: const Text('测试域名'), trailing: Text(dns.testDomain), onTap: _editTestDomain),
        ListTile(
          title: const Text('TTL'),
          trailing: Text(dns.ttl == null ? '保持原样' : '${dns.ttl} 秒'),
          onTap: _editTtl,
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('启用 DNS 分流规则'),
          subtitle: const Text('域名会根据分流规则选择对应的 DNS 服务器解析'),
          value: dns.enableRule,
          onChanged: hijack ? (value) => _change(() => dns.enableRule = value) : null,
        ),
        SwitchListTile(
          title: const Text('直连启用 ECS'),
          subtitle: const Text('让 CDN 返回离你更近的地址。直连 DNS 选系统 DNS 时不起作用'),
          value: dns.clientSubnet,
          onChanged: hijack ? (value) => _change(() => dns.clientSubnet = value) : null,
        ),
        ListTile(
          title: const Text('代理解析通道'),
          subtitle: const Text('当前选择：通过节点连接 DNS 服务器\n直连：直接连接 DNS 服务器\nFakeIP：由节点代为解析，断开后应用可能要重启，只对 TUN 生效'),
          isThreeLine: true,
          trailing: DropdownButton<ProxyResolve>(
            value: dns.proxyResolve,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: ProxyResolve.fakeip, child: Text('FakeIP')),
              DropdownMenuItem(value: ProxyResolve.proxy, child: Text('当前选择')),
              DropdownMenuItem(value: ProxyResolve.direct, child: Text('直连')),
            ],
            onChanged: hijack
                ? (value) {
                    if (value != null) _change(() => dns.proxyResolve = value);
                  }
                : null,
          ),
        ),
        const Divider(height: 1),
        _server('DNS 服务器', '用于解析其他 DNS 服务器的域名', dns.resolver, DnsRole.resolver),
        _server('代理服务器', '用于解析节点的域名', dns.outbound, DnsRole.outbound),
        _server('直连', '用于直连流量的域名解析', dns.direct, DnsRole.direct, enabled: hijack),
        _server('代理', '用于代理流量的域名解析', dns.proxy, DnsRole.proxy, enabled: hijack),
        SwitchListTile(
          title: const Text('优先静态解析'),
          subtitle: const Text('有效防止 DNS 服务器本身解析时被污染'),
          value: dns.staticIpForResolver,
          onChanged: (value) => _change(() => dns.staticIpForResolver = value),
        ),
        ListTile(
          title: const Text('自动设置服务器'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(const DnsAutoSetupPage()),
        ),
        ListTile(title: const Text('重置服务器'), onTap: _reset),
      ]),
    );
  }
}

enum DnsRole { resolver, outbound, direct, proxy }

/// 测过的延迟留在这里，离开页面再回来还在，选服务器和自动设置看的是同一份
class DnsLatencyBoard extends ChangeNotifier {
  static final DnsLatencyBoard instance = DnsLatencyBoard();

  /// 同时测的上限，太多会把内核的连接数占满
  static const int _concurrency = 5;

  final Map<String, int?> direct = {};
  final Map<String, int?> node = {};
  bool testing = false;

  Future<void> test(CoreManager manager, Iterable<String> urls) async {
    if (testing) return;
    testing = true;
    direct.clear();
    node.clear();
    notifyListeners();

    final running = manager.isRunning;
    final queue = urls.toList();
    Future<void> worker() async {
      // 测到一半连接状态变了，走的就不是同一条路了，后面的不用测
      while (queue.isNotEmpty && manager.isRunning == running) {
        await testOne(manager, queue.removeLast());
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    testing = false;
    notifyListeners();
  }

  Future<void> testOne(CoreManager manager, String url) async {
    final domain = manager.settings.dns.testDomain;
    final system = url == DnsCatalog.local || url == DnsCatalog.dhcp;
    final nodeProbe = manager.nodeProbe;
    final results = await Future.wait([
      DnsProbe.measure(url, domain, route: system ? null : manager.directProbe),
      if (nodeProbe != null) DnsProbe.measure(url, domain, route: nodeProbe),
    ]);
    direct[url] = results.first;
    if (results.length > 1) node[url] = results.last;
    notifyListeners();
  }
}

/// 一行里的两列延迟。点一下只重测这一行
class _LatencyColumns extends StatelessWidget {
  final CoreManager manager;
  final String url;

  const _LatencyColumns(this.manager, this.url);

  @override
  Widget build(BuildContext context) {
    final board = DnsLatencyBoard.instance;
    Widget cell(Map<String, int?> results) {
      final tested = results.containsKey(url);
      final value = results[url];
      final text = !tested ? '' : (value == null ? '失败' : (value == DnsProbe.unsupported ? '不支持' : '$value'));
      return SizedBox(width: 44, child: Text(text, textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall));
    }

    return InkWell(
      onTap: board.testing ? null : () => board.testOne(manager, url),
      child: Row(mainAxisSize: MainAxisSize.min, children: [cell(board.direct), cell(board.node)]),
    );
  }
}

/// 选一个 DNS 服务器，可以看延迟，也可以加自己的
class DnsServerPage extends StatefulWidget {
  final String title;
  final DnsRole role;

  const DnsServerPage({super.key, required this.title, required this.role});

  @override
  State<DnsServerPage> createState() => _DnsServerPageState();
}

class _DnsServerPageState extends State<DnsServerPage> {
  final CoreManager _manager = CoreManager.instance;
  final DnsLatencyBoard _board = DnsLatencyBoard.instance;
  bool _changed = false;

  DnsSettings get _dns => _manager.settings.dns;

  String get _current => switch (widget.role) {
        DnsRole.resolver => _dns.resolver,
        DnsRole.outbound => _dns.outbound,
        DnsRole.direct => _dns.direct,
        DnsRole.proxy => _dns.proxy,
      };

  void _select(String url) {
    setState(() {
      switch (widget.role) {
        case DnsRole.resolver:
          _dns.resolver = url;
        case DnsRole.outbound:
          _dns.outbound = url;
        case DnsRole.direct:
          _dns.direct = url;
        case DnsRole.proxy:
          _dns.proxy = url;
      }
      _changed = true;
    });
  }

  List<DnsServer> get _servers => [
        ..._dns.custom.map(DnsServer.fromJson),
        ...DnsCatalog.servers,
      ];

  Future<void> _add() async {
    final provider = TextEditingController();
    final url = TextEditingController();
    String? error;
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('添加 DNS 服务器'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: provider, decoration: const InputDecoration(labelText: '名称')),
            TextField(
              controller: url,
              autocorrect: false,
              decoration: InputDecoration(labelText: '地址', hintText: 'https://dns.example/dns-query', errorText: error),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(
              onPressed: () {
                final problem = provider.text.trim().isEmpty
                    ? '请填写名称'
                    : (DnsSettings.isValidServer(url.text.trim()) ? null : '地址无效，支持 udp、tcp、tls、https、h3、quic');
                if (problem == null) return Navigator.pop(context, true);
                setDialog(() => error = problem);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    final name = provider.text.trim(), address = url.text.trim();
    provider.dispose();
    url.dispose();
    if (added != true || !mounted || _servers.any((e) => e.url == address)) return;
    setState(() {
      _dns.custom = [..._dns.custom, DnsServer(name, address).toJson()];
      _changed = true;
    });
  }

  /// 删掉的服务器正在用的话，那一项回到默认，否则下次连接时配置里还是它
  void _remove(String url) {
    setState(() {
      _dns.custom = _dns.custom.where((e) => e['url'] != url).toList();
      if (_dns.resolver == url) _dns.resolver = DnsCatalog.local;
      if (_dns.outbound == url) _dns.outbound = DnsCatalog.local;
      if (_dns.direct == url) _dns.direct = DnsCatalog.local;
      if (_dns.proxy == url) _dns.proxy = DnsSettings.defaultProxy;
      _changed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: ListenableBuilder(
        listenable: _board,
        builder: (context, _) {
          final servers = _servers;
          final custom = _dns.custom.map((e) => e['url']).toSet();
          return Scaffold(
            appBar: AppBar(title: Text(widget.title), actions: [
              IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
              IconButton(
                tooltip: '测延迟',
                icon: _board.testing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt_outlined),
                onPressed: _board.testing ? null : () => _board.test(_manager, servers.map((e) => e.url)),
              ),
            ]),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                    '第一列是直连延迟，第二列是经当前节点的延迟，单位毫秒，测的是查询 ${_dns.testDomain} 的耗时。点数字重测这一行。官方内核每类只能用一个服务器。',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: servers.length,
                  itemBuilder: (context, index) {
                    final server = servers[index];
                    final disabled = widget.role == DnsRole.resolver && server.usesHostName;
                    return ListTile(
                      enabled: !disabled,
                      dense: true,
                      leading: Icon(server.url == _current ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                      title: Text(server.provider),
                      subtitle: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        _LatencyColumns(_manager, server.url),
                        if (custom.contains(server.url) && !_board.testing)
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.remove_circle_outline, size: 20),
                            onPressed: () => _remove(server.url),
                          ),
                      ]),
                      onTap: disabled ? null : () => _select(server.url),
                    );
                  },
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

/// 自定义域名解析：域名和 IP，一个域名可以有多个 IP
class StaticIpPage extends StatefulWidget {
  const StaticIpPage({super.key});

  @override
  State<StaticIpPage> createState() => _StaticIpPageState();
}

class _StaticIpPageState extends State<StaticIpPage> {
  final DnsSettings _dns = CoreManager.instance.settings.dns;
  bool _changed = false;

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  /// [host] 不为空时是修改已有的一条
  Future<void> _edit([String? host]) async {
    final domain = TextEditingController(text: host);
    final ips = TextEditingController(text: _dns.staticIps[host]?.join(', '));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(host == null ? '添加静态 IP' : '修改静态 IP'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: domain,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '域名', hintText: 'google.com'),
          ),
          TextField(
            controller: ips,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'IP，多个用逗号隔开', hintText: '93.46.8.90'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    final name = domain.text.trim();
    final addresses = ips.text.split(',').map((e) => e.trim()).where((e) => InternetAddress.tryParse(e) != null).toList();
    domain.dispose();
    ips.dispose();
    if (saved != true || !mounted) return;
    if (!RuleChecks.isDomain(name) || addresses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('域名或 IP 格式不对')));
      return;
    }
    _change(() {
      final entries = {..._dns.staticIps}..remove(host);
      _dns.staticIps = {...entries, name: addresses};
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _dns.staticIps.entries.toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('静态 IP'), actions: [
          IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _edit),
        ]),
        body: ListView(children: [
          SwitchListTile(
            title: const Text('启用'),
            subtitle: const Text('需要开启 TUN HijackDNS 或解析入站域名'),
            value: _dns.staticIp,
            onChanged: (value) => _change(() => _dns.staticIp = value),
          ),
          for (final entry in entries)
            ListTile(
              title: Text(entry.key),
              subtitle: Text(entry.value.join(', ')),
              onTap: () => _edit(entry.key),
              trailing: IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => _change(() => _dns.staticIps = {..._dns.staticIps}..remove(entry.key)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// 从测好的延迟里挑每种用途最快的服务器
class DnsAutoSetup {
  final String? direct;
  final String? resolver;
  final String? proxy;

  const DnsAutoSetup(this.direct, this.resolver, this.proxy);

  bool get isEmpty => direct == null && resolver == null && proxy == null;

  /// 系统 DNS 不进候选，它有缓存，总是最快。解析其他 DNS 的只能用 IP 地址的服务器，
  /// 代理流量不用明文，免得节点上被看到。[node] 有结果且代理 DNS 确实走节点时按节点延迟挑
  static DnsAutoSetup choose(
    List<DnsServer> servers,
    Map<String, int?> direct,
    Map<String, int?> node,
    ProxyResolve resolve,
  ) {
    String? fastest(Iterable<DnsServer> candidates, Map<String, int?> latency) {
      final reachable = candidates.where((e) => (latency[e.url] ?? -1) >= 0).toList()
        ..sort((a, b) => latency[a.url]!.compareTo(latency[b.url]!));
      return reachable.isEmpty ? null : reachable.first.url;
    }

    final measured = servers.where((e) => e.url != DnsCatalog.local && e.url != DnsCatalog.dhcp);
    final encrypted = measured.where((e) => !e.url.startsWith('udp://') && !e.url.startsWith('tcp://'));
    return DnsAutoSetup(
      fastest(measured, direct),
      fastest(measured.where((e) => !e.usesHostName), direct),
      fastest(encrypted, resolve != ProxyResolve.direct && node.isNotEmpty ? node : direct),
    );
  }

  void applyTo(DnsSettings dns) {
    if (direct != null) {
      dns
        ..direct = direct!
        ..outbound = direct!;
    }
    if (resolver != null) dns.resolver = resolver!;
    if (proxy != null) dns.proxy = proxy!;
  }
}

/// 测全部服务器，把每种用途换成最快的
class DnsAutoSetupPage extends StatefulWidget {
  const DnsAutoSetupPage({super.key});

  @override
  State<DnsAutoSetupPage> createState() => _DnsAutoSetupPageState();
}

class _DnsAutoSetupPageState extends State<DnsAutoSetupPage> {
  final CoreManager _manager = CoreManager.instance;
  final DnsLatencyBoard _board = DnsLatencyBoard.instance;
  bool _changed = false;

  DnsSettings get _dns => _manager.settings.dns;

  /// 没开 IPv6 时 IPv6 地址的服务器连不上
  List<DnsServer> get _servers => [
        ..._dns.custom.map(DnsServer.fromJson),
        ...DnsCatalog.servers,
      ].where((e) => _manager.settings.ipStrategy != IpStrategy.ipv4Only || !e.url.contains('[')).toList();

  Future<void> _start() async {
    final servers = _servers;
    await _board.test(_manager, servers.map((e) => e.url));
    final best = DnsAutoSetup.choose(servers, _board.direct, _board.node, _dns.proxyResolve);
    if (best.isEmpty) return _show('全部测试失败，没有修改');
    best.applyTo(_dns);
    if (mounted) {
      _changed = true;
      _show('已设置为延迟最低的服务器');
    } else {
      await _manager.applySettings();
    }
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: ListenableBuilder(
        listenable: _board,
        builder: (context, _) {
          final servers = _servers;
          return Scaffold(
            appBar: AppBar(title: const Text('自动设置服务器'), actions: [
              IconButton(
                tooltip: '开始',
                icon: _board.testing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt_outlined),
                onPressed: _board.testing ? null : _start,
              ),
            ]),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _manager.isRunning ? '点闪电开始，测完自动换成每种用途延迟最低的服务器。' : '还没有连接，只能测直连延迟。代理 DNS 走节点，连接后再测更准。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: servers.length,
                  itemBuilder: (context, index) {
                    final server = servers[index];
                    return ListTile(
                      dense: true,
                      title: Text(server.provider),
                      subtitle: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: _LatencyColumns(_manager, server.url),
                    );
                  },
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}
