import 'clash_routing.dart';
import 'core_settings.dart';
import 'dns_catalog.dart';
import 'rule_group.dart';
import 'rule_sets.dart';
import 'share_link.dart';

/// 路由模式，切换时不需要重载配置，见 [CoreConfig.clashModeOf]
enum RouteMode { rule, global }

/// 生成 sing-box 配置所需的全部输入
class CoreOptions {
  /// 当前配置的节点
  final List<Outbound> nodes;

  /// 首页选中的节点 tag，空表示自动选择
  final String? selected;
  final List<RuleGroup> groups;

  /// 机场的分流规则，排在用户的分流组之后
  final ProviderRouting? providerRouting;

  /// 机场规则里可用的规则集
  final Set<String> providerRuleSets;

  /// 都没命中时的去向。[RuleTarget.selected] 时听机场规则的 MATCH
  final String finalTarget;

  /// 配置自带的 DNS，优先用来解析节点域名
  final String? outboundDns;
  final DnsSettings dns;
  final TunSettings tunSettings;
  final IpStrategy ipStrategy;

  /// 私有网络直连
  final bool privateDirect;

  /// Windows TUN 下不能用系统 DNS：系统把请求发回 TUN，就绕回来了（sing-box#1592）
  final bool avoidLocalDns;

  /// iOS 走 TUN；Windows 默认走本地代理，也可以开 TUN
  final bool tun;

  /// 本地代理端口，系统代理指向这里。0 表示不开
  final int mixedPort;

  /// 解密后的流量从这个端口回到 sing-box 出站
  final int upstreamPort;

  /// RsProxy 解密端口
  final int mitmPort;

  /// 测 DNS 延迟用的入站，0 表示不开
  final int probePort;

  /// 代理设置里绕过的域名
  final List<String> proxyBypass;

  /// 要解密的域名后缀，null 表示全部 TCP 都交给 RsProxy，由它按规则判断
  final List<String>? mitmDomains;

  final int clashPort;
  final String clashSecret;
  final String clashDefaultMode;

  /// 规则集目录，里面是 assets/rules 的文件
  final String ruleSetDirectory;
  final String cachePath;

  final String testUrl;
  final String logLevel;

  CoreOptions({
    required this.nodes,
    this.selected,
    this.groups = const [],
    this.providerRouting,
    this.providerRuleSets = const {},
    this.finalTarget = RuleTarget.selected,
    this.outboundDns,
    DnsSettings? dns,
    TunSettings? tunSettings,
    this.ipStrategy = IpStrategy.ipv4Only,
    this.privateDirect = true,
    this.avoidLocalDns = false,
    this.tun = false,
    this.mixedPort = 0,
    required this.upstreamPort,
    required this.mitmPort,
    this.probePort = 0,
    this.proxyBypass = const [],
    this.mitmDomains = const [],
    required this.clashPort,
    required this.clashSecret,
    this.clashDefaultMode = 'Rule',
    required this.ruleSetDirectory,
    required this.cachePath,
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.logLevel = 'warn',
  })  : dns = dns ?? DnsSettings(),
        tunSettings = tunSettings ?? TunSettings();

  bool get ipv6 => ipStrategy != IpStrategy.ipv4Only;
}

/// 把节点、分流组和解密名单组装成 sing-box 配置。
///
/// 流量路径：
/// ```text
/// 应用 -> tun-in / mixed-in -> 路由
///   名单内的域名 -> rs-mitm -> RsProxy 解密 -> upstream-in -> 路由（不再进 rs-mitm） -> 节点
///   其他流量     -> 按分流组走节点、直连或拦截
/// ```
class CoreConfig {
  static const String _tagSelect = RuleTarget.selected;
  static const String _tagAuto = RuleTarget.auto;
  static const String _tagDirect = RuleTarget.direct;
  static const String _tagMitm = 'rs-mitm';
  static const String _tagTun = 'tun-in';
  static const String _tagMixed = 'mixed-in';
  static const String _tagUpstream = 'upstream-in';
  static const String _tagProbe = 'probe-in';
  static const String _dnsProxy = 'dns-proxy';
  static const String _dnsDirect = 'dns-direct';
  static const String _dnsFakeIp = 'dns-fakeip';
  static const String _dnsOutbound = 'dns-outbound';
  static const String _dnsResolver = 'dns-resolver';
  static const String _dnsHosts = 'dns-hosts';
  static const String _dnsGroup = 'dns-group-';

