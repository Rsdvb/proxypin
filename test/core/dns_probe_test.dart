import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/dns_catalog.dart';
import 'package:proxypin/core/dns_probe.dart';
import 'package:proxypin/ui/core/dns_page.dart';

/// 按查询造一个应答：ID 不变，QR 置位，rcode 由 [rcode] 决定
Uint8List _answer(List<int> query, {int rcode = 0}) {
  return Uint8List.fromList([...query.take(2), 0x81, 0x80 | rcode, ...query.skip(4)]);
}

/// 收完一个带长度前缀的 DNS 查询就回答
void _serveFramed(Stream<List<int>> input, void Function(List<int>) write, {int rcode = 0}) {
  final buffer = BytesBuilder();
  input.listen((chunk) {
    buffer.add(chunk);
    final data = buffer.toBytes();
    if (data.length < 2 || data.length < (data[0] << 8 | data[1]) + 2) return;
    final reply = _answer(data.sublist(2), rcode: rcode);
    write([reply.length >> 8, reply.length & 0xff, ...reply]);
  }, onError: (_) {});
}

/// 只认带正确凭据的 CONNECT，然后转发到本机的 [port]
class _FakeProxy {
  final ServerSocket server;
  final List<String> requests = [];

  _FakeProxy._(this.server);

  int get port => server.port;

  static Future<_FakeProxy> start(int Function() target) async {
    final proxy = _FakeProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    proxy.server.listen((client) async {
      final header = BytesBuilder();
      Socket? upstream;
      client.listen((chunk) async {
        if (upstream != null) {
          upstream!.add(chunk);
          return;
        }
        header.add(chunk);
        final text = latin1.decode(header.toBytes());
        if (!text.contains('\r\n\r\n')) return;
        proxy.requests.add(text);
        if (!text.contains('Proxy-Authorization: Basic ${base64.encode(utf8.encode('direct:secret'))}')) {
          client.write('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');
          await client.close();
          return;
        }
        final connected = await Socket.connect(InternetAddress.loopbackIPv4, target());
        upstream = connected;
        client.write('HTTP/1.1 200 Connection established\r\n\r\n');
        connected.listen(client.add, onDone: client.destroy, onError: (_) {});
      }, onDone: () => upstream?.destroy(), onError: (_) {});
    });
    return proxy;
  }
}

