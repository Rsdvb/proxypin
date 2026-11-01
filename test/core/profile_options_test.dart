import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/clash_routing.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/profile_decrypt.dart';
import 'package:proxypin/core/profile_parser.dart';
import 'package:proxypin/core/subscription.dart';

const _links = 'trojan://p@a.example:443#香港 01\ntrojan://p@b.example:443#日本 02\nvless://u@c.example:443?security=tls#美国 03';

/// Encrypts the way a provider does, so the decryption is tested against the format and not against itself.
String _encrypt(String password, String plain) {
  final key = MD5Digest().process(Uint8List.fromList(utf8.encode(password)));
  final random = Random(1);
  final iv = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(true, PaddedBlockCipherParameters<CipherParameters, CipherParameters>(ParametersWithIV<KeyParameter>(KeyParameter(key), iv), null));
  return base64.encode([...iv, ...cipher.process(Uint8List.fromList(utf8.encode(plain)))]);
}

class _Platform implements CorePlatform {
  final Directory root;
  final List<String> calls = [];

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
  Future<bool> isRunning() async => false;

  @override
  Future<void> start([Map<String, Object> options = const {}]) async => calls.add('start');

  @override
  Future<void> reload() async => calls.add('reload');

  @override
  Future<void> stop() async => calls.add('stop');

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
  Map<String, int> group = const {};

  /// How each node answers a retry, in order. Missing means it stays down.
  final Map<String, List<int?>> retries = {};
  final List<String> asked = [];

  _Api() : super(port: 1, secret: 's');

  @override
  Future<String?> mode() async => 'Rule';

  @override
  Future<void> setMode(String mode) async {}

  @override
  Future<Map<String, int>> groupDelay(String group, {required String url, int timeoutMs = 5000}) async => this.group;

  @override
  Future<int?> delay(String node, {required String url, int timeoutMs = 5000}) async {
    asked.add(node);
    final answers = retries[node];
    return answers == null || answers.isEmpty ? null : answers.removeAt(0);
  }
}

