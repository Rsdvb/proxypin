import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/rule_group.dart';

class _Platform implements CorePlatform {
  final Directory root;
  final StreamController<CoreState> controller = StreamController.broadcast();
  final List<String> calls = [];
  bool running = false;
  Object? startError;

  _Platform(this.root);

  @override
  Stream<CoreState> get states => controller.stream;

  @override
  Future<Directory> directory() async => root;

  @override
  Future<String> cachePath() async => '${root.path}/cache.db';

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<void> start() async {
    calls.add('start');
    if (startError != null) throw startError!;
    running = true;
  }

  @override
  Future<void> reload() async => calls.add('reload');

  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<void> setSystemProxy(int? port) async => calls.add('systemProxy:$port');

  @override
  Future<void> setKeepAlive(bool enabled) async => calls.add('keepAlive:$enabled');

  @override
  Future<void> watchCapture({required int port, required int clashPort, required String secret, required String fallbackMode}) async {
    calls.add('watch:$fallbackMode');
  }

  @override
  Future<void> unwatchCapture() async => calls.add('unwatch');
}

class _Mitm implements MitmHost {
  final List<String> calls;

  _Mitm(this.calls);

  @override
  int get port => 9099;

  @override
  List<String>? domains = ['example.com'];

  @override
  List<String> editableDomains = ['example.com'];

  @override
  Future<void> attach(int upstreamPort) async => calls.add('attach:$upstreamPort');

  @override
  Future<void> detach() async => calls.add('detach');
}

class _Api extends ClashApi {
  final List<String> calls;
  int failuresBeforeReady = 0;
  Map<String, int> latency = const {};

  _Api(this.calls) : super(port: 1, secret: 's');

  @override
  Future<String?> mode() async {
    if (failuresBeforeReady > 0) {
      failuresBeforeReady--;
      throw const SocketException('not ready');
    }
    return 'Rule';
  }

  @override
  Future<void> setMode(String mode) async => calls.add('mode:$mode');

  @override
  Future<void> select(String group, String node) async => calls.add('select:$group:$node');

  @override
  Future<Map<String, int>> groupDelay(String group, {required String url, int timeoutMs = 5000}) async => latency;
}

