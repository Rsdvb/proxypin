import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'core_config.dart';
import 'dns_catalog.dart';
import 'profile.dart';
import 'rule_group.dart';
import 'traffic_stats.dart';

/// IPv6 策略，默认关闭：节点没有 IPv6 时开着反而容易连不上
enum IpStrategy { ipv4Only, preferIpv4, preferIpv6, ipv6Only }

/// 代理流量的域名怎么解析
enum ProxyResolve {
  /// 不真正解析，由节点解析。快，但断开后应用可能要重启，且只对 TUN 入站生效
  fakeip,

  /// 通过当前节点连接 DNS 服务器解析
  proxy,

  /// 直连 DNS 服务器解析
  direct,
}

class DnsSettings {
  static const String defaultProxy = 'https://1.1.1.1/dns-query';
  static const String defaultTestDomain = 'gstatic.com';
  static const int minTtl = 5;
  static const int maxTtl = 365 * 86400;

  /// 解析 DNS 服务器自身域名用的 DNS
  String resolver;

  /// 解析节点域名用的 DNS
  String outbound;

  /// 直连流量用的 DNS
  String direct;

  /// 代理流量用的 DNS
  String proxy;
  ProxyResolve proxyResolve;

  /// 改写返回的 TTL（秒），空表示保持原样
  int? ttl;

  /// 按分流组决定域名用哪个 DNS
  bool enableRule;

  /// 直连 DNS 带上本机网段（ECS），让 CDN 返回就近的地址
  bool clientSubnet;

  /// 上次测到的本机网段，空表示还不知道
  String clientSubnetValue;
  DateTime? clientSubnetUpdatedAt;

  /// 代理端口进来的域名先解析，才能命中基于 IP 的分流规则
  bool inboundDomainResolve;
  bool staticIp;
  Map<String, List<String>> staticIps;

  /// 常见 DNS 服务器的域名用内置地址，防止它们自己被污染
  bool staticIpForResolver;

  /// 测延迟时解析的域名
  String testDomain;

  /// 用户自己加的 DNS 服务器
  List<Map<String, dynamic>> custom;

  DnsSettings({
    this.resolver = 'local',
    this.outbound = 'local',
    this.direct = 'local',
    this.proxy = defaultProxy,
    this.proxyResolve = ProxyResolve.fakeip,
    this.ttl,
    this.enableRule = false,
    this.clientSubnet = true,
    this.clientSubnetValue = '',
    this.clientSubnetUpdatedAt,
    this.inboundDomainResolve = false,
    this.staticIp = false,
    Map<String, List<String>>? staticIps,
    this.staticIpForResolver = true,
    this.testDomain = defaultTestDomain,
    List<Map<String, dynamic>>? custom,
  })  : staticIps = staticIps ?? {},
        custom = custom ?? [];

  /// 自定义服务器的地址能不能用。[DnsCatalog.schemes] 之外的写法内核不认，会起不来
  static bool isValidServer(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && !url.contains(' ') && uri.host.isNotEmpty && DnsCatalog.schemes.contains(uri.scheme);
  }

  factory DnsSettings.fromJson(Map<String, dynamic> json) => DnsSettings(
        resolver: json['resolver'] ?? 'local',
        outbound: json['outbound'] ?? 'local',
        direct: json['direct'] ?? 'local',
        proxy: json['proxy'] ?? defaultProxy,
        proxyResolve: ProxyResolve.values.asNameMap()[json['proxyResolve']] ?? ProxyResolve.fakeip,
        ttl: (json['ttl'] as int?)?.clamp(minTtl, maxTtl),
        enableRule: json['enableRule'] ?? false,
        clientSubnet: json['clientSubnet'] ?? true,
        clientSubnetValue: json['clientSubnetValue'] ?? '',
        clientSubnetUpdatedAt: json['clientSubnetUpdatedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['clientSubnetUpdatedAt']),
        inboundDomainResolve: json['inboundDomainResolve'] ?? false,
        staticIp: json['staticIp'] ?? false,
        staticIps: (json['staticIps'] as Map?)
            ?.map((key, value) => MapEntry(key.toString(), (value as List).map((e) => e.toString()).toList()))
          ?..removeWhere((_, addresses) => addresses.isEmpty),
        staticIpForResolver: json['staticIpForResolver'] ?? true,
        testDomain: (json['testDomain'] as String?)?.isNotEmpty == true ? json['testDomain'] : defaultTestDomain,
        custom: (json['custom'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e))
            .where((e) => isValidServer(e['url']?.toString() ?? ''))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'resolver': resolver,
        'outbound': outbound,
        'direct': direct,
        'proxy': proxy,
        'proxyResolve': proxyResolve.name,
        'ttl': ttl,
        'enableRule': enableRule,
        'clientSubnet': clientSubnet,
        'clientSubnetValue': clientSubnetValue,
        'clientSubnetUpdatedAt': clientSubnetUpdatedAt?.millisecondsSinceEpoch,
        'inboundDomainResolve': inboundDomainResolve,
        'staticIp': staticIp,
        'staticIps': staticIps,
        'staticIpForResolver': staticIpForResolver,
        'testDomain': testDomain,
        'custom': custom,
      };
}

class TunSettings {
  static const String defaultIpv4 = '172.19.0.1/30';
  static const String defaultIpv6 = 'fdfe:dcba:9876::1/126';
  static const int defaultMtu = 4064;

