import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/ui/core/node_edit_page.dart';
import 'package:proxypin/ui/core/nodes_page.dart';

const _three = 'trojan://p@a.example:443#A\ntrojan://p@b.example:443#B\nvless://11111111-1111-1111-1111-111111111111@c.example:443#C';

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
  Map<String, int> latency = const {};
  final List<String> asked = [];
  final List<String> groupTests = [];

  /// 设置后测试卡在这里，用来观察进行中的状态
  Completer<void>? gate;

  _Api() : super(port: 1, secret: 's');

  @override
  Future<String?> mode() async => 'Rule';

  @override
  Future<void> setMode(String mode) async {}

  @override
  Future<void> select(String group, String node) async {}

  @override
  Future<int?> delay(String node, {required String url, int timeoutMs = 5000}) async {
    asked.add(node);
    await gate?.future;
    return latency[node];
  }

  @override
  Future<Map<String, int>> groupDelay(String group, {required String url, int timeoutMs = 5000}) async {
    groupTests.add(group);
    return latency;
  }

  /// 自动选择现在走的节点和内核记下的延迟
  String? now;
  Map<String, int> history = const {};
  int groupReads = 0;

  @override
  Future<(Map<String, ProxyGroup>, Map<String, int>)> groupsAndDelays() async {
    groupReads++;
    return ({'auto': ProxyGroup('auto', 'URLTest', now, const [])}, history);
  }
}

