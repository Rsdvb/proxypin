import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_routing.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/rule_group.dart';

const _nodes = [
  {'type': 'trojan', 'tag': 'HK', 'server': 'h.example', 'server_port': 443, 'password': 'p'},
  {'type': 'trojan', 'tag': 'JP', 'server': 'j.example', 'server_port': 443, 'password': 'p'},
];

CoreOptions _options({
  List<Map<String, dynamic>> nodes = _nodes,
  String? selected,
  List<RuleGroup>? groups,
  bool tun = false,
  int mixedPort = 7890,
  List<String>? mitmDomains = const ['example.com'],
}) =>
    CoreOptions(
      nodes: nodes,
      selected: selected,
      groups: groups ?? [],
      tun: tun,
      mixedPort: mixedPort,
      upstreamPort: 7891,
      mitmPort: 9099,
      mitmDomains: mitmDomains,
      clashPort: 9191,
      clashSecret: 'secret',
      ruleSetDirectory: 'rules',
      cachePath: 'cache.db',
    );

List<Map<String, dynamic>> _rules(Map<String, dynamic> config) =>
    (config['route']['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _outbound(Map<String, dynamic> config, String tag) =>
    (config['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

void main() {
  test('every mode string is reachable from the mode and capture switches', () {
    expect(CoreConfig.clashModeOf(RouteMode.rule, capture: false), CoreConfig.modeRule);
    expect(CoreConfig.clashModeOf(RouteMode.rule, capture: true), CoreConfig.modeCaptureRule);
    expect(CoreConfig.clashModeOf(RouteMode.global, capture: false), CoreConfig.modeGlobal);
    expect(CoreConfig.clashModeOf(RouteMode.global, capture: true), CoreConfig.modeCaptureGlobal);
  });

  test('every mode is declared, because sing-box silently ignores any other', () {
    for (final domains in [const ['example.com'], const <String>[], null]) {
      final rules = _rules(CoreConfig.build(_options(mitmDomains: domains)));
      final declared = rules.map((e) => e['clash_mode']).whereType<String>().toSet();
      expect(declared, containsAll(CoreConfig.modes), reason: 'with decryption list $domains');
    }
  });

  test('decrypted traffic cannot loop back into the decryption port', () {
    final rules = _rules(CoreConfig.build(_options(tun: true)));
    final toMitm = rules.where((e) => e['outbound'] == 'rs-mitm').toList();
    expect(toMitm, hasLength(2));
    for (final rule in toMitm) {
      expect(rule['inbound'], ['tun-in', 'mixed-in']);
      expect(rule['inbound'], isNot(contains('upstream-in')));
      expect(rule['domain_suffix'], ['example.com']);
    }
  });

  test('decryption only applies in the capture modes', () {
    final rules = _rules(CoreConfig.build(_options()));
    final modes = rules.where((e) => e['outbound'] == 'rs-mitm').map((e) => e['clash_mode']).toSet();
    expect(modes, {CoreConfig.modeCaptureRule, CoreConfig.modeCaptureGlobal});
  });

  test('HTTP/3 is refused for decrypted domains so clients fall back to TCP', () {
    final rules = _rules(CoreConfig.build(_options()));
    final refused = rules.where((e) => e['action'] == 'reject' && e['port'] == 443).toList();
    expect(refused, hasLength(2));
    for (final rule in refused) {
      expect(rule['network'], 'udp');
      expect(rule['domain_suffix'], ['example.com']);
    }
    final firstRefuse = rules.indexOf(refused.first);
    final firstRoute = rules.indexWhere((e) => e['outbound'] == 'rs-mitm');
    expect(firstRefuse, lessThan(firstRoute));
  });

  test('an empty list decrypts nothing; a null list hands all TCP to RsProxy', () {
    final none = _rules(CoreConfig.build(_options(mitmDomains: const [])));
    expect(none.where((e) => e['outbound'] == 'rs-mitm'), isEmpty);

    final all = _rules(CoreConfig.build(_options(mitmDomains: null)));
    final toMitm = all.where((e) => e['outbound'] == 'rs-mitm').toList();
    expect(toMitm, hasLength(2));
    expect(toMitm.first.containsKey('domain_suffix'), isFalse);
  });

  test('decryption rules come before the groups, which would otherwise win', () {
    final config = CoreConfig.build(_options(groups: [
      RuleGroup(id: 'x', name: 'x', domainSuffixes: ['example.com'], target: RuleTarget.direct),
    ]));
    final rules = _rules(config);
    final mitm = rules.indexWhere((e) => e['outbound'] == 'rs-mitm');
    final group = rules.indexWhere((e) => e['domain_suffix']?.contains('example.com') == true && e['outbound'] == 'direct');
    expect(mitm, greaterThanOrEqualTo(0));
    expect(mitm, lessThan(group));
  });

  test('global mode skips the groups', () {
    final rules = _rules(CoreConfig.build(_options(groups: RuleGroup.defaults())));
    final global = rules.indexWhere((e) => e['clash_mode'] == CoreConfig.modeGlobal && e['outbound'] == 'select');
    final firstGroup = rules.indexWhere((e) => e['rule_set'] != null);
    expect(global, greaterThanOrEqualTo(0));
    expect(global, lessThan(firstGroup));
  });

  test('group targets become the right action', () {
    final rules = _rules(CoreConfig.build(_options(groups: [
      RuleGroup(id: 'a', name: 'a', domainSuffixes: ['block.example'], target: RuleTarget.block),
      RuleGroup(id: 'b', name: 'b', domainSuffixes: ['direct.example'], target: RuleTarget.direct),
      RuleGroup(id: 'c', name: 'c', domainSuffixes: ['node.example'], target: 'JP'),
      RuleGroup(id: 'd', name: 'd', domainSuffixes: ['gone.example'], target: 'removed node'),
      RuleGroup(id: 'e', name: 'e', domainSuffixes: ['off.example'], enabled: false),
      RuleGroup(id: 'f', name: 'nothing to match'),
    ])));

    Map<String, dynamic> rule(String domain) => rules.firstWhere((e) => e['domain_suffix']?.contains(domain) == true);

    expect(rule('block.example')['action'], 'reject');
    expect(rule('direct.example')['outbound'], 'direct');
    expect(rule('node.example')['outbound'], 'JP');
    expect(rule('gone.example')['outbound'], 'select', reason: 'a node removed by an update falls back');
    expect(rules.where((e) => e['domain_suffix']?.contains('off.example') == true), isEmpty);
  });

  test('only rule sets in use are loaded', () {
    final config = CoreConfig.build(_options(groups: [
      RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-netflix']),
      RuleGroup(id: 'b', name: 'b', ruleSets: ['geosite-apple'], enabled: false),
    ]));
    final sets = (config['route']['rule_set'] as List).cast<Map<String, dynamic>>();
    expect(sets.map((e) => e['tag']), ['geosite-netflix']);
    expect(sets.single['path'], 'rules/geosite-netflix.srs');
  });

  test('selector offers auto, every node and direct', () {
    final config = CoreConfig.build(_options(selected: 'JP'));
    final select = _outbound(config, 'select');
    expect(select['outbounds'], ['auto', 'HK', 'JP', 'direct']);
    expect(select['default'], 'JP');
    expect(_outbound(config, 'auto')['outbounds'], ['HK', 'JP']);
  });

  test('a selection that no longer exists falls back to the first choice', () {
    expect(_outbound(CoreConfig.build(_options(selected: 'gone')), 'select')['default'], 'auto');
  });

  test('works with no profile at all, so decryption is usable alone', () {
    final config = CoreConfig.build(_options(nodes: const []));
    final select = _outbound(config, 'select');
    expect(select['outbounds'], ['direct']);
    expect(select['default'], 'direct');
    expect((config['outbounds'] as List).where((e) => e['tag'] == 'auto'), isEmpty);
  });

  test('fake DNS is used only with TUN', () {
    expect(jsonEncode(CoreConfig.build(_options(tun: false))['dns']), isNot(contains('fakeip')));
    expect(jsonEncode(CoreConfig.build(_options(tun: true))['dns']), contains('fakeip'));
  });

  test('HTTPS records are withheld for decrypted domains so ECH cannot hide them', () {
    final rules = (CoreConfig.build(_options())['dns']['rules'] as List).cast<Map<String, dynamic>>();
    expect(rules.first, containsPair('query_type', 'HTTPS'));
    expect(rules.first, containsPair('domain_suffix', ['example.com']));
  });

  test('default groups only name rule sets the app bundles', () {
    final bundled = File('tool/rule_sets.txt').readAsLinesSync().map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    final used = {for (final group in RuleGroup.defaults()) ...group.ruleSets};
    expect(bundled.containsAll(used), isTrue, reason: 'missing: ${used.difference(bundled)}');
  });

  test('groups survive a round trip through json', () {
    final groups = RuleGroup.defaults();
    final decoded = (jsonDecode(jsonEncode(groups)) as List).map((e) => RuleGroup.fromJson(e)).toList();
    expect(decoded.map((e) => e.toJson()), groups.map((e) => e.toJson()));
  });

  // CI points this at a folder and runs `sing-box check` over what lands there.
  test('writes sample configs for sing-box to check', () {
    final directory = Platform.environment['CORE_CONFIG_OUT'];
    if (directory == null) return;
    Directory(directory).createSync(recursive: true);

    final nodes = [
      ..._nodes,
      {'type': 'shadowsocks', 'tag': 'SS', 'server': 's.example', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'p'},
    ];
    final samples = {
      'desktop': _options(nodes: nodes, groups: RuleGroup.defaults()),
      'tun': _options(nodes: nodes, groups: RuleGroup.defaults(), tun: true, mixedPort: 0),
      'empty': _options(nodes: const [], groups: const [], mitmDomains: null),
      'provider': CoreOptions(
        nodes: nodes,
        groups: const [],
        mixedPort: 7890,
        upstreamPort: 7891,
        mitmPort: 9099,
        clashPort: 9191,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
        outboundDns: '1.1.1.1',
        providerRuleSets: const {'geoip-cn'},
        providerRouting: ProviderRouting.parse({
          'proxy-groups': [
            {'name': 'Proxy', 'type': 'select', 'proxies': ['Auto', 'HK', 'DIRECT']},
            {'name': 'Auto', 'type': 'url-test', 'proxies': ['HK', 'JP']},
          ],
          'rules': [
            'DOMAIN-SUFFIX,a.example,Proxy',
            'DOMAIN-KEYWORD,b,DIRECT',
            'IP-CIDR,10.1.0.0/16,DIRECT,no-resolve',
            'GEOIP,CN,DIRECT',
            'DOMAIN,ads.example,REJECT',
            'MATCH,Proxy',
          ],
        }),
      ),
    };
    samples.forEach((name, options) {
      File('$directory/$name.json').writeAsStringSync(jsonEncode(CoreConfig.build(options)));
    });
  });
}