  /// 网络栈。iOS 只能用 gvisor
  String stack;
  int udpTimeoutSeconds;
  String ipv4Address;
  String ipv6Address;
  String loopbackAddress;
  int mtu;

  /// Windows：自动设置路由
  bool autoRoute;

  /// 开启后其他设备可能连不上这台设备的共享
  bool strictRoute;

  /// 接管发往 TUN 的 DNS 请求，由内核按规则解析
  bool hijackDns;

  /// 总开关：排除地址段的流量不进 TUN
  bool routeExclude;
  bool routeExcludeTun;
  bool routeExcludeMulticast;

  /// iOS：排除默认路由的一小段，状态栏就不显示 VPN 图标。开 IPv6 时无效
  bool hideVpn;
  List<String> routeExcludeAddresses;

  /// iOS：使用默认路由。关闭后用一组子网路由代替
  bool defaultRoute;
  bool includeAllNetworks;
  bool excludeLocalNetworks;
  bool excludeCellularServices;
  bool excludeApns;
  bool excludeDeviceCommunication;
  bool enforceRoutes;

  /// iOS：同时设置 HTTP 代理，一些 App 绕过虚拟网卡时还能接住
  bool appendHttpProxy;

  /// iOS：系统保持隧道常开，App 没运行时也会自动连接
  bool alwaysOn;

  TunSettings({
    this.stack = 'gvisor',
    this.udpTimeoutSeconds = 300,
    this.ipv4Address = defaultIpv4,
    this.ipv6Address = defaultIpv6,
    this.loopbackAddress = '',
    this.mtu = defaultMtu,
    this.autoRoute = true,
    this.strictRoute = false,
    this.hijackDns = true,
    this.routeExclude = true,
    bool? routeExcludeTun,
    this.routeExcludeMulticast = false,
    this.hideVpn = false,
    List<String>? routeExcludeAddresses,
    this.defaultRoute = true,
    this.includeAllNetworks = false,
    this.excludeLocalNetworks = false,
    this.excludeCellularServices = false,
    this.excludeApns = false,
    this.excludeDeviceCommunication = false,
    this.enforceRoutes = false,
    this.appendHttpProxy = true,
    this.alwaysOn = false,
  })  : routeExcludeTun = routeExcludeTun ?? Platform.isWindows,
        routeExcludeAddresses = routeExcludeAddresses ?? [];

  factory TunSettings.fromJson(Map<String, dynamic> json) => TunSettings(
        stack: json['stack'] ?? 'gvisor',
        udpTimeoutSeconds: json['udpTimeoutSeconds'] ?? 300,
        ipv4Address: json['ipv4Address'] ?? defaultIpv4,
        ipv6Address: json['ipv6Address'] ?? defaultIpv6,
        loopbackAddress: json['loopbackAddress'] ?? '',
        mtu: normalizeMtu(json['mtu']),
        autoRoute: json['autoRoute'] ?? true,
        strictRoute: json['strictRoute'] ?? false,
        hijackDns: json['hijackDns'] ?? true,
        routeExclude: json['routeExclude'] ?? true,
        routeExcludeTun: json['routeExcludeTun'],
        routeExcludeMulticast: json['routeExcludeMulticast'] ?? false,
        hideVpn: json['hideVpn'] ?? false,
        routeExcludeAddresses: (json['routeExcludeAddresses'] as List?)?.map((e) => e.toString()).toList(),
        defaultRoute: json['defaultRoute'] ?? true,
        includeAllNetworks: json['includeAllNetworks'] ?? false,
        excludeLocalNetworks: json['excludeLocalNetworks'] ?? false,
        excludeCellularServices: json['excludeCellularServices'] ?? false,
        excludeApns: json['excludeApns'] ?? false,
        excludeDeviceCommunication: json['excludeDeviceCommunication'] ?? false,
        enforceRoutes: json['enforceRoutes'] ?? false,
        appendHttpProxy: json['appendHttpProxy'] ?? true,
        alwaysOn: json['alwaysOn'] ?? false,
      );

  Map<String, dynamic> toJson() => {
        'stack': stack,
        'udpTimeoutSeconds': udpTimeoutSeconds,
        'ipv4Address': ipv4Address,
        'ipv6Address': ipv6Address,
        'loopbackAddress': loopbackAddress,
        'mtu': mtu,
        'autoRoute': autoRoute,
        'strictRoute': strictRoute,
        'hijackDns': hijackDns,
        'routeExclude': routeExclude,
        'routeExcludeTun': routeExcludeTun,
        'routeExcludeMulticast': routeExcludeMulticast,
        'hideVpn': hideVpn,
        'routeExcludeAddresses': routeExcludeAddresses,
        'defaultRoute': defaultRoute,
        'includeAllNetworks': includeAllNetworks,
        'excludeLocalNetworks': excludeLocalNetworks,
        'excludeCellularServices': excludeCellularServices,
        'excludeApns': excludeApns,
        'excludeDeviceCommunication': excludeDeviceCommunication,
        'enforceRoutes': enforceRoutes,
        'appendHttpProxy': appendHttpProxy,
        'alwaysOn': alwaysOn,
      };

