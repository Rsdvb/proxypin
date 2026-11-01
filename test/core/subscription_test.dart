import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/subscription.dart';

void main() {
  group('usage header', () {
    test('reads usage and expiry', () {
      final info = SubscriptionInfo.parse('upload=5368709120; download=190000000000; total=549755813888; expire=1799500000')!;
      expect(info.used, 5368709120 + 190000000000);
      expect(info.total, 549755813888);
      expect(info.expire, DateTime.fromMillisecondsSinceEpoch(1799500000 * 1000));
    });

    test('a plan with no end date has no expiry', () {
      expect(SubscriptionInfo.parse('upload=0; download=0; total=1; expire=0')!.expire, isNull);
      expect(SubscriptionInfo.parse('upload=0; download=0; total=1')!.expire, isNull);
    });

    test('tolerates decimals and odd spacing', () {
      expect(SubscriptionInfo.parse(' upload = 1.5 ;download=2;total=3;')!.upload, 1);
    });

    test('anything else is no usage at all', () {
      expect(SubscriptionInfo.parse(null), isNull);
      expect(SubscriptionInfo.parse('nonsense'), isNull);
    });
  });

  group('file names', () {
    test('RFC 5987 form', () {
      expect(Subscription.fileName("attachment; filename*=UTF-8''%E6%88%91%E7%9A%84%E6%9C%BA%E5%9C%BA.yaml"), '我的机场');
    });

    test('plain form', () {
      expect(Subscription.fileName('attachment; filename="airport.yaml"'), 'airport');
      expect(Subscription.fileName('attachment; filename=airport'), 'airport');
    });

    test('nothing usable', () {
      expect(Subscription.fileName(null), isNull);
      expect(Subscription.fileName('inline'), isNull);
    });
  });

  group('profile', () {
    Profile profile({String? include, String? exclude}) => Profile(
          id: '1',
          name: 'p',
          include: include,
          exclude: exclude,
          nodes: [
            {'tag': '香港 01'},
            {'tag': 'Japan 02'},
            {'tag': '剩余流量：100G'},
          ],
        );

    test('filters by name, ignoring case', () {
      expect(profile(exclude: '剩余|到期').activeNodes.map((e) => e['tag']), ['香港 01', 'Japan 02']);
      expect(profile(include: 'japan').activeNodes.map((e) => e['tag']), ['Japan 02']);
    });

    test('a broken filter keeps every node rather than dropping them', () {
      expect(profile(exclude: '(').activeNodes, hasLength(3));
    });

    test('is due once the interval has passed', () {
      final now = DateTime(2026, 11, 1, 12);
      final item = Profile(id: '1', name: 'p', url: 'https://example.com', updatedAt: now);
      expect(item.isDue(now.add(const Duration(hours: 11))), isFalse);
      expect(item.isDue(now.add(const Duration(hours: 12))), isTrue);
    });

    test('pasted configs and an interval of zero never update themselves', () {
      final now = DateTime(2026, 11, 1);
      expect(Profile(id: '1', name: 'p').isDue(now), isFalse);
      expect(Profile(id: '1', name: 'p', url: 'https://example.com', updateHours: 0).isDue(now), isFalse);
      expect(Profile(id: '1', name: 'p', url: 'https://example.com').isDue(now), isTrue, reason: 'never fetched');
    });

    test('survives a round trip through json', () {
      final item = Profile(
          id: '1',
          name: 'p',
          url: 'https://example.com',
          info: SubscriptionInfo(upload: 1, download: 2, total: 3, expire: DateTime.fromMillisecondsSinceEpoch(1000)),
          nodes: [
            {'tag': 'a', 'server_port': 1}
          ]);
      expect(jsonEncode(Profile.fromJson(jsonDecode(jsonEncode(item)))), jsonEncode(item));
    });
  });

  group('over the network', () {
    late HttpServer server;
    String? seenAgent;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        seenAgent = request.headers.value(HttpHeaders.userAgentHeader);
        final response = request.response;
        if (request.uri.path == '/missing') {
          response.statusCode = 404;
        } else {
          response.headers
            ..set('subscription-userinfo', 'upload=1; download=2; total=3')
            ..set('profile-title', 'base64:${base64.encode(utf8.encode('标题'))}')
            ..set('profile-update-interval', '6')
            ..set('profile-web-page-url', 'https://panel.example');
          response.write(base64.encode(utf8.encode('trojan://p@a.example:443#A')));
        }
        response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('reads the body and headers', () async {
      final result = await Subscription.fetch('http://127.0.0.1:${server.port}/sub');
      expect(seenAgent, Profile.defaultUserAgent);
      expect(result.parsed.outbounds.single['tag'], 'A');
      expect(result.info!.total, 3);
      expect(result.title, '标题');
      expect(result.updateHours, 6);
      expect(result.website, 'https://panel.example');
    });

    test('falls back to a direct request when the proxy is down', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      final result = await Subscription.fetch('http://127.0.0.1:${server.port}/sub', proxy: '127.0.0.1:$port');
      expect(result.parsed.outbounds, hasLength(1));
    });

    test('an error status is an error', () {
      expect(Subscription.fetch('http://127.0.0.1:${server.port}/missing'), throwsA(isA<HttpException>()));
    });
  });

  group('clash api', () {
    late HttpServer server;
    final requests = <String>[];

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add('${request.method} ${request.uri} ${request.headers.value('authorization')} $body');
        final response = request.response;
        switch (request.uri.path) {
          case '/proxies':
            response.write(jsonEncode({
              'proxies': {
                'select': {'type': 'Selector', 'now': 'HK', 'all': ['auto', 'HK']},
                'HK': {'type': 'Trojan'},
              }
            }));
          case '/connections':
            response.write(jsonEncode({
              'uploadTotal': 10,
              'downloadTotal': 20,
              'connections': [
                {
                  'id': 'c1',
                  'metadata': {'host': 'a.example', 'destinationIP': '1.1.1.1', 'destinationPort': '443', 'network': 'tcp'},
                  'rule': 'final',
                  'chains': ['HK', 'select'],
                  'upload': 1,
                  'download': 2,
                  'start': '2026-11-01T00:00:00Z',
                },
                {
                  'id': 'c2',
                  'metadata': {'host': '', 'destinationIP': '1.1.1.1', 'destinationPort': '53', 'network': 'udp'},
                },
              ]
            }));
          case '/traffic':
            response.write('{"up":1,"down":2}\n\n{"up":3,"down":4}\n');
          default:
            if (request.uri.path.endsWith('/delay')) {
              if (request.uri.path.contains('dead')) {
                response.statusCode = 503;
              } else {
                response.write(jsonEncode(request.uri.path.startsWith('/group') ? {'HK': 80, 'JP': 0} : {'delay': 101}));
              }
            } else {
              response.statusCode = 204;
            }
        }
        response.close();
      });
    });

    tearDown(() => server.close(force: true));

    ClashApi api() {
      final client = ClashApi(port: server.port, secret: 's3');
      addTearDown(client.close);
      return client;
    }

    test('sends the secret and the mode', () async {
      await api().setMode('CaptureRule');
      expect(requests.single, 'PATCH /configs Bearer s3 {"mode":"CaptureRule"}');
    });

    test('lists only groups', () async {
      final groups = await api().groups();
      expect(groups.keys, ['select']);
      expect(groups['select']!.now, 'HK');
      expect(groups['select']!.members, ['auto', 'HK']);
    });

    test('escapes node names', () async {
      await api().select('select', '香港 01');
      expect(requests.single, startsWith('PUT /proxies/select '));
      expect(requests.single, endsWith('{"name":"香港 01"}'));

      await api().delay('香港 01', url: 'https://t.example/204');
      expect(requests.last, contains('/proxies/%E9%A6%99%E6%B8%AF%2001/delay'));
      expect(requests.last, contains('url=https%3A%2F%2Ft.example%2F204'));
    });

    test('a dead node has no latency', () async {
      expect(await api().delay('HK', url: 'https://t.example'), 101);
      expect(await api().delay('dead', url: 'https://t.example'), isNull);
    });

    test('a group test leaves out nodes that failed', () async {
      expect(await api().groupDelay('select', url: 'https://t.example'), {'HK': 80});
    });

    test('reads connections and falls back to the address', () async {
      final snapshot = await api().connections();
      expect(snapshot.downloadTotal, 20);
      expect(snapshot.connections.first.host, 'a.example:443');
      expect(snapshot.connections.first.chains, ['HK', 'select']);
      expect(snapshot.connections.last.host, '1.1.1.1:53');
    });

    test('streams traffic line by line', () async {
      final samples = await api().traffic().toList();
      expect(samples.map((e) => e.down), [2, 4]);
    });
  });
}
