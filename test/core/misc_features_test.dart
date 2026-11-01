import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/core/rule_sets.dart';
import 'package:proxypin/core/traffic_stats.dart';
import 'package:proxypin/ui/core/rule_sets_page.dart';

class _Platform implements CorePlatform {
  final Directory root;
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
  Future<void> start([Map<String, Object> options = const {}]) async => running = true;

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
  int uploadTotal = 0;
  int downloadTotal = 0;
  String? autoNow = 'A';
  Map<String, int> latency = const {};
  final List<String> groupTests = [];
  final List<String> asked = [];

  _Api() : super(port: 1, secret: 's');

  @override
  Future<String?> mode() async => 'Rule';

  @override
  Future<void> setMode(String mode) async {}

  @override
  Future<ConnectionSnapshot> connections() async => ConnectionSnapshot(uploadTotal, downloadTotal, const []);

  @override
  Future<Map<String, ProxyGroup>> groups() async => {'auto': ProxyGroup('auto', 'URLTest', autoNow, const ['A', 'B'])};

  @override
  Future<int?> delay(String node, {required String url, int timeoutMs = 5000}) async {
    asked.add(node);
    return latency[node];
  }

  @override
  Future<Map<String, int>> groupDelay(String group, {required String url, int timeoutMs = 5000}) async {
    groupTests.add(group);
    return latency;
  }
}