  /// 0 和不合法的值用默认值
  static int normalizeMtu(int? value) => value == null || value <= 0 || value > 65535 ? defaultMtu : value;

  /// 掩码限制在 /24-/30，没写掩码时用 /30。不合法返回 null
  static String? normalizeIpv4(String text) {
    final match = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?$').firstMatch(text.trim());
    if (match == null) return null;
    if (match.group(1)!.split('.').any((e) => int.parse(e) > 255)) return null;
    final mask = (int.tryParse(match.group(2) ?? '') ?? 30).clamp(24, 30);
    return '${match.group(1)}/$mask';
  }

  /// 掩码限制在 /64-/126，没写掩码时用 /126。不合法返回 null
  static String? normalizeIpv6(String text) {
    final parts = text.trim().split('/');
    if (parts.length > 2 || InternetAddress.tryParse(parts.first)?.type != InternetAddressType.IPv6) return null;
    final mask = (int.tryParse(parts.length == 2 ? parts[1] : '') ?? 126).clamp(64, 126);
    return '${parts.first}/$mask';
  }

  /// iOS 隧道启动时要交给系统的选项，只在建立连接时生效
  Map<String, Object> get tunnelOptions => {
        'defaultRoute': defaultRoute,
        'includeAllNetworks': includeAllNetworks,
        'excludeLocalNetworks': excludeLocalNetworks,
        'excludeCellularServices': excludeCellularServices,
        'excludeApns': excludeApns,
        'excludeDeviceCommunication': excludeDeviceCommunication,
        'enforceRoutes': enforceRoutes,
        'alwaysOn': alwaysOn,
      };
}

/// 给所有节点统一加的选项。配置文件里的节点不动，生成内核配置时才加上
class NodeTuning {
  static const Set<String> muxCapableTypes = {'vmess', 'vless', 'trojan', 'shadowsocks'};
  static const Set<String> _quicTypes = {'hysteria', 'hysteria2', 'tuic'};

  /// 跳过证书验证。Karing 默认开，这里默认关：能连上的节点才不会被中间人冒充
  bool tlsInsecure;

  /// 拆分 TLS 握手绕过简单的过滤。官方内核不能指定大小，先试记录分片，它慢得少
  bool tlsFragment;
  bool tlsRecordFragment;

  /// 拆分后等待的时间，内核测不出来时才用，单位毫秒，0 表示用内核的默认值
  int fragmentDelayMs;
  bool muxEnabled;

  /// h2mux、smux、yamux
  String muxProtocol;
  bool muxPadding;

  /// 内核规定最大流数和另外两项不能同时填：填了最大流数时另外两项不写入
  int muxMaxStreams;
  int muxMaxConnections;
  int muxMinStreams;
  bool muxBrutal;
  int muxUpMbps;
  int muxDownMbps;
  Set<String> muxTypes;

  NodeTuning({
    this.tlsInsecure = false,
    this.tlsFragment = false,
    this.tlsRecordFragment = false,
    this.fragmentDelayMs = 0,
    this.muxEnabled = false,
    this.muxProtocol = 'h2mux',
    this.muxPadding = false,
    this.muxMaxStreams = 8,
    this.muxMaxConnections = 0,
    this.muxMinStreams = 0,
    this.muxBrutal = false,
    this.muxUpMbps = 100,
    this.muxDownMbps = 100,
    Set<String>? muxTypes,
  }) : muxTypes = muxTypes ?? {};

  factory NodeTuning.fromJson(Map<String, dynamic> json) => NodeTuning(
        tlsInsecure: json['tlsInsecure'] ?? false,
        tlsFragment: json['tlsFragment'] ?? false,
        tlsRecordFragment: json['tlsRecordFragment'] ?? false,
        fragmentDelayMs: json['fragmentDelayMs'] ?? 0,
        muxEnabled: json['muxEnabled'] ?? false,
        muxProtocol: json['muxProtocol'] ?? 'h2mux',
        muxPadding: json['muxPadding'] ?? false,
        muxMaxStreams: json['muxMaxStreams'] ?? 8,
        muxMaxConnections: json['muxMaxConnections'] ?? 0,
        muxMinStreams: json['muxMinStreams'] ?? 0,
        muxBrutal: json['muxBrutal'] ?? false,
        muxUpMbps: json['muxUpMbps'] ?? 100,
        muxDownMbps: json['muxDownMbps'] ?? 100,
        muxTypes: (json['muxTypes'] as List?)?.map((e) => e.toString()).toSet(),
      );

  Map<String, dynamic> toJson() => {
        'tlsInsecure': tlsInsecure,
        'tlsFragment': tlsFragment,
        'tlsRecordFragment': tlsRecordFragment,
        'fragmentDelayMs': fragmentDelayMs,
        'muxEnabled': muxEnabled,
        'muxProtocol': muxProtocol,
        'muxPadding': muxPadding,
        'muxMaxStreams': muxMaxStreams,
        'muxMaxConnections': muxMaxConnections,
        'muxMinStreams': muxMinStreams,
        'muxBrutal': muxBrutal,
        'muxUpMbps': muxUpMbps,
        'muxDownMbps': muxDownMbps,
        'muxTypes': muxTypes.toList(),
      };