  /// [CoreOptions.avoidLocalDns] 时代替系统 DNS
  static const String _fallbackLocalDns = 'udp://223.6.6.6';

  /// 探测入站的用户名，决定走直连还是当前节点。放在内核里分流，
  /// 这样连接时也能真的测到直连，而不是绕进隧道
  static const String probeDirect = 'direct';
  static const String probeNode = 'node';

  static const String modeRule = 'Rule';
  static const String modeGlobal = 'Global';
  static const String modeCaptureRule = 'CaptureRule';
  static const String modeCaptureGlobal = 'CaptureGlobal';
  static const List<String> modes = [modeRule, modeGlobal, modeCaptureRule, modeCaptureGlobal];
  static const List<String> _neverDomain = ['rsproxy.invalid'];

  /// 模式写成 clash mode，规则和全局、解密开和关都不用重载，已有连接不受影响。
  ///
  /// sing-box 会把模式存进缓存文件，下次启动时恢复，所以每次启动后都要重新设置一遍，
  /// 否则可能恢复成解密模式，而这时 RsProxy 并没有运行。
  static String clashModeOf(RouteMode mode, {required bool capture}) => switch ((mode, capture)) {
        (RouteMode.rule, false) => modeRule,
        (RouteMode.rule, true) => modeCaptureRule,
        (RouteMode.global, false) => modeGlobal,
        (RouteMode.global, true) => modeCaptureGlobal,
      };

