import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:proxypin/core/clash_routing.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/qr_decoder.dart';
import 'package:proxypin/core/windows_loopback.dart';
import 'package:proxypin/ui/core/app_shell.dart';
import 'package:proxypin/ui/desktop/widgets/windows_toolbar.dart';
import 'package:zxing2/qrcode.dart';

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

void main() {
  group('provider groups', () {
    const routing = ProviderRouting(
      [
        ProviderGroup('Streaming', 'urltest', ['A', 'B']),
        ProviderGroup('Ads', 'selector', ['direct']),
      ],
      [
        ProviderRule('Streaming', {
          'domain': ['a.example']
        }),
        ProviderRule('Ads', {
          'domain': ['ads.example']
        }),
      ],
      null,
    );

    Map<String, dynamic> group(ProviderRouting value, String name) =>
        value.outbounds(const ['A', 'B'], testUrl: 'https://t').firstWhere((e) => e['tag'] == 'group:$name');

    test('untouched groups stay as the subscription made them', () {
      expect(group(routing, 'Streaming')['type'], 'urltest');
    });

    test('choosing a member pins it, even in a group that picks by speed', () {
      final pinned = group(routing.withTargets({'Streaming': 'B'}), 'Streaming');

      expect(pinned['type'], 'selector');
      expect(pinned['default'], 'B');
      expect(pinned.containsKey('url'), isFalse, reason: 'selector rejects urltest options');
    });

    test('direct works on a group that never listed it', () {
      final pinned = group(routing.withTargets({'Streaming': 'direct'}), 'Streaming');

      expect(pinned['outbounds'], contains('direct'));
      expect(pinned['default'], 'direct');
    });

    test('blocking turns the rules of the group into a reject', () {
      final rules = routing.withTargets({'Ads': 'reject'}).routeRules(const ['A'], const {}, fallback: 'select');

      expect(rules.last['action'], 'reject');
      expect(rules.first['action'], 'route');
    });

    test('a node the subscription dropped is ignored instead of breaking the config', () {
      expect(group(routing.withTargets({'Streaming': 'gone'}), 'Streaming')['type'], 'urltest');
    });
  });

  group('several profiles at once', () {
    late Directory root;
    late CoreManager manager;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('rsproxy_extras_');
      manager = CoreManager(
        platform: _Platform(root),
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (_) async => Uint8List(0),
        fetchRuleSet: (_, __) async => throw const SocketException('offline'),
      );
      await manager.load();
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // A save may still be finishing on Windows
      }
    });

    List<String> tags() => manager.nodes.map((e) => e['tag'].toString()).toList();

    test('nodes of both show up, grouped, and names stay unique', () async {
      await manager.addProfile('trojan://p@a.example:443#A', name: 'one');
      final second = await manager.addProfile('trojan://p@b.example:443#A\ntrojan://p@c.example:443#C', name: 'two');
      expect(tags(), ['A']);

      await manager.setProfileAlsoEnabled(second.id, true);

      expect(tags(), ['A', 'two A', 'C']);
      expect(manager.nodeGroups.map((e) => e.profile.name), ['one', 'two']);
    });

    test('switching it off or removing the profile takes the nodes away', () async {
      await manager.addProfile('trojan://p@a.example:443#A', name: 'one');
      final second = await manager.addProfile('trojan://p@b.example:443#B', name: 'two');
      await manager.setProfileAlsoEnabled(second.id, true);
      expect(tags(), ['A', 'B']);

      await manager.setProfileAlsoEnabled(second.id, false);
      expect(tags(), ['A']);

      await manager.setProfileAlsoEnabled(second.id, true);
      await manager.removeProfile(second.id);
      expect(tags(), ['A']);
    });

    test('provider targets belong to the active profile and survive a reload', () async {
      final profile = await manager.addProfile('trojan://p@a.example:443#A');
      manager.setProviderTarget('Ads', 'reject');
      await manager.store.saveSettings(manager.settings);

      await manager.load();

      expect(manager.settings.providerTargets[profile.id], {'Ads': 'reject'});
      manager.setProviderTarget('Ads', null);
      expect(manager.providerTarget('Ads'), isNull);
    });
  });

  test('a QR code is read back from an image', () async {
    final code = Encoder.encode('trojan://p@a.example:443#A', ErrorCorrectionLevel.m);
    final matrix = code.matrix!;
    const scale = 6, quiet = 24;
    final image = img.Image(width: matrix.width * scale + quiet * 2, height: matrix.height * scale + quiet * 2);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) == 1) {
          img.fillRect(image,
              x1: quiet + x * scale,
              y1: quiet + y * scale,
              x2: quiet + (x + 1) * scale - 1,
              y2: quiet + (y + 1) * scale - 1,
              color: img.ColorRgb8(0, 0, 0));
        }
      }
    }

    expect(await QrDecoder.decode(img.encodePng(image)), 'trojan://p@a.example:443#A');
  });

  test('an image without a code gives nothing', () async {
    final blank = img.Image(width: 64, height: 64);
    expect(await QrDecoder.decode(img.encodePng(blank)), isNull);
    expect(await QrDecoder.decode(Uint8List.fromList(const [1, 2, 3])), isNull);
  });

  group('UWP loopback', () {
    test('resource references fall back to the package name', () {
      final containers = WindowsLoopback.parseContainers(
          '[{"sid":"S-1-15-2-1","name":"@{Microsoft.Foo/res}","moniker":"microsoft.foo"},'
          '{"sid":"S-1-15-2-2","name":"Mail","moniker":"microsoft.mail"}]');

      expect(containers.map((e) => e.name), ['Mail', 'microsoft.foo']);
    });

    test('PowerShell gives a bare object when there is only one', () {
      expect(WindowsLoopback.parseContainers('{"sid":"S-1-15-2-1","name":"Mail","moniker":"m"}'), hasLength(1));
      expect(WindowsLoopback.parseContainers(''), isEmpty);
    });

    test('reads the exempted ids out of CheckNetIsolation output', () {
      const output = '\n[1] -----------------------------------------------------------------\n'
          '    Name: microsoft.mail\n    SID:  S-1-15-2-123-456\n\nOK.\n';
      expect(WindowsLoopback.parseExempted(output), {'S-1-15-2-123-456'});
    });
  });

  group('moving the window', () {
    final calls = <String>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
        calls.add(call.method);
        return call.method.startsWith('is') ? false : null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    });

    testWidgets('the empty title bar is tall enough to grab', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Align(alignment: Alignment.topCenter, child: SizedBox(height: 34, child: WindowsToolbar(showIcon: false)))),
      ));
      await tester.pump();

      expect(tester.getSize(find.byType(WindowDragArea)).height, 34);

      await tester.drag(find.byType(WindowDragArea), const Offset(40, 20));
      await tester.pump();
      expect(calls, contains('startDragging'));
    });

    testWidgets('the sidebar can be dragged in its empty part', (tester) async {
      tester.view.physicalSize = const Size(3000, 2100);
      addTearDown(tester.view.resetPhysicalSize);
      final tab = ValueNotifier(0);
      addTearDown(tab.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ShellLayout(tab: tab, onSelect: (_) {}, pages: [for (final _ in ShellTab.all) const SizedBox()]),
      ));
      await tester.pump();

      final blank = find.byType(WindowDragArea).last;
      expect(tester.getSize(blank).height, greaterThan(100));
      await tester.drag(blank, const Offset(40, 20));
      await tester.pump();
      expect(calls, contains('startDragging'));
    });
  });

  test('the rule set a provider target needs stays out of the core options', () {
    final config = CoreConfig.build(CoreOptions(
      nodes: const [
        {'type': 'trojan', 'tag': 'A', 'server': 'a.example', 'server_port': 443, 'password': 'p'}
      ],
      providerRouting: const ProviderRouting([ProviderGroup('G', 'urltest', ['A'])], [], null).withTargets({'G': 'A'}),
      upstreamPort: 1,
      mitmPort: 2,
      clashPort: 3,
      clashSecret: 's',
      ruleSetDirectory: 'rules',
      cachePath: 'cache.db',
    ));

    final group = (config['outbounds'] as List).firstWhere((e) => e['tag'] == 'group:G');
    expect(group['default'], 'A');
  });

  test('home defaults keep the important switches', () {
    final settings = CoreSettings();
    expect(settings.homeSwitches, containsAll([HomeSwitch.capture, HomeSwitch.tun]));
    final restored = CoreSettings.fromJson(jsonDecode(jsonEncode(settings)) as Map<String, dynamic>);
    expect(restored.homeShortcuts, settings.homeShortcuts);
  });
}