void main() {
  group('traffic stats', () {
    final noon = DateTime(2026, 11, 1, 12);

    test('counts what changed since the last reading', () {
      final stats = TrafficStats()
        ..record(100, 200, noon, keepDays: 7)
        ..record(150, 500, noon, keepDays: 7);

      expect(stats.days.single.upload, 150);
      expect(stats.days.single.download, 500);
    });

    test('a restarted core counts from zero rather than going negative', () {
      final stats = TrafficStats()
        ..record(1000, 1000, noon, keepDays: 7)
        ..record(10, 20, noon, keepDays: 7);

      expect(stats.days.single.upload, 1010);
      expect(stats.days.single.download, 1020);
    });

    test('each day gets its own row, newest first, and old ones drop off', () {
      final stats = TrafficStats();
      for (var day = 1; day <= 5; day++) {
        stats.record(day * 10, day * 10, DateTime(2026, 11, day, 12), keepDays: 3);
      }

      expect(stats.days.map((e) => e.date), ['2026-11-05', '2026-11-04', '2026-11-03']);
    });

    test('survives saving, including the last reading', () {
      final stats = TrafficStats()..record(100, 200, noon, keepDays: 7);
      final restored = TrafficStats.fromJson(jsonDecode(jsonEncode(stats)))..record(150, 200, noon, keepDays: 7);

      expect(restored.days.single.upload, 150, reason: 'not counted twice after a restart of the app');
    });

    test('clearing keeps counting from the last reading', () {
      final stats = TrafficStats()
        ..record(100, 100, noon, keepDays: 7)
        ..clear()
        ..record(150, 100, noon, keepDays: 7);

      expect(stats.days.single.upload, 50);
    });
  });

  group('region rules', () {
    test('only mainland China has complete geosite data', () {
      expect(RuleSets.ofRegion('cn'), ['geosite-cn', 'geoip-cn']);
      expect(RuleSets.ofRegion('jp'), ['geoip-jp']);
    });

    test('the region comes from saved settings or the system', () {
      expect(CoreSettings(region: 'jp').region, 'jp');
      expect(CoreSettings().region, matches(RegExp(r'^[a-z]{2}$')));
      expect(CoreSettings.fromJson(jsonDecode(jsonEncode(CoreSettings(region: 'kr')))).region, 'kr');
    });

    test('names fall back to the code', () {
      expect(regionLabel('jp'), '日本');
      expect(regionLabel('zz'), 'ZZ');
    });
  });

  group('the manager', () {
    late Directory root;
    late _Api api;
    late _Platform platform;
    late CoreManager manager;

    Map<String, dynamic> written() => jsonDecode(File('${root.path}/config.json').readAsStringSync());

    CoreManager build() => CoreManager(
          platform: platform,
          store: CoreStore(root),
          mitm: _Mitm(),
          loadRuleSet: (_) async => Uint8List(0),
          apiFactory: (_, __) => api,
        );

    setUp(() async {
      root = Directory.systemTemp.createTempSync('rsproxy_misc_');
      api = _Api();
      platform = _Platform(root);
      manager = build();
      CoreManager.instance = manager;
      await manager.load();
      manager.settings.groups = [];
    });

    tearDown(() {
      manager.dispose();
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // A save may still be finishing on Windows; a leftover temp folder is harmless.
      }
    });

    group('region rules', () {
      test('stay out until turned on', () async {
        await manager.connect();
        expect(written()['route']['rule_set'], isEmpty);
      });

      test('go direct, after the user\'s groups', () async {
        manager.settings
          ..region = 'jp'
          ..regionRules = true
          ..groups = [RuleGroup(id: 'a', name: 'a', domainSuffixes: ['a.example'], target: RuleTarget.block)];
        await manager.connect();

        final rules = (written()['route']['rules'] as List).cast<Map<String, dynamic>>();
        final mine = rules.indexWhere((e) => e['domain_suffix'] != null);
        final region = rules.indexWhere((e) => (e['rule_set'] as List?)?.contains('geoip-jp') == true);
        expect(mine, lessThan(region));
        expect(rules[region]['outbound'], 'direct');
      });

      test('apply even with custom groups switched off', () async {
        manager.settings
          ..regionRules = true
          ..region = 'cn'
          ..groupsEnabled = false;
        await manager.connect();

        expect((written()['route']['rule_set'] as List).map((e) => e['tag']), containsAll(['geosite-cn', 'geoip-cn']));
      });
    });

    group('the log level', () {
      test('reaches the core', () async {
        manager.settings.logLevel = 'debug';
        await manager.connect();
        expect(written()['log']['level'], 'debug');
      });
    });

    group('a raw sing-box config', () {
      const raw = '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"mine"}],"experimental":{"cache_file":{"enabled":true}}}';

      test('runs as it is, with only the control api replaced', () async {
        await manager.useRawConfig('mine.json', raw);
        await manager.connect();
        final config = written();

        expect(config['outbounds'].single['tag'], 'mine');
        expect(config['experimental']['cache_file']['enabled'], isTrue);
        expect(config['experimental']['clash_api']['external_controller'], '127.0.0.1:${manager.settings.clashPort}');
        expect(config['experimental']['clash_api']['secret'], manager.settings.clashSecret);
        expect(manager.settings.rawConfigName, 'mine.json');
      });

      test('clearing goes back to the generated one', () async {
        await manager.useRawConfig('mine.json', raw);
        await manager.useRawConfig(null, null);
        await manager.connect();

        expect((written()['outbounds'] as List).any((e) => e['tag'] == 'select'), isTrue);
        expect(manager.settings.rawConfigName, isEmpty);
      });

      test('something that is not a config is refused and changes nothing', () async {
        await expectLater(manager.useRawConfig('bad.json', '[1, 2]'), throwsFormatException);
        await expectLater(manager.useRawConfig('bad.json', 'nonsense'), throwsFormatException);
        expect(manager.settings.rawConfigName, isEmpty);
      });

      test('stays on this device', () async {
        await manager.useRawConfig('mine.json', raw);
        expect(CoreBackup.decode(manager.exportBackup()).settings.rawConfigName, isEmpty);
      });
    });

    group('updating every profile', () {
      test('counts failures without stopping at the first', () async {
        final first = await manager.addProfile('trojan://p@a.example:443#A');
        first.url = 'http://127.0.0.1:1/dead';
        final second = await manager.addProfile('trojan://p@b.example:443#B');
        second.url = 'http://127.0.0.1:1/also-dead';

        expect(await manager.updateAllProfiles(), 2);
      });

      test('local profiles are skipped', () async {
        await manager.addProfile('trojan://p@a.example:443#A');
        expect(await manager.updateAllProfiles(), 0);
      });
    });

    group('traffic statistics', () {
      test('record nothing unless turned on', () async {
        await manager.connect();
        api
          ..uploadTotal = 100
          ..downloadTotal = 200;
        await manager.disconnect();

        expect(manager.trafficStats.days, isEmpty);
      });

      test('take a last reading on disconnect and survive a restart', () async {
        await manager.setStatsEnabled(true);
        await manager.connect();
        api
          ..uploadTotal = 100
          ..downloadTotal = 200;
        await manager.disconnect();

        expect(manager.trafficStats.days.single.download, 200);

        final restarted = build();
        await restarted.load();
        expect(restarted.trafficStats.days.single.download, 200);
        restarted.dispose();
      });

      test('can be cleared', () async {
        await manager.setStatsEnabled(true);
        await manager.connect();
        api.uploadTotal = 100;
        await manager.disconnect();

        await manager.clearTrafficStats();
        expect(manager.trafficStats.days, isEmpty);
      });
    });

    group('health check', () {
      setUp(() async {
        await manager.addProfile('trojan://p@a.example:443#A\ntrojan://p@b.example:443#B');
        api.groupTests.clear();
      });

      test('is off by default', () async {
        await manager.connect();
        await Future.delayed(const Duration(milliseconds: 20));
        expect(api.asked, isEmpty);
      });
    });
  });

  group('the log stream', () {
    late HttpServer server;
    late ClashApi api;

    setUp(() async {
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api = ClashApi(port: server.port, secret: 's');
    });

    tearDown(() async {
      api.close();
      await server.close(force: true);
    });

    test('delivers lines and passes the level', () async {
      String? level;
      server.listen((request) async {
        level = request.uri.queryParameters['level'];
        request.response.write('{"type":"error","payload":"boom"}\n');
        await request.response.close();
      });

      final line = await api.logs(level: 'debug').first;

      expect(line.level, 'error');
      expect(line.message, 'boom');
      expect(level, 'debug');
    });

    test('cancelling while the core has nothing to say does not hang', () async {
      // 内核没有日志时不回响应头，取消必须靠关掉连接
      server.listen((request) {});

      final subscription = api.logs().listen((_) {});
      await Future.delayed(const Duration(milliseconds: 20));
      await subscription.cancel().timeout(const Duration(seconds: 2));
    });
  });

  group('picking a region', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        if (key != 'assets/rules/index.txt') return null;
        return ByteData.sublistView(utf8.encode('geoip-cn\ngeoip-jp\ngeoip-zz\ngeoip-private\ngeosite-cn\n'));
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', null);
    });

    testWidgets('lists real regions only and searches by name or code', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RegionPage(current: 'cn')));
      await tester.pumpAndSettle();

      expect(find.text('日本'), findsOneWidget);
      expect(find.text('ZZ'), findsWidgets);
      expect(find.textContaining('private'), findsNothing);

      await tester.enterText(find.byType(TextField), '日本');
      await tester.pump();
      expect(find.text('中国大陆'), findsNothing);

      await tester.enterText(find.byType(TextField), 'cn');
      await tester.pump();
      expect(find.text('中国大陆'), findsOneWidget);
    });
  });

  group('maintenance', () {
    late Directory root;
    late _Platform platform;
    late CoreManager manager;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('rsproxy_maintenance_');
      platform = _Platform(root);
      manager = CoreManager(
        platform: platform,
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (_) async => Uint8List(0),
        fetchRuleSet: (_, __) async => throw const SocketException('offline'),
        apiFactory: (_, __) => _Api(),
      );
      await manager.load();
      await manager.addProfile('trojan://p@a.example:443#A');
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // A save may still be finishing on Windows
      }
    });

    test('resetting settings keeps profiles and what belongs to this device', () async {
      final secret = manager.settings.clashSecret;
      manager.settings
        ..privateDirect = false
        ..testConcurrency = 50
        ..mixedPort = 18000;

      await manager.resetSettings();

      expect(manager.settings.privateDirect, isTrue);
      expect(manager.settings.testConcurrency, 10);
      expect(manager.settings.mixedPort, 18000);
      expect(manager.settings.clashSecret, secret);
      expect(manager.profiles, hasLength(1));
      expect(manager.activeProfile, isNotNull);
    });

    test('clearing the cache removes the file and comes back connected', () async {
      await manager.connect();
      final cache = File(await platform.cachePath())..writeAsStringSync('old');
      manager.delays['A'] = 80;
      manager.failedNodes.add('B');

      await manager.clearCache();

      expect(cache.existsSync(), isFalse);
      expect(manager.delays, isEmpty);
      expect(manager.failedNodes, isEmpty);
      expect(manager.isRunning, isTrue);
    });
  });

  test('time sync is in the config only when a server is set', () {
    Map<String, dynamic> build(String server) => CoreConfig.build(CoreOptions(
          nodes: const [],
          upstreamPort: 1,
          mitmPort: 2,
          clashPort: 3,
          clashSecret: 's',
          ruleSetDirectory: 'rules',
          cachePath: 'cache.db',
          ntpServer: server,
        ));

    expect(build('').containsKey('ntp'), isFalse);
    expect(build('time.apple.com')['ntp'], {'enabled': true, 'server': 'time.apple.com', 'server_port': 123, 'interval': '30m'});
    expect(build('pool.example:1234')['ntp']['server_port'], 1234);
  });
}
