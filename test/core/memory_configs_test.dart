import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_routing.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/rule_group.dart';

/// Writes the configurations tool/measure_memory.py compares. Each one changes a single
/// thing from `base`, so the difference between two rows is the cost of that thing.
void main() {
  final directory = Platform.environment['MEMORY_CONFIG_OUT'];

  List<Map<String, dynamic>> nodes(int count) => [
        for (var index = 0; index < count; index++)
          {
            'type': 'shadowsocks',
            'tag': 'node-$index',
            'server': '127.0.0.1',
            'server_port': 1,
            'method': 'aes-128-gcm',
            'password': 'password',
          }
      ];

  CoreOptions options({int count = 20, List<RuleGroup> groups = const [], ProviderRouting? routing}) => CoreOptions(
        nodes: nodes(count),
        groups: groups,
        providerRouting: routing,
        mixedPort: 17890,
        upstreamPort: 17891,
        mitmPort: 9099,
        clashPort: 17892,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
        logLevel: 'error',
      );

  test('writes the configurations', () {
    if (directory == null) return;
    Directory(directory).createSync(recursive: true);

    final samples = {
      'base': options(),
      'nodes-200': options(count: 200),
      'nodes-1000': options(count: 1000),
      'default-groups': options(groups: RuleGroup.defaults()),
      'china-only': options(groups: [
        RuleGroup(id: 'cn', name: 'cn', target: RuleTarget.direct, ruleSets: ['geosite-cn', 'geoip-cn'])
      ]),
      'provider-3000-rules': options(
        routing: ProviderRouting(const [], [
          ProviderRule('direct', {
            'domain_suffix': [for (var index = 0; index < 3000; index++) 'host-$index.example.com'],
          })
        ], null),
      ),
    };
    samples.forEach((name, value) {
      File('$directory/$name.json').writeAsStringSync(jsonEncode(CoreConfig.build(value)));
    });
  });
}
