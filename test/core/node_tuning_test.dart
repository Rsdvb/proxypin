import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/ui/core/network_pages.dart';

const _trojan = {
  'type': 'trojan',
  'tag': 'T',
  'server': 't.example',
  'server_port': 443,
  'password': 'p',
  'tls': {'enabled': true, 'server_name': 't.example'},
};
const _hysteria = {
  'type': 'hysteria2',
  'tag': 'H',
  'server': 'h.example',
  'server_port': 443,
  'password': 'p',
  'tls': {'enabled': true},
};
const _reality = {
  'type': 'vless',
  'tag': 'R',
  'server': 'r.example',
  'server_port': 443,
  'uuid': '11111111-1111-1111-1111-111111111111',
  'flow': 'xtls-rprx-vision',
  'tls': {
    'enabled': true,
    'server_name': 'r.example',
    'utls': {'enabled': true, 'fingerprint': 'chrome'},
    'reality': {'enabled': true, 'public_key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0', 'short_id': '0123456789abcdef'},
  },
};
const _plain = {'type': 'shadowsocks', 'tag': 'S', 'server': 's.example', 'server_port': 443, 'method': 'aes-128-gcm', 'password': 'p'};

CoreOptions _options({
  List<Map<String, dynamic>> nodes = const [_trojan],
  NodeTuning? tuning,
  int directPort = 0,
  int globalPort = 0,
  int lanPort = 0,
  int lanGlobalPort = 0,
  String lanUsername = '',
  String lanPassword = '',
  String mixedUsername = '',
  String mixedPassword = '',
  List<String> chain = const [],
  bool chainFront = true,
}) =>
    CoreOptions(
      nodes: nodes,
      tuning: tuning,
      directPort: directPort,
      globalPort: globalPort,
      lanPort: lanPort,
      lanGlobalPort: lanGlobalPort,
      lanUsername: lanUsername,
      lanPassword: lanPassword,
      mixedUsername: mixedUsername,
      mixedPassword: mixedPassword,
      chain: chain,
      chainFront: chainFront,
      mixedPort: 7890,
      upstreamPort: 7891,
      mitmPort: 9099,
      clashPort: 9191,
      clashSecret: 'secret',
      ruleSetDirectory: 'rules',
      cachePath: 'cache.db',
    );

