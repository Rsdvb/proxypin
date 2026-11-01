/// 分流组的去向
abstract class RuleTarget {
  /// 跟随首页选中的节点
  static const String selected = 'select';
  static const String direct = 'direct';

  /// 拦截。sing-box 里这是路由动作，不是 outbound
  static const String block = 'block';
}

/// 分流组：一组匹配规则加一个去向。从上到下匹配，都不中就走首页选中的节点
class RuleGroup {
  final String id;
  String name;
  bool enabled;

  /// [RuleTarget] 或节点 tag
  String target;

  /// 内置规则集，名称对应 assets/rules/<name>.srs
  List<String> ruleSets;
  List<String> domains;
  List<String> domainSuffixes;
  List<String> domainKeywords;
  List<String> domainRegexes;
  List<String> ipCidrs;

  /// Windows 进程名，如 chrome.exe
  List<String> processNames;

  RuleGroup({
    required this.id,
    required this.name,
    this.enabled = true,
    this.target = RuleTarget.selected,
    this.ruleSets = const [],
    this.domains = const [],
    this.domainSuffixes = const [],
    this.domainKeywords = const [],
    this.domainRegexes = const [],
    this.ipCidrs = const [],
    this.processNames = const [],
  });

  factory RuleGroup.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => (json[key] as List?)?.map((e) => e.toString()).toList() ?? const [];
    return RuleGroup(
      id: json['id'],
      name: json['name'],
      enabled: json['enabled'] ?? true,
      target: json['target'] ?? RuleTarget.selected,
      ruleSets: list('ruleSets'),
      domains: list('domains'),
      domainSuffixes: list('domainSuffixes'),
      domainKeywords: list('domainKeywords'),
      domainRegexes: list('domainRegexes'),
      ipCidrs: list('ipCidrs'),
      processNames: list('processNames'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'target': target,
        'ruleSets': ruleSets,
        'domains': domains,
        'domainSuffixes': domainSuffixes,
        'domainKeywords': domainKeywords,
        'domainRegexes': domainRegexes,
        'ipCidrs': ipCidrs,
        'processNames': processNames,
      };

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