  Map<String, dynamic> apply(Map<String, dynamic> node) {
    final tls = _tuneTls(node);
    final mux = _multiplexFor(node);
    if (tls == null && mux == null) return node;
    return {...node, if (tls != null) 'tls': tls, if (mux != null) 'multiplex': mux};
  }

  Map<String, dynamic>? _tuneTls(Map<String, dynamic> node) {
    final tls = node['tls'];
    if (tls is! Map || tls['enabled'] != true) return null;
    // Reality 自己验证服务器，用不上跳过验证
    final reality = tls['reality'];
    final insecure = tlsInsecure && !(reality is Map && reality['enabled'] == true);
    // 拆分只对 TCP 有意义，QUIC 协议没有这一层
    final fragmentable = !_quicTypes.contains(node['type']);
    final fragment = fragmentable && tlsFragment;
    final record = fragmentable && tlsRecordFragment;
    if (!insecure && !fragment && !record) return null;
    return {
      ...tls.cast<String, dynamic>(),
      if (insecure) 'insecure': true,
      if (fragment) 'fragment': true,
      if (record) 'record_fragment': true,
      if (fragment && fragmentDelayMs > 0) 'fragment_fallback_delay': '${fragmentDelayMs}ms',
    };
  }

  /// 节点自己写了 multiplex 的不动。用了 flow 的 VLESS 不套，和 Karing 一样
  Map<String, dynamic>? _multiplexFor(Map<String, dynamic> node) {
    if (!muxEnabled || !muxTypes.contains(node['type']) || node['multiplex'] != null) return null;
    if (node['flow']?.toString().isNotEmpty == true) return null;
    return {
      'enabled': true,
      'protocol': muxProtocol,
      if (muxPadding) 'padding': true,
      if (muxMaxStreams > 0)
        'max_streams': muxMaxStreams
      else ...{
        if (muxMaxConnections > 0) 'max_connections': muxMaxConnections,
        if (muxMinStreams > 0) 'min_streams': muxMinStreams,
      },
      if (muxBrutal) 'brutal': {'enabled': true, 'up_mbps': muxUpMbps, 'down_mbps': muxDownMbps},
    };
  }
}

/// 首页能显示的数字
abstract class HomeStat {
  static const String runtime = 'runtime';
  static const String connections = 'connections';
  static const String traffic = 'traffic';
  static const String speed = 'speed';
  static const String memory = 'memory';
  static const String outboundIp = 'outbound_ip';
  static const List<String> all = [runtime, connections, traffic, speed, memory, outboundIp];
}

/// 首页能放的开关
abstract class HomeSwitch {
  static const String capture = 'capture';
  static const String systemProxy = 'system_proxy';
  static const String tun = 'tun';
  static const String rules = 'rules';
  static const String proxyBypass = 'proxy_bypass';
  static const String routeExclude = 'route_exclude';
  static const List<String> all = [capture, systemProxy, tun, rules, proxyBypass, routeExclude];
  static const List<String> defaults = [capture, systemProxy, tun, rules];
}

/// 首页能放的入口
abstract class HomeShortcut {
  static const String addProfile = 'add_profile';
  static const String profiles = 'profiles';
  static const String connections = 'connections';
  static const String networkCheck = 'network_check';
  static const String speedTest = 'speed_test';
  static const String ruleCheck = 'rule_check';
  static const String logs = 'logs';
  static const String statistics = 'statistics';
  static const String dns = 'dns';
  static const String backup = 'backup';
  static const List<String> all = [
    addProfile,
    profiles,
    connections,
    networkCheck,
    speedTest,
    ruleCheck,
    logs,
    statistics,
    dns,
    backup,
  ];
  static const List<String> defaults = [addProfile, connections, networkCheck, speedTest];
}

/// 连接相关的设置
class CoreSettings {
  String? activeProfileId;

  /// 配置 id -> 上次选中的节点
  Map<String, String> selectedNodes;

  /// 收藏的节点名。按名称存，订阅更新后仍然有效
  Set<String> favorites;

  /// 用户自己加的 User-Agent，所有配置都能选
  List<String> userAgents;

  /// X-HWID 发送的设备标识，安装时随机生成
  String deviceId;
  String webDavUrl;
  String webDavUsername;
  String webDavPassword;
  RouteMode mode;
  bool capture;

  /// 总开关：是否使用机场的分流规则，配置里选了保留才有
  bool providerRulesEnabled;

  /// 机场分流组改过的去向：配置 id -> 组名 -> 去向
  Map<String, Map<String, String>> providerTargets;

  /// Windows：是否走 TUN（需要管理员权限）。iOS 始终走 TUN
  bool tun;

  /// Windows：连接时是否设置系统代理
  bool systemProxy;

  /// 系统代理现在指向我们。崩溃后靠它知道要清掉，否则代理指着死端口，整机上不了网
  bool systemProxyActive;

  /// 让代理设置绕过 [bypassDomains]。Windows 用在系统代理上，iOS 用在附加的 HTTP 代理上
  bool proxyBypass;
  List<String> bypassDomains;

  /// 启动 App 时自动连接
  bool autoConnect;
  IpStrategy ipStrategy;
  DnsSettings dns;
  TunSettings tunSettings;

  /// 私有网络直连
  bool privateDirect;

  /// 总开关：是否使用分流组
  bool groupsEnabled;

