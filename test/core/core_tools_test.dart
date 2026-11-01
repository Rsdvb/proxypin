import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/rule_group.dart';

void main() {
  group('backup', () {
    BackupContent sample() => BackupContent(
          [
            Profile(id: '1', name: '机场', url: 'https://example.com/sub', nodes: [
              {'tag': '香港', 'server_port': 1}
            ])
          ],
          CoreSettings(activeProfileId: '1', dns: DnsSettings(proxy: 'https://dns.example/q'), clashSecret: 'device-secret', groups: [
            RuleGroup(id: 'a', name: '自定义', domainSuffixes: ['a.example'], target: 'direct')
          ]),
          const ['example.com'],
        );

    test('keeps what a person set up', () {
      final restored = CoreBackup.decode(CoreBackup.encode(sample()));

      expect(restored.profiles.single.name, '机场');
      expect(restored.profiles.single.nodes.single['tag'], '香港');
      expect(restored.settings.activeProfileId, '1');
      expect(restored.settings.dns.proxy, 'https://dns.example/q');
      expect(restored.settings.groups.single.domainSuffixes, ['a.example']);
      expect(restored.decryptDomains, ['example.com']);
    });

    test('leaves out what belongs to the device', () {
      final restored = CoreBackup.decode(CoreBackup.encode(sample()));
      expect(restored.settings.clashSecret, isNot('device-secret'));
    });

    test('rejects other files', () {
      expect(() => CoreBackup.decode(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });

  group('webdav', () {
    late HttpServer server;
    final stored = <String, List<int>>{};
    String? authorization;

    setUp(() async {
      stored.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        authorization = request.headers.value('authorization');
        final path = request.uri.path;
        if (request.method == 'PUT') {
          stored[path] = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
          request.response.statusCode = 201;
        } else if (stored.containsKey(path)) {
          request.response.add(stored[path]!);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    WebDavBackup client(String path) =>
        WebDavBackup(url: 'http://127.0.0.1:${server.port}$path', username: 'me', password: 'pw');

    test('round trips with basic auth, with or without a trailing slash', () async {
      await client('/dav').upload(Uint8List.fromList([1, 2, 3]));

      expect(authorization, 'Basic ${base64.encode(utf8.encode('me:pw'))}');
      expect(await client('/dav/').download(), [1, 2, 3]);
    });

    test('a missing backup is an error', () {
      expect(client('/empty').download(), throwsA(isA<HttpException>()));
    });
  });

  group('regions', () {
    test('reads names in several styles', () {
      expect(NodeRegions.of('香港 01 IEPL'), '香港');
      expect(NodeRegions.of('🇯🇵 Tokyo-02'), '日本');
      expect(NodeRegions.of('US-LAX 流媒体'), '美国');
      // Windows draws a flag as two small letters, so this reads as "sgSG06" on screen
      expect(NodeRegions.of('🇸🇬SG06 / 4.0x'), '新加坡');
      expect(NodeRegions.of('SG06'), '新加坡');
    });

    test('a short code does not match inside a word', () {
      expect(NodeRegions.of('Premium Reuse'), isNull);
      expect(NodeRegions.of('Default Node'), isNull);
    });

    test('lists only what is present, in a stable order', () {
      expect(NodeRegions.present(['美国 01', '香港 01', '香港 02', '其他']), ['香港', '美国']);
    });
  });

  group('tools', () {
    test('speed comes from the bytes that arrived', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        // Acts as the proxy too: a plain-HTTP proxy request reaches it directly.
        request.response.add(Uint8List(1 << 20));
        await request.response.close();
      });

      var updates = 0;
      final speed = await CoreTools.downloadSpeed('127.0.0.1:${server.port}',
          url: 'http://speed.example/data', onProgress: (_) => updates++);

      expect(speed, greaterThan(0));
      expect(updates, greaterThan(0));
    });

    test('a failing download reports the status', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..statusCode = 503
          ..close();
      });

      expect(CoreTools.downloadSpeed('127.0.0.1:${server.port}', url: 'http://speed.example/data'),
          throwsA(isA<HttpException>()));
    });
  });
}