void main() {
  late SecurityContext serverContext;

  setUpAll(() {
    final key = base64.encode(File('test/fixtures/certs/ca_private.der').readAsBytesSync());
    final lines = [for (var start = 0; start < key.length; start += 64) key.substring(start, min(start + 64, key.length))];
    serverContext = SecurityContext()
      ..useCertificateChain('test/fixtures/certs/ca.crt')
      ..usePrivateKeyBytes(utf8.encode('-----BEGIN PRIVATE KEY-----\n${lines.join('\n')}\n-----END PRIVATE KEY-----\n'));
  });

  group('the query', () {
    test('asks for an A record with recursion', () {
      final query = DnsProbe.encodeQuery('a.bc', 0x1234);

      expect(query.sublist(0, 4), [0x12, 0x34, 0x01, 0x00]);
      expect(query.sublist(12), [1, 0x61, 2, 0x62, 0x63, 0, 0, 1, 0, 1]);
    });

    test('an answer has to match the id and carry no error', () {
      final query = DnsProbe.encodeQuery('a.bc', 7);

      expect(DnsProbe.isAnswer(_answer(query), 7), isTrue);
      expect(DnsProbe.isAnswer(_answer(query), 8), isFalse);
      expect(DnsProbe.isAnswer(_answer(query, rcode: 2), 7), isFalse);
      expect(DnsProbe.isAnswer(query, 7), isFalse, reason: 'a query is not an answer');
      expect(DnsProbe.isAnswer(const [1, 2, 3], 7), isFalse);
    });
  });

  group('over udp', () {
    late RawDatagramSocket server;

    Future<void> serve({int rcode = 0}) async {
      server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((event) {
        final datagram = event == RawSocketEvent.read ? server.receive() : null;
        if (datagram != null) server.send(_answer(datagram.data, rcode: rcode), datagram.address, datagram.port);
      });
    }

    tearDown(() => server.close());

    test('a working server gives a time', () async {
      await serve();
      expect(await DnsProbe.measure('udp://127.0.0.1:${server.port}', 'gstatic.com'), isNotNull);
    });

    test('an error reply counts as a failure', () async {
      await serve(rcode: 2);
      expect(await DnsProbe.measure('udp://127.0.0.1:${server.port}', 'gstatic.com'), isNull);
    });
  });

  group('over tcp and tls', () {
    test('plain tcp', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) => _serveFramed(client, client.add));
      addTearDown(server.close);

      expect(await DnsProbe.measure('tcp://127.0.0.1:${server.port}', 'gstatic.com'), isNotNull);
    });

    test('tls', () async {
      final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, serverContext);
      server.listen((client) => _serveFramed(client, client.add), onError: (_) {});
      addTearDown(server.close);

      expect(await DnsProbe.measure('tls://127.0.0.1:${server.port}', 'gstatic.com'), isNotNull);
    });

    test('https posts a dns message', () async {
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
      String? contentType;
      server.listen((request) async {
        contentType = request.headers.contentType?.mimeType;
        final body = BytesBuilder();
        await request.forEach(body.add);
        request.response
          ..add(_answer(body.takeBytes()))
          ..close();
      });
      addTearDown(() => server.close(force: true));

      expect(await DnsProbe.measure('https://127.0.0.1:${server.port}/dns-query', 'gstatic.com'), isNotNull);
      expect(contentType, 'application/dns-message');
    });

    test('a dead server is a failure, not a hang', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      expect(await DnsProbe.measure('tcp://127.0.0.1:$port', 'gstatic.com'), isNull);
    });
  });

  group('through the probe inbound', () {
    const route = (user: 'direct', password: 'secret');
    ProbeRoute via(int port) => ProbeRoute(port, route.user, route.password, viaNode: false);

    test('udp servers are asked over tcp, because CONNECT cannot carry udp', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) => _serveFramed(client, client.add));
      addTearDown(server.close);
      final proxy = await _FakeProxy.start(() => server.port);
      addTearDown(proxy.server.close);

      expect(await DnsProbe.measure('udp://203.0.113.1', 'gstatic.com', route: via(proxy.port)), isNotNull);
      expect(proxy.requests.single, startsWith('CONNECT 203.0.113.1:53 HTTP/1.1'));
    });

    test('tls upgrades after the tunnel opens', () async {
      final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, serverContext);
      server.listen((client) => _serveFramed(client, client.add), onError: (_) {});
      addTearDown(server.close);
      final proxy = await _FakeProxy.start(() => server.port);
      addTearDown(proxy.server.close);

      expect(await DnsProbe.measure('tls://203.0.113.1', 'gstatic.com', route: via(proxy.port)), isNotNull);
      expect(proxy.requests.single, startsWith('CONNECT 203.0.113.1:853 HTTP/1.1'));
    });

    test('quic is approximated with tls on the same host', () async {
      final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, serverContext);
      server.listen((client) => _serveFramed(client, client.add), onError: (_) {});
      addTearDown(server.close);
      final proxy = await _FakeProxy.start(() => server.port);
      addTearDown(proxy.server.close);

      expect(await DnsProbe.measure('quic://dns.example', 'gstatic.com', route: via(proxy.port)), isNotNull);
      expect(proxy.requests.single, startsWith('CONNECT dns.example:853 HTTP/1.1'));
    });

    test('a refused tunnel is a failure', () async {
      final proxy = await _FakeProxy.start(() => 1);
      addTearDown(proxy.server.close);
      final wrong = ProbeRoute(proxy.port, 'direct', 'wrong', viaNode: false);

      expect(await DnsProbe.measure('tcp://203.0.113.1', 'gstatic.com', route: wrong), isNull);
    });

    test('the system resolver cannot go through a node', () async {
      final node = ProbeRoute(1, 'node', 'secret', viaNode: true);

      expect(await DnsProbe.measure(DnsCatalog.local, 'gstatic.com', route: node), DnsProbe.unsupported);
      expect(await DnsProbe.measure(DnsCatalog.dhcp, 'gstatic.com', route: node), DnsProbe.unsupported);
    });
  });

  group('the probe inbound in the config', () {
    CoreOptions options({List<String> bypass = const [], TunSettings? tun}) => CoreOptions(
          nodes: const [],
          tun: true,
          tunSettings: tun,
          mixedPort: 7890,
          upstreamPort: 7891,
          mitmPort: 9099,
          probePort: 7893,
          proxyBypass: bypass,
          clashPort: 9191,
          clashSecret: 'secret',
          ruleSetDirectory: 'rules',
          cachePath: 'cache.db',
        );

    List<Map<String, dynamic>> rules(CoreOptions value) =>
        (CoreConfig.build(value)['route']['rules'] as List).cast<Map<String, dynamic>>();

    Map<String, dynamic> inbound(CoreOptions value, String tag) =>
        (CoreConfig.build(value)['inbounds'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

    test('needs a password, so other programs cannot use it to get around the rules', () {
      final users = inbound(options(), 'probe-in')['users'] as List;
      expect(users.map((e) => e['username']), [CoreConfig.probeDirect, CoreConfig.probeNode]);
      expect(users.every((e) => e['password'] == 'secret'), isTrue);
    });

    test('comes before sniffing, or a query to port 53 gets hijacked by the dns rule', () {
      final list = rules(options());

      expect(list[0], {
        'inbound': ['probe-in'],
        'auth_user': [CoreConfig.probeDirect],
        'action': 'route',
        'outbound': 'direct',
      });
      expect(list[1]['outbound'], 'select');
      expect(list[1].containsKey('auth_user'), isFalse);
      expect(list[2], {'action': 'sniff'});
    });

    test('bypass domains reach the HTTP proxy without the Windows-only entry', () {
      final tun = inbound(options(bypass: const ['localhost', '<local>'], tun: TunSettings()), 'tun-in');
      expect(tun['platform']['http_proxy']['bypass_domain'], ['localhost']);
    });

    test('strict route needs auto route', () {
      expect(inbound(options(tun: TunSettings(strictRoute: true)), 'tun-in')['strict_route'], isTrue);
      expect(inbound(options(tun: TunSettings(strictRoute: true, autoRoute: false)), 'tun-in').containsKey('strict_route'), isFalse);
    });

    // CI points this at a folder and runs `sing-box check` over what lands there.
    test('writes a config for sing-box to check', () {
      final directory = Platform.environment['CORE_CONFIG_OUT'];
      if (directory == null) return;
      Directory(directory).createSync(recursive: true);
      final config = CoreConfig.build(options(bypass: CoreSettings.defaultBypassDomains, tun: TunSettings()));
      File('$directory/probe.json').writeAsStringSync(jsonEncode(config));
    });
  });

  group('choosing servers automatically', () {
    const ipUdp = DnsServer('a', 'udp://1.1.1.1');
    const namedTls = DnsServer('b', 'tls://dns.example');
    const ipHttps = DnsServer('c', 'https://8.8.8.8/dns-query');
    const system = DnsServer('Local', DnsCatalog.local);
    const servers = [system, ipUdp, namedTls, ipHttps];

    test('the system resolver never wins, its cache would always make it fastest', () {
      final best = DnsAutoSetup.choose(servers, {DnsCatalog.local: 0, ipUdp.url: 5}, const {}, ProxyResolve.fakeip);
      expect(best.direct, ipUdp.url);
    });

    test('the resolver has to be an address, and proxy traffic stays encrypted', () {
      final best = DnsAutoSetup.choose(servers, {namedTls.url: 1, ipHttps.url: 2, ipUdp.url: 3}, const {}, ProxyResolve.proxy);

      expect(best.direct, namedTls.url);
      expect(best.resolver, ipHttps.url);
      expect(best.proxy, namedTls.url);
    });

    test('proxy dns is judged by the node path unless it goes direct', () {
      final direct = {ipHttps.url: 1, namedTls.url: 9};
      final node = {ipHttps.url: 9, namedTls.url: 1};

      expect(DnsAutoSetup.choose(servers, direct, node, ProxyResolve.proxy).proxy, namedTls.url);
      expect(DnsAutoSetup.choose(servers, direct, node, ProxyResolve.fakeip).proxy, namedTls.url);
      expect(DnsAutoSetup.choose(servers, direct, node, ProxyResolve.direct).proxy, ipHttps.url);
    });

    test('failures and unsupported paths are skipped', () {
      final best = DnsAutoSetup.choose(servers, {ipUdp.url: null, ipHttps.url: DnsProbe.unsupported, namedTls.url: 7}, const {},
          ProxyResolve.fakeip);
      expect(best.direct, namedTls.url);
    });

    test('nothing reachable changes nothing', () {
      final best = DnsAutoSetup.choose(servers, const {}, const {}, ProxyResolve.fakeip);
      expect(best.isEmpty, isTrue);

      final dns = DnsSettings(direct: 'udp://9.9.9.9');
      best.applyTo(dns);
      expect(dns.direct, 'udp://9.9.9.9');
    });

    test('the result goes to the right roles', () {
      final dns = DnsSettings();
      const DnsAutoSetup('udp://1.1.1.1', 'udp://2.2.2.2', 'tls://3.3.3.3').applyTo(dns);

      expect(dns.direct, 'udp://1.1.1.1');
      expect(dns.outbound, 'udp://1.1.1.1');
      expect(dns.resolver, 'udp://2.2.2.2');
      expect(dns.proxy, 'tls://3.3.3.3');
    });
  });

  group('saved settings are cleaned on load', () {
    test('ttl stays in range', () {
      expect(DnsSettings.fromJson({'ttl': 1}).ttl, DnsSettings.minTtl);
      expect(DnsSettings.fromJson({'ttl': 1 << 40}).ttl, DnsSettings.maxTtl);
      expect(DnsSettings.fromJson(const {}).ttl, isNull);
    });

    test('an empty test domain falls back', () {
      expect(DnsSettings.fromJson({'testDomain': ''}).testDomain, DnsSettings.defaultTestDomain);
    });

    test('static entries without addresses are dropped', () {
      final dns = DnsSettings.fromJson({
        'staticIps': {
          'a.example': ['1.2.3.4'],
          'b.example': [],
        }
      });
      expect(dns.staticIps.keys, ['a.example']);
    });

    test('custom servers the core cannot read are dropped', () {
      final dns = DnsSettings.fromJson({
        'custom': [
          {'provider': 'good', 'url': 'tls://dns.example'},
          {'provider': 'dhcp', 'url': 'dhcp://auto'},
          {'provider': 'space', 'url': 'tls://dns .example'},
          {'provider': 'none'},
        ]
      });
      expect(dns.custom.map((e) => e['provider']), ['good']);
    });

    test('mtu falls back when it makes no sense', () {
      expect(TunSettings.normalizeMtu(0), TunSettings.defaultMtu);
      expect(TunSettings.normalizeMtu(70000), TunSettings.defaultMtu);
      expect(TunSettings.normalizeMtu(null), TunSettings.defaultMtu);
      expect(TunSettings.normalizeMtu(1500), 1500);
      expect(TunSettings.fromJson({'mtu': 0}).mtu, TunSettings.defaultMtu);
    });
  });

  group('explaining why the core stopped', () {
    test('a taken port names the port, in either wording', () {
      expect(
          CoreTools.describeFailure(
              'FATAL[0000] start service: start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:17890: bind: Only one usage of each socket address'),
          contains('17890'));
      expect(CoreTools.describeFailure('listen tcp 127.0.0.1:53: bind: address already in use'), contains('被其他程序占用'));
    });

    test('TUN and permission failures say what to do', () {
      expect(CoreTools.describeFailure('configure tun interface: wintun: Failed to setup adapter'), contains('管理员'));
      expect(CoreTools.describeFailure('create tun: Access is denied.'), contains('管理员身份'));
    });

    test('a broken rule set points at where to fix it', () {
      expect(CoreTools.describeFailure('initialize rule-set[geosite-a]: decode: unexpected EOF'), contains('规则集'));
    });

    test('anything else gives the last line without the log prefix or colours', () {
      expect(CoreTools.describeFailure('line one\n\x1B[31mFATAL\x1B[0m[0000] something broke'), 'something broke');
      expect(CoreTools.describeFailure(''), '内核意外退出');
    });
  });
}