  /// 分流页隐藏未启用的组
  bool hideDisabledGroups;
  String testUrl;

  /// 手动测延迟的超时和同时测的节点数
  int testTimeoutSeconds;
  int testConcurrency;

  /// 内核校时用的服务器，空表示不校时。设备时间不准时 TLS 节点会连不上
  String ntpServer;
  List<RuleGroup> groups;

  /// 给所有节点统一加的 TLS 和多路复用选项
  NodeTuning tuning;

  /// 全部直连和全部走代理的本地端口，给想按程序区分的用户。0 表示不开
  int directPort;
  int globalPort;

  /// 局域网里的其他设备能连上来
  bool lanEnabled;
  int lanPort;
  int lanGlobalPort;
  String lanUsername;
  String lanPassword;

  /// 本机代理端口的账号，两项都填才生效
  String mixedUsername;
  String mixedPassword;

  /// 地区的两位代码，小写
  String region;

  /// 分流最后追加“这个地区直连”。默认分流组里已经有中国大陆，所以默认关
  bool regionRules;

  /// 自动选择时多久检查一次正在用的节点，秒，0 表示不检查。不通就立刻重选，不等下一轮测试
  int autoHealthCheckSeconds;

  /// 内核日志级别
  String logLevel;
  bool statsEnabled;
  int statsDays;

  /// 用户自己的 sing-box 配置的文件名，空表示用 RsProxy 生成的
  String rawConfigName;

  /// 添加配置后自动备份，换手机或误删时能找回来
  bool autoBackupOnAdd;
  bool autoBackupOnRemove;
  DownloadStrategy webDavDownload;

  /// 首页显示的数字，按这个顺序
  List<String> homeStats;
  List<String> homeSwitches;
  List<String> homeShortcuts;

  /// 和当前配置一起用的其他配置，它们的节点合在一起
  List<String> alsoEnabledProfiles;

  /// 这次连接开始的时间。存下来：iOS 的隧道可能比 App 活得久
  DateTime? connectedAt;

  /// 规则检测上次查的域名
  String ruleCheckDomain;

  /// 禁用的节点，存 `类型;地址;端口`：换了配置或改了名字也还算同一个节点
  Set<String> disabledNodes;

  /// 最近选过的节点，新的在前
  List<String> recentNodes;

  /// 节点搜索的候选词，可以是关键词或正则
  List<String> searchKeywords;
  bool hideRecommendedNodes;
  bool hideRecentNodes;
  bool hideFavoriteNodes;
  bool hideFailedNodes;
  bool sortNodesByDelay;

  /// 手动测完延迟后，让自动选择换到最快的节点
  bool autoUpdateAfterTest;

  /// 分流都没命中时的去向
  String finalTarget;

  /// 链式代理经过的节点，从上到下
  List<String> chain;

  /// 链在当前节点前面：应用 -> 链 -> 当前节点。关闭时在后面：应用 -> 当前节点 -> 链
  bool chainFront;
  List<AutoGroup> autoGroups;

  /// 自动选择多久测一次，单位分钟。手机上定时唤醒很耗电
  int autoTestMinutes;

  /// 新节点要快过当前节点这么多才切换，单位毫秒
  int autoTolerance;

  /// 有收藏时只在收藏里选
  bool autoPreferFavorites;

  /// 自动选择最多测这么多节点
  int autoNodeLimit;

  /// 规则集多久更新一次，单位小时
  int ruleSetUpdateHours;

  /// 随安装包带的规则集也从网上更新
  bool updateBundledRuleSets;
  DownloadStrategy ruleSetDownload;

  /// 上次更新规则集的时间，这台设备自己的
  DateTime? ruleSetsUpdatedAt;
  int mixedPort;
  int upstreamPort;
  int clashPort;

  /// 内核里测 DNS 延迟用的入站
  int probePort;
  String clashSecret;