void main() {
  group('user agent', () {
    test('sends the choices joined, after the app name when appending', () {
      expect(UserAgents.compose(true, ['a', 'b']), '${UserAgents.self} a;b');
      expect(UserAgents.compose(false, ['a', 'b']), 'a;b');
    });

    test('never sends an empty one', () {
      expect(UserAgents.compose(false, const []), UserAgents.self);
    });

    test('every preset is on for a new profile', () {
      expect(Profile(id: '1', name: 'p').userAgents, UserAgents.presets);
    });

    test('the short form hides versions', () {
      expect(UserAgents.short(['mihomo/1.19.28', 'FLClash']), 'mihomo/...;FLClash');
    });
  });

  group('filter', () {
    Profile profile(NodeFilterMethod method, String pattern, {bool matchType = false}) => Profile(
          id: '1',
          name: 'p',
          filterMethod: method,
          filterPattern: pattern,
          filterMatchType: matchType,
          nodes: ProfileParser.parse(_links).outbounds,
        );

    List<Object?> tags(Profile item) => item.activeNodes.map((e) => e['tag']).toList();

    test('all keeps everything, whatever the pattern says', () {
      expect(tags(profile(NodeFilterMethod.all, '香港')), hasLength(3));
    });

    test('include and exclude', () {
      expect(tags(profile(NodeFilterMethod.include, '香港|日本')), ['香港 01', '日本 02']);
      expect(tags(profile(NodeFilterMethod.exclude, '香港')), ['日本 02', '美国 03']);
    });

    test('an empty pattern filters nothing', () {
      expect(tags(profile(NodeFilterMethod.include, '')), hasLength(3));
    });

    test('text that is not a valid regex is a keyword', () {
      final item = profile(NodeFilterMethod.include, '香港 (')..nodes = [
        {'tag': '香港 (IEPL)', 'type': 'trojan'},
        {'tag': '日本', 'type': 'trojan'},
      ];
      expect(tags(item), ['香港 (IEPL)']);
    });

    test('attributes match the protocol as well', () {
      expect(tags(profile(NodeFilterMethod.include, 'vless')), isEmpty);
      expect(tags(profile(NodeFilterMethod.include, 'vless', matchType: true)), ['美国 03']);
    });

    test('nodes removed by a failed check stay out', () {
      expect(tags(profile(NodeFilterMethod.all, '')..removedNodes = {'日本 02'}), ['香港 01', '美国 03']);
    });
  });

  group('links', () {
    test('a name can come from the link itself', () {
      expect(Subscription.nameInLink('https://a.example/sub#%E6%9C%BA%E5%9C%BA'), '机场');
      expect(Subscription.nameInLink('https://a.example/sub?remarks=me'), 'me');
      expect(Subscription.nameInLink('https://a.example/sub?name=you'), 'you');
      expect(Subscription.nameInLink('https://a.example/sub?token=1'), isNull);
    });

    test('GitHub pages become raw file addresses', () {
      expect(Subscription.normalizeUrl('https://github.com/u/r/blob/main/a/b.yaml'),
          'https://raw.githubusercontent.com/u/r/main/a/b.yaml');
      expect(Subscription.normalizeUrl('https://example.com/blob/x'), 'https://example.com/blob/x');
    });
  });

  group('encrypted subscriptions', () {
    test('decrypts the format providers use', () {
      expect(ProfileDecrypt.decrypt('secret', _encrypt('secret', _links)), _links);
    });

    test('a wrong password or other text gives nothing back', () {
      expect(ProfileDecrypt.decrypt('wrong', _encrypt('secret', _links)), isNull);
      expect(ProfileDecrypt.decrypt('secret', 'not base64 at all'), isNull);
      expect(ProfileDecrypt.decrypt('', _encrypt('secret', _links)), isNull);
    });
  });

  group('download', () {
    late HttpServer server;
    final seen = <String>[];
    final headers = <String, String?>{};
    var encrypted = false;
    var body = _links;

    setUp(() async {
      seen.clear();
      headers.clear();
      encrypted = false;
      body = _links;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        seen.add(request.uri.toString());
        headers['x-hwid'] = request.headers.value('x-hwid');
        if (encrypted) request.response.headers.set('subscription-encryption', 'true');
        request.response
          ..write(body)
          ..close();
      });
    });

    tearDown(() => server.close(force: true));

    String direct() => 'http://127.0.0.1:${server.port}/sub';

    /// Plain HTTP through a proxy carries the whole address in the request line, which tells the two paths apart.
    String proxy() => '127.0.0.1:${server.port}';

    Future<int> deadPort() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    }

    test('prefer proxy goes through it', () async {
      await Subscription.fetch('http://panel.invalid/sub', proxy: proxy());
      expect(seen.single, 'http://panel.invalid/sub');
    });

    test('prefer proxy falls back to direct', () async {
      await Subscription.fetch(direct(), proxy: '127.0.0.1:${await deadPort()}');
      expect(seen.single, '/sub');
    });

    test('prefer direct tries direct first, then the proxy', () async {
      await Subscription.fetch(direct(), strategy: DownloadStrategy.preferDirect, proxy: proxy());
      expect(seen.single, '/sub');

      await Subscription.fetch('http://panel.invalid/sub', strategy: DownloadStrategy.preferDirect, proxy: proxy());
      expect(seen.last, 'http://panel.invalid/sub');
    });

    test('only direct ignores the proxy', () async {
      await Subscription.fetch(direct(), strategy: DownloadStrategy.onlyDirect, proxy: '127.0.0.1:${await deadPort()}');
      expect(seen.single, '/sub');
    });

    test('only proxy does not fall back', () async {
      await expectLater(
          Subscription.fetch(direct(), strategy: DownloadStrategy.onlyProxy, proxy: '127.0.0.1:${await deadPort()}'),
          throwsA(isA<SocketException>()));
      expect(seen, isEmpty);
    });

    test('only proxy needs a connection', () {
      expect(Subscription.fetch(direct(), strategy: DownloadStrategy.onlyProxy), throwsA(isA<SocketException>()));
    });

    test('sends the extra headers', () async {
      await Subscription.fetch(direct(), headers: const {'x-hwid': 'abc'});
      expect(headers['x-hwid'], 'abc');
    });

    test('an encrypted subscription needs its password', () async {
      encrypted = true;
      body = _encrypt('secret', _links);

      await expectLater(Subscription.fetch(direct()), throwsFormatException);
      await expectLater(Subscription.fetch(direct(), decryptPassword: 'wrong'), throwsFormatException);

      final result = await Subscription.fetch(direct(), decryptPassword: 'secret');
      expect(result.parsed.outbounds, hasLength(3));
    });

    test('a password is not applied to a plain subscription', () async {
      final result = await Subscription.fetch(direct(), decryptPassword: 'secret');
      expect(result.parsed.outbounds, hasLength(3));
    });

    test('what could not be read is kept so it can be looked at', () async {
      body = '<html>blocked</html>';
      await expectLater(
          Subscription.fetch(direct()),
          throwsA(isA<UnreadableProfileException>().having((e) => e.content, 'content', contains('blocked'))));
    });
  });

  group('provider rules', () {
    const clash = '''
proxies:
  - {name: HK, type: trojan, server: h.example, port: 443, password: p}
  - {name: JP, type: trojan, server: j.example, port: 443, password: p}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Auto, HK, DIRECT]}
  - {name: Auto, type: url-test, proxies: [HK, JP, Gone], url: 'http://t.example'}
  - {name: Everything, type: select, include-all: true}
rules:
  - DOMAIN-SUFFIX,a.example,Proxy
  - DOMAIN-KEYWORD,b,Proxy
  - DOMAIN,c.example,DIRECT
  - IP-CIDR,10.1.0.0/16,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - GEOSITE,netflix,JP
  - DOMAIN-SUFFIX,ads.example,REJECT
  - RULE-SET,custom,Proxy
  - MATCH,Proxy
''';

    ProviderRouting routing() => ProfileParser.parse(clash).routing!;

    test('merges neighbours with the same target and reads the end rule', () {
      final parsed = routing();
      expect(parsed.rules.first.target, 'Proxy');
      expect(parsed.rules.first.match, {
        'domain_suffix': ['a.example'],
        'domain_keyword': ['b'],
      });
      expect(parsed.finalTarget, 'Proxy');
      expect(parsed.ruleSets, {'geoip-cn', 'geosite-netflix'});
    });

    test('share links carry no rules', () {
      expect(ProfileParser.parse(_links).routing, isNull);
    });

    test('groups become outbounds, dropping members that are gone', () {
      final groups = routing().outbounds(['HK', 'JP'], testUrl: 'http://t.example');
      Map<String, dynamic> group(String tag) => groups.firstWhere((e) => e['tag'] == tag);

      expect(group('group:Proxy')['type'], 'selector');
      expect(group('group:Proxy')['outbounds'], ['group:Auto', 'HK', 'direct']);
      expect(group('group:Auto')['type'], 'urltest');
      expect(group('group:Auto')['outbounds'], ['HK', 'JP']);
      expect(group('group:Everything')['outbounds'], ['HK', 'JP']);
    });

    test('a group left with nothing still gives sing-box something valid', () {
      final groups = routing().outbounds(const [], testUrl: 'http://t.example');
      expect(groups.firstWhere((e) => e['tag'] == 'group:Auto')['outbounds'], ['direct']);
    });

    test('rules point at the right outbound, and a filtered node falls back', () {
      final rules = routing().routeRules(['HK'], {'geoip-cn', 'geosite-netflix'}, fallback: 'select');
      Map<String, dynamic> rule(String field) => rules.firstWhere((e) => e.containsKey(field));

      expect(rule('domain_suffix')['outbound'], 'group:Proxy');
      expect(rule('domain')['outbound'], 'direct');
      expect(rules.firstWhere((e) => e['rule_set']?.contains('geosite-netflix') == true)['outbound'], 'select');
      expect(rules.last['action'], 'reject');
    });

    test('rule sets the app lacks are dropped, or the core would not start', () {
      final rules = routing().routeRules(['HK', 'JP'], {'geoip-cn'}, fallback: 'select');
      expect(jsonEncode(rules), isNot(contains('geosite-netflix')));
    });

    test('survives being saved', () {
      final restored = ProviderRouting.fromJson(jsonDecode(jsonEncode(routing())));
      expect(jsonEncode(restored), jsonEncode(routing()));
    });

    test('they run after the user\'s groups, and only when kept', () {
      final options = CoreOptions(
        nodes: ProfileParser.parse(clash).outbounds,
        providerRouting: routing(),
        providerRuleSets: const {'geoip-cn'},
        upstreamPort: 1,
        mitmPort: 2,
        clashPort: 3,
        clashSecret: 's',
        ruleSetDirectory: 'rules',
        cachePath: 'c',
      );
      final config = CoreConfig.build(options);
      expect((config['outbounds'] as List).map((e) => e['tag']), contains('group:Proxy'));
      expect(config['route']['final'], 'group:Proxy');
      expect((config['route']['rule_set'] as List).map((e) => e['tag']), ['geoip-cn']);
    });
  });

  group('manager', () {
    late Directory root;
    late _Platform platform;
    late _Api api;
    late CoreManager manager;
    late HttpServer server;
    var body = _links;

    setUp(() async {
      body = _links;
      root = await Directory.systemTemp.createTemp('rsproxy_options_');
      platform = _Platform(root);
      api = _Api();
      manager = CoreManager(
        platform: platform,
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (_) async => null,
        fetchRuleSet: (_, __) async => throw const SocketException('offline'),
        apiFactory: (_, __) => api,
      );
      await manager.load();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response
          ..write(body)
          ..close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await root.delete(recursive: true);
    });

    String url([String path = '/sub']) => 'http://127.0.0.1:${server.port}$path';

    Map<String, dynamic> config() => jsonDecode(File('${root.path}/config.json').readAsStringSync());

    test('options chosen on the add page reach the profile', () async {
      final options = Profile(id: '', name: '')
        ..xhwid = true
        ..filterMethod = NodeFilterMethod.exclude
        ..filterPattern = '美国'
        ..updateMinutes = 30
        ..website = 'https://panel.example';
      final profile = await manager.addProfile(url(), options: options);

      expect(profile.xhwid, isTrue);
      expect(profile.updateMinutes, 30);
      expect(profile.website, 'https://panel.example');
      expect(profile.activeNodes, hasLength(2));
    });

    test('the same subscription cannot be added twice', () async {
      await manager.addProfile(url());
      await expectLater(manager.addProfile(url()), throwsA(isA<DuplicateProfileException>()));
    });

    test('a name in use is refused when typed, and numbered when automatic', () async {
      await manager.addProfile(url('/a'), name: 'mine');
      await expectLater(manager.addProfile(url('/b'), name: 'mine'), throwsA(isA<DuplicateProfileException>()));

      final first = await manager.addProfile(url('/c#auto'));
      final second = await manager.addProfile(url('/d#auto'));
      expect(first.name, 'auto');
      expect(second.name, 'auto 2');
    });

    test('an import link pasted in works, and brings its DNS along', () async {
      final encoded = Uri.encodeComponent(url());
      final profile = await manager.addProfile('clash://install-config?url=$encoded&name=me&outbound-dns=1.1.1.1,8.8.8.8');

      expect(profile.url, url());
      expect(profile.name, 'me');
      expect(profile.outboundDns, ['1.1.1.1', '8.8.8.8']);
      expect(profile.preferOutboundDns, isTrue);

      await manager.connect();
      expect(config()['route']['default_domain_resolver'], {'server': 'dns-outbound'});
    });

    test('updating leaves the running core alone unless asked to reload', () async {
      final profile = await manager.addProfile(url());
      await manager.connect();
      platform.calls.clear();

      await manager.updateProfile(profile);
      expect(platform.calls, isNot(contains('reload')));
      expect(manager.needsReload, isTrue);

      await manager.reloadConfig();
      expect(platform.calls, contains('reload'));
      expect(manager.needsReload, isFalse);
    });

    test('with reload on, an update applies at once', () async {
      final profile = await manager.addProfile(url());
      profile.reloadAfterUpdate = true;
      await manager.connect();
      platform.calls.clear();

      await manager.updateProfile(profile);

      expect(platform.calls, contains('reload'));
      expect(manager.needsReload, isFalse);
    });

    test('an automatic update can test latency, a manual one does not', () async {
      final profile = await manager.addProfile(url());
      profile
        ..reloadAfterUpdate = true
        ..testLatencyAfterUpdate = true;
      api.group = {'香港 01': 50};
      await manager.connect();

      await manager.updateProfile(profile);
      expect(manager.delays, isEmpty);

      await manager.updateProfile(profile, automatic: true);
      await Future.delayed(const Duration(milliseconds: 20));
      expect(manager.delays, containsPair('香港 01', 50));
    });

    test('an update reaches a merged profile that uses it', () async {
      final source = await manager.addProfile(url());
      source.reloadAfterUpdate = true;
      final merged = await manager.mergeProfiles('all', [source.id]);
      await manager.setActiveProfile(merged.id);
      await manager.connect();
      platform.calls.clear();

      body = 'trojan://p@z.example:443#新节点';
      await manager.updateProfile(source);

      expect(manager.nodes.map((e) => e['tag']), ['新节点']);
      expect(platform.calls, contains('reload'));
    });

    group('failed nodes', () {
      late Profile profile;

      setUp(() async {
        profile = await manager.addProfile(url());
        profile.autoRemoveFailed = true;
        await manager.connect();
      });

      test('are tried up to three times in all before going', () async {
        api
          ..group = {'香港 01': 50}
          ..retries['日本 02'] = [null, 80];
        await manager.testLatency();

        expect(profile.removedNodes, {'美国 03'});
        expect(api.asked.where((e) => e == '美国 03'), hasLength(2), reason: 'two retries after the group test');
        expect(api.asked.where((e) => e == '日本 02'), hasLength(2));
        expect(manager.delays, containsPair('日本 02', 80));
      });

      test('stay out after the subscription updates', () async {
        api.group = {'香港 01': 50, '日本 02': 60};
        await manager.testLatency();
        await manager.updateProfile(profile);

        expect(manager.nodes.map((e) => e['tag']), ['香港 01', '日本 02']);
      });

      test('nothing goes when everything failed: that is this device being offline', () async {
        api.group = {};
        await manager.testLatency();

        expect(profile.removedNodes, isEmpty);
        expect(manager.nodes, hasLength(3));
      });

      test('nothing goes unless the option is on', () async {
        profile.autoRemoveFailed = false;
        api.group = {'香港 01': 50};
        await manager.testLatency();

        expect(profile.removedNodes, isEmpty);
      });

      test('can be brought back', () async {
        api.group = {'香港 01': 50};
        await manager.testLatency();
        await manager.restoreRemovedNodes(profile);

        expect(manager.nodes, hasLength(3));
      });
    });

    test('provider rules need the profile option and the global switch', () async {
      body = '''
proxies:
  - {name: HK, type: trojan, server: h.example, port: 443, password: p}
proxy-groups:
  - {name: Proxy, type: select, proxies: [HK]}
rules:
  - DOMAIN-SUFFIX,a.example,Proxy
''';
      final profile = await manager.addProfile(url());
      await manager.connect();
      expect(jsonEncode(config()), isNot(contains('group:Proxy')));

      profile.keepProviderRules = true;
      await manager.saveProfile(profile);
      expect(jsonEncode(config()), contains('group:Proxy'));

      manager.settings.providerRulesEnabled = false;
      await manager.reloadConfig();
      expect(jsonEncode(config()), isNot(contains('group:Proxy')));
    });

    test('custom user agents are shared and can be removed', () async {
      await manager.addUserAgent(' my-agent ');
      await manager.addUserAgent('my-agent');
      await manager.addUserAgent(UserAgents.presets.first);
      expect(manager.settings.userAgents, ['my-agent']);

      await manager.removeUserAgent('my-agent');
      expect(manager.settings.userAgents, isEmpty);
    });

    test('the device id is stable and stays out of backups', () async {
      final id = manager.settings.deviceId;
      expect(id, hasLength(32));

      final backup = manager.exportBackup();
      manager.settings.deviceId = 'other';
      await manager.restoreBackup(backup);
      expect(manager.settings.deviceId, 'other');
      expect(id, isNot('other'));
    });

    test('nodes are worked out once, not on every read', () async {
      await manager.addProfile(url());
      expect(identical(manager.nodes, manager.nodes), isTrue);
    });
  });

  test('a saved profile keeps every option', () {
    final profile = Profile(
      id: '1',
      name: 'p',
      url: 'https://example.com',
      userAgentAppend: false,
      userAgents: ['a'],
      xhwid: true,
      decryptPassword: 'pw',
      filterMethod: NodeFilterMethod.exclude,
      filterPattern: 'x',
      filterMatchType: true,
      keepProviderRules: true,
      downloadStrategy: DownloadStrategy.onlyDirect,
      updateMinutes: null,
      reloadAfterUpdate: true,
      testLatencyAfterUpdate: true,
      autoRemoveFailed: true,
      removedNodes: {'n'},
      outboundDns: ['1.1.1.1'],
      preferOutboundDns: true,
    );
    final restored = Profile.fromJson(jsonDecode(jsonEncode(profile)));

    expect(jsonEncode(restored), jsonEncode(profile));
    expect(restored.updateMinutes, isNull, reason: 'off is not the same as the default');
  });
}