  static Map<String, dynamic> build(CoreOptions options) {
    final nodeTags = options.nodes.map((e) => e['tag'].toString()).toList();
    return {
      'log': {'level': options.logLevel, 'timestamp': false},
      'dns': _dns(options),
      'inbounds': _inbounds(options),
      'outbounds': _outbounds(options, nodeTags),
      'route': _route(options, nodeTags),
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:${options.clashPort}',
          'secret': options.clashSecret,
          'default_mode': options.clashDefaultMode,
        },
        // 假 IP 映射要留下来：内核重启后，应用手里缓存的还是旧的假 IP
        'cache_file': {'enabled': true, 'path': options.cachePath, 'store_fakeip': true},
      },
    };
  }

  static List<Map<String, dynamic>> _inbounds(CoreOptions options) => [
        if (options.tun) _tun(options),
        if (options.mixedPort > 0)
          {'type': 'mixed', 'tag': _tagMixed, 'listen': '127.0.0.1', 'listen_port': options.mixedPort},
        {'type': 'mixed', 'tag': _tagUpstream, 'listen': '127.0.0.1', 'listen_port': options.upstreamPort},
        if (options.probePort > 0)
          {
            'type': 'mixed',
            'tag': _tagProbe,
            'listen': '127.0.0.1',
            'listen_port': options.probePort,
            'users': [
              for (final user in [probeDirect, probeNode]) {'username': user, 'password': options.clashSecret},
            ],
          },
      ];

  static Map<String, dynamic> _tun(CoreOptions options) {
    final tun = options.tunSettings;
    final addresses = [tun.ipv4Address, if (options.ipv6) tun.ipv6Address];
    final excluded = [
      if (tun.routeExclude) ...[
        if (tun.routeExcludeTun) ...addresses,
        if (tun.routeExcludeMulticast) ...['224.0.0.0/4', if (options.ipv6) 'ff00::/8'],
        // 排除默认路由的开头一小段，系统就认为默认路由不在隧道里，不显示 VPN 图标
        if (tun.hideVpn) ...['0.0.0.0/31', if (options.ipv6) '::/127'],
        ...tun.routeExcludeAddresses,
      ],
    ];
    return {
      'type': 'tun',
      'tag': _tagTun,
      'address': addresses,
      'mtu': tun.mtu,
      'stack': tun.stack,
      'auto_route': tun.autoRoute,
      if (tun.strictRoute && tun.autoRoute) 'strict_route': true,
      'udp_timeout': '${tun.udpTimeoutSeconds}s',
      if (tun.loopbackAddress.isNotEmpty) 'loopback_address': [tun.loopbackAddress],
      if (excluded.isNotEmpty) 'route_exclude_address': excluded,
      if (tun.appendHttpProxy && options.mixedPort > 0)
        'platform': {
          'http_proxy': {
            'enabled': true,
            'server': '127.0.0.1',
            'server_port': options.mixedPort,
            // <local> 是 Windows 的写法
            if (options.proxyBypass.isNotEmpty) 'bypass_domain': options.proxyBypass.where((e) => e != '<local>').toList(),
          },
        },
    };
  }

  static List<Map<String, dynamic>> _outbounds(CoreOptions options, List<String> nodeTags) {
    final choices = [if (nodeTags.length > 1) _tagAuto, ...nodeTags, _tagDirect];
    final selected = options.selected;
    return [
      {
        'type': 'selector',
        'tag': _tagSelect,
        'outbounds': choices,
        'default': selected != null && choices.contains(selected) ? selected : choices.first,
        'interrupt_exist_connections': true,
      },
      if (nodeTags.length > 1)
        {
          'type': 'urltest',
          'tag': _tagAuto,
          'outbounds': nodeTags,
          'url': options.testUrl,
          // 空闲时不测速，手机上定时唤醒很耗电
          'interval': '10m',
          'idle_timeout': '30m',
          'tolerance': 50,
        },
      ...options.nodes,
      ...?options.providerRouting?.outbounds(nodeTags, testUrl: options.testUrl),
      {'type': 'direct', 'tag': _tagDirect},
      {'type': 'http', 'tag': _tagMitm, 'server': '127.0.0.1', 'server_port': options.mitmPort},
    ];
  }

  static Map<String, dynamic> _dns(CoreOptions options) {
    final dns = options.dns;
    final fakeIp = options.tun && dns.proxyResolve == ProxyResolve.fakeip;
    final mitmDomains = options.mitmDomains;
    final enabled = options.groups.where((e) => e.enabled).toList();
    final subnet = dns.clientSubnet && dns.clientSubnetValue.isNotEmpty ? dns.clientSubnetValue : null;
    final ttl = dns.ttl;
    final finalServer = dns.proxyResolve == ProxyResolve.direct ? _dnsDirect : _dnsProxy;
    final nodeTags = options.nodes.map((e) => e['tag'].toString()).toList();

    Map<String, dynamic> routeTo(String server, Map<String, dynamic> match) => {
          ...match,
          'action': 'route',
          'server': server,
          if (subnet != null) 'client_subnet': subnet,
          if (ttl != null) 'rewrite_ttl': ttl,
        };

    // 组单独指定的 DNS 走这个组的去向，这样解析结果和实际出口一致
    final groupServers = <RuleGroup, String>{
      for (final (index, group) in enabled.indexed)
        if (group.dnsServer.isNotEmpty && group.target != RuleTarget.block) group: '$_dnsGroup$index',
    };

    final hosts = <String, List<String>>{
      if (dns.staticIpForResolver) ...DnsCatalog.knownHosts,
      if (dns.staticIp) ...dns.staticIps,
    };

    Map<String, dynamic> server(String url, String tag, {String? detour}) {
      return _dnsServer(_usable(url, options), tag,
          detour: detour, resolver: hosts.containsKey(Uri.tryParse(url)?.host) ? _dnsHosts : _dnsResolver);
    }

    return {
      'servers': [
        server(dns.proxy, _dnsProxy, detour: _tagSelect),
        server(dns.direct, _dnsDirect),
        server(options.outboundDns ?? dns.outbound, _dnsOutbound),
        _dnsServer(_usable(dns.resolver, options), _dnsResolver),
        for (final MapEntry(key: group, value: tag) in groupServers.entries)
          server(group.dnsServer, tag, detour: _outboundOf(group.target, nodeTags)),
        if (hosts.isNotEmpty) {'type': 'hosts', 'tag': _dnsHosts, 'predefined': hosts},
        if (fakeIp)
          {
            'type': 'fakeip',
            'tag': _dnsFakeIp,
            'inet4_range': '198.18.0.0/15',
            if (options.ipv6) 'inet6_range': 'fc00::/18',
          },
      ],
      'rules': [
        if (dns.staticIp && dns.staticIps.isNotEmpty)
          {'domain': dns.staticIps.keys.toList(), 'action': 'route', 'server': _dnsHosts},
        // HTTPS 记录里的 ECH 会把真实域名藏起来，解密的域名不能让客户端拿到它
        if (mitmDomains != null && mitmDomains.isNotEmpty)
          {
            'query_type': 'HTTPS',
            'domain_suffix': mitmDomains,
            'action': 'predefined',
            'rcode': 'NOERROR',
          },
        ..._dnsGroupRules(enabled, routeTo, groupServers, followTargets: dns.enableRule),
        if (!dns.enableRule && enabled.any((e) => e.ruleSets.contains('geosite-cn')))
          routeTo(_dnsDirect, {'rule_set': 'geosite-cn'}),
        if (fakeIp)
          {
            'query_type': ['A', 'AAAA'],
            'action': 'route',
            'server': _dnsFakeIp,
          },
        if (ttl != null) {'action': 'route', 'server': finalServer, 'rewrite_ttl': ttl},
      ],
      'final': finalServer,
      'strategy': switch (options.ipStrategy) {
        IpStrategy.ipv4Only => 'ipv4_only',
        IpStrategy.preferIpv4 => 'prefer_ipv4',
        IpStrategy.preferIpv6 => 'prefer_ipv6',
        IpStrategy.ipv6Only => 'ipv6_only',
      },
    };
  }

  /// 分流组决定域名用哪个 DNS。单独指定了服务器的组总是生效；[followTargets] 时其余的组按去向来：
  /// 直连用直连 DNS，拦截返回 NXDOMAIN。走节点的组不用单独写，落到后面的 FakeIP 或代理 DNS 就对了。
  /// 只用 geosite 规则集：geoip 解析之前还没有 IP，其他来源的规则集可能混着 IP 规则
  static List<Map<String, dynamic>> _dnsGroupRules(
    List<RuleGroup> groups,
    Map<String, dynamic> Function(String server, Map<String, dynamic> match) routeTo,
    Map<RuleGroup, String> servers, {
    required bool followTargets,
  }) {
    final rules = <Map<String, dynamic>>[];
    for (final group in groups) {
      final geosites = group.ruleSets.where((e) => e.startsWith('geosite-')).toList();
      final match = <String, dynamic>{
        if (geosites.isNotEmpty) 'rule_set': geosites,
        if (group.domains.isNotEmpty) 'domain': group.domains,
        if (group.domainSuffixes.isNotEmpty) 'domain_suffix': group.domainSuffixes,
        if (group.domainKeywords.isNotEmpty) 'domain_keyword': group.domainKeywords,
        if (group.domainRegexes.isNotEmpty) 'domain_regex': group.domainRegexes,
      };
      if (match.isEmpty) continue;
      if (!group.matchOr) {
        if (group.networkTypes.isNotEmpty) match['network_type'] = group.networkTypes;
        if (group.wifiSsids.isNotEmpty) match['wifi_ssid'] = group.wifiSsids;
        if (group.wifiBssids.isNotEmpty) match['wifi_bssid'] = group.wifiBssids;
      }

      final server = servers[group];
      if (server != null) {
        rules.add(routeTo(server, match));
      } else if (followTargets && !group.narrowsTraffic) {
        if (group.target == RuleTarget.direct) {
          rules.add(routeTo(_dnsDirect, match));
        } else if (group.target == RuleTarget.block) {
          rules.add({...match, 'action': 'predefined', 'rcode': 'NXDOMAIN'});
        }
      }
    }
    return rules;
  }

  static String _usable(String url, CoreOptions options) =>
      options.avoidLocalDns && (url == DnsCatalog.local || url == DnsCatalog.dhcp) ? _fallbackLocalDns : url;

  /// [server] 取值：local、dhcp://auto、1.1.1.1、udp://、tcp://、tls://、https://、h3://、quic://。
  /// 地址是域名时要先解析，[resolver] 指定用哪个 DNS
  static Map<String, dynamic> _dnsServer(String server, String tag, {String? detour, String? resolver}) {
    if (server == DnsCatalog.local) return {'type': 'local', 'tag': tag};
    if (server == DnsCatalog.dhcp) return {'type': 'dhcp', 'tag': tag};
    if (!server.contains('://')) {
      return {'type': 'udp', 'tag': tag, 'server': server, if (detour != null) 'detour': detour};
    }

    final uri = Uri.parse(server);
    final named = DnsServer('', server).usesHostName;
    return {
      'type': uri.scheme,
      'tag': tag,
      'server': uri.host,
      if (uri.hasPort) 'server_port': uri.port,
      if (uri.path.isNotEmpty && uri.path != '/' && uri.path != '/dns-query') 'path': uri.path,
      if (detour != null) 'detour': detour,
      if (named && resolver != null) 'domain_resolver': resolver,
    };
  }

  static Map<String, dynamic> _route(CoreOptions options, List<String> nodeTags) {
    final enabled = options.groups.where((e) => e.enabled).toList();
    final provider = options.providerRouting;
    final ruleSets = {for (final group in enabled) ...group.ruleSets, ...options.providerRuleSets};
    final frontDoors = [if (options.tun) _tagTun, if (options.mixedPort > 0) _tagMixed];

    return {
      'rules': [
        // 排在嗅探前面：发往 53 端口的探测会被认成 DNS 接管掉，就测不到那台服务器了
        if (options.probePort > 0) ...[
          {
            'inbound': [_tagProbe],
            'auth_user': [probeDirect],
            'action': 'route',
            'outbound': _tagDirect,
          },
          {
            'inbound': [_tagProbe],
            'action': 'route',
            'outbound': _tagSelect,
          },
        ],
        {'action': 'sniff'},
        if (options.tun && options.tunSettings.hijackDns) {'protocol': 'dns', 'action': 'hijack-dns'},
        if (options.privateDirect) {'ip_is_private': true, 'action': 'route', 'outbound': _tagDirect},
        // sing-box 只接受规则里出现过的模式，其他名字会被悄悄忽略。这几条匹配不到任何流量，只为声明模式
        for (final mode in modes) {'clash_mode': mode, 'domain': _neverDomain, 'action': 'route', 'outbound': _tagDirect},
        for (final mode in [modeCaptureRule, modeCaptureGlobal]) ..._mitmRules(mode, frontDoors, options.mitmDomains),
        for (final mode in [modeGlobal, modeCaptureGlobal])
          {'clash_mode': mode, 'action': 'route', 'outbound': _tagSelect},
        if (options.dns.inboundDomainResolve && options.mixedPort > 0)
          {
            'inbound': [_tagMixed],
            'action': 'resolve',
          },
        for (final group in enabled) ..._groupRule(group, nodeTags),
        ...?provider?.routeRules(nodeTags, options.providerRuleSets, fallback: _tagSelect),
        // route.final 只能是 outbound，拦截要写成最后一条规则
        if (options.finalTarget == RuleTarget.block) {'action': 'reject'},
      ],
      'rule_set': [
        for (final name in ruleSets)
          {
            'type': 'local',
            'tag': name,
            'format': RuleSets.isSource(name) ? 'source' : 'binary',
            'path': '${options.ruleSetDirectory}/${RuleSets.fileName(name)}',
          },
      ],
      'final': _final(options, nodeTags),
      'auto_detect_interface': true,
      'default_domain_resolver': {'server': _dnsOutbound},
    };
  }

  /// 用户选的兜底去向优先。没选时听机场的 MATCH 规则，它是拦截的话写不进 route.final，就还走选中的节点
  static String _final(CoreOptions options, List<String> nodeTags) {
    final chosen = options.finalTarget;
    if (chosen != RuleTarget.selected) return _outboundOf(chosen, nodeTags) ?? _tagSelect;
    final provider = options.providerRouting;
    final target = provider?.finalTarget;
    if (target == null) return _tagSelect;
    return provider!.action(target, nodeTags, fallback: _tagSelect)['outbound'] ?? _tagSelect;
  }

  /// 去向对应的 outbound。拦截没有 outbound，返回 null
  static String? _outboundOf(String target, List<String> nodeTags) {
    if (target == RuleTarget.block) return null;
    if (target == RuleTarget.direct) return _tagDirect;
    if (target == RuleTarget.auto && nodeTags.length > 1) return _tagAuto;
    if (nodeTags.contains(target)) return target;
    // 节点可能在订阅更新后消失了
    return _tagSelect;
  }

  static List<Map<String, dynamic>> _mitmRules(String mode, List<String> frontDoors, List<String>? domains) {
    if (frontDoors.isEmpty || (domains != null && domains.isEmpty)) return const [];
    final match = {
      'clash_mode': mode,
      'inbound': frontDoors,
      if (domains != null) 'domain_suffix': domains,
    };
    return [
      // 挡掉 HTTP/3，浏览器才会退回 TCP，解密只处理 TCP
      {...match, 'network': 'udp', 'port': 443, 'action': 'reject'},
      {...match, 'network': 'tcp', 'action': 'route', 'outbound': _tagMitm},
    ];
  }

  /// 内核的默认语义：域名和 IP 这一类里任一条命中，再和端口、协议、进程这些类别同时满足
  static List<Map<String, dynamic>> _groupRule(RuleGroup group, List<String> nodeTags) {
    final outbound = _outboundOf(group.target, nodeTags);
    final action = outbound == null ? {'action': 'reject'} : {'action': 'route', 'outbound': outbound};

    final match = <String, dynamic>{
      if (group.ruleSets.isNotEmpty) 'rule_set': group.ruleSets,
      if (group.domains.isNotEmpty) 'domain': group.domains,
      if (group.domainSuffixes.isNotEmpty) 'domain_suffix': group.domainSuffixes,
      if (group.domainKeywords.isNotEmpty) 'domain_keyword': group.domainKeywords,
      if (group.domainRegexes.isNotEmpty) 'domain_regex': group.domainRegexes,
      if (group.ipCidrs.isNotEmpty) 'ip_cidr': group.ipCidrs,
      if (group.ports.isNotEmpty) 'port': group.ports,
      if (group.portRanges.isNotEmpty) 'port_range': group.portRanges,
      if (group.networks.isNotEmpty) 'network': group.networks,
      if (group.protocols.isNotEmpty) 'protocol': group.protocols,
      if (group.networkTypes.isNotEmpty) 'network_type': group.networkTypes,
      if (group.wifiSsids.isNotEmpty) 'wifi_ssid': group.wifiSsids,
      if (group.wifiBssids.isNotEmpty) 'wifi_bssid': group.wifiBssids,
      if (group.processNames.isNotEmpty) 'process_name': group.processNames,
      if (group.processPaths.isNotEmpty) 'process_path': group.processPaths,
      if (group.processDirs.isNotEmpty) 'process_path_regex': group.processDirs.map(_directoryRegex).toList(),
    };
    if (match.isEmpty) return const [];
    if (group.matchOr && match.length > 1) {
      return [
        {
          'type': 'logical',
          'mode': 'or',
          'rules': [for (final entry in match.entries) {entry.key: entry.value}],
          ...action,
        }
      ];
    }
    return [{...match, ...action}];
  }

  /// 目录下的所有程序。Windows 的路径不分大小写
  static String _directoryRegex(String directory) {
    final trimmed = directory.replaceFirst(RegExp(r'[\\/]+$'), '');
    final escaped = trimmed.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (match) => '\\${match[0]}');
    return '(?i)^$escaped[\\\\/]';
  }
}