  CoreSettings({
    this.activeProfileId,
    Map<String, String>? selectedNodes,
    Set<String>? favorites,
    List<String>? userAgents,
    String? deviceId,
    this.webDavUrl = '',
    this.webDavUsername = '',
    this.webDavPassword = '',
    this.mode = RouteMode.rule,
    this.capture = false,
    this.providerRulesEnabled = true,
    Map<String, Map<String, String>>? providerTargets,
    this.tun = false,
    this.systemProxy = true,
    this.systemProxyActive = false,
    this.proxyBypass = true,
    List<String>? bypassDomains,
    this.autoConnect = false,
    this.ipStrategy = IpStrategy.ipv4Only,
    DnsSettings? dns,
    TunSettings? tunSettings,
    this.privateDirect = true,
    this.groupsEnabled = true,
    this.hideDisabledGroups = false,
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.testTimeoutSeconds = 5,
    this.testConcurrency = 10,
    this.ntpServer = '',
    List<RuleGroup>? groups,
    NodeTuning? tuning,
    this.directPort = 0,
    this.globalPort = 0,
    this.lanEnabled = false,
    this.lanPort = 17895,
    this.lanGlobalPort = 17896,
    this.lanUsername = '',
    this.lanPassword = '',
    this.mixedUsername = '',
    this.mixedPassword = '',
    String? region,
    this.regionRules = false,
    this.autoHealthCheckSeconds = 0,
    this.logLevel = 'warn',
    this.statsEnabled = false,
    this.statsDays = 7,
    this.rawConfigName = '',
    this.autoBackupOnAdd = true,
    this.autoBackupOnRemove = false,
    this.webDavDownload = DownloadStrategy.preferDirect,
    List<String>? homeStats,
    List<String>? homeSwitches,
    List<String>? homeShortcuts,
    List<String>? alsoEnabledProfiles,
    this.connectedAt,
    this.ruleCheckDomain = 'google.com',
    Set<String>? disabledNodes,
    List<String>? recentNodes,
    List<String>? searchKeywords,
    this.hideRecommendedNodes = false,
    this.hideRecentNodes = false,
    this.hideFavoriteNodes = false,
    this.hideFailedNodes = false,
    this.sortNodesByDelay = false,
    this.autoUpdateAfterTest = true,
    this.finalTarget = RuleTarget.selected,
    List<String>? chain,
    this.chainFront = true,
    List<AutoGroup>? autoGroups,
    this.autoTestMinutes = 480,
    this.autoTolerance = 0,
    this.autoPreferFavorites = false,
    this.autoNodeLimit = 2000,
    this.ruleSetUpdateHours = 24,
    this.updateBundledRuleSets = false,
    this.ruleSetDownload = DownloadStrategy.preferProxy,
    this.ruleSetsUpdatedAt,
    this.mixedPort = 17890,
    this.upstreamPort = 17891,
    this.clashPort = 17892,
    this.probePort = 17893,
    String? clashSecret,
  })  : selectedNodes = selectedNodes ?? {},
        favorites = favorites ?? {},
        dns = dns ?? DnsSettings(),
        tunSettings = tunSettings ?? TunSettings(),
        bypassDomains = bypassDomains ?? [...defaultBypassDomains],
        region = region ?? _systemRegion(),
        tuning = tuning ?? NodeTuning(),
        homeStats = homeStats ?? [HomeStat.speed],
        homeSwitches = homeSwitches ?? [...HomeSwitch.defaults],
        homeShortcuts = homeShortcuts ?? [...HomeShortcut.defaults],
        alsoEnabledProfiles = alsoEnabledProfiles ?? [],
        providerTargets = providerTargets ?? {},
        disabledNodes = disabledNodes ?? {},
        recentNodes = recentNodes ?? [],
        searchKeywords = searchKeywords ?? [],
        chain = chain ?? [],
        autoGroups = autoGroups ?? [],
        userAgents = userAgents ?? [],
        deviceId = deviceId ?? _randomDeviceId(),
        groups = groups ?? RuleGroup.defaults(),
        clashSecret = clashSecret ?? _randomSecret();

  /// zh_CN、zh-Hans-CN 取最后一段，取不到时用 cn：这个软件主要在国内用
  static String _systemRegion() {
    final last = Platform.localeName.split('.').first.split(RegExp('[-_]')).last.toLowerCase();
    return RegExp(r'^[a-z]{2}$').hasMatch(last) ? last : 'cn';
  }

  static const List<String> defaultBypassDomains = ['localhost', '127.*', '10.*', '172.16.*', '192.168.*', '<local>'];

  static String _randomDeviceId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 接口只监听本机，但同一台设备上的其他程序也能访问，所以每次安装生成一个
  static String _randomSecret() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }

  factory CoreSettings.fromJson(Map<String, dynamic> json) => CoreSettings(
        activeProfileId: json['activeProfileId'],
        selectedNodes: (json['selectedNodes'] as Map?)?.cast<String, String>(),
        favorites: (json['favorites'] as List?)?.map((e) => e.toString()).toSet(),
        userAgents: (json['userAgents'] as List?)?.map((e) => e.toString()).toList(),
        deviceId: json['deviceId'],
        webDavUrl: json['webDavUrl'] ?? '',
        webDavUsername: json['webDavUsername'] ?? '',
        webDavPassword: json['webDavPassword'] ?? '',
        mode: RouteMode.values.asNameMap()[json['mode']] ?? RouteMode.rule,
        capture: json['capture'] ?? false,
        providerRulesEnabled: json['providerRulesEnabled'] ?? true,
        providerTargets: (json['providerTargets'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), (value as Map).map((k, v) => MapEntry(k.toString(), v.toString()))),
        ),
        tun: json['tun'] ?? false,
        systemProxy: json['systemProxy'] ?? true,
        systemProxyActive: json['systemProxyActive'] ?? false,
        proxyBypass: json['proxyBypass'] ?? true,
        bypassDomains: (json['bypassDomains'] as List?)?.map((e) => e.toString()).toList(),
        autoConnect: json['autoConnect'] ?? false,
        ipStrategy: IpStrategy.values.asNameMap()[json['ipStrategy']] ?? IpStrategy.ipv4Only,
        dns: json['dns'] == null ? null : DnsSettings.fromJson(json['dns']),
        tunSettings: json['tunSettings'] == null ? null : TunSettings.fromJson(json['tunSettings']),
        privateDirect: json['privateDirect'] ?? true,
        groupsEnabled: json['groupsEnabled'] ?? true,
        hideDisabledGroups: json['hideDisabledGroups'] ?? false,
        testUrl: json['testUrl'] ?? 'https://www.gstatic.com/generate_204',
        testTimeoutSeconds: json['testTimeoutSeconds'] ?? 5,
        testConcurrency: json['testConcurrency'] ?? 10,
        ntpServer: json['ntpServer'] ?? '',
        groups: (json['groups'] as List?)?.map((e) => RuleGroup.fromJson(e)).toList(),
        tuning: json['tuning'] == null ? null : NodeTuning.fromJson(json['tuning']),
        directPort: json['directPort'] ?? 0,
        globalPort: json['globalPort'] ?? 0,
        lanEnabled: json['lanEnabled'] ?? false,
        lanPort: json['lanPort'] ?? 17895,
        lanGlobalPort: json['lanGlobalPort'] ?? 17896,
        lanUsername: json['lanUsername'] ?? '',
        lanPassword: json['lanPassword'] ?? '',
        mixedUsername: json['mixedUsername'] ?? '',
        mixedPassword: json['mixedPassword'] ?? '',
        region: json['region'],
        regionRules: json['regionRules'] ?? false,
        autoHealthCheckSeconds: json['autoHealthCheckSeconds'] ?? 0,
        logLevel: json['logLevel'] ?? 'warn',
        statsEnabled: json['statsEnabled'] ?? false,
        statsDays: json['statsDays'] ?? 7,
        rawConfigName: json['rawConfigName'] ?? '',
        autoBackupOnAdd: json['autoBackupOnAdd'] ?? true,
        autoBackupOnRemove: json['autoBackupOnRemove'] ?? false,
        webDavDownload: DownloadStrategy.values.asNameMap()[json['webDavDownload']] ?? DownloadStrategy.preferDirect,
        homeStats: (json['homeStats'] as List?)?.map((e) => e.toString()).toList(),
        homeSwitches: (json['homeSwitches'] as List?)?.map((e) => e.toString()).toList(),
        homeShortcuts: (json['homeShortcuts'] as List?)?.map((e) => e.toString()).toList(),
        alsoEnabledProfiles: (json['alsoEnabledProfiles'] as List?)?.map((e) => e.toString()).toList(),
        connectedAt: DateTime.tryParse(json['connectedAt'] ?? ''),
        ruleCheckDomain: json['ruleCheckDomain'] ?? 'google.com',
        disabledNodes: (json['disabledNodes'] as List?)?.map((e) => e.toString()).toSet(),
        recentNodes: (json['recentNodes'] as List?)?.map((e) => e.toString()).toList(),
        searchKeywords: (json['searchKeywords'] as List?)?.map((e) => e.toString()).toList(),
        hideRecommendedNodes: json['hideRecommendedNodes'] ?? false,
        hideRecentNodes: json['hideRecentNodes'] ?? false,
        hideFavoriteNodes: json['hideFavoriteNodes'] ?? false,
        hideFailedNodes: json['hideFailedNodes'] ?? false,
        sortNodesByDelay: json['sortNodesByDelay'] ?? false,
        autoUpdateAfterTest: json['autoUpdateAfterTest'] ?? true,
        finalTarget: json['finalTarget'] ?? RuleTarget.selected,
        chain: (json['chain'] as List?)?.map((e) => e.toString()).toList(),
        chainFront: json['chainFront'] ?? true,
        autoGroups: (json['autoGroups'] as List?)?.map((e) => AutoGroup.fromJson(e)).toList(),
        autoTestMinutes: json['autoTestMinutes'] ?? 480,
        autoTolerance: json['autoTolerance'] ?? 0,
        autoPreferFavorites: json['autoPreferFavorites'] ?? false,
        autoNodeLimit: json['autoNodeLimit'] ?? 2000,
        ruleSetUpdateHours: json['ruleSetUpdateHours'] ?? 24,
        updateBundledRuleSets: json['updateBundledRuleSets'] ?? false,
        ruleSetDownload: DownloadStrategy.values.asNameMap()[json['ruleSetDownload']] ?? DownloadStrategy.preferProxy,
        ruleSetsUpdatedAt: DateTime.tryParse(json['ruleSetsUpdatedAt'] ?? ''),
        mixedPort: json['mixedPort'] ?? 17890,
        upstreamPort: json['upstreamPort'] ?? 17891,
        clashPort: json['clashPort'] ?? 17892,
        probePort: json['probePort'] ?? 17893,
        clashSecret: json['clashSecret'],
      );

  Map<String, dynamic> toJson() => {
        'activeProfileId': activeProfileId,
        'selectedNodes': selectedNodes,
        'favorites': favorites.toList(),
        'userAgents': userAgents,
        'deviceId': deviceId,
        'webDavUrl': webDavUrl,
        'webDavUsername': webDavUsername,
        'webDavPassword': webDavPassword,
        'mode': mode.name,
        'capture': capture,
        'providerRulesEnabled': providerRulesEnabled,
        'providerTargets': providerTargets,
        'tun': tun,
        'systemProxy': systemProxy,
        'systemProxyActive': systemProxyActive,
        'proxyBypass': proxyBypass,
        'bypassDomains': bypassDomains,
        'autoConnect': autoConnect,
        'ipStrategy': ipStrategy.name,
        'dns': dns,
        'tunSettings': tunSettings,
        'privateDirect': privateDirect,
        'groupsEnabled': groupsEnabled,
        'hideDisabledGroups': hideDisabledGroups,
        'testUrl': testUrl,
        'testTimeoutSeconds': testTimeoutSeconds,
        'testConcurrency': testConcurrency,
        'ntpServer': ntpServer,
        'groups': groups,
        'tuning': tuning,
        'directPort': directPort,
        'globalPort': globalPort,
        'lanEnabled': lanEnabled,
        'lanPort': lanPort,
        'lanGlobalPort': lanGlobalPort,
        'lanUsername': lanUsername,
        'lanPassword': lanPassword,
        'mixedUsername': mixedUsername,
        'mixedPassword': mixedPassword,
        'region': region,
        'regionRules': regionRules,
        'autoHealthCheckSeconds': autoHealthCheckSeconds,
        'logLevel': logLevel,
        'statsEnabled': statsEnabled,
        'statsDays': statsDays,
        'rawConfigName': rawConfigName,
        'autoBackupOnAdd': autoBackupOnAdd,
        'autoBackupOnRemove': autoBackupOnRemove,
        'webDavDownload': webDavDownload.name,
        'homeStats': homeStats,
        'homeSwitches': homeSwitches,
        'homeShortcuts': homeShortcuts,
        'alsoEnabledProfiles': alsoEnabledProfiles,
        'connectedAt': connectedAt?.toIso8601String(),
        'ruleCheckDomain': ruleCheckDomain,
        'disabledNodes': disabledNodes.toList(),
        'recentNodes': recentNodes,
        'searchKeywords': searchKeywords,
        'hideRecommendedNodes': hideRecommendedNodes,
        'hideRecentNodes': hideRecentNodes,
        'hideFavoriteNodes': hideFavoriteNodes,
        'hideFailedNodes': hideFailedNodes,
        'sortNodesByDelay': sortNodesByDelay,
        'autoUpdateAfterTest': autoUpdateAfterTest,
        'finalTarget': finalTarget,
        'chain': chain,
        'chainFront': chainFront,
        'autoGroups': autoGroups,
        'autoTestMinutes': autoTestMinutes,
        'autoTolerance': autoTolerance,
        'autoPreferFavorites': autoPreferFavorites,
        'autoNodeLimit': autoNodeLimit,
        'ruleSetUpdateHours': ruleSetUpdateHours,
        'updateBundledRuleSets': updateBundledRuleSets,
        'ruleSetDownload': ruleSetDownload.name,
        'ruleSetsUpdatedAt': ruleSetsUpdatedAt?.toIso8601String(),
        'mixedPort': mixedPort,
        'upstreamPort': upstreamPort,
        'clashPort': clashPort,
        'probePort': probePort,
        'clashSecret': clashSecret,
      };
}