void main() {
  late Directory root;
  late _Api api;
  late CoreManager manager;

  CoreManager build() => CoreManager(
        platform: _Platform(root),
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (_) async => Uint8List(0),
        fetchRuleSet: (_, __) async => throw const SocketException('offline'),
        apiFactory: (_, __) => api,
      );

  List<String> tags() => manager.nodes.map((e) => e['tag'].toString()).toList();

  Map<String, dynamic> nodeNamed(String tag) => manager.listedNodes.firstWhere((e) => e['tag'] == tag);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('rsproxy_nodes_');
    api = _Api();
    manager = build();
    CoreManager.instance = manager;
    await manager.load();
    manager.settings.groups = [];
  });

  tearDown(() {
    // A save may still be finishing on Windows; a leftover temp folder is harmless.
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // ignored
    }
  });

  group('the node automatic selection is really using', () {
    setUp(() async {
      await manager.addProfile(_three);
      await manager.connect();
    });

    test('comes from the core, with the delay the core measured', () async {
      api
        ..now = 'B'
        ..history = {'B': 95};

      await manager.refreshActiveNode();

      expect(manager.activeNode, 'B');
      expect(manager.delays['B'], 95);
    });

    test('is not asked for when a node was chosen by hand', () async {
      api.now = 'B';
      await manager.refreshActiveNode();
      final reads = api.groupReads;

      await manager.selectNode('A');
      await manager.refreshActiveNode();

      expect(api.groupReads, reads, reason: 'this request serialises every node');
      expect(manager.activeNode, isNull);
    });

    test('is forgotten on disconnect', () async {
      api.now = 'B';
      await manager.refreshActiveNode();

      await manager.disconnect();

      expect(manager.activeNode, isNull);
    });
  });

  test('the delay comes from the latest entry of the history the core keeps', () async {
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'proxies': {
            'auto': {'type': 'URLTest', 'now': 'A', 'all': ['A', 'B'], 'history': []},
            'A': {'type': 'Trojan', 'history': [{'delay': 300}, {'delay': 120}]},
            'B': {'type': 'Trojan', 'history': [{'delay': 0}]},
          },
        }))
        ..close();
    });

    final (groups, delays) = await ClashApi(port: server.port, secret: 's').groupsAndDelays();

    expect(groups['auto']?.now, 'A');
    expect(delays, {'A': 120}, reason: 'a zero means the test failed');
  });

  group('testing latency', () {
    setUp(() async {
      await manager.addProfile(_three);
      await manager.connect();
    });

    test('tells apart working, failed and never tested nodes', () async {
      api.latency = {'A': 80};
      await manager.testLatency(tags: ['A', 'B']);

      expect(manager.delays, {'A': 80});
      expect(manager.failedNodes, {'B'});
      expect(manager.delays.containsKey('C'), isFalse);
      expect(manager.failedNodes.contains('C'), isFalse);
    });

    test('shows which nodes are still being tested', () async {
      api.gate = Completer();
      final running = manager.testLatency(tags: ['A', 'B']);
      await Future.delayed(Duration.zero);

      expect(manager.testing, isTrue);
      expect(manager.testingNodes, {'A', 'B'});

      api.gate!.complete();
      await running;
      expect(manager.testing, isFalse);
      expect(manager.testingNodes, isEmpty);
    });

    test('a node already being tested is not tested twice', () async {
      api.gate = Completer();
      final first = manager.testLatency(tags: ['A']);
      await Future.delayed(Duration.zero);
      await manager.testLatency(tags: ['A']);

      api.gate!.complete();
      await first;
      expect(api.asked, ['A']);
    });

    test('a failure clears the old time, a success clears the failure', () async {
      api.latency = {'A': 80};
      await manager.testLatency(tags: ['A']);
      api.latency = const {};
      await manager.testLatency(tags: ['A']);

      expect(manager.delays.containsKey('A'), isFalse);
      expect(manager.failedNodes, {'A'});

      api.latency = {'A': 90};
      await manager.testLatency(tags: ['A']);
      expect(manager.failedNodes, isEmpty);
    });

    test('results survive a restart', () async {
      api.latency = {'A': 80};
      await manager.testLatency(tags: ['A', 'B']);

      final restarted = build();
      await restarted.load();
      expect(restarted.delays, {'A': 80});
      expect(restarted.failedNodes, {'B'});
    });

    test('switching profiles keeps the results of the other one', () async {
      api.latency = {'A': 80};
      await manager.testLatency(tags: ['A']);
      final other = await manager.addProfile('trojan://p@z.example:443#Z');
      await manager.setActiveProfile(other.id);

      expect(manager.delays, containsPair('A', 80));
    });

    test('a full test forgets nodes no profile has any more', () async {
      manager.delays['gone'] = 1;
      manager.failedNodes.add('also gone');
      api.latency = {'A': 80};
      await manager.testLatency();

      expect(manager.delays.containsKey('gone'), isFalse);
      expect(manager.failedNodes.contains('also gone'), isFalse);
    });

    test('nudges the auto group when it is the selection, so it moves to the fastest', () async {
      api.latency = {'A': 80};
      await manager.testLatency();
      expect(api.groupTests, ['auto']);
    });

    test('leaves the auto group alone when a node is chosen, or when told to', () async {
      await manager.selectNode('A');
      await manager.testLatency();
      expect(api.groupTests, isEmpty);

      await manager.selectNode('auto');
      manager.settings.autoUpdateAfterTest = false;
      await manager.testLatency();
      expect(api.groupTests, isEmpty);
    });
  });

  group('connecting for a test', () {
    test('happens only when asked for', () async {
      await manager.addProfile(_three);

      await manager.testLatency();
      expect(api.asked, isEmpty);
      expect(manager.isRunning, isFalse);

      await manager.testLatency(connectFirst: true);
      expect(manager.isRunning, isTrue);
      expect(api.asked, hasLength(3));
    });
  });

  group('disabling nodes', () {
    setUp(() => manager.addProfile(_three));

    test('takes the node out of the core but not out of the list', () async {
      await manager.setNodeDisabled(nodeNamed('B'), true);

      expect(tags(), ['A', 'C']);
      expect(manager.listedNodes, hasLength(3));
      expect(manager.isDisabled(nodeNamed('B')), isTrue);
    });

    test('goes by address, so renamed copies count too', () async {
      await manager.setNodeDisabled(nodeNamed('B'), true);
      final other = await manager.addProfile('trojan://x@b.example:443#Another name');
      await manager.setActiveProfile(other.id);

      expect(tags(), isEmpty);
    });

    test('can be undone', () async {
      await manager.setNodeDisabled(nodeNamed('B'), true);
      await manager.setNodeDisabled(nodeNamed('B'), false);
      expect(tags(), ['A', 'B', 'C']);
    });

    test('asks for a reload rather than dropping connections', () async {
      await manager.connect();
      await manager.setNodeDisabled(nodeNamed('B'), true);
      expect(manager.needsReload, isTrue);
    });

    test('disabled nodes are skipped when testing', () async {
      await manager.connect();
      await manager.setNodeDisabled(nodeNamed('B'), true);
      await manager.testLatency();
      expect(api.asked, unorderedEquals(['A', 'C']));
    });

    test('survives a restart', () async {
      await manager.setNodeDisabled(nodeNamed('B'), true);

      manager = build();
      await manager.load();
      expect(tags(), ['A', 'C']);
    });
  });

  group('recent nodes', () {
    test('newest first, without repeats, five at most', () async {
      await manager.addProfile([for (var i = 0; i < 7; i++) 'trojan://p@n$i.example:443#N$i'].join('\n'));
      for (var i = 0; i < 7; i++) {
        await manager.selectNode('N$i');
      }
      await manager.selectNode('N4');

      expect(manager.settings.recentNodes, ['N4', 'N6', 'N5', 'N3', 'N2']);
    });

    test('only real nodes count', () async {
      await manager.addProfile(_three);
      await manager.selectNode('auto');
      await manager.selectNode('direct');
      expect(manager.settings.recentNodes, isEmpty);
    });

    test('can be cleared', () async {
      await manager.addProfile(_three);
      await manager.selectNode('A');
      await manager.clearRecentNodes();
      expect(manager.settings.recentNodes, isEmpty);
    });
  });

  group('editing nodes', () {
    test('deleting a subscription node keeps it out after updates', () async {
      final profile = await manager.addProfile(_three);
      profile.url = 'https://example.com/sub';
      await manager.removeNode('B');

      expect(tags(), ['A', 'C']);
      expect(profile.removedNodes, {'B'});
      expect(profile.nodes, hasLength(3));
    });

    test('deleting a local node removes it', () async {
      final profile = await manager.addProfile(_three);
      await manager.removeNode('B');

      expect(profile.nodes.map((e) => e['tag']), ['A', 'C']);
      expect(profile.removedNodes, isEmpty);
    });

    test('changing a node keeps its place', () async {
      await manager.addProfile(_three);
      await manager.updateNode('B', {...nodeNamed('B'), 'server': 'new.example'});

      expect(tags(), ['A', 'B', 'C']);
      expect(nodeNamed('B')['server'], 'new.example');
    });

    test('renaming carries everything attached to the old name', () async {
      final profile = await manager.addProfile(_three);
      manager.settings.favorites.add('B');
      manager.settings.chain = ['B'];
      manager.delays['B'] = 80;
      await manager.selectNode('B');

      await manager.updateNode('B', {...nodeNamed('B'), 'tag': 'New'});

      expect(manager.settings.selectedNodes[profile.id], 'New');
      expect(manager.settings.favorites, {'New'});
      expect(manager.settings.recentNodes, ['New']);
      expect(manager.settings.chain, ['New']);
      expect(manager.delays, {'New': 80});
    });

    test('a name in use or reserved by the app is refused', () async {
      await manager.addProfile(_three);

      expect(() => manager.updateNode('B', {...nodeNamed('B'), 'tag': 'A'}), throwsA(isA<DuplicateProfileException>()));
      expect(() => manager.updateNode('B', {...nodeNamed('B'), 'tag': 'select'}), throwsA(isA<DuplicateProfileException>()));
    });

    test('a node edited through a merged profile changes its source', () async {
      final source = await manager.addProfile(_three);
      final merged = await manager.mergeProfiles('all', [source.id]);
      await manager.setActiveProfile(merged.id);

      await manager.updateNode('A', {...nodeNamed('A'), 'server': 'new.example'});

      expect(source.nodes.first['server'], 'new.example');
      expect(nodeNamed('A')['server'], 'new.example');
    });

    test('groups of a merged profile follow its sources', () async {
      final first = await manager.addProfile('trojan://p@a.example:443#A', name: 'one');
      final second = await manager.addProfile('trojan://p@b.example:443#A', name: 'two');
      final merged = await manager.mergeProfiles('all', [first.id, second.id]);
      await manager.setActiveProfile(merged.id);

      final groups = manager.nodeGroups;
      expect(groups.map((e) => e.profile.name), ['one', 'two']);
      expect(groups.first.tags, ['A']);
      expect(groups.last.tags, ['two A'], reason: 'names are made unique across sources');
    });
  });

  group('adding nodes by hand', () {
    test('an empty local profile can be created', () async {
      final profile = await manager.createLocalProfile('  mine ');

      expect(profile.name, 'mine');
      expect(profile.isSubscription, isFalse);
      expect(manager.settings.activeProfileId, profile.id);
      await expectLater(manager.createLocalProfile('mine'), throwsA(isA<DuplicateProfileException>()));
      await expectLater(manager.createLocalProfile('  '), throwsA(isA<DuplicateProfileException>()));
    });

    test('takes a share link', () async {
      final profile = await manager.createLocalProfile('mine');
      expect(await manager.addNodes(profile, 'trojan://p@a.example:443#A'), 1);
      expect(tags(), ['A']);
    });

    test('takes a single node as JSON', () async {
      final profile = await manager.createLocalProfile('mine');
      await manager.addNodes(profile, jsonEncode({'type': 'socks', 'tag': 'S', 'server': 'a.example', 'server_port': 1080}));
      expect(tags(), ['S']);
    });

    test('takes what a share QR code carries', () async {
      final profile = await manager.createLocalProfile('mine');
      await manager.addNodes(
          profile,
          jsonEncode({
            'outbounds': [
              {'type': 'socks', 'tag': 'S', 'server': 'a.example', 'server_port': 1080}
            ]
          }));
      expect(tags(), ['S']);
    });

    test('a name clash gets a suffix instead of breaking the core', () async {
      final profile = await manager.createLocalProfile('mine');
      await manager.addNodes(profile, 'trojan://p@a.example:443#A');
      await manager.addNodes(profile, 'trojan://p@b.example:443#A');
      expect(tags(), ['A', 'A 2']);
    });

    test('nonsense is refused', () async {
      final profile = await manager.createLocalProfile('mine');
      await expectLater(manager.addNodes(profile, 'nonsense'), throwsFormatException);
      expect(profile.nodes, isEmpty);
    });

    test('every template parses into a node', () {
      for (final type in ['shadowsocks', 'vmess', 'vless', 'trojan', 'hysteria2', 'tuic', 'anytls', 'socks', 'http']) {
        expect(nodeTypeLabel({'type': type}), isNot(type), reason: 'has a display name');
      }
      expect(nodeTypeLabel({'type': 'something-new'}), 'something-new');
    });
  });

  group('the page', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const MaterialApp(home: NodesPage()));
      await tester.pump();
    }

    testWidgets('sorts fastest first and the dead last, and hides the dead on request', (tester) async {
      await tester.runAsync(() => manager.addProfile(_three));
      manager
        ..delays.addAll({'B': 50, 'A': 200})
        ..failedNodes.add('C');
      manager.settings
        ..sortNodesByDelay = true
        ..hideRecommendedNodes = true;
      await pump(tester);

      final y = {for (final tag in ['A', 'B', 'C']) tag: tester.getTopLeft(find.text(tag)).dy};
      expect(y['B']!, lessThan(y['A']!));
      expect(y['A']!, lessThan(y['C']!));
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);

      manager.settings.hideFailedNodes = true;
      await tester.pumpWidget(const MaterialApp(home: NodesPage(key: ValueKey('again'))));
      await tester.pump();
      expect(find.text('C'), findsNothing);
    });

    testWidgets('recommends the fastest working nodes, never disabled ones', (tester) async {
      await tester.runAsync(() async {
        await manager.addProfile(_three);
        await manager.setNodeDisabled(nodeNamed('A'), true);
      });
      manager.delays.addAll({'A': 10, 'B': 50});
      await pump(tester);

      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('A'), findsOneWidget, reason: 'only in its group');
      expect(find.text('B'), findsNWidgets(2), reason: 'in its group and recommended');
    });

    testWidgets('search reaches protocols and regexes, and survives a broken regex', (tester) async {
      await tester.runAsync(() => manager.addProfile(_three));
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'vless');
      await tester.pump();
      expect(find.text('C'), findsOneWidget);
      expect(find.text('A'), findsNothing);

      await tester.enterText(find.byType(TextField), r'^[ab]$');
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('C'), findsNothing);

      await tester.enterText(find.byType(TextField), '[');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a collapsed group hides its nodes until searched', (tester) async {
      await tester.runAsync(() => manager.addProfile(_three));
      await pump(tester);

      await tester.tap(find.textContaining('[3]'));
      await tester.pump();
      expect(find.text('A'), findsNothing);

      await tester.enterText(find.byType(TextField), r'^A$');
      await tester.pump();
      expect(find.text('A'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.tap(find.textContaining('[3]'));
      await tester.pump();
    });

    testWidgets('choosing a disabled node explains instead of switching', (tester) async {
      await tester.runAsync(() async {
        await manager.addProfile(_three);
        await manager.setNodeDisabled(nodeNamed('A'), true);
      });
      await pump(tester);

      await tester.tap(find.text('A'));
      await tester.pump();

      expect(find.textContaining('已禁用，长按'), findsOneWidget);
      expect(manager.selectedNode, isNull);
    });

    testWidgets('holding a node opens its menu', (tester) async {
      await tester.runAsync(() => manager.addProfile(_three));
      await pump(tester);

      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();

      for (final item in ['禁用', '查看', '分享', '编辑', '删除']) {
        expect(find.text(item), findsOneWidget);
      }
    });
  });

  group('search keywords', () {
    testWidgets('renaming or deleting reaches the auto groups using them', (tester) async {
      manager.settings
        ..searchKeywords = ['香港', '日本']
        ..autoGroups = [AutoGroup(name: 'g', keywords: const ['香港', '日本'])];
      await tester.pumpWidget(const MaterialApp(home: SearchKeywordsPage()));

      await tester.tap(find.byTooltip('删除').first);
      await tester.pump();

      expect(manager.settings.searchKeywords, ['日本']);
      expect(manager.settings.autoGroups.single.keywords, ['日本']);
    });
  });

  group('editing page', () {
    Future<void> open(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('bad JSON keeps the page open and says so', (tester) async {
      await tester.runAsync(() => manager.addProfile(_three));
      await open(tester, NodeEditPage(tag: 'A', node: nodeNamed('A')));

      await tester.enterText(find.widgetWithText(TextField, '其他参数'), '{ nope');
      await tester.tap(find.byTooltip('保存'));
      await tester.pump();

      expect(find.textContaining('JSON 格式不对'), findsOneWidget);
    });

    testWidgets('a detour is saved on the node', (tester) async {
      await tester.runAsync(() => manager.addProfile(_three));
      await open(tester, NodeEditPage(tag: 'A', node: nodeNamed('A')));

      await tester.enterText(find.widgetWithText(TextField, '前置节点'), 'B');
      await tester.tap(find.byTooltip('保存'));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(nodeNamed('A')['detour'], 'B');
    });

    testWidgets('clearing the detour removes it', (tester) async {
      await tester.runAsync(() async {
        await manager.addProfile(_three);
        await manager.updateNode('A', {...nodeNamed('A'), 'detour': 'B'});
      });
      await open(tester, NodeEditPage(tag: 'A', node: nodeNamed('A')));

      await tester.enterText(find.widgetWithText(TextField, '前置节点'), '');
      await tester.tap(find.byTooltip('保存'));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(nodeNamed('A').containsKey('detour'), isFalse);
    });

    testWidgets('a template fills the box with something the parser accepts', (tester) async {
      final profile = await tester.runAsync(() => manager.createLocalProfile('mine'));
      await open(tester, AddNodePage(profile: profile!));

      await tester.tap(find.text('VLESS'));
      await tester.pump();
      await tester.tap(find.byTooltip('保存'));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(tags(), ['VLESS']);
      expect(nodeNamed('VLESS')['type'], 'vless');
    });
  });
}
