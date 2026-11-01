import 'rule_group.dart';
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

  /// iOS 走 TUN；Windows 默认走本地代理，也可以开 TUN
  final bool tun;

  /// 本地代理端口，系统代理指向这里。0 表示不开
  final int mixedPort;

  /// 解密后的流量从这个端口回到 sing-box 出站
  final int upstreamPort;

  /// RsProxy 解密端口
  final int mitmPort;

  /// 要解密的域名后缀，null 表示全部 TCP 都交给 RsProxy，由它按规则判断
  final List<String>? mitmDomains;

  final int clashPort;
  final String clashSecret;
  final String clashDefaultMode;

  /// 规则集目录，里面是 assets/rules 的文件
  final String ruleSetDirectory;
  final String cachePath;

  final String directDns;
  final String remoteDns;
  final bool fakeIp;
  final bool ipv6;
  final String testUrl;
  final String logLevel;

  const CoreOptions({
    required this.nodes,
    this.selected,
    this.groups = const [],
    this.tun = false,
    this.mixedPort = 0,
    required this.upstreamPort,
    required this.mitmPort,
    this.mitmDomains = const [],
    required this.clashPort,
    required this.clashSecret,
    this.clashDefaultMode = 'Rule',
    required this.ruleSetDirectory,
    required this.cachePath,
    this.directDns = 'local',
    this.remoteDns = 'https://1.1.1.1/dns-query',
    this.fakeIp = true,
    this.ipv6 = true,
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.logLevel = 'warn',
  });
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
  static const String _tagAuto = 'auto';
  static const String _tagDirect = RuleTarget.direct;
  static const String _tagMitm = 'rs-mitm';
  static const String _tagTun = 'tun-in';
  static const String _tagMixed = 'mixed-in';
  static const String _tagUpstream = 'upstream-in';
  static const String _dnsRemote = 'dns-remote';
  static const String _dnsDirect = 'dns-direct';
  static const String _dnsFakeIp = 'dns-fakeip';

  static const String modeRule = 'Rule';
  static const String modeGlobal = 'Global';
  static const String modeCaptureRule = 'CaptureRule';
  static const String modeCaptureGlobal = 'CaptureGlobal';
  static const List<String> modes = [modeRule, modeGlobal, modeCaptureRule, modeCaptureGlobal];

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
        if (options.tun)
          {
            'type': 'tun',
            'tag': _tagTun,
            'address': ['172.19.0.1/30', if (options.ipv6) 'fdfe:dcba:9876::1/126'],
            'auto_route': true,
            'strict_route': true,
          },
        if (options.mixedPort > 0)
          {'type': 'mixed', 'tag': _tagMixed, 'listen': '127.0.0.1', 'listen_port': options.mixedPort},
        {'type': 'mixed', 'tag': _tagUpstream, 'listen': '127.0.0.1', 'listen_port': options.upstreamPort},
      ];

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
      {'type': 'direct', 'tag': _tagDirect},
      {'type': 'http', 'tag': _tagMitm, 'server': '127.0.0.1', 'server_port': options.mitmPort},
    ];
  }

  static Map<String, dynamic> _dns(CoreOptions options) {
    final china = options.groups.any((e) => e.ruleSets.contains('geosite-cn'));
    final fakeIp = options.tun && options.fakeIp;
    final mitmDomains = options.mitmDomains;
    return {
      'servers': [
        _dnsServer(options.remoteDns, _dnsRemote, detour: _tagSelect),
        _dnsServer(options.directDns, _dnsDirect),
        if (fakeIp)
          {
            'type': 'fakeip',
            'tag': _dnsFakeIp,
            'inet4_range': '198.18.0.0/15',
            if (options.ipv6) 'inet6_range': 'fc00::/18',
          },
      ],
      'rules': [
        // HTTPS 记录里的 ECH 会把真实域名藏起来，解密的域名不能让客户端拿到它
        if (mitmDomains != null && mitmDomains.isNotEmpty)
          {
            'query_type': 'HTTPS',
            'domain_suffix': mitmDomains,
            'action': 'predefined',
            'rcode': 'NOERROR',
          },
        if (china) {'rule_set': 'geosite-cn', 'action': 'route', 'server': _dnsDirect},
        if (fakeIp)
          {
            'query_type': ['A', 'AAAA'],
            'action': 'route',
            'server': _dnsFakeIp,
          },
      ],
      'final': _dnsRemote,
      'strategy': options.ipv6 ? 'prefer_ipv4' : 'ipv4_only',
    };
  }

  /// [server] 取值：local、1.1.1.1（UDP）、https://host/path、tls://host
  static Map<String, dynamic> _dnsServer(String server, String tag, {String? detour}) {
    final Map<String, dynamic> result;
    if (server == 'local') {
      result = {'type': 'local', 'tag': tag};
    } else if (server.contains('://')) {
      final uri = Uri.parse(server);
      result = {
        'type': uri.scheme,
        'tag': tag,
        'server': uri.host,
        if (uri.hasPort) 'server_port': uri.port,
        if (uri.path.isNotEmpty && uri.path != '/') 'path': uri.path,
      };
    } else {
      result = {'type': 'udp', 'tag': tag, 'server': server};
    }
    // 本机 DNS 不走节点，所以 local 不加 detour
    if (detour != null && server != 'local') result['detour'] = detour;
    return result;
  }

  static Map<String, dynamic> _route(CoreOptions options, List<String> nodeTags) {
    final enabled = options.groups.where((e) => e.enabled).toList();
    final ruleSets = {for (final group in enabled) ...group.ruleSets};
    final frontDoors = [if (options.tun) _tagTun, if (options.mixedPort > 0) _tagMixed];

    return {
      'rules': [
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
        {'ip_is_private': true, 'action': 'route', 'outbound': _tagDirect},
        // sing-box 只接受规则里出现过的模式，其他名字会被悄悄忽略。这几条本身不起作用，只为声明模式
        for (final mode in modes) {'clash_mode': mode, 'ip_is_private': true, 'action': 'route', 'outbound': _tagDirect},
        for (final mode in [modeCaptureRule, modeCaptureGlobal]) ..._mitmRules(mode, frontDoors, options.mitmDomains),
        for (final mode in [modeGlobal, modeCaptureGlobal])
          {'clash_mode': mode, 'action': 'route', 'outbound': _tagSelect},
        for (final group in enabled) ..._groupRule(group, nodeTags),
      ],
      'rule_set': [
        for (final name in ruleSets)
          {
            'type': 'local',
            'tag': name,
            'format': 'binary',
            'path': '${options.ruleSetDirectory}/$name.srs',
          },
      ],
      'final': _tagSelect,
      'auto_detect_interface': true,
      'default_domain_resolver': {'server': _dnsDirect},
    };
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

  static List<Map<String, dynamic>> _groupRule(RuleGroup group, List<String> nodeTags) {
    final Map<String, dynamic> action;
    if (group.target == RuleTarget.block) {
      action = {'action': 'reject'};
    } else if (group.target == RuleTarget.direct) {
      action = {'action': 'route', 'outbound': _tagDirect};
    } else if (nodeTags.contains(group.target)) {
      action = {'action': 'route', 'outbound': group.target};
    } else {
      // 节点可能在订阅更新后消失了
      action = {'action': 'route', 'outbound': _tagSelect};
    }

    final match = <String, dynamic>{
      if (group.ruleSets.isNotEmpty) 'rule_set': group.ruleSets,
      if (group.domains.isNotEmpty) 'domain': group.domains,
      if (group.domainSuffixes.isNotEmpty) 'domain_suffix': group.domainSuffixes,
      if (group.domainKeywords.isNotEmpty) 'domain_keyword': group.domainKeywords,
      if (group.domainRegexes.isNotEmpty) 'domain_regex': group.domainRegexes,
      if (group.ipCidrs.isNotEmpty) 'ip_cidr': group.ipCidrs,
      if (group.processNames.isNotEmpty) 'process_name': group.processNames,
    };
    return match.isEmpty ? const [] : [{...match, ...action}];
  }
}
