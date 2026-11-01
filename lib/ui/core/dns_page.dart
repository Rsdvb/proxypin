import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/dns_catalog.dart';

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
    if (!RegExp(r'^[\w-]+(\.[\w-]+)+$').hasMatch(text)) {
      _show('无效的域名');
      return;
    }
    _change(() => _dns.testDomain = text);
  }

  Future<void> _editTtl() async {
    final text = await _askText('TTL（秒），留空保持原样', _dns.ttl?.toString() ?? '', number: true, allowEmpty: true);
    if (text == null) return;
    final value = int.tryParse(text);
    _change(() => _dns.ttl = value?.clamp(5, 365 * 86400));
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

  Future<void> _autoSetup() async {
    if (!_manager.isRunning) {
      _show('连接后才能测试 DNS');
      return;
    }
    _show('正在测试，请稍候');
    final best = await DnsAutoSetup.run(_manager);
    if (!mounted) return;
    _change(() {
      if (best.direct != null) {
        _dns
          ..direct = best.direct!
          ..outbound = best.direct!;
      }
      if (best.resolver != null) _dns.resolver = best.resolver!;
      if (best.proxy != null) _dns.proxy = best.proxy!;
    });
    _show('已设置为延迟最低的服务器');
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

  Widget _server(String title, String tip, String value, DnsRole role) {
    return ListTile(
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
        _server('直连', '用于直连流量的域名解析', dns.direct, DnsRole.direct),
        _server('代理', '用于代理流量的域名解析', dns.proxy, DnsRole.proxy),
        SwitchListTile(
          title: const Text('优先静态解析'),
          subtitle: const Text('有效防止 DNS 服务器本身解析时被污染'),
          value: dns.staticIpForResolver,
          onChanged: (value) => _change(() => dns.staticIpForResolver = value),
        ),
        ListTile(title: const Text('自动设置服务器'), onTap: _autoSetup),
        ListTile(title: const Text('重置服务器'), onTap: _reset),
      ]),
    );
  }
}

enum DnsRole { resolver, outbound, direct, proxy }

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
  final Map<String, int?> _direct = {};
  final Map<String, int?> _proxied = {};
  bool _testing = false;
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

  /// 同时测的上限，太多会把内核的连接数占满
  static const int _concurrency = 5;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _direct.clear();
      _proxied.clear();
    });
    final proxyPort = _manager.isRunning ? _manager.settings.upstreamPort : null;
    final queue = _servers.where((e) => !_isSystem(e.url)).toList();
    Future<void> worker() async {
      while (queue.isNotEmpty && mounted) {
        final url = queue.removeLast().url;
        final direct = await CoreTools.dnsLatency(url);
        final proxied = proxyPort == null ? null : await CoreTools.dnsLatency(url, proxyPort: proxyPort);
        if (!mounted) return;
        setState(() {
          _direct[url] = direct;
          _proxied[url] = proxied;
        });
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    if (mounted) setState(() => _testing = false);
  }

  static bool _isSystem(String url) => url == DnsCatalog.local || url == DnsCatalog.dhcp;

  Future<void> _add() async {
    final provider = TextEditingController();
    final url = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 DNS 服务器'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: provider, decoration: const InputDecoration(labelText: '名称')),
          TextField(
            controller: url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '地址', hintText: 'https://dns.example/dns-query'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('添加')),
        ],
      ),
    );
    final name = provider.text.trim(), address = url.text.trim();
    provider.dispose();
    url.dispose();
    if (added != true || !mounted) return;

    final uri = Uri.tryParse(address);
    if (name.isEmpty || uri == null || uri.host.isEmpty || !DnsCatalog.schemes.contains(uri.scheme)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('地址无效，支持 udp、tcp、tls、https、h3、quic')));
      return;
    }
    if (_servers.any((e) => e.url == address)) return;
    setState(() {
      _dns.custom = [..._dns.custom, DnsServer(name, address).toJson()];
      _changed = true;
    });
  }

  void _remove(String url) {
    setState(() {
      _dns.custom = _dns.custom.where((e) => e['url'] != url).toList();
      _changed = true;
    });
  }

  Widget _latency(int? value, bool tested) {
    final text = !tested ? '' : (value == null ? '失败' : '$value');
    return SizedBox(width: 44, child: Text(text, textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall));
  }

  @override
  Widget build(BuildContext context) {
    final servers = _servers;
    final custom = _dns.custom.map((e) => e['url']).toSet();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title), actions: [
          IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
          IconButton(
            tooltip: '测延迟',
            icon: _testing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bolt_outlined),
            onPressed: _testing ? null : _test,
          ),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('第一列是直连延迟，第二列是经当前节点的延迟，都是连接耗时（毫秒）。官方内核每类只能用一个服务器。',
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
                    _latency(_direct[server.url], _direct.containsKey(server.url)),
                    _latency(_proxied[server.url], _proxied.containsKey(server.url)),
                    if (custom.contains(server.url))
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

  static final RegExp _ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  Future<void> _add() async {
    final domain = TextEditingController();
    final ips = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加静态 IP'),
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
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('添加')),
        ],
      ),
    );
    final host = domain.text.trim();
    final addresses = ips.text.split(',').map((e) => e.trim()).where((e) => _ipv4.hasMatch(e) || e.contains(':')).toList();
    domain.dispose();
    ips.dispose();
    if (added == true && host.contains('.') && addresses.isNotEmpty) {
      _change(() => _dns.staticIps = {..._dns.staticIps, host: addresses});
    }
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
          IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
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

/// 自动选 DNS：挑延迟最低的。用 IP 地址的服务器才进候选，不用先解析
class DnsAutoSetup {
  final String? direct;
  final String? resolver;
  final String? proxy;

  const DnsAutoSetup(this.direct, this.resolver, this.proxy);

  static Future<DnsAutoSetup> run(CoreManager manager) async {
    final candidates = DnsCatalog.servers
        .where((e) => !e.usesHostName && e.url != DnsCatalog.local && e.url != DnsCatalog.dhcp)
        .where((e) => !e.url.contains('[')) // 默认不开 IPv6
        .map((e) => e.url)
        .toList();

    Future<String?> fastest(Iterable<String> urls, {int? proxyPort}) async {
      final results = await Future.wait(urls.map((url) async => (url, await CoreTools.dnsLatency(url, proxyPort: proxyPort))));
      final reachable = results.where((e) => e.$2 != null).toList()..sort((a, b) => a.$2!.compareTo(b.$2!));
      return reachable.isEmpty ? null : reachable.first.$1;
    }

    final direct = await fastest(candidates.where((e) => e.startsWith('udp://') || e.startsWith('https://')));
    final resolver = await fastest(candidates.where((e) => e.startsWith('udp://')));
    final proxy = await fastest(candidates.where((e) => e.startsWith('https://') || e.startsWith('tls://')),
        proxyPort: manager.settings.upstreamPort);
    return DnsAutoSetup(direct, resolver, proxy);
  }
}
