import 'dart:io';

import 'rule_sets.dart';

/// 分流组的去向
abstract class RuleTarget {
  /// 跟随首页选中的节点
  static const String selected = 'select';

  /// 自动选择延迟最低的节点
  static const String auto = 'auto';
  static const String direct = 'direct';

  /// 拦截。sing-box 里这是路由动作，不是 outbound
  static const String block = 'block';

  static const List<String> builtIn = [selected, auto, direct, block];
}

/// 分流组：一组匹配规则加一个去向。从上到下匹配，都不中就走兜底去向
class RuleGroup {
  final String id;
  String name;
  bool enabled;

  /// [RuleTarget] 或节点 tag
  String target;

  /// 规则集名称，见 [RuleSets]
  List<String> ruleSets;

  /// 用户填的规则集地址，.srs 或 .json
  List<String> ruleSetUrls;
  List<String> domains;
  List<String> domainSuffixes;
  List<String> domainKeywords;
  List<String> domainRegexes;
  List<String> ipCidrs;
  List<int> ports;

  /// 1000:2000、:3000、4000:
  List<String> portRanges;

  /// tcp、udp、icmp
  List<String> networks;

  /// http、tls、quic 这类应用协议，靠嗅探识别
  List<String> protocols;

  /// wifi、cellular、ethernet、other。官方内核只在 iOS 上能判断
  List<String> networkTypes;
  List<String> wifiSsids;
  List<String> wifiBssids;

  /// 进程条件只在 Windows 上能判断。进程名如 chrome.exe
  List<String> processNames;
  List<String> processPaths;
  List<String> processDirs;

  /// 满足任一条件就算命中。默认是不同类别都要满足，同一类里任一条命中就行
  bool matchOr;

  /// 这个组的域名单独用的 DNS，空表示按全局设置
  String dnsServer;

  RuleGroup({
    required this.id,
    required this.name,
    this.enabled = true,
    this.target = RuleTarget.selected,
    this.ruleSets = const [],
    this.ruleSetUrls = const [],
    this.domains = const [],
    this.domainSuffixes = const [],
    this.domainKeywords = const [],
    this.domainRegexes = const [],
    this.ipCidrs = const [],
    this.ports = const [],
    this.portRanges = const [],
    this.networks = const [],
    this.protocols = const [],
    this.networkTypes = const [],
    this.wifiSsids = const [],
    this.wifiBssids = const [],
    this.processNames = const [],
    this.processPaths = const [],
    this.processDirs = const [],
    this.matchOr = false,
    this.dnsServer = '',
  });