/// 设置和配置的本地存储。写入先落到临时文件再改名，写到一半退出不会把文件写坏
class CoreStore {
  final Directory directory;

  CoreStore(this.directory);

  File get _settingsFile => File('${directory.path}/core_settings.json');

  File get _profilesFile => File('${directory.path}/profiles.json');

  /// 节点多时这张表不小，不放进设置里跟着每次保存
  File get _latencyFile => File('${directory.path}/latency.json');

  File get _trafficFile => File('${directory.path}/traffic.json');

  File get _rawConfigFile => File('${directory.path}/raw_config.json');

  Future<CoreSettings> loadSettings() async {
    final json = await _read(_settingsFile);
    return json is Map<String, dynamic> ? CoreSettings.fromJson(json) : CoreSettings();
  }

  Future<List<Profile>> loadProfiles() async {
    final json = await _read(_profilesFile);
    return json is List ? json.map((e) => Profile.fromJson(e)).toList() : [];
  }

  /// 节点 tag -> 延迟（毫秒），不通的是 -1
  Future<Map<String, int>> loadLatency() async {
    final json = await _read(_latencyFile);
    return json is Map ? json.map((key, value) => MapEntry(key.toString(), value as int)) : {};
  }

  Future<void> saveLatency(Map<String, int> latency) => _write(_latencyFile, latency);

  Future<TrafficStats> loadTraffic() async {
    final json = await _read(_trafficFile);
    return json is Map<String, dynamic> ? TrafficStats.fromJson(json) : TrafficStats();
  }

  Future<void> saveTraffic(TrafficStats stats) => _write(_trafficFile, stats);

  /// 用户自己的 sing-box 配置，读不了时返回 null
  Future<Map<String, dynamic>?> loadRawConfig() async {
    final json = await _read(_rawConfigFile);
    return json is Map<String, dynamic> ? json : null;
  }

  Future<void> saveRawConfig(Map<String, dynamic>? config) async {
    if (config != null) return _write(_rawConfigFile, config);
    if (await _rawConfigFile.exists()) await _rawConfigFile.delete();
  }

  Future<void> saveSettings(CoreSettings settings) => _write(_settingsFile, settings);

  Future<void> saveProfiles(List<Profile> profiles) => _write(_profilesFile, profiles);

  Future<Object?> _read(File file) async {
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } on FormatException {
      return null;
    }
  }

  /// 依次写入，连续保存时后一次不会被前一次盖掉
  Future<void> _pending = Future.value();

  Future<void> _write(File file, Object? value) {
    final text = jsonEncode(value);
    return _pending = _pending.catchError((_) {}).then((_) async {
      await directory.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
  }
}
