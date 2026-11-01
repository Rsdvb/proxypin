import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/clash_routing.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/core/rule_sets.dart';
import 'package:proxypin/ui/core/rule_group_edit_page.dart';
import 'package:proxypin/ui/core/rule_sets_page.dart';

const _nodes = [
  {'type': 'trojan', 'tag': 'HK', 'server': 'h.example', 'server_port': 443, 'password': 'p'},
  {'type': 'trojan', 'tag': 'JP', 'server': 'j.example', 'server_port': 443, 'password': 'p'},
];

CoreOptions _options({
  List<Map<String, dynamic>> nodes = _nodes,
  List<RuleGroup> groups = const [],
  String finalTarget = RuleTarget.selected,
  ProviderRouting? provider,
  DnsSettings? dns,
}) =>
    CoreOptions(
      nodes: nodes,
      groups: groups,
      finalTarget: finalTarget,
      providerRouting: provider,
      dns: dns,
      mixedPort: 7890,
      upstreamPort: 7891,
      mitmPort: 9099,
      clashPort: 9191,
      clashSecret: 'secret',
      ruleSetDirectory: 'rules',
      cachePath: 'cache.db',
    );

List<Map<String, dynamic>> _rules(CoreOptions options) =>
    (CoreConfig.build(options)['route']['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _ruleFor(CoreOptions options, String key) => _rules(options).firstWhere((e) => e.containsKey(key));

Map<String, dynamic> _dns(CoreOptions options) => CoreConfig.build(options)['dns'];

List<Map<String, dynamic>> _dnsRules(CoreOptions options) => (_dns(options)['rules'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _dnsServers(CoreOptions options) =>
    (_dns(options)['servers'] as List).cast<Map<String, dynamic>>();

/// 能通过内核校验的最小 .srs 文件头
Uint8List _srs() => Uint8List.fromList([0x53, 0x52, 0x53, 3, 0]);

final RuleGroup _everyCondition = RuleGroup(
  id: 'all',
  name: 'all',
  target: 'JP',
  ruleSets: ['geosite-cn'],
  domains: ['www.example.com'],
  domainSuffixes: ['example.com'],
  domainKeywords: ['example'],
  domainRegexes: [r'^ads?\.'],
  ipCidrs: ['1.2.3.0/24'],
  ports: [443],
  portRanges: ['1000:2000'],
  networks: ['tcp'],
  protocols: ['tls'],
  networkTypes: ['wifi'],
  wifiSsids: ['Home'],
  wifiBssids: ['aa:bb:cc:dd:ee:ff'],
  processNames: ['chrome.exe'],
  processPaths: [r'C:\App\app.exe'],
  processDirs: [r'C:\Program Files\App\'],
);

void main() {
  group('match conditions', () {
    test('every condition reaches the rule under the field name the core reads', () {
      final rule = _ruleFor(_options(groups: [_everyCondition]), 'wifi_ssid');

      expect(rule, {
        'rule_set': ['geosite-cn'],
        'domain': ['www.example.com'],
        'domain_suffix': ['example.com'],
        'domain_keyword': ['example'],
        'domain_regex': [r'^ads?\.'],
        'ip_cidr': ['1.2.3.0/24'],
        'port': [443],
        'port_range': ['1000:2000'],
        'network': ['tcp'],
        'protocol': ['tls'],
        'network_type': ['wifi'],
        'wifi_ssid': ['Home'],
        'wifi_bssid': ['aa:bb:cc:dd:ee:ff'],
        'process_name': ['chrome.exe'],
        'process_path': [r'C:\App\app.exe'],
        'process_path_regex': [r'(?i)^C:\\Program Files\\App[\\/]'],
        'action': 'route',
        'outbound': 'JP',
      });
    });

    test('a directory matches the programs inside it, not a sibling with the same prefix', () {
      final rule = _ruleFor(_options(groups: [RuleGroup(id: 'a', name: 'a', processDirs: [r'C:\App (x86)'])]), 'process_path_regex');
      final regex = RegExp((rule['process_path_regex'] as List).single.toString().replaceFirst('(?i)', ''));

      expect(regex.hasMatch(r'C:\App (x86)\tool.exe'), isTrue);
      expect(regex.hasMatch(r'C:\App (x86) old\tool.exe'), isFalse);
    });

    test('"any of" becomes a logical rule with the action outside it', () {
      final rule = _ruleFor(
          _options(groups: [
            RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example'], ports: [22], matchOr: true, target: RuleTarget.direct)
          ]),
          'mode');

      expect(rule, {
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {'domain_suffix': ['a.example']},
          {'port': [22]},
        ],
        'action': 'route',
        'outbound': 'direct',
      });
    });

    test('"any of" with a single condition stays a plain rule', () {
      final rule = _ruleFor(
          _options(groups: [RuleGroup(id: 'a', name: 'a', ports: [22], matchOr: true)]), 'port');
      expect(rule.containsKey('type'), isFalse);
    });
  });

  group('targets', () {
    Map<String, dynamic> rule(String target, {List<Map<String, dynamic>> nodes = _nodes}) => _ruleFor(
        _options(nodes: nodes, groups: [RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example'], target: target)]),
        'domain_suffix');

    test('auto uses the urltest group', () => expect(rule(RuleTarget.auto)['outbound'], 'auto'));

    test('auto with one node falls back, because no urltest group exists then', () {
      final one = rule(RuleTarget.auto, nodes: [_nodes.first]);
      expect(one['outbound'], 'select');
    });

    test('block is a route action, not an outbound', () {
      final blocked = rule(RuleTarget.block);
      expect(blocked['action'], 'reject');
      expect(blocked.containsKey('outbound'), isFalse);
    });

    test('a node that disappeared follows the selection', () => expect(rule('gone')['outbound'], 'select'));
  });

  group('the fallback target', () {
    String finalOf(CoreOptions options) => CoreConfig.build(options)['route']['final'];

    test('follows the selection by default', () => expect(finalOf(_options()), 'select'));

    test('can be direct, auto or a node', () {
      expect(finalOf(_options(finalTarget: RuleTarget.direct)), 'direct');
      expect(finalOf(_options(finalTarget: RuleTarget.auto)), 'auto');
      expect(finalOf(_options(finalTarget: 'JP')), 'JP');
    });

    test('blocking takes a last rule, because route.final must be an outbound', () {
      final options = _options(finalTarget: RuleTarget.block);
      expect(_rules(options).last, {'action': 'reject'});
      expect(finalOf(options), 'select');
    });

    final provider = ProviderRouting.parse({
      'proxy-groups': [],
      'rules': ['MATCH,DIRECT'],
    });

    test('the provider MATCH applies only while the user has not chosen', () {
      expect(finalOf(_options(provider: provider)), 'direct');
      expect(finalOf(_options(provider: provider, finalTarget: 'JP')), 'JP');
    });
  });

  group('custom auto groups', () {
    final group = AutoGroup(name: 'Asia', nodes: const ['HK'], keywords: const ['jp']);

    test('take named nodes and anything matching a keyword, ignoring case', () {
      expect(group.membersIn(['HK', 'JP', 'US']), ['HK', 'JP']);
    });

    test('become urltest groups a rule can point at', () {
      final options = CoreOptions(
        nodes: _nodes,
        autoGroups: [group],
        groups: [RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example'], target: group.tag)],
        upstreamPort: 7891,
        mitmPort: 9099,
        clashPort: 9191,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
      );
      final config = CoreConfig.build(options);
      final outbound = (config['outbounds'] as List).firstWhere((e) => e['tag'] == group.tag);

      expect(outbound['type'], 'urltest');
      expect(outbound['outbounds'], ['HK', 'JP']);
      expect((config['outbounds'] as List).first['outbounds'], contains(group.tag), reason: 'can be selected too');
      expect((config['route']['rules'] as List).firstWhere((e) => e['domain_suffix'] != null)['outbound'], group.tag);
    });

    Map<String, dynamic> config(List<AutoGroup> groups, {List<RuleGroup> rules = const []}) => CoreConfig.build(CoreOptions(
          nodes: _nodes,
          autoGroups: groups,
          groups: rules,
          upstreamPort: 7891,
          mitmPort: 9099,
          clashPort: 9191,
          clashSecret: 'secret',
          ruleSetDirectory: 'rules',
          cachePath: 'cache.db',
        ));

    Map<String, dynamic> outbound(Map<String, dynamic> built, String tag) =>
        (built['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

    test('an empty group is left out and rules pointing at it fall back', () {
      final built = config([
        AutoGroup(name: 'empty')
      ], rules: [
        RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example'], target: 'auto:empty')
      ]);

      expect((built['outbounds'] as List).any((e) => e['tag'] == 'auto:empty'), isFalse);
      expect((built['route']['rules'] as List).firstWhere((e) => e['domain_suffix'] != null)['outbound'], 'select');
    });

    test('a front group applies only inside the group, through copies of its nodes', () {
      final built = config([
        AutoGroup(name: 'exit', nodes: const ['HK'], front: 'entry'),
        AutoGroup(name: 'entry', nodes: const ['JP']),
      ]);

      expect(outbound(built, 'auto:exit')['outbounds'], ['auto:exit/HK']);
      expect(outbound(built, 'auto:exit/HK')['detour'], 'auto:entry');
      expect(outbound(built, 'auto:exit/HK')['server'], 'h.example');
      expect(outbound(built, 'HK').containsKey('detour'), isFalse);
    });

    test('a loop of front groups from an old backup is dropped, or the core would not start', () {
      final built = config([
        AutoGroup(name: 'a', nodes: const ['HK'], front: 'b'),
        AutoGroup(name: 'b', nodes: const ['JP'], front: 'a'),
      ]);

      expect(outbound(built, 'auto:a')['outbounds'], ['HK']);
      expect(outbound(built, 'auto:b')['outbounds'], ['JP']);
    });

    test('a front group with no members is ignored', () {
      final built = config([
        AutoGroup(name: 'a', nodes: const ['HK'], front: 'empty'),
        AutoGroup(name: 'empty'),
      ]);
      expect(outbound(built, 'auto:a')['outbounds'], ['HK']);
    });
  });

  group('auto select settings', () {
    Map<String, dynamic> auto({int minutes = 480, int tolerance = 0, Set<String> favorites = const {}, int limit = 2000}) {
      final config = CoreConfig.build(CoreOptions(
        nodes: _nodes,
        autoTestMinutes: minutes,
        autoTolerance: tolerance,
        autoFavorites: favorites,
        autoNodeLimit: limit,
        upstreamPort: 7891,
        mitmPort: 9099,
        clashPort: 9191,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
      ));
      return (config['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == 'auto');
    }

    test('the interval can never exceed idle_timeout, the core refuses that', () {
      expect(auto(minutes: 480)['idle_timeout'], '480m');
      expect(auto(minutes: 5)['interval'], '5m');
      expect(auto(minutes: 5)['idle_timeout'], '30m');
    });

    test('zero tolerance is written as 1, because the core reads 0 as "use 50"', () {
      expect(auto()['tolerance'], 1);
      expect(auto(tolerance: 200)['tolerance'], 200);
    });

    test('favorites narrow the choice when there are any among the nodes', () {
      expect(auto(favorites: {'JP'})['outbounds'], ['HK', 'JP'], reason: 'one favorite is not enough to pick from');
    });

    test('the node limit keeps the first ones', () {
      expect(auto(limit: 2)['outbounds'], ['HK', 'JP']);
    });
  });

  group('chain proxy', () {
    const three = [
      {'type': 'trojan', 'tag': 'A', 'server': 'a.example', 'server_port': 443, 'password': 'p'},
      {'type': 'trojan', 'tag': 'B', 'server': 'b.example', 'server_port': 443, 'password': 'p'},
      {'type': 'trojan', 'tag': 'C', 'server': 'c.example', 'server_port': 443, 'password': 'p'},
      {'type': 'trojan', 'tag': 'D', 'server': 'd.example', 'server_port': 443, 'password': 'p'},
    ];

    Map<String, dynamic> build({List<String> chain = const ['A', 'B'], bool front = true, List<AutoGroup> groups = const []}) =>
        CoreConfig.build(CoreOptions(
          nodes: three,
          chain: chain,
          chainFront: front,
          autoGroups: groups,
          mixedPort: 7890,
          upstreamPort: 7891,
          mitmPort: 9099,
          clashPort: 9191,
          clashSecret: 'secret',
          ruleSetDirectory: 'rules',
          cachePath: 'cache.db',
        ));

    Map<String, dynamic> outbound(Map<String, dynamic> config, String tag) =>
        (config['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

    test('in front: every node sits behind the end of the chain', () {
      final config = build();

      expect(outbound(config, 'A').containsKey('detour'), isFalse);
      expect(outbound(config, 'B')['detour'], 'A');
      expect(outbound(config, 'C')['detour'], 'B');
      expect(outbound(config, 'D')['detour'], 'B');
      expect(config['route']['final'], 'select');
    });

    test('behind: traffic leaves through the last hop, which follows the selection', () {
      final config = build(front: false);

      expect(outbound(config, 'A')['detour'], 'select');
      expect(outbound(config, 'B')['detour'], 'A');
      expect(outbound(config, 'C').containsKey('detour'), isFalse);
      expect(config['route']['final'], 'B');
    });

    test('behind: chain nodes leave every group that leads back to them', () {
      final config = build(front: false, groups: [AutoGroup(name: 'g', keywords: const ['a', 'c'])]);

      expect(outbound(config, 'select')['outbounds'], ['auto', 'auto:g', 'C', 'D', 'direct']);
      expect(outbound(config, 'auto')['outbounds'], ['C', 'D']);
      expect(outbound(config, 'auto:g')['outbounds'], ['C']);
    });

    test('nodes that are gone are skipped', () {
      final config = build(chain: const ['gone', 'A']);
      expect(outbound(config, 'A').containsKey('detour'), isFalse);
      expect(outbound(config, 'C')['detour'], 'A');
    });

    test('no chain leaves the nodes alone', () {
      expect(outbound(build(chain: const []), 'C').containsKey('detour'), isFalse);
    });

    test('a node with its own detour keeps it', () {
      final config = CoreConfig.build(CoreOptions(
        nodes: const [
          {'type': 'trojan', 'tag': 'A', 'server': 'a.example', 'server_port': 443, 'password': 'p'},
          {'type': 'trojan', 'tag': 'B', 'server': 'b.example', 'server_port': 443, 'password': 'p', 'detour': 'C'},
          {'type': 'trojan', 'tag': 'C', 'server': 'c.example', 'server_port': 443, 'password': 'p'},
        ],
        chain: const ['A'],
        upstreamPort: 7891,
        mitmPort: 9099,
        clashPort: 9191,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
      ));
      expect(outbound(config, 'B')['detour'], 'C');
    });
  });

  group('dns per group', () {
    final direct = RuleGroup(id: 'd', name: 'd', target: RuleTarget.direct, domainSuffixes: ['d.example'], dnsServer: 'udp://9.9.9.9');
    final node = RuleGroup(id: 'n', name: 'n', target: 'JP', domainSuffixes: ['n.example'], dnsServer: 'tls://9.9.9.10');

    test('gets its own server, going out the way the group does', () {
      final servers = _dnsServers(_options(groups: [direct, node]));

      final directServer = servers.firstWhere((e) => e['server'] == '9.9.9.9');
      expect(directServer['detour'], 'direct');
      expect(servers.firstWhere((e) => e['server'] == '9.9.9.10')['detour'], 'JP');
    });

    test('applies even with dns rules off, because the user asked for it by name', () {
      final rules = _dnsRules(_options(groups: [node], dns: DnsSettings(enableRule: false)));
      final rule = rules.firstWhere((e) => e.containsKey('domain_suffix'));

      expect(rule['server'], startsWith('dns-group-'));
      expect(rule['domain_suffix'], ['n.example']);
    });

    test('a bare address keeps the detour', () {
      final group = RuleGroup(id: 'a', name: 'a', target: 'JP', domainSuffixes: ['a.example'], dnsServer: '8.8.8.8');
      final server = _dnsServers(_options(groups: [group])).firstWhere((e) => e['server'] == '8.8.8.8');
      expect(server['detour'], 'JP');
    });

    test('a block group answers with NXDOMAIN, whatever server it had', () {
      final group = RuleGroup(id: 'a', name: 'a', target: RuleTarget.block, domainSuffixes: ['a.example'], dnsServer: '8.8.8.8');
      final options = _options(groups: [group], dns: DnsSettings(enableRule: true));

      expect(_dnsServers(options).any((e) => e['server'] == '8.8.8.8'), isFalse);
      expect(_dnsRules(options).firstWhere((e) => e.containsKey('domain_suffix'))['rcode'], 'NXDOMAIN');
    });

    test('wifi conditions carry over to the dns rule', () {
      final group = RuleGroup(id: 'a', name: 'a', target: RuleTarget.direct, domainSuffixes: ['a.example'], wifiSsids: ['Home']);
      final rule = _dnsRules(_options(groups: [group], dns: DnsSettings(enableRule: true)))
          .firstWhere((e) => e.containsKey('domain_suffix'));
      expect(rule['wifi_ssid'], ['Home']);
    });

    test('a group limited to one port does not decide dns for the whole domain', () {
      final group = RuleGroup(id: 'a', name: 'a', target: RuleTarget.block, domainSuffixes: ['a.example'], ports: [80]);
      final rules = _dnsRules(_options(groups: [group], dns: DnsSettings(enableRule: true)));
      expect(rules.any((e) => e.containsKey('domain_suffix')), isFalse);
    });

    test('rule sets of unknown content stay out of dns rules', () {
      final group = RuleGroup(id: 'a', name: 'a', target: RuleTarget.direct, ruleSets: ['acl-Foo', 'url-1234']);
      final rules = _dnsRules(_options(groups: [group], dns: DnsSettings(enableRule: true)));
      expect(rules.any((e) => e.containsKey('rule_set')), isFalse);
    });
  });

  group('narrowing a group to what this device can do', () {
    test('a failed rule set must not leave only the port behind', () {
      final group = RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-x'], ports: [443]);
      expect(group.usableOn(ios: false, available: const {}), isNull);
    });

    test('other sets or addresses keep the group alive', () {
      final group = RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-x', 'geosite-y'], domains: ['a.example']);
      expect(group.usableOn(ios: false, available: {'geosite-y'})!.ruleSets, ['geosite-y']);
      expect(group.usableOn(ios: false, available: const {})!.ruleSets, isEmpty);
    });

    test('"any of" loses just the part it cannot evaluate', () {
      final group = RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-x'], ports: [22], processNames: ['a.exe'], matchOr: true);
      final usable = group.usableOn(ios: true, available: const {})!;
      expect(usable.ruleSets, isEmpty);
      expect(usable.processNames, isEmpty);
      expect(usable.ports, [22]);
    });

    test('process conditions cannot be evaluated on iOS, network types only there', () {
      final process = RuleGroup(id: 'a', name: 'a', domains: ['a.example'], processNames: ['a.exe']);
      expect(process.usableOn(ios: true, available: const {}), isNull);
      expect(process.usableOn(ios: false, available: const {}), isNotNull);

      final network = RuleGroup(id: 'b', name: 'b', domains: ['a.example'], networkTypes: ['wifi']);
      expect(network.usableOn(ios: false, available: const {}), isNull);
      expect(network.usableOn(ios: true, available: const {}), isNotNull);
    });

    test('rule set addresses turn into the names the config refers to', () {
      const url = 'https://example.com/a.srs';
      final group = RuleGroup(id: 'a', name: 'a', ruleSetUrls: [url]);
      final usable = group.usableOn(ios: false, available: {RuleSets.tagOfUrl(url)})!;
      expect(usable.ruleSets, [RuleSets.tagOfUrl(url)]);
      expect(usable.ruleSetUrls, isEmpty);
    });

    test('the original group is left alone', () {
      final group = RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-x'], domains: ['a.example']);
      group.usableOn(ios: false, available: const {});
      expect(group.ruleSets, ['geosite-x']);
    });
  });

  group('format checks', () {
    test('ports and ranges', () {
      expect(RuleChecks.isPort('443'), isTrue);
      expect(RuleChecks.isPort('65536'), isFalse);
      expect(RuleChecks.isPortRange('1000:2000'), isTrue);
      expect(RuleChecks.isPortRange(':3000'), isTrue);
      expect(RuleChecks.isPortRange('4000:'), isTrue);
      expect(RuleChecks.isPortRange(':'), isFalse);
      expect(RuleChecks.isPortRange('2000:1000'), isFalse);
      expect(RuleChecks.isPortRange('1000-2000'), isFalse);
    });

    test('addresses', () {
      expect(RuleChecks.isCidr('1.2.3.0/24'), isTrue);
      expect(RuleChecks.isCidr('2001:db8::/32'), isTrue);
      expect(RuleChecks.isCidr('1.2.3.4/33'), isFalse);
      expect(RuleChecks.isCidr('1.2.3.4'), isFalse);
      expect(RuleChecks.normalizeCidr('1.2.3.4'), '1.2.3.4/32');
      expect(RuleChecks.normalizeCidr('2001:db8::1'), '2001:db8::1/128');
      expect(RuleChecks.normalizeCidr('nonsense'), 'nonsense');
    });

    test('regexes Go cannot compile are caught even though Dart can', () {
      expect(RuleChecks.isRegex(r'^ads?\.'), isTrue);
      expect(RuleChecks.isRegex('(unclosed'), isFalse);
      expect(RuleChecks.isRegex(r'^(?!www)'), isFalse);
      expect(RuleChecks.isRegex(r'(?<=a)b'), isFalse);
      expect(RuleChecks.isRegex(r'(a)\1'), isFalse);
    });

    test('rule set addresses must be https and a known format', () {
      expect(RuleChecks.isRuleSetUrl('https://example.com/a.srs'), isTrue);
      expect(RuleChecks.isRuleSetUrl('https://example.com/a.json?x=1'), isTrue);
      expect(RuleChecks.isRuleSetUrl('http://example.com/a.srs'), isFalse);
      expect(RuleChecks.isRuleSetUrl('https://example.com/a.txt'), isFalse);
    });

    test('a group names the first thing wrong with it', () {
      expect(RuleGroup(id: 'a', name: ' ').firstProblem(), '请填写名称');
      expect(RuleGroup(id: 'a', name: 'x' * 33).firstProblem(), contains('32'));
      expect(RuleGroup(id: 'a', name: 'a', ipCidrs: ['bad']).firstProblem(), contains('bad'));
      expect(_everyCondition.firstProblem(), isNull);
    });

    test('the defaults pass their own checks', () {
      expect(RuleGroup.defaults().map((e) => e.firstProblem()).nonNulls, isEmpty);
    });
  });

  test('a group survives a round trip through json, including ones from older backups', () {
    final copy = RuleGroup.fromJson(jsonDecode(jsonEncode(_everyCondition)));
    expect(copy.toJson(), _everyCondition.toJson());

    final old = RuleGroup.fromJson({'id': 'a', 'name': 'a', 'domainSuffixes': ['a.example']});
    expect(old.matchOr, isFalse);
    expect(old.ports, isEmpty);
    expect(old.dnsServer, isEmpty);
  });

  group('rule set names', () {
    test('map to the repositories they come from', () {
      expect(RuleSets.sources('geosite-category-ai-!cn').first.toString(),
          'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ai-!cn.srs');
      expect(RuleSets.sources('geoip-cn').last.toString(),
          'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs');
      expect(RuleSets.sources('acl-BanAD').first.toString(),
          'https://raw.githubusercontent.com/KaringX/karing-ruleset/sing/ACL4SSR/BanAD.srs');
      expect(RuleSets.sources('something-else'), isEmpty);
    });

    test('addresses become stable, file-safe names that keep the format', () {
      final binary = RuleSets.tagOfUrl('https://example.com/a.srs');
      final source = RuleSets.tagOfUrl('https://example.com/a.json');

      expect(binary, RuleSets.tagOfUrl('https://example.com/a.srs'));
      expect(binary, matches(RegExp(r'^url-[0-9a-f]{16}$')));
      expect(RuleSets.fileName(binary), '$binary.srs');
      expect(source, endsWith('.json'));
      expect(RuleSets.fileName(source), source);
    });

    test('the config reads each file in its own format', () {
      final tag = RuleSets.tagOfUrl('https://example.com/a.json');
      final config = CoreConfig.build(_options(groups: [
        RuleGroup(id: 'a', name: 'a', ruleSets: [tag, 'geosite-cn'])
      ]));
      final sets = (config['route']['rule_set'] as List).cast<Map<String, dynamic>>();

      expect(sets.firstWhere((e) => e['tag'] == tag)['format'], 'source');
      expect(sets.firstWhere((e) => e['tag'] == tag)['path'], 'rules/$tag');
      expect(sets.firstWhere((e) => e['tag'] == 'geosite-cn')['format'], 'binary');
    });

    test('only files the core can read count as valid', () {
      expect(RuleSets.isValid('geosite-a', _srs()), isTrue);
      expect(RuleSets.isValid('geosite-a', Uint8List.fromList([0x53, 0x52, 0x53, 99, 0])), isFalse, reason: 'too new');
      expect(RuleSets.isValid('geosite-a', Uint8List.fromList(utf8.encode('<html>blocked</html>'))), isFalse);
      expect(RuleSets.isValid('url-1.json', Uint8List.fromList(utf8.encode('{"version":3,"rules":[]}'))), isTrue);
      expect(RuleSets.isValid('url-1.json', Uint8List.fromList(utf8.encode('{"rules":[]}'))), isFalse);
      expect(RuleSets.isValid('url-1.json', Uint8List.fromList(utf8.encode('not json'))), isFalse);
    });
  });

  group('rule set store', () {
    late Directory root;
    late List<String> fetched;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rsproxy_rules_');
      fetched = [];
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    RuleSetStore store({
      Set<String> bundled = const {},
      Future<Uint8List> Function(Uri uri, String? proxy)? fetch,
    }) =>
        RuleSetStore(root,
            bundled: (name) async => bundled.contains(name) ? Uint8List.fromList([1]) : null,
            fetch: (uri, proxy) async {
              fetched.add('${proxy ?? 'direct'} ${uri.host}');
              return (fetch ?? (_, __) async => _srs())(uri, proxy);
            });

    test('bundled sets need no network', () async {
      final available = await store(bundled: {'geosite-cn'}).prepare(['geosite-cn']);

      expect(available, {'geosite-cn'});
      expect(fetched, isEmpty);
      expect(File('${root.path}/geosite-cn.srs').existsSync(), isTrue);
    });

    test('other sets are downloaded on first use, and only once', () async {
      final rules = store();
      expect(await rules.prepare(['geosite-bilibili']), {'geosite-bilibili'});
      expect(await rules.prepare(['geosite-bilibili']), {'geosite-bilibili'});

      expect(fetched, ['direct raw.githubusercontent.com']);
    });

    test('moves on to the mirror, then to the next route', () async {
      final available = await store(fetch: (uri, proxy) async {
        if (proxy == null) throw const SocketException('blocked');
        if (uri.host == 'raw.githubusercontent.com') throw const SocketException('blocked');
        return _srs();
      }).prepare(['geosite-a'], routes: [null, '127.0.0.1:1']);

      expect(available, {'geosite-a'});
      expect(fetched, [
        'direct raw.githubusercontent.com',
        'direct cdn.jsdelivr.net',
        '127.0.0.1:1 raw.githubusercontent.com',
        '127.0.0.1:1 cdn.jsdelivr.net',
      ]);
    });

    test('a bad download leaves nothing behind for the core to choke on', () async {
      final available = await store(fetch: (_, __) async => Uint8List.fromList(utf8.encode('<html>'))).prepare(['geosite-a']);

      expect(available, isEmpty);
      expect(root.listSync(), isEmpty);
    });

    test('a failed set is not retried on every reload', () async {
      final rules = store(fetch: (_, __) async => throw const SocketException('offline'));
      await rules.prepare(['geosite-a']);
      final attempts = fetched.length;

      await rules.prepare(['geosite-a']);
      expect(fetched.length, attempts);

      rules.forgetFailures();
      await rules.prepare(['geosite-a']);
      expect(fetched.length, attempts * 2);
    });

    test('a slow download does not hold up connecting, and lands for next time', () async {
      final gate = Completer<Uint8List>();
      final rules = store(fetch: (_, __) => gate.future);

      final available = await rules.prepare(['geosite-a'], budget: const Duration(milliseconds: 20));
      expect(available, isEmpty);

      gate.complete(_srs());
      final file = File('${root.path}/geosite-a.srs');
      for (var attempt = 0; attempt < 200 && !file.existsSync(); attempt++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(await rules.prepare(['geosite-a']), {'geosite-a'});
    });

    test('addresses are fetched as given', () async {
      const url = 'https://example.com/a.srs';
      final tag = RuleSets.tagOfUrl(url);

      expect(await store().prepare(const [], urls: {tag: url}), {tag});
      expect(fetched, ['direct example.com']);
    });

    test('refreshing skips bundled sets unless asked', () async {
      final rules = store(bundled: {'geosite-cn'});
      await rules.prepare(['geosite-cn', 'geosite-a']);
      fetched.clear();

      expect(await rules.refresh(['geosite-cn', 'geosite-a']), (1, 0));
      expect(fetched, hasLength(1));

      fetched.clear();
      expect(await rules.refresh(['geosite-cn', 'geosite-a'], includeBundled: true), (2, 0));
      expect(fetched, hasLength(2));
    });

    test('states report what is on disk', () async {
      final rules = store(bundled: {'geosite-cn'});
      await rules.prepare(['geosite-cn']);

      final states = await rules.states(['geosite-cn', 'geosite-a']);
      expect(states.first.updatedAt, isNotNull);
      expect(states.last.updatedAt, isNull);
    });
  });

  group('the manager and rule sets', () {
    late Directory root;
    late _Platform platform;
    late CoreManager manager;
    late bool online;

    Map<String, dynamic> written() => jsonDecode(File('${root.path}/config.json').readAsStringSync());

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rsproxy_rule_manager_');
      platform = _Platform(root);
      online = true;
      manager = CoreManager(
        platform: platform,
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (name) async => name == 'geosite-cn' ? Uint8List.fromList([1]) : null,
        fetchRuleSet: (_, __) async {
          if (!online) throw const SocketException('offline');
          return _srs();
        },
        apiFactory: (_, __) => _Api(),
      );
      await manager.load();
      await manager.addProfile('trojan://p@a.example:443#A\ntrojan://p@b.example:443#B');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('downloads what a group needs before writing the config', () async {
      manager.settings.groups = [
        RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-bilibili'], target: RuleTarget.direct)
      ];
      await manager.connect();

      final sets = (written()['route']['rule_set'] as List).map((e) => e['tag']);
      expect(sets, ['geosite-bilibili']);
      expect(manager.missingRuleSets, isEmpty);
    });

    test('a set that cannot be fetched is reported and left out, and the core still starts', () async {
      online = false;
      manager.settings.groups = [
        RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-bilibili'], ports: [443]),
        RuleGroup(id: 'b', name: 'b', ruleSets: ['geosite-cn']),
      ];
      await manager.connect();

      expect(manager.state, CoreState.running);
      expect(manager.missingRuleSets, {'geosite-bilibili'});
      final config = written();
      expect((config['route']['rule_set'] as List).map((e) => e['tag']), ['geosite-cn']);
      expect((config['route']['rules'] as List).any((e) => e['port'] != null), isFalse);
    });

    test('a set that only downloads through the node asks for a reload once connected', () async {
      online = false;
      platform.onStart = () => online = true;
      manager.settings.groups = [
        RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-bilibili'])
      ];
      await manager.connect();
      // 重试在后台跑，慢机器上要多等一会
      for (var attempt = 0; attempt < 200 && !manager.needsReload; attempt++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      expect(manager.missingRuleSets, isEmpty);
      expect(manager.needsReload, isTrue);
    });

    test('updates when due, and not again until the interval passes', () async {
      var downloads = 0;
      manager = CoreManager(
        platform: _Platform(root),
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (_) async => null,
        fetchRuleSet: (_, __) async {
          downloads++;
          return _srs();
        },
        apiFactory: (_, __) => _Api(),
      );
      await manager.load();
      manager.settings.groups = [
        RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-a'])
      ];

      await manager.updateDueProfiles();
      expect(downloads, 1);
      await manager.updateDueProfiles();
      expect(downloads, 1);

      manager.settings.ruleSetsUpdatedAt = DateTime.now().subtract(const Duration(hours: 25));
      await manager.updateDueProfiles();
      expect(downloads, 2);
    });

    test('a failed update tries again in an hour, not a whole interval', () async {
      online = false;
      manager.settings.groups = [
        RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-bilibili'])
      ];
      await manager.updateDueProfiles();

      final wait = manager.settings.ruleSetsUpdatedAt!.add(const Duration(hours: 24)).difference(DateTime.now());
      expect(wait.inMinutes, inInclusiveRange(58, 61));
    });

    test('the fallback target and rule set settings are saved, and stay out of the device fields', () async {
      manager.settings
        ..finalTarget = RuleTarget.direct
        ..ruleSetUpdateHours = 6
        ..updateBundledRuleSets = true
        ..ruleSetDownload = DownloadStrategy.onlyDirect;
      final restored = CoreSettings.fromJson(jsonDecode(jsonEncode(manager.settings)));

      expect(restored.finalTarget, RuleTarget.direct);
      expect(restored.ruleSetUpdateHours, 6);
      expect(restored.updateBundledRuleSets, isTrue);
      expect(restored.ruleSetDownload, DownloadStrategy.onlyDirect);
    });
  });

  group('current wifi on Windows', () {
    test('reads the name and BSSID from a Chinese system', () {
      const output = '''
    名称                   : WLAN
    描述                   : Intel(R) Wi-Fi 6
    状态                   : 已连接
    SSID                   : Home 5G
    AP BSSID               : AA:BB:CC:DD:EE:FF
    网络类型               : 结构
''';
      final wifi = CoreTools.parseNetshWifi(output);

      expect(wifi?.ssid, 'Home 5G');
      expect(wifi?.bssid, 'aa:bb:cc:dd:ee:ff');
    });

    test('older systems write BSSID on its own', () {
      expect(CoreTools.parseNetshWifi('  SSID : A\n  BSSID : 00:11:22:33:44:55\n')?.bssid, '00:11:22:33:44:55');
    });

    test('nothing connected', () => expect(CoreTools.parseNetshWifi('没有接口'), isNull));
  });

  group('editing a group', () {
    Future<RuleGroupEdit?> save(WidgetTester tester, Future<void> Function() fill, {RuleGroup? group, Set<String> others = const {}}) async {
      RuleGroupEdit? result;
      await tester.pumpWidget(MaterialApp(home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push<RuleGroupEdit>(MaterialPageRoute(
              builder: (_) => EditRuleGroupPage(group: group, otherNames: others),
            ));
          },
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await fill();
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('fields with content start open, the rest stay out of the way', (tester) async {
      await save(tester, () async {
        expect(find.widgetWithText(TextField, '域名后缀，每行一个'), findsOneWidget);
        expect(find.widgetWithText(TextField, '端口，每行一个'), findsNothing);
      }, group: RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example']));
    });

    testWidgets('a bare IP gets its mask and duplicates collapse', (tester) async {
      final result = await save(tester, () async {
        await tester.enterText(find.widgetWithText(TextField, '名称'), '新组');
        await tester.tap(find.text('IP 和端口'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, 'IP 段，每行一个'), '1.2.3.4\n1.2.3.4\n');
        await tester.enterText(find.widgetWithText(TextField, '端口，每行一个'), '443\n8443');
      });

      expect(result?.group?.ipCidrs, ['1.2.3.4/32']);
      expect(result?.group?.ports, [443, 8443]);
    });

    testWidgets('a mistake keeps the page open and says what is wrong', (tester) async {
      final result = await save(tester, () async {
        await tester.enterText(find.widgetWithText(TextField, '名称'), '新组');
        await tester.tap(find.text('IP 和端口'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, '端口，每行一个'), 'http');
      });

      expect(result, isNull);
      expect(find.text('端口格式不对：http'), findsOneWidget);
    });

    testWidgets('names must be unique', (tester) async {
      final result = await save(tester, () async {
        await tester.enterText(find.widgetWithText(TextField, '名称'), '重名');
      }, others: {'重名'});

      expect(result, isNull);
      expect(find.text('已经有同名的分流组了'), findsOneWidget);
    });

    testWidgets('choosing "any of" and a protocol is kept', (tester) async {
      final result = await save(tester, () async {
        await tester.enterText(find.widgetWithText(TextField, '名称'), '新组');
        await tester.tap(find.text('满足任一条'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('网络和协议'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilterChip, 'quic'));
        await tester.pumpAndSettle();
      });

      expect(result?.group?.matchOr, isTrue);
      expect(result?.group?.protocols, ['quic']);
    });

    testWidgets('keeps the id and the things this page does not edit', (tester) async {
      final group = RuleGroup(id: 'keep', name: 'a', target: 'JP', dnsServer: '8.8.8.8', domainSuffixes: ['a.example']);
      final result = await save(tester, () async {}, group: group);

      expect(result?.group?.id, 'keep');
      expect(result?.group?.target, 'JP');
      expect(result?.group?.dnsServer, '8.8.8.8');
    });
  });

  group('picking rule sets', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        if (key != 'assets/rules/index.txt') return null;
        return ByteData.sublistView(utf8.encode('acl-BanAD\ngeoip-cn\ngeosite-bilibili\ngeosite-cn\n'));
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', null);
    });

    testWidgets('lists by kind, searches, and hands back the full names', (tester) async {
      List<String>? result;
      await tester.pumpWidget(MaterialApp(home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push<List<String>>(MaterialPageRoute(
              builder: (_) => const RuleSetPickerPage(selected: ['geosite-cn']),
            ));
          },
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('bilibili'), findsOneWidget);
      expect(find.text('BanAD'), findsNothing);

      await tester.enterText(find.byType(TextField), 'bili');
      await tester.pump();
      expect(find.text('cn'), findsNothing);
      await tester.tap(find.text('bilibili'));
      await tester.pump();

      await tester.tap(find.text('ACL'));
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('BanAD'));
      await tester.pump();

      await tester.tap(find.byTooltip('完成'));
      await tester.pumpAndSettle();
      expect(result, unorderedEquals(['geosite-cn', 'geosite-bilibili', 'acl-BanAD']));
    });
  });

  // CI points this at a folder and runs `sing-box check` over what lands there.
  test('writes configs with every rule feature, for sing-box to check', () {
    final directory = Platform.environment['CORE_CONFIG_OUT'];
    if (directory == null) return;
    Directory(directory).createSync(recursive: true);

    final group = RuleGroup.fromJson(_everyCondition.toJson())..dnsServer = 'tls://1.1.1.1';
    final sourceSet = RuleSets.tagOfUrl('https://example.com/a.json');
    // 内核启动时就会读 JSON 规则集，这里顺便验证一下格式
    File('$directory/rules/$sourceSet')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'version': 3,
        'rules': [
          {'domain_suffix': ['example.com']}
        ]
      }));
    final options = _options(
      finalTarget: RuleTarget.block,
      dns: DnsSettings(enableRule: true),
      groups: [
        group,
        RuleGroup(
          id: 'or',
          name: 'or',
          target: RuleTarget.auto,
          ruleSets: ['geoip-cn', sourceSet],
          domainSuffixes: ['or.example'],
          ports: [22],
          portRanges: [':1000'],
          networks: ['udp', 'icmp'],
          protocols: ['quic', 'bittorrent', 'ntp'],
          processDirs: [r'C:\App'],
          matchOr: true,
          dnsServer: '8.8.8.8',
        ),
        RuleGroup(id: 'block', name: 'block', target: RuleTarget.block, domainRegexes: [r'^ads?\.'], wifiBssids: ['aa:bb:cc:dd:ee:ff']),
      ],
    );
    File('$directory/rule-groups.json').writeAsStringSync(jsonEncode(CoreConfig.build(options)));

    const nodes = [
      {'type': 'trojan', 'tag': 'A', 'server': 'a.example', 'server_port': 443, 'password': 'p'},
      {'type': 'trojan', 'tag': 'B', 'server': 'b.example', 'server_port': 443, 'password': 'p'},
      {'type': 'trojan', 'tag': 'C', 'server': 'c.example', 'server_port': 443, 'password': 'p'},
      {'type': 'trojan', 'tag': 'D', 'server': 'd.example', 'server_port': 443, 'password': 'p'},
    ];
    for (final (name, front) in [('chain-front', true), ('chain-behind', false)]) {
      final chained = CoreOptions(
        nodes: nodes,
        chain: const ['A', 'B'],
        chainFront: front,
        autoGroups: [
          AutoGroup(name: 'exit', keywords: const ['C'], front: 'entry'),
          AutoGroup(name: 'entry', nodes: const ['D']),
          AutoGroup(name: 'all', keywords: const ['a', 'b', 'c', 'd']),
        ],
        autoTestMinutes: 5,
        autoTolerance: 200,
        finalTarget: 'auto:all',
        groups: [
          RuleGroup(id: 'a', name: 'a', target: 'auto:exit', domainSuffixes: ['a.example'], dnsServer: '8.8.8.8')
        ],
        mixedPort: 7890,
        upstreamPort: 7891,
        mitmPort: 9099,
        clashPort: 9191,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
      );
      File('$directory/$name.json').writeAsStringSync(jsonEncode(CoreConfig.build(chained)));
    }
  });
}

class _Platform implements CorePlatform {
  final Directory root;
  bool running = false;
  void Function()? onStart;

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
    running = true;
    onStart?.call();
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
  List<String> editableDomains = const [];

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