Map<String, dynamic> _inbound(CoreOptions options, String tag) =>
    (CoreConfig.build(options)['inbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

bool _hasInbound(CoreOptions options, String tag) => (CoreConfig.build(options)['inbounds'] as List).any((e) => e['tag'] == tag);

void main() {
  group('tls options', () {
    test('nothing on leaves a node exactly as it was', () {
      expect(identical(NodeTuning().apply(_trojan), _trojan), isTrue);
    });

    test('skipping verification reaches TLS nodes only', () {
      final tuning = NodeTuning(tlsInsecure: true);

      expect(tuning.apply(_trojan)['tls']['insecure'], isTrue);
      expect(tuning.apply(_plain), same(_plain));
    });

    test('reality verifies by itself, so it is left out', () {
      final result = NodeTuning(tlsInsecure: true).apply(_reality);
      expect((result['tls'] as Map).containsKey('insecure'), isFalse);
    });

    test('fragmenting applies to TCP protocols, not QUIC ones', () {
      final tuning = NodeTuning(tlsFragment: true, tlsRecordFragment: true, fragmentDelayMs: 300);
      final tls = tuning.apply(_trojan)['tls'];

      expect(tls['fragment'], isTrue);
      expect(tls['record_fragment'], isTrue);
      expect(tls['fragment_fallback_delay'], '300ms');
      expect(tuning.apply(_hysteria), same(_hysteria));
    });

    test('the node in the profile is not touched', () {
      NodeTuning(tlsInsecure: true).apply(_trojan);
      expect((_trojan['tls'] as Map).containsKey('insecure'), isFalse);
    });

    test('the config picks the options up', () {
      final config = CoreConfig.build(_options(tuning: NodeTuning(tlsRecordFragment: true)));
      final node = (config['outbounds'] as List).firstWhere((e) => e['tag'] == 'T');
      expect(node['tls']['record_fragment'], isTrue);
    });
  });

  group('multiplexing', () {
    NodeTuning mux({Set<String> types = const {'trojan', 'vless', 'shadowsocks'}}) => NodeTuning(muxEnabled: true, muxTypes: {...types});

    test('applies to the chosen protocols only', () {
      expect(mux().apply(_trojan)['multiplex'], {'enabled': true, 'protocol': 'h2mux', 'max_streams': 8});
      expect(mux(types: const {'vmess'}).apply(_trojan), same(_trojan));
    });

    test('stays off until the master switch is on', () {
      expect(NodeTuning(muxTypes: {'trojan'}).apply(_trojan), same(_trojan));
    });

    test('never on a VLESS node with flow', () {
      expect(mux().apply(_reality), same(_reality));
    });

    test('leaves a node that set its own alone', () {
      final node = {..._trojan, 'multiplex': {'enabled': true, 'protocol': 'smux'}};
      expect(mux().apply(node)['multiplex']['protocol'], 'smux');
    });

    test('max streams excludes the other two, the core rejects them together', () {
      final tuning = mux()
        ..muxMaxStreams = 16
        ..muxMaxConnections = 4
        ..muxMinStreams = 2;
      expect(tuning.apply(_trojan)['multiplex'].containsKey('max_connections'), isFalse);

      tuning.muxMaxStreams = 0;
      final multiplex = tuning.apply(_trojan)['multiplex'];
      expect(multiplex['max_connections'], 4);
      expect(multiplex['min_streams'], 2);
      expect(multiplex.containsKey('max_streams'), isFalse);
    });

    test('padding and brutal carry over', () {
      final tuning = mux()
        ..muxPadding = true
        ..muxBrutal = true
        ..muxUpMbps = 50
        ..muxDownMbps = 200;
      final multiplex = tuning.apply(_trojan)['multiplex'];

      expect(multiplex['padding'], isTrue);
      expect(multiplex['brutal'], {'enabled': true, 'up_mbps': 50, 'down_mbps': 200});
    });
  });

  test('settings survive a round trip', () {
    final tuning = NodeTuning(tlsInsecure: true, muxEnabled: true, muxProtocol: 'smux', muxTypes: {'vmess'}, muxBrutal: true);
    final restored = NodeTuning.fromJson(jsonDecode(jsonEncode(tuning)));

    expect(restored.toJson(), tuning.toJson());
    expect(NodeTuning.fromJson(const {}).muxProtocol, 'h2mux');
  });

  group('extra ports', () {
    test('are off by default', () {
      for (final tag in ['direct-in', 'global-in', 'lan-in', 'lan-global-in']) {
        expect(_hasInbound(_options(), tag), isFalse, reason: tag);
      }
    });

    List<Map<String, dynamic>> rules(CoreOptions options) =>
        (CoreConfig.build(options)['route']['rules'] as List).cast<Map<String, dynamic>>();

    test('the direct port goes direct, the global ports go to the selection', () {
      final options = _options(directPort: 7001, globalPort: 7002, lanPort: 7003, lanGlobalPort: 7004);
      final list = rules(options);

      expect(list.firstWhere((e) => e['inbound']?.contains('direct-in') == true)['outbound'], 'direct');
      final global = list.firstWhere((e) => e['inbound']?.contains('global-in') == true);
      expect(global['inbound'], ['global-in', 'lan-global-in']);
      expect(global['outbound'], 'select');
    });

    test('the global ports leave through the chain when it sits behind the node', () {
      final options = _options(nodes: const [_trojan, _plain], chain: const ['S'], chainFront: false, globalPort: 7002);
      final global = rules(options).firstWhere((e) => e['inbound']?.contains('global-in') == true);
      expect(global['outbound'], 'S');
    });

    test('these rules sit before the private network and capture rules', () {
      final list = rules(_options(globalPort: 7002));
      final global = list.indexWhere((e) => e['inbound']?.contains('global-in') == true);
      final private = list.indexWhere((e) => e.containsKey('ip_is_private'));
      expect(global, lessThan(private));
    });

    test('only the LAN ports listen on every interface', () {
      final options = _options(directPort: 7001, lanPort: 7003, lanGlobalPort: 7004);

      expect(_inbound(options, 'lan-in')['listen'], '0.0.0.0');
      expect(_inbound(options, 'lan-global-in')['listen'], '0.0.0.0');
      expect(_inbound(options, 'direct-in')['listen'], '127.0.0.1');
      expect(_inbound(options, 'mixed-in')['listen'], '127.0.0.1');
    });

    test('LAN traffic is never sent to the decrypting proxy, its certificates would not be trusted there', () {
      final options = CoreOptions(
        nodes: const [_trojan],
        mixedPort: 7890,
        upstreamPort: 7891,
        mitmPort: 9099,
        lanPort: 7003,
        mitmDomains: const ['a.example'],
        clashPort: 9191,
        clashSecret: 'secret',
        ruleSetDirectory: 'rules',
        cachePath: 'cache.db',
      );
      final mitm = (CoreConfig.build(options)['route']['rules'] as List).where((e) => e['outbound'] == 'rs-mitm');

      expect(mitm, isNotEmpty);
      expect(mitm.every((e) => !(e['inbound'] as List).contains('lan-in')), isTrue);
    });

    test('an account needs both fields, half of one must not lock anyone out', () {
      expect(_inbound(_options(lanPort: 7003, lanUsername: 'u', lanPassword: 'p'), 'lan-in')['users'], [
        {'username': 'u', 'password': 'p'}
      ]);
      expect(_inbound(_options(lanPort: 7003, lanUsername: 'u'), 'lan-in').containsKey('users'), isFalse);
      expect(_inbound(_options(mixedUsername: 'u', mixedPassword: 'p'), 'mixed-in').containsKey('users'), isTrue);
    });
  });

  group('port checks', () {
    test('stay in range and do not repeat', () {
      expect(PortsPage.problem(1024, const []), isNotNull);
      expect(PortsPage.problem(70000, const []), isNotNull);
      expect(PortsPage.problem(7890, const [7890]), isNotNull);
      expect(PortsPage.problem(7890, const [7891]), isNull);
    });
  });

  test('this device\'s ports and LAN passwords stay out of backups', () {
    final bytes = CoreBackup.encode(BackupContent(
      <Profile>[],
      CoreSettings(lanEnabled: true, lanPassword: 'secret', mixedPassword: 'secret', globalPort: 7002),
      const [],
    ));
    final restored = CoreBackup.decode(bytes).settings;

    expect(restored.lanEnabled, isFalse);
    expect(restored.lanPassword, isEmpty);
    expect(restored.mixedPassword, isEmpty);
    expect(restored.globalPort, 0);
  });

  // CI points this at a folder and runs `sing-box check` over what lands there.
  test('writes a config with every tuning option, for sing-box to check', () {
    final directory = Platform.environment['CORE_CONFIG_OUT'];
    if (directory == null) return;
    Directory(directory).createSync(recursive: true);

    final tuning = NodeTuning(
      tlsInsecure: true,
      tlsFragment: true,
      tlsRecordFragment: true,
      fragmentDelayMs: 300,
      muxEnabled: true,
      muxProtocol: 'smux',
      muxPadding: true,
      muxBrutal: true,
      muxTypes: {'trojan', 'vless', 'shadowsocks'},
    );
    final options = _options(
      nodes: const [_trojan, _hysteria, _reality, _plain],
      tuning: tuning,
      directPort: 27001,
      globalPort: 27002,
      lanPort: 27003,
      lanGlobalPort: 27004,
      lanUsername: 'u',
      lanPassword: 'p',
      mixedUsername: 'u',
      mixedPassword: 'p',
    );
    File('$directory/tuning.json').writeAsStringSync(jsonEncode(CoreConfig.build(options)));

    final noMaxStreams = NodeTuning(muxEnabled: true, muxMaxStreams: 0, muxMaxConnections: 4, muxMinStreams: 2, muxTypes: {'trojan'});
    File('$directory/tuning-connections.json').writeAsStringSync(jsonEncode(CoreConfig.build(_options(tuning: noMaxStreams))));
  });
}
