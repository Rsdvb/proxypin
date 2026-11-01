import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'core_config.dart';
import 'dns_catalog.dart';
import 'profile.dart';
import 'rule_group.dart';

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
      };
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
  List<RuleGroup> groups;

  /// 分流都没命中时的去向
  String finalTarget;

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
    List<RuleGroup>? groups,
    this.finalTarget = RuleTarget.selected,
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
        userAgents = userAgents ?? [],
        deviceId = deviceId ?? _randomDeviceId(),
        groups = groups ?? RuleGroup.defaults(),
        clashSecret = clashSecret ?? _randomSecret();

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
        groups: (json['groups'] as List?)?.map((e) => RuleGroup.fromJson(e)).toList(),
        finalTarget: json['finalTarget'] ?? RuleTarget.selected,
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
        'groups': groups,
        'finalTarget': finalTarget,
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

  Future<CoreSettings> loadSettings() async {
    final json = await _read(_settingsFile);
    return json is Map<String, dynamic> ? CoreSettings.fromJson(json) : CoreSettings();
  }

  Future<List<Profile>> loadProfiles() async {
    final json = await _read(_profilesFile);
    return json is List ? json.map((e) => Profile.fromJson(e)).toList() : [];
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
