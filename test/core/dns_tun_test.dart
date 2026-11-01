import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/dns_catalog.dart';
import 'package:proxypin/core/rule_group.dart';

CoreOptions _options({
  DnsSettings? dns,
  TunSettings? tun,
  bool useTun = true,
  int mixedPort = 7890,
  IpStrategy ipStrategy = IpStrategy.ipv4Only,
  List<RuleGroup> groups = const [],
  bool privateDirect = true,
  bool avoidLocalDns = false,
  String? outboundDns,
}) =>
    CoreOptions(
      nodes: const [
        {'type': 'trojan', 'tag': 'HK', 'server': 'h.example', 'server_port': 443, 'password': 'p'}
      ],
      groups: groups,
      dns: dns,
      tunSettings: tun,
      tun: useTun,
      mixedPort: mixedPort,
      ipStrategy: ipStrategy,
      privateDirect: privateDirect,
      avoidLocalDns: avoidLocalDns,
      outboundDns: outboundDns,
      upstreamPort: 7891,
      mitmPort: 9099,
      clashPort: 9191,
      clashSecret: 'secret',
      ruleSetDirectory: 'rules',
      cachePath: 'cache.db',
    );

Map<String, dynamic> _dns(CoreOptions options) => CoreConfig.build(options)['dns'];