  factory RuleGroup.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => (json[key] as List?)?.map((e) => e.toString()).toList() ?? const [];
    return RuleGroup(
      id: json['id'],
      name: json['name'],
      enabled: json['enabled'] ?? true,
      target: json['target'] ?? RuleTarget.selected,
      ruleSets: list('ruleSets'),
      ruleSetUrls: list('ruleSetUrls'),
      domains: list('domains'),
      domainSuffixes: list('domainSuffixes'),
      domainKeywords: list('domainKeywords'),
      domainRegexes: list('domainRegexes'),
      ipCidrs: list('ipCidrs'),
      ports: list('ports').map(int.tryParse).nonNulls.toList(),
      portRanges: list('portRanges'),
      networks: list('networks'),
      protocols: list('protocols'),
      networkTypes: list('networkTypes'),
      wifiSsids: list('wifiSsids'),
      wifiBssids: list('wifiBssids'),
      processNames: list('processNames'),
      processPaths: list('processPaths'),
      processDirs: list('processDirs'),
      matchOr: json['matchOr'] ?? false,
      dnsServer: json['dnsServer'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'target': target,
        'ruleSets': ruleSets,
        'ruleSetUrls': ruleSetUrls,
        'domains': domains,
        'domainSuffixes': domainSuffixes,
        'domainKeywords': domainKeywords,
        'domainRegexes': domainRegexes,
        'ipCidrs': ipCidrs,
        'ports': ports,
        'portRanges': portRanges,
        'networks': networks,
        'protocols': protocols,
        'networkTypes': networkTypes,
        'wifiSsids': wifiSsids,
        'wifiBssids': wifiBssids,
        'processNames': processNames,
        'processPaths': processPaths,
        'processDirs': processDirs,
        'matchOr': matchOr,
        'dnsServer': dnsServer,
      };

  bool get _hasAddress =>
      domains.isNotEmpty ||
      domainSuffixes.isNotEmpty ||
      domainKeywords.isNotEmpty ||
      domainRegexes.isNotEmpty ||
      ipCidrs.isNotEmpty;

  bool get _hasProcess => processNames.isNotEmpty || processPaths.isNotEmpty || processDirs.isNotEmpty;

  /// 除了域名和 IP，还限定了端口、协议或进程。这种组不能决定整个域名用哪个 DNS
  bool get narrowsTraffic =>
      !matchOr &&
      (ports.isNotEmpty || portRanges.isNotEmpty || networks.isNotEmpty || protocols.isNotEmpty || _hasProcess);

  /// 按这台设备实际能用的内容收窄。[available] 是准备好的规则集，[ios] 决定哪些条件判断不了。
  ///
  /// 内核遇到判断不了的条件不报错，只是永远不中。所以不能直接去掉：“都要满足”的组少一个条件，
  /// 匹配范围就变大了，比如规则集下载失败后只剩端口 443，会把所有 HTTPS 都带走。这时返回 null，整组跳过
  RuleGroup? usableOn({required bool ios, required Set<String> available}) {
    final sets = [...ruleSets, ...ruleSetUrls.map(RuleSets.tagOfUrl)];
    final usable = sets.where(available.contains).toList();
    final platformGap = ios ? _hasProcess : networkTypes.isNotEmpty;
    if (!matchOr && (platformGap || (sets.isNotEmpty && usable.isEmpty && !_hasAddress))) return null;

    return RuleGroup.fromJson(toJson())
      ..ruleSets = usable
      ..ruleSetUrls = const []
      ..processNames = ios ? const [] : processNames
      ..processPaths = ios ? const [] : processPaths
      ..processDirs = ios ? const [] : processDirs
      ..networkTypes = ios ? networkTypes : const [];
  }

  /// 第一个写错的条目。内核遇到写错的规则会起不来，所以编辑和导入都要过这一关
  String? firstProblem() {
    if (name.trim().isEmpty) return '请填写名称';
    if (name.length > 32) return '名称不能超过 32 个字';
    String? check(List<String> values, String label, bool Function(String) valid) {
      for (final value in values) {
        if (!valid(value)) return '$label格式不对：$value';
      }
      return null;
    }

    return check(ruleSetUrls, '规则集地址', RuleChecks.isRuleSetUrl) ??
        check(domains, '域名', RuleChecks.isDomain) ??
        check(domainRegexes, '域名正则', RuleChecks.isRegex) ??
        check(ipCidrs, 'IP 段', RuleChecks.isCidr) ??
        check(portRanges, '端口范围', RuleChecks.isPortRange) ??
        check(ports.map((e) => '$e').toList(), '端口', RuleChecks.isPort);
  }

  /// 全新安装时的分流组，开箱即用
  static List<RuleGroup> defaults() => [
        RuleGroup(id: 'ads', name: '广告拦截', target: RuleTarget.block, ruleSets: ['geosite-category-ads-all']),
        RuleGroup(id: 'ai', name: 'AI 服务', ruleSets: ['geosite-category-ai-!cn', 'geosite-openai', 'geosite-anthropic']),
        RuleGroup(id: 'youtube', name: 'YouTube', ruleSets: ['geosite-youtube']),
        RuleGroup(id: 'google', name: 'Google', ruleSets: ['geosite-google']),
        RuleGroup(id: 'netflix', name: 'Netflix', ruleSets: ['geosite-netflix']),
        RuleGroup(id: 'disney', name: 'Disney+', ruleSets: ['geosite-disney']),
        RuleGroup(id: 'spotify', name: 'Spotify', ruleSets: ['geosite-spotify']),
        RuleGroup(id: 'tiktok', name: 'TikTok', ruleSets: ['geosite-tiktok']),
        RuleGroup(id: 'telegram', name: 'Telegram', ruleSets: [
          'geosite-telegram'
        ], ipCidrs: [
          '91.105.192.0/23',
          '91.108.0.0/16',
          '95.161.64.0/20',
          '149.154.160.0/20',
          '185.76.151.0/24',
          '2001:67c:4e8::/48',
          '2001:b28:f23d::/48',
        ]),
        RuleGroup(id: 'twitter', name: 'X / Twitter', ruleSets: ['geosite-twitter']),
        RuleGroup(id: 'facebook', name: 'Meta', ruleSets: ['geosite-facebook']),
        RuleGroup(id: 'github', name: 'GitHub', ruleSets: ['geosite-github']),
        RuleGroup(id: 'paypal', name: 'PayPal', ruleSets: ['geosite-paypal']),
        RuleGroup(id: 'steam', name: 'Steam', ruleSets: ['geosite-steam']),
        RuleGroup(id: 'microsoft', name: '微软', target: RuleTarget.direct, ruleSets: ['geosite-microsoft']),
        RuleGroup(id: 'apple', name: '苹果', target: RuleTarget.direct, ruleSets: ['geosite-apple']),
        RuleGroup(id: 'china', name: '中国大陆', target: RuleTarget.direct, ruleSets: ['geosite-cn', 'geoip-cn']),
      ];
}

/// 分流规则的格式检查
abstract class RuleChecks {
  static final RegExp _domain = RegExp(r'^[\w-]+(\.[\w-]+)*$', unicode: true);
  static final RegExp _portRange = RegExp(r'^(\d*):(\d*)$');

  /// Go 的正则不支持这些写法，Dart 支持，所以光靠 [RegExp] 编译一下查不出来
  static final RegExp _goUnsupported = RegExp(r'\(\?[=!]|\(\?<[=!]|\\[1-9]');

  static bool isDomain(String value) => _domain.hasMatch(value);

  static bool isPort(String value) {
    final port = int.tryParse(value);
    return port != null && port >= 0 && port <= 65535;
  }

  static bool isPortRange(String value) {
    final match = _portRange.firstMatch(value);
    if (match == null || value == ':') return false;
    final start = match.group(1)!, end = match.group(2)!;
    if ((start.isNotEmpty && !isPort(start)) || (end.isNotEmpty && !isPort(end))) return false;
    return start.isEmpty || end.isEmpty || int.parse(start) <= int.parse(end);
  }

  static bool isRegex(String value) {
    if (_goUnsupported.hasMatch(value)) return false;
    try {
      RegExp(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool isCidr(String value) {
    final parts = value.split('/');
    if (parts.length != 2) return false;
    final address = InternetAddress.tryParse(parts[0]);
    final prefix = int.tryParse(parts[1]);
    if (address == null || prefix == null || prefix < 0) return false;
    return prefix <= (address.type == InternetAddressType.IPv4 ? 32 : 128);
  }

  /// 单个 IP 补上掩码，其他原样返回
  static String normalizeCidr(String value) {
    if (value.contains('/')) return value;
    final address = InternetAddress.tryParse(value);
    if (address == null) return value;
    return '$value/${address.type == InternetAddressType.IPv4 ? 32 : 128}';
  }

  static bool isRuleSetUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    return uri.path.endsWith('.srs') || uri.path.endsWith('.json');
  }
}