void main() {
  late Directory root;
  late _Platform platform;
  late _Api api;
  late _Mitm mitm;
  late CoreManager manager;

  Map<String, dynamic> writtenConfig() => jsonDecode(File('${root.path}/config.json').readAsStringSync());

  CoreManager build({bool alwaysTun = false, Set<String> bundled = const {}}) => CoreManager(
        platform: platform,
        store: CoreStore(root),
        mitm: mitm,
        alwaysTun: alwaysTun,
        loadRuleSet: (name) async => bundled.contains(name) ? Uint8List.fromList([1, 2, 3]) : null,
        apiFactory: (port, secret) => api,
      );

  const twoNodes = 'trojan://p@a.example:443#A\ntrojan://p@b.example:443#B';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rsproxy_manager_');
    platform = _Platform(root);
    api = _Api(platform.calls);
    mitm = _Mitm(platform.calls);
    manager = build();
    await manager.load();
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  group('connecting', () {
    test('sets the system proxy only after the core answers', () async {
      api.failuresBeforeReady = 3;
      await manager.addProfile(twoNodes);
      await manager.connect();

      expect(manager.state, CoreState.running);
      expect(platform.calls, ['start', 'mode:Rule', 'unwatch', 'keepAlive:false', 'detach', 'systemProxy:17890']);
    });

    test('with TUN there is no system proxy and no local port', () async {
      manager = build(alwaysTun: true);
      await manager.load();
      await manager.connect();

      expect(platform.calls, isNot(contains('systemProxy:17890')));
      final inbounds = (writtenConfig()['inbounds'] as List).map((e) => e['tag']);
      expect(inbounds, ['tun-in', 'upstream-in']);
    });

    test('a failed start reports why and stops cleanly', () async {
      platform.startError = StateError('port in use');
      await manager.connect();

      expect(manager.state, CoreState.stopped);
      expect(manager.lastError, contains('port in use'));
      expect(platform.calls, contains('stop'));
      expect(platform.calls, isNot(contains('systemProxy:17890')));
    });

    test('disconnecting clears the system proxy before the core goes away', () async {
      await manager.connect();
      platform.calls.clear();
      await manager.disconnect();

      expect(manager.state, CoreState.stopped);
      expect(platform.calls.indexOf('systemProxy:null'), lessThan(platform.calls.indexOf('stop')));
    });

    test('a tunnel already running after a relaunch is picked up, and its stored mode corrected', () async {
      platform.running = true;
      manager = build(alwaysTun: true);
      await manager.load();

      expect(manager.state, CoreState.running);
      expect(platform.calls, contains('mode:Rule'));
    });

    test('rule sets missing from the build are left out, or the core would not start', () async {
      manager = build(bundled: {'geosite-netflix'});
      await manager.load();
      manager.settings.groups = [
        RuleGroup(id: 'a', name: 'a', ruleSets: ['geosite-netflix', 'geosite-missing'])
      ];
      await manager.connect();

      final sets = (writtenConfig()['route']['rule_set'] as List).map((e) => e['tag']);
      expect(sets, ['geosite-netflix']);
      expect(File('${root.path}/rules/geosite-netflix.srs').existsSync(), isTrue);
    });
  });

  group('capture', () {
    test('the decryption side is ready before traffic is sent to it', () async {
      await manager.connect();
      platform.calls.clear();
      await manager.setCapture(true);

      expect(platform.calls, ['attach:17891', 'keepAlive:true', 'mode:CaptureRule', 'watch:Rule']);
    });

    test('turning it off stops traffic first, then releases the app', () async {
      await manager.connect();
      await manager.setCapture(true);
      platform.calls.clear();
      await manager.setCapture(false);

      expect(platform.calls, ['mode:Rule', 'unwatch', 'keepAlive:false', 'detach']);
    });

    test('needs no reload', () async {
      await manager.connect();
      await manager.setCapture(true);
      await manager.setCapture(false);
      await manager.setMode(RouteMode.global);

      expect(platform.calls, isNot(contains('reload')));
      expect(platform.calls.where((e) => e == 'start'), hasLength(1));
    });

    test('global mode keeps capture and watches the right fallback', () async {
      await manager.connect();
      await manager.setCapture(true);
      platform.calls.clear();
      await manager.setMode(RouteMode.global);

      expect(platform.calls, ['mode:CaptureGlobal']);

      platform.calls.clear();
      await manager.onResumed();
      expect(platform.calls, contains('watch:Global'));
    });

    test('is remembered for the next connection', () async {
      await manager.setCapture(true);
      expect(platform.calls, isEmpty, reason: 'nothing to do while disconnected');

      await manager.connect();
      expect(platform.calls, containsAllInOrder(['start', 'attach:17891', 'mode:CaptureRule']));
    });
  });

  group('profiles', () {
    test('pasting content makes the first profile active', () async {
      final profile = await manager.addProfile(twoNodes);

      expect(manager.activeProfile, same(profile));
      expect(manager.nodes.map((e) => e['tag']), ['A', 'B']);
      expect(profile.isSubscription, isFalse);
    });

    test('a second profile does not take over', () async {
      final first = await manager.addProfile(twoNodes);
      await manager.addProfile('trojan://p@c.example:443#C');
      expect(manager.activeProfile, same(first));
    });

    test('rejects what it cannot read and keeps nothing', () async {
      await expectLater(manager.addProfile('hello'), throwsFormatException);
      expect(manager.profiles, isEmpty);
    });

    test('downloads a subscription and names it', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..headers.set('subscription-userinfo', 'upload=1; download=2; total=10')
          ..headers.set('content-disposition', 'attachment; filename="airport.yaml"')
          ..write(base64.encode(utf8.encode(twoNodes)))
          ..close();
      });

      final profile = await manager.addProfile(' http://127.0.0.1:${server.port}/sub \n');

      expect(profile.name, 'airport');
      expect(profile.isSubscription, isTrue);
      expect(profile.info!.used, 3);
      expect(profile.nodes, hasLength(2));
    });

    test('a failed update keeps the nodes it had', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var healthy = true;
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (healthy) {
          request.response.write(twoNodes);
        } else {
          request.response.statusCode = 500;
        }
        request.response.close();
      });

      final profile = await manager.addProfile('http://127.0.0.1:${server.port}/sub');
      healthy = false;

      await expectLater(manager.updateProfile(profile), throwsA(isA<HttpException>()));
      expect(profile.nodes, hasLength(2));
    });

    test('updating the active profile reloads the running core', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..write(twoNodes)
          ..close();
      });

      final profile = await manager.addProfile('http://127.0.0.1:${server.port}/sub');
      await manager.connect();
      await manager.updateProfile(profile);

      expect(platform.calls, contains('reload'));
    });

    test('removing the active profile moves on to the next', () async {
      final first = await manager.addProfile(twoNodes);
      final second = await manager.addProfile('trojan://p@c.example:443#C');
      await manager.removeProfile(first.id);

      expect(manager.activeProfile, same(second));
      await manager.removeProfile(second.id);
      expect(manager.activeProfile, isNull);
      expect(manager.nodes, isEmpty);
    });

    test('order and contents survive a restart', () async {
      await manager.addProfile('trojan://p@a.example:443#A', name: 'one');
      await manager.addProfile('trojan://p@b.example:443#B', name: 'two');
      await manager.reorderProfiles(1, 0);
      await manager.selectNode('A');

      final next = build();
      await next.load();

      expect(next.profiles.map((e) => e.name), ['two', 'one']);
      expect(next.activeProfile!.name, 'one');
      expect(next.selectedNode, 'A');
    });
  });

  group('nodes', () {
    test('choosing a node applies at once and comes back after a restart', () async {
      await manager.addProfile(twoNodes);
      await manager.connect();
      await manager.selectNode('B');

      expect(platform.calls, contains('select:select:B'));
      expect(platform.calls, isNot(contains('reload')));

      await manager.disconnect();
      await manager.connect();
      final select = (writtenConfig()['outbounds'] as List).firstWhere((e) => e['tag'] == 'select');
      expect(select['default'], 'B');
    });

    test('each profile remembers its own node', () async {
      final first = await manager.addProfile(twoNodes);
      await manager.selectNode('B');
      final second = await manager.addProfile('trojan://p@c.example:443#C');
      await manager.setActiveProfile(second.id);
      expect(manager.selectedNode, isNull);
      await manager.setActiveProfile(first.id);
      expect(manager.selectedNode, 'B');
    });

    test('latency replaces the old results', () async {
      await manager.addProfile(twoNodes);
      await manager.connect();
      manager.delays['gone'] = 1;
      api.latency = {'A': 80};
      await manager.testLatency();

      expect(manager.delays, {'A': 80});
      expect(manager.testing, isFalse);
    });

    test('changing rule groups needs a reload to take effect', () async {
      await manager.connect();
      await manager.saveGroups([]);
      expect(platform.calls, contains('reload'));
      expect(platform.calls.last, isNot('reload'), reason: 'the stored mode must be set again afterwards');
    });
  });

  group('merged profiles', () {
    test('take their nodes from the sources, and follow them', () async {
      final first = await manager.addProfile('trojan://p@a.example:443#A');
      final second = await manager.addProfile('trojan://p@b.example:443#B', name: 'second');
      final merged = await manager.mergeProfiles('all', [first.id, second.id]);
      await manager.setActiveProfile(merged.id);

      expect(manager.nodes.map((e) => e['tag']), ['A', 'B']);

      second.nodes = [
        {'tag': 'C', 'type': 'trojan'}
      ];
      expect(manager.nodes.map((e) => e['tag']), ['A', 'C']);
    });

    test('keep tags unique, which sing-box requires', () async {
      final first = await manager.addProfile('trojan://p@a.example:443#HK', name: 'one');
      final second = await manager.addProfile('trojan://p@b.example:443#HK', name: 'two');
      final merged = await manager.mergeProfiles('all', [first.id, second.id]);
      await manager.setActiveProfile(merged.id);

      expect(manager.nodes.map((e) => e['tag']), ['HK', 'two HK']);
      expect(first.nodes.single['tag'], 'HK', reason: 'the source stays as it was');
    });

    test('lose a removed source without breaking', () async {
      final first = await manager.addProfile('trojan://p@a.example:443#A');
      final second = await manager.addProfile('trojan://p@b.example:443#B');
      final merged = await manager.mergeProfiles('all', [first.id, second.id]);
      await manager.setActiveProfile(merged.id);
      await manager.removeProfile(second.id);

      expect(manager.nodes.map((e) => e['tag']), ['A']);
    });
  });

  group('backup', () {
    test('restores profiles and the list, and keeps this device\'s secret', () async {
      await manager.addProfile(twoNodes, name: 'saved');
      await manager.selectNode('B');
      final secret = manager.settings.clashSecret;
      final backup = manager.exportBackup();

      await manager.removeProfile(manager.profiles.single.id);
      mitm.editableDomains = [];
      await manager.restoreBackup(backup);

      expect(manager.activeProfile!.name, 'saved');
      expect(manager.selectedNode, 'B');
      expect(mitm.editableDomains, ['example.com']);
      expect(manager.settings.clashSecret, secret);
    });

    test('a bad file changes nothing', () async {
      await manager.addProfile(twoNodes);
      await expectLater(manager.restoreBackup(Uint8List.fromList([1, 2, 3])), throwsFormatException);
      expect(manager.profiles, hasLength(1));
    });

    test('never contains the WebDAV password', () async {
      await manager.saveWebDav(url: 'https://dav.example', username: 'me', password: 'hunter2');
      final backup = manager.exportBackup();
      await manager.saveWebDav(url: '', username: '', password: '');
      await manager.restoreBackup(backup);

      expect(manager.settings.webDavPassword, isEmpty);
    });
  });

  test('favourites are kept by name and survive a restart', () async {
    await manager.toggleFavorite('香港 01');
    await manager.toggleFavorite('日本 01');
    await manager.toggleFavorite('日本 01');

    final next = build();
    await next.load();
    expect(next.settings.favorites, {'香港 01'});
  });

  test('blank advanced fields keep what was there', () async {
    await manager.saveAdvanced(remoteDns: '', directDns: '223.5.5.5', testUrl: '', fakeIp: false, ipv6: false);

    expect(manager.settings.remoteDns, 'https://1.1.1.1/dns-query');
    expect(manager.settings.directDns, '223.5.5.5');
    expect(manager.settings.fakeIp, isFalse);
  });

  test('settings use a secret of their own on each install', () {
    expect(CoreSettings().clashSecret, isNot(CoreSettings().clashSecret));
    expect(CoreConfig.modes, contains('CaptureRule'));
  });
}