Map<String, dynamic> _tun(CoreOptions options) =>
    (CoreConfig.build(options)['inbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == 'tun-in');

Map<String, dynamic> _server(CoreOptions options, String tag) =>
    (_dns(options)['servers'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

List<Map<String, dynamic>> _dnsRules(CoreOptions options) => (_dns(options)['rules'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _routeRules(CoreOptions options) =>
    (CoreConfig.build(options)['route']['rules'] as List).cast<Map<String, dynamic>>();

void main() {
  group('dns servers', () {
    Map<String, dynamic> proxyServer(String url) => _server(_options(dns: DnsSettings(proxy: url)), 'dns-proxy');

    test('every address form becomes the right server', () {
      expect(proxyServer('udp://8.8.8.8'), containsPair('type', 'udp'));
      expect(proxyServer('tcp://8.8.8.8'), containsPair('type', 'tcp'));
      expect(proxyServer('tls://1.1.1.1'), containsPair('type', 'tls'));
      expect(proxyServer('https://1.1.1.1/dns-query'), containsPair('type', 'https'));
      expect(proxyServer('h3://8.8.8.8/dns-query'), containsPair('type', 'h3'));
      expect(proxyServer('quic://dns.adguard.com'), containsPair('type', 'quic'));
      expect(proxyServer('8.8.8.8'), containsPair('type', 'udp'));
      expect(proxyServer('udp://[2400:3200::1]'), containsPair('server', '2400:3200::1'));
    });

    test('a custom port and path are kept, the default path is not repeated', () {
      expect(proxyServer('https://1.1.1.1:8443/custom'), allOf(containsPair('server_port', 8443), containsPair('path', '/custom')));
      expect(proxyServer('https://1.1.1.1/dns-query').containsKey('path'), isFalse);
    });

    test('proxy DNS goes through the selected node, the others do not', () {
      final options = _options(dns: DnsSettings(direct: 'udp://223.5.5.5'));
      expect(_server(options, 'dns-proxy'), containsPair('detour', 'select'));
      expect(_server(options, 'dns-direct').containsKey('detour'), isFalse);
    });

    test('the system resolvers take no address', () {
      expect(_server(_options(dns: DnsSettings(direct: DnsCatalog.dhcp)), 'dns-direct'), {'type': 'dhcp', 'tag': 'dns-direct'});
      expect(_server(_options(), 'dns-direct'), {'type': 'local', 'tag': 'dns-direct'});
    });

    test('a server named by domain resolves through the resolver DNS', () {
      final options = _options(dns: DnsSettings(proxy: 'https://my.example/dns-query'));
      expect(_server(options, 'dns-proxy'), containsPair('domain_resolver', 'dns-resolver'));
    });

    test('known servers use built-in addresses, so they cannot be poisoned', () {
      final on = _options(dns: DnsSettings(proxy: 'https://dns.google/dns-query'));
      expect(_server(on, 'dns-proxy'), containsPair('domain_resolver', 'dns-hosts'));
      expect(_server(on, 'dns-hosts')['predefined'], containsPair('dns.google', ['8.8.8.8', '8.8.4.4']));

      final off = _options(dns: DnsSettings(proxy: 'https://dns.google/dns-query', staticIpForResolver: false));
      expect(_server(off, 'dns-proxy'), containsPair('domain_resolver', 'dns-resolver'));
      expect((_dns(off)['servers'] as List).where((e) => e['tag'] == 'dns-hosts'), isEmpty);
    });

    test('node domains use the outbound DNS, or the one a profile brought', () {
      expect(_server(_options(dns: DnsSettings(outbound: 'udp://8.8.8.8')), 'dns-outbound'), containsPair('server', '8.8.8.8'));
      expect(_server(_options(outboundDns: '1.1.1.1'), 'dns-outbound'), containsPair('server', '1.1.1.1'));
      expect(CoreConfig.build(_options())['route']['default_domain_resolver'], {'server': 'dns-outbound'});
    });

    test('Windows TUN never uses the system resolver, which would loop back', () {
      final options = _options(avoidLocalDns: true, dns: DnsSettings(direct: DnsCatalog.dhcp));
      expect(_server(options, 'dns-direct')['type'], 'udp');
      expect(_server(options, 'dns-outbound')['type'], 'udp');
      expect(_server(options, 'dns-resolver')['type'], 'udp');
    });
  });

  group('proxy resolve', () {
    test('fake IP answers A and AAAA for TUN', () {
      final options = _options();
      expect(_dnsRules(options).last, {
        'query_type': ['A', 'AAAA'],
        'action': 'route',
        'server': 'dns-fakeip',
      });
      expect(_dns(options)['final'], 'dns-proxy');
    });

    test('fake IP means nothing without TUN', () {
      expect(jsonEncode(_dns(_options(useTun: false))), isNot(contains('fakeip')));
    });

    test('the current node resolves real addresses', () {
      final options = _options(dns: DnsSettings(proxyResolve: ProxyResolve.proxy));
      expect(jsonEncode(_dns(options)), isNot(contains('fakeip')));
      expect(_dns(options)['final'], 'dns-proxy');
    });

    test('direct resolves without the node', () {
      final options = _options(dns: DnsSettings(proxyResolve: ProxyResolve.direct));
      expect(jsonEncode(_dns(options)), isNot(contains('fakeip')));
      expect(_dns(options)['final'], 'dns-direct');
    });

    test('IPv6 ranges follow the strategy', () {
      expect(_server(_options(), 'dns-fakeip').containsKey('inet6_range'), isFalse);
      expect(_server(_options(ipStrategy: IpStrategy.preferIpv4), 'dns-fakeip').containsKey('inet6_range'), isTrue);
    });

    test('every strategy maps across', () {
      expect(_dns(_options())['strategy'], 'ipv4_only');
      expect(_dns(_options(ipStrategy: IpStrategy.preferIpv4))['strategy'], 'prefer_ipv4');
      expect(_dns(_options(ipStrategy: IpStrategy.preferIpv6))['strategy'], 'prefer_ipv6');
      expect(_dns(_options(ipStrategy: IpStrategy.ipv6Only))['strategy'], 'ipv6_only');
    });
  });

  group('dns rules', () {
    final groups = [
      RuleGroup(id: 'a', name: 'cn', target: RuleTarget.direct, ruleSets: ['geosite-cn', 'geoip-cn']),
      RuleGroup(id: 'b', name: 'ads', target: RuleTarget.block, domainSuffixes: ['ads.example']),
      RuleGroup(id: 'c', name: 'ai', ruleSets: ['geosite-openai']),
      RuleGroup(id: 'd', name: 'off', target: RuleTarget.direct, domainSuffixes: ['off.example'], enabled: false),
    ];

    test('without them only China goes direct', () {
      final rules = _dnsRules(_options(groups: groups));
      expect(rules.first, {'rule_set': 'geosite-cn', 'action': 'route', 'server': 'dns-direct'});
      expect(jsonEncode(rules), isNot(contains('ads.example')));
    });

    test('with them each group decides, and IP rule sets stay out', () {
      final rules = _dnsRules(_options(groups: groups, dns: DnsSettings(enableRule: true)));

      expect(rules[0]['rule_set'], ['geosite-cn'], reason: 'no IP is known before resolving');
      expect(rules[0]['server'], 'dns-direct');
      expect(rules[1], {'domain_suffix': ['ads.example'], 'action': 'predefined', 'rcode': 'NXDOMAIN'});
      expect(jsonEncode(rules), isNot(contains('openai')), reason: 'node groups fall through to the proxy DNS');
      expect(jsonEncode(rules), isNot(contains('off.example')));
    });

    test('ECS goes on direct lookups only', () {
      final dns = DnsSettings(clientSubnetValue: '1.2.3.0/24');
      final rules = _dnsRules(_options(groups: groups, dns: dns));
      expect(rules.first['client_subnet'], '1.2.3.0/24');
      expect(rules.last.containsKey('client_subnet'), isFalse);

      dns.clientSubnet = false;
      expect(jsonEncode(_dnsRules(_options(groups: groups, dns: dns))), isNot(contains('client_subnet')));
    });

    test('TTL is only rewritten when asked, and never on fake answers', () {
      expect(jsonEncode(_dns(_options(groups: groups))), isNot(contains('rewrite_ttl')));

      final rules = _dnsRules(_options(groups: groups, dns: DnsSettings(ttl: 600)));
      expect(rules.first['rewrite_ttl'], 600);
      expect(rules.last, {'action': 'route', 'server': 'dns-proxy', 'rewrite_ttl': 600});
      expect(rules.firstWhere((e) => e['server'] == 'dns-fakeip').containsKey('rewrite_ttl'), isFalse);
    });

    test('static IPs answer first', () {
      final dns = DnsSettings(staticIp: true, staticIps: {
        'a.example': ['1.2.3.4']
      });
      final options = _options(dns: dns);
      expect(_dnsRules(options).first, {'domain': ['a.example'], 'action': 'route', 'server': 'dns-hosts'});
      expect(_server(options, 'dns-hosts')['predefined'], containsPair('a.example', ['1.2.3.4']));
    });

    test('static IPs that are switched off do nothing', () {
      final dns = DnsSettings(staticIps: {
        'a.example': ['1.2.3.4']
      });
      expect(jsonEncode(_dns(_options(dns: dns))), isNot(contains('a.example')));
    });
  });

  group('routing switches', () {
    test('DNS is hijacked unless switched off, and only for TUN', () {
      bool hijacks(CoreOptions options) => _routeRules(options).any((e) => e['action'] == 'hijack-dns');

      expect(hijacks(_options()), isTrue);
      expect(hijacks(_options(tun: TunSettings(hijackDns: false))), isFalse);
      expect(hijacks(_options(useTun: false)), isFalse);
    });

    test('private networks can be sent through the rules instead', () {
      bool direct(CoreOptions options) =>
          _routeRules(options).any((e) => e['ip_is_private'] == true && e['outbound'] == 'direct');

      expect(direct(_options()), isTrue);
      expect(direct(_options(privateDirect: false)), isFalse);
    });

    test('the rules that declare modes can never match real traffic', () {
      final declared = _routeRules(_options(privateDirect: false)).where((e) => e['domain'] != null).toList();
      expect(declared, hasLength(CoreConfig.modes.length));
      for (final rule in declared) {
        expect(rule['domain'], ['rsproxy.invalid']);
      }
    });

    test('inbound domains are resolved before the groups when asked', () {
      final options = _options(
        dns: DnsSettings(inboundDomainResolve: true),
        groups: [
          RuleGroup(id: 'a', name: 'a', ipCidrs: ['1.0.0.0/8'], target: RuleTarget.direct)
        ],
      );
      final rules = _routeRules(options);
      final resolve = rules.indexWhere((e) => e['action'] == 'resolve');
      expect(rules[resolve]['inbound'], ['mixed-in']);
      expect(resolve, lessThan(rules.indexWhere((e) => e['ip_cidr'] != null)));
    });
  });

  group('tun', () {
    test('defaults match what works on phones', () {
      final tun = _tun(_options());
      expect(tun['stack'], 'gvisor');
      expect(tun['mtu'], 4064);
      expect(tun['auto_route'], isTrue);
      expect(tun['udp_timeout'], '300s');
      expect(tun.containsKey('strict_route'), isFalse, reason: 'it breaks sharing, so it is opt-in');
      expect(tun['address'], ['172.19.0.1/30'], reason: 'IPv6 is off by default');
    });

    test('settings carry over', () {
      final tun = _tun(_options(
          tun: TunSettings(
            mtu: 1500,
            stack: 'system',
            udpTimeoutSeconds: 60,
            strictRoute: true,
            loopbackAddress: '10.7.0.1',
          ),
          ipStrategy: IpStrategy.preferIpv4));
      expect(tun['mtu'], 1500);
      expect(tun['stack'], 'system');
      expect(tun['udp_timeout'], '60s');
      expect(tun['strict_route'], isTrue);
      expect(tun['loopback_address'], ['10.7.0.1']);
      expect(tun['address'], hasLength(2));
    });

    test('excluded ranges are built from the switches', () {
      final tun = _tun(_options(
          tun: TunSettings(
        routeExcludeTun: true,
        routeExcludeMulticast: true,
        hideVpn: true,
        routeExcludeAddresses: ['192.168.0.0/16'],
      )));
      expect(tun['route_exclude_address'], ['172.19.0.1/30', '224.0.0.0/4', '0.0.0.0/31', '192.168.0.0/16']);
    });

    test('the master switch turns them all off', () {
      final tun = _tun(_options(
          tun: TunSettings(routeExclude: false, routeExcludeMulticast: true, routeExcludeAddresses: ['10.0.0.0/8'])));
      expect(tun.containsKey('route_exclude_address'), isFalse);
    });

    test('the HTTP proxy points at the local port', () {
      expect(_tun(_options())['platform'], {
        'http_proxy': {'enabled': true, 'server': '127.0.0.1', 'server_port': 7890}
      });
      expect(_tun(_options(tun: TunSettings(appendHttpProxy: false))).containsKey('platform'), isFalse);
      expect(_tun(_options(mixedPort: 0)).containsKey('platform'), isFalse);
    });

    test('addresses are checked and masks kept in range', () {
      expect(TunSettings.normalizeIpv4('10.20.0.1'), '10.20.0.1/30');
      expect(TunSettings.normalizeIpv4('10.20.0.1/16'), '10.20.0.1/24');
      expect(TunSettings.normalizeIpv4('10.20.0.1/32'), '10.20.0.1/30');
      expect(TunSettings.normalizeIpv4('300.1.1.1'), isNull);
      expect(TunSettings.normalizeIpv4('nonsense'), isNull);

      expect(TunSettings.normalizeIpv6('fdfe::1'), 'fdfe::1/126');
      expect(TunSettings.normalizeIpv6('fdfe::1/48'), 'fdfe::1/64');
      expect(TunSettings.normalizeIpv6('10.0.0.1'), isNull);
    });

    test('settings survive being saved', () {
      final tun = TunSettings(mtu: 1400, hideVpn: true, routeExcludeAddresses: ['10.0.0.0/8'], defaultRoute: false);
      final dns = DnsSettings(proxyResolve: ProxyResolve.direct, ttl: 60, staticIps: {
        'a.example': ['1.2.3.4']
      });
      expect(jsonEncode(TunSettings.fromJson(jsonDecode(jsonEncode(tun)))), jsonEncode(tun));
      expect(jsonEncode(DnsSettings.fromJson(jsonDecode(jsonEncode(dns)))), jsonEncode(dns));
    });
  });

  test('the catalog marks which servers need resolving first', () {
    bool named(String url) => DnsServer('', url).usesHostName;

    expect(named('https://dns.google/dns-query'), isTrue);
    expect(named('tls://dot.pub'), isTrue);
    expect(named('https://1.1.1.1/dns-query'), isFalse);
    expect(named('udp://[2400:3200::1]'), isFalse);
    expect(named(DnsCatalog.local), isFalse);
    expect(named(DnsCatalog.dhcp), isFalse);
  });

  group('manager', () {
    late Directory root;
    late _Platform platform;
    var lookups = 0;
    String? lookupResult;

    CoreManager build() => CoreManager(
          platform: platform,
          store: CoreStore(root),
          mitm: _Mitm(),
          loadRuleSet: (_) async => Uint8List(0),
          apiFactory: (_, __) => _Api(),
          clientSubnetLookup: () async {
            lookups++;
            return lookupResult;
          },
        );

    setUp(() {
      root = Directory.systemTemp.createTempSync('rsproxy_dns_');
      platform = _Platform(root);
      lookups = 0;
      lookupResult = '1.2.3.0/24';
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // ignored
      }
    });

    Map<String, dynamic> config() => jsonDecode(File('${root.path}/config.json').readAsStringSync());

    test('the local network is looked up at most once a day, and only when it helps', () async {
      final manager = build();
      await manager.load();

      await manager.connect();
      expect(lookups, 0, reason: 'the system resolver takes no client subnet');

      await manager.disconnect();
      manager.settings.dns.direct = 'udp://223.5.5.5';
      await manager.connect();
      expect(lookups, 1);
      expect(manager.settings.dns.clientSubnetValue, '1.2.3.0/24');

      await manager.disconnect();
      await manager.connect();
      expect(lookups, 1);
    });

    test('a failed lookup does not stop the connection', () async {
      lookupResult = null;
      final manager = build();
      await manager.load();
      manager.settings.dns.direct = 'udp://223.5.5.5';
      await manager.connect();

      expect(manager.state, CoreState.running);
      expect(manager.settings.dns.clientSubnetValue, isEmpty);
    });

    test('the groups master switch drops them all', () async {
      final manager = build();
      await manager.load();
      manager.settings
        ..groupsEnabled = false
        ..groups = [
          RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example'])
        ];
      await manager.connect();

      expect(jsonEncode(config()), isNot(contains('a.example')));
    });

    test('system options reach the tunnel when it starts', () async {
      final manager = CoreManager(
        platform: platform,
        store: CoreStore(root),
        mitm: _Mitm(),
        alwaysTun: true,
        loadRuleSet: (_) async => Uint8List(0),
        apiFactory: (_, __) => _Api(),
      );
      await manager.load();
      manager.settings.tunSettings
        ..excludeApns = true
        ..defaultRoute = false;
      await manager.connect();

      expect(platform.startOptions, containsPair('excludeApns', true));
      expect(platform.startOptions, containsPair('defaultRoute', false));
    });
  });

  // CI points this at a folder and runs `sing-box check` over what lands there.
  test('writes a config with every option on, for sing-box to check', () {
    final directory = Platform.environment['CORE_CONFIG_OUT'];
    if (directory == null) return;
    Directory(directory).createSync(recursive: true);

    final options = _options(
      ipStrategy: IpStrategy.preferIpv4,
      groups: [
        RuleGroup(id: 'a', name: 'a', target: RuleTarget.direct, domainSuffixes: ['a.example'], ruleSets: ['geosite-cn']),
        RuleGroup(id: 'b', name: 'b', target: RuleTarget.block, domainKeywords: ['ads']),
      ],
      dns: DnsSettings(
        resolver: 'udp://223.5.5.5',
        outbound: 'tls://1.1.1.1',
        direct: 'https://dns.alidns.com/dns-query',
        proxy: 'h3://8.8.8.8/dns-query',
        ttl: 600,
        enableRule: true,
        clientSubnetValue: '1.2.3.0/24',
        inboundDomainResolve: true,
        staticIp: true,
        staticIps: {
          'a.example': ['1.2.3.4', '2001:db8::1']
        },
      ),
      tun: TunSettings(
        stack: 'system',
        mtu: 1500,
        strictRoute: true,
        loopbackAddress: '10.7.0.1',
        routeExcludeTun: true,
        routeExcludeMulticast: true,
        hideVpn: true,
        routeExcludeAddresses: ['192.168.0.0/16'],
      ),
    );
    File('$directory/all-options.json').writeAsStringSync(jsonEncode(CoreConfig.build(options)));

    final dhcp = _options(dns: DnsSettings(direct: DnsCatalog.dhcp, proxy: 'quic://dns.adguard.com', proxyResolve: ProxyResolve.proxy));
    File('$directory/dhcp.json').writeAsStringSync(jsonEncode(CoreConfig.build(dhcp)));
  });
}

class _Platform implements CorePlatform {
  final Directory root;
  Map<String, Object> startOptions = const {};
  bool running = false;

  _Platform(this.root);

  @override
  Stream<CoreState> get states => const Stream.empty();

  @override
  Stream<String> get links => const Stream.empty();

  @override
  Future<String?> takePendingLink() async => null;

  @override
  Future<Directory> directory() async => root;

  @override
  Future<String> cachePath() async => '${root.path}/cache.db';

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<void> start([Map<String, Object> options = const {}]) async {
    startOptions = options;
    running = true;
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> stop() async => running = false;

  @override
  Future<void> setSystemProxy(int? port, {List<String> bypass = const []}) async {}

  @override
  Future<void> setKeepAlive(bool enabled) async {}

  @override
  Future<void> watchCapture({required int port, required int clashPort, required String secret, required String fallbackMode}) async {}

  @override
  Future<void> unwatchCapture() async {}

  @override
  Future<String?> lastFailure() async => null;
}

class _Mitm implements MitmHost {
  @override
  int get port => 9099;

  @override
  List<String>? get domains => const [];

  @override
  List<String> editableDomains = [];

  @override
  Future<void> attach(int upstreamPort) async {}

  @override
  Future<void> detach() async {}
}

class _Api extends ClashApi {
  _Api() : super(port: 1, secret: 's');

  @override
  Future<String?> mode() async => 'Rule';

  @override
  Future<void> setMode(String mode) async {}
}
