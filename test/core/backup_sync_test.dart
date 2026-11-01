import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/lan_sync.dart';
import 'package:proxypin/core/rule_group.dart';

const _nodes = 'trojan://p@a.example:443#A\ntrojan://p@b.example:443#B';

class _Platform implements CorePlatform {
  final Directory root;

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
  Future<void> start([Map<String, Object> options = const {}]) async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> stop() async {}

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

void main() {
  late Directory root;

  Future<CoreManager> build(Directory directory) async {
    final manager = CoreManager(
      platform: _Platform(directory),
      store: CoreStore(directory),
      mitm: _Mitm(),
      loadRuleSet: (_) async => Uint8List(0),
      fetchRuleSet: (_, __) async => throw const SocketException('offline'),
      apiFactory: (_, __) => _Api(),
    );
    await manager.load();
    manager.settings.groups = [];
    return manager;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rsproxy_backup_');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A save may still be finishing on Windows; a leftover temp folder is harmless.
    }
  });

  group('restoring a backup', () {
    late CoreManager source;
    late CoreManager target;
    late Directory other;

    setUp(() async {
      source = await build(root);
      other = Directory.systemTemp.createTempSync('rsproxy_backup_other_');
      target = await build(other);
    });

    tearDown(() {
      try {
        other.deleteSync(recursive: true);
      } on FileSystemException {
        // see above
      }
    });

    test('brings back every setting that is not tied to the device', () async {
      await source.addProfile(_nodes);
      source.settings
        ..finalTarget = RuleTarget.direct
        ..chain = ['A']
        ..chainFront = false
        ..autoGroups = [AutoGroup(name: 'g', keywords: const ['A'])]
        ..autoTestMinutes = 60
        ..autoPreferFavorites = true
        ..disabledNodes = {'trojan;b.example;443'}
        ..recentNodes = ['A']
        ..searchKeywords = ['香港']
        ..bypassDomains = ['x.example']
        ..homeStats = [HomeStat.memory]
        ..tuning = NodeTuning(tlsRecordFragment: true)
        ..ruleSetUpdateHours = 6;

      await target.restoreBackup(source.exportBackup());
      final restored = target.settings;

      expect(restored.finalTarget, RuleTarget.direct);
      expect(restored.chain, ['A']);
      expect(restored.chainFront, isFalse);
      expect(restored.autoGroups.single.name, 'g');
      expect(restored.autoTestMinutes, 60);
      expect(restored.autoPreferFavorites, isTrue);
      expect(restored.disabledNodes, {'trojan;b.example;443'});
      expect(restored.recentNodes, ['A']);
      expect(restored.searchKeywords, ['香港']);
      expect(restored.bypassDomains, ['x.example']);
      expect(restored.homeStats, [HomeStat.memory]);
      expect(restored.tuning.tlsRecordFragment, isTrue);
      expect(restored.ruleSetUpdateHours, 6);
    });

    test('no field is forgotten: anything saved in settings comes back', () async {
      // 新加设置时不用记得改恢复逻辑，这里保证它自动跟上
      final json = source.settings.toJson()..removeWhere((key, _) => CoreBackup.deviceFields.contains(key));
      await target.restoreBackup(source.exportBackup());
      final restored = jsonDecode(jsonEncode(target.settings)) as Map<String, dynamic>;

      for (final key in json.keys) {
        expect(restored.containsKey(key), isTrue, reason: key);
      }
    });

    test('this device keeps its own ports and secrets', () async {
      target.settings
        ..mixedPort = 12345
        ..lanPassword = 'mine';
      final secret = target.settings.clashSecret;

      await target.restoreBackup(source.exportBackup());

      expect(target.settings.mixedPort, 12345);
      expect(target.settings.lanPassword, 'mine');
      expect(target.settings.clashSecret, secret);
    });

    /// 直接拼一个备份包：导出时已经过滤过，走导出测不到恢复这一侧
    Uint8List craft(Map<String, dynamic> settings) {
      final archive = Archive()
        ..add(ArchiveFile.bytes('profiles.json', utf8.encode('[]')))
        ..add(ArchiveFile.bytes('settings.json', utf8.encode(jsonEncode(settings))))
        ..add(ArchiveFile.bytes('decrypt_domains.json', utf8.encode('[]')));
      return ZipEncoder().encodeBytes(archive);
    }

    test('device fields in a hand-made backup are ignored', () async {
      final port = target.settings.clashPort;
      final secret = target.settings.clashSecret;

      await target.restoreBackup(craft({'clashPort': 1, 'clashSecret': 'stolen', 'lanEnabled': true}));

      expect(target.settings.clashPort, port);
      expect(target.settings.clashSecret, secret);
      expect(target.settings.lanEnabled, isFalse);
    });

    test('an older backup does not reset what it never had', () async {
      target.settings.autoTestMinutes = 77;

      await target.restoreBackup(craft({'testUrl': 'https://t.example/204'}));

      expect(target.settings.autoTestMinutes, 77);
      expect(target.settings.testUrl, 'https://t.example/204');
    });

    test('only the chosen parts are replaced', () async {
      await source.addProfile(_nodes);
      source.settings
        ..groups = [RuleGroup(id: 'a', name: 'a', domains: ['a.example'])]
        ..autoTestMinutes = 60;
      await target.addProfile('trojan://p@z.example:443#Z');

      await target.restoreBackup(source.exportBackup(), parts: const RestoreParts(profiles: false, others: false));

      expect(target.profiles.single.nodes.single['tag'], 'Z', reason: 'profiles were not ticked');
      expect(target.settings.groups.single.name, 'a');
      expect(target.settings.autoTestMinutes, isNot(60));
    });

    test('profiles alone leaves the rules', () async {
      await source.addProfile(_nodes);
      target.settings.groups = [RuleGroup(id: 'keep', name: 'keep', domains: ['k.example'])];

      await target.restoreBackup(source.exportBackup(), parts: const RestoreParts(rules: false, others: false));

      expect(target.profiles.single.nodes, hasLength(2));
      expect(target.settings.groups.single.id, 'keep');
    });
  });

  group('automatic backups', () {
    late CoreManager manager;

    setUp(() async => manager = await build(root));

    test('adding a profile saves one, named by the day', () async {
      await manager.addProfile(_nodes);
      final backups = await manager.autoBackups();

      expect(backups, hasLength(1));
      expect(backups.single.name, '${DateTime.now().toIso8601String().substring(0, 10)}.zip');
    });

    test('can be turned off', () async {
      manager.settings.autoBackupOnAdd = false;
      await manager.addProfile(_nodes);
      expect(await manager.autoBackups(), isEmpty);
    });

    test('removing a profile saves one only when asked, and never an empty one', () async {
      manager.settings.autoBackupOnAdd = false;
      final first = await manager.addProfile('trojan://p@a.example:443#A');
      final second = await manager.addProfile('trojan://p@b.example:443#B');

      await manager.removeProfile(first.id);
      expect(await manager.autoBackups(), isEmpty);

      manager.settings.autoBackupOnRemove = true;
      await manager.removeProfile(second.id);
      expect(await manager.autoBackups(), isEmpty, reason: 'nothing left to protect');
    });

    test('only the newest five are kept', () async {
      final directory = Directory('${root.path}/backups')..createSync();
      for (var day = 1; day <= 8; day++) {
        File('${directory.path}/2026-01-0$day.zip').writeAsBytesSync([1]);
      }
      await manager.addProfile(_nodes);

      final names = (await manager.autoBackups()).map((e) => e.name).toList();
      expect(names, hasLength(5));
      expect(names.last, '2026-01-05.zip');
    });

    test('can be read back and deleted', () async {
      await manager.addProfile(_nodes);
      final name = (await manager.autoBackups()).single.name;

      expect(CoreBackup.decode(await manager.readAutoBackup(name)).profiles, hasLength(1));
      await manager.deleteAutoBackup(name);
      expect(await manager.autoBackups(), isEmpty);
    });
  });

  group('webdav listing', () {
    test('reads the names whatever the namespace prefix', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href></d:response>
  <d:response><d:href>/dav/rsproxy-20261101120000.zip</d:href></d:response>
  <d:response><D:href>/dav/rsproxy-20261102120000.zip</D:href></d:response>
  <d:response><href>/dav/rsproxy-backup.zip</href></d:response>
  <d:response><d:href>/dav/other.zip</d:href></d:response>
</d:multistatus>''';

      expect(WebDavBackup.parseListing(xml), ['rsproxy-backup.zip', 'rsproxy-20261102120000.zip', 'rsproxy-20261101120000.zip']);
    });

    test('new uploads get names that sort by time', () {
      expect(WebDavBackup.newName(DateTime(2026, 11, 1, 9, 5, 7)), 'rsproxy-20261101090507.zip');
    });

    group('against a server', () {
      late HttpServer server;
      final stored = <String, List<int>>{};

      setUp(() async {
        stored.clear();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final path = request.uri.path;
          switch (request.method) {
            case 'PUT':
              stored[path] = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
              request.response.statusCode = 201;
            case 'PROPFIND':
              request.response.statusCode = 207;
              request.response.write('<d:multistatus>${stored.keys.map((e) => '<d:href>$e</d:href>').join()}</d:multistatus>');
            case 'DELETE':
              stored.remove(path);
              request.response.statusCode = 204;
            default:
              if (stored.containsKey(path)) {
                request.response.add(stored[path]!);
              } else {
                request.response.statusCode = 404;
              }
          }
          await request.response.close();
        });
      });

      tearDown(() => server.close(force: true));

      test('keeps history, and lists, restores and deletes by name', () async {
        final webDav = WebDavBackup(url: 'http://127.0.0.1:${server.port}/dav', username: 'me', password: 'pw');
        await webDav.upload(Uint8List.fromList([1]), name: 'rsproxy-1.zip');
        await webDav.upload(Uint8List.fromList([2]), name: 'rsproxy-2.zip');

        expect(await webDav.list(), ['rsproxy-2.zip', 'rsproxy-1.zip']);
        expect(await webDav.download('rsproxy-1.zip'), [1]);

        await webDav.delete('rsproxy-1.zip');
        expect(await webDav.list(), ['rsproxy-2.zip']);
      });

      test('a failed listing is an error, not an empty cloud', () async {
        final refused = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => refused.close(force: true));
        refused.listen((request) async {
          request.response.statusCode = 401;
          await request.response.close();
        });

        final webDav = WebDavBackup(url: 'http://127.0.0.1:${refused.port}/dav', username: 'me', password: 'wrong');
        await expectLater(webDav.list(), throwsA(isA<HttpException>()));
      });
    });
  });

  group('lan sync', () {
    final backup = Uint8List.fromList([1, 2, 3]);

    test('the link survives its trip through a QR code', () {
      const link = LanSyncLink(['192.168.1.2', '10.0.0.2'], 5000, 'tok-en_', LanSyncLink.download);
      final parsed = LanSyncLink.parse(link.toString())!;

      expect(parsed.addresses, ['192.168.1.2', '10.0.0.2']);
      expect(parsed.port, 5000);
      expect(parsed.token, 'tok-en_');
      expect(parsed.action, LanSyncLink.download);
    });

    test('anything else is not a sync link', () {
      expect(LanSyncLink.parse('https://example.com'), isNull);
      expect(LanSyncLink.parse('rsproxy://install-config?url=https://a.example'), isNull);
      expect(LanSyncLink.parse('rsproxy://sync?ips=1.2.3.4&port=1'), isNull, reason: 'no token');
      expect(LanSyncLink.parse('rsproxy://sync?ips=1.2.3.4&port=1&token=t&action=erase'), isNull);
    });

    test('the other device downloads what this one offers', () async {
      final server = await LanSyncServer.start(outgoing: backup);
      addTearDown(server.close);
      final link = server.link(['127.0.0.1']);

      expect(link.action, LanSyncLink.download);
      final address = await LanSyncClient.reachable(link);
      expect(address, '127.0.0.1');
      expect(await LanSyncClient.download(link, address!), backup);
    });

    test('the other device uploads to one that waits', () async {
      Uint8List? received;
      final server = await LanSyncServer.start(onReceived: (bytes) => received = bytes);
      addTearDown(server.close);
      final link = server.link(['127.0.0.1']);

      expect(link.action, LanSyncLink.upload);
      await LanSyncClient.upload(link, '127.0.0.1', backup);
      expect(received, backup);
    });

    test('a backup holds subscription links, so the token is required', () async {
      final server = await LanSyncServer.start(outgoing: backup);
      addTearDown(server.close);
      final guess = LanSyncLink(const ['127.0.0.1'], server.port, 'guess', LanSyncLink.download);

      await expectLater(LanSyncClient.download(guess, '127.0.0.1'), throwsA(isA<HttpException>()));
    });

    test('each session has its own token', () async {
      final first = await LanSyncServer.start(outgoing: backup);
      final second = await LanSyncServer.start(outgoing: backup);
      addTearDown(first.close);
      addTearDown(second.close);

      expect(first.link(const []).token, isNot(second.link(const []).token));
    });

    test('an address that does not answer is skipped', () async {
      final server = await LanSyncServer.start(outgoing: backup);
      addTearDown(server.close);
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();

      expect(await LanSyncClient.reachable(LanSyncLink(const ['127.0.0.1'], port, 't', LanSyncLink.download)), isNull);
    });
  });
}
