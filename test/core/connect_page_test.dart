import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/ui/core/nodes_page.dart';
import 'package:proxypin/ui/core/profiles_page.dart';
import 'package:proxypin/ui/core/rule_groups_page.dart';

class _Platform implements CorePlatform {
  @override
  Stream<CoreState> get states => const Stream.empty();

  @override
  Stream<String> get links => const Stream.empty();

  @override
  Future<String?> takePendingLink() async => null;

  @override
  Future<Directory> directory() async => Directory.systemTemp;

  @override
  Future<String> cachePath() async => 'cache.db';

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
  List<String> editableDomains = [];

  @override
  Future<void> attach(int upstreamPort) async {}

  @override
  Future<void> detach() async {}
}

void main() {
  late Directory root;
  late CoreManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('rsproxy_ui_');
    manager = CoreManager(
      platform: _Platform(),
      store: CoreStore(root),
      mitm: _Mitm(),
      loadRuleSet: (_) async => Uint8List(0),
    );
    CoreManager.instance = manager;
  });

  tearDown(() {
    // A save may still be finishing on Windows; a leftover temp folder is harmless.
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // ignored
    }
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pump();
  }

  testWidgets('adding asks for nothing but the content', (tester) async {
    await pump(tester, const AddProfilePage());

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('添加'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'not a profile');
    await tester.tap(find.text('添加'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.textContaining('看不懂'), findsOneWidget);
    expect(manager.profiles, isEmpty);
  });

  testWidgets('nodes page offers automatic choice, direct and every node', (tester) async {
    await tester.runAsync(() => manager.addProfile('trojan://p@a.example:443#香港 01\ntrojan://p@b.example:443#日本 02'));
    await pump(tester, const NodesPage());

    expect(find.text('自动选择'), findsOneWidget);
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('香港 01'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '日本');
    await tester.pump();

    expect(find.text('日本 02'), findsOneWidget);
    expect(find.text('香港 01'), findsNothing);
    expect(find.text('自动选择'), findsOneWidget, reason: 'fixed choices stay while searching');
  });

  testWidgets('choosing a node takes effect on tap', (tester) async {
    await tester.runAsync(() => manager.addProfile('trojan://p@a.example:443#A\ntrojan://p@b.example:443#B'));
    await pump(tester, const NodesPage());

    await tester.tap(find.text('B'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));

    expect(manager.selectedNode, 'B');
  });

  testWidgets('rule groups are saved once, on leaving the page', (tester) async {
    tester.view.physicalSize = const Size(2400, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    manager.settings.groups = [RuleGroup(id: 'a', name: '分组 A', domainSuffixes: ['a.example'])];
    await tester.pumpWidget(MaterialApp(home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RuleGroupsPage())),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分组 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(find.text('已关闭'), findsOneWidget);
    expect(manager.settings.groups.single.enabled, isTrue, reason: 'nothing is applied while editing');

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));

    expect(manager.settings.groups.single.enabled, isFalse);
  });

  testWidgets('the rules tab saves when you switch away, because it is never closed', (tester) async {
    tester.view.physicalSize = const Size(2400, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    manager.settings.groups = [RuleGroup(id: 'a', name: '分组 A', domainSuffixes: ['a.example'])];
    final tab = ValueNotifier(2);
    addTearDown(tab.dispose);
    await tester.pumpWidget(MaterialApp(home: RuleGroupsPage(visibleTab: tab)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分组 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(find.text('立即生效'), findsOneWidget);
    expect(manager.settings.groups.single.enabled, isTrue);

    tab.value = 0;
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));

    expect(manager.settings.groups.single.enabled, isFalse);
    expect(find.text('立即生效'), findsNothing);
  });

  testWidgets('managing groups changes the list the rules page is holding', (tester) async {
    tester.view.physicalSize = const Size(2400, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    final groups = [RuleGroup(id: 'a', name: '分组 A', domainSuffixes: ['a.example'])];
    var changes = 0;
    await tester.pumpWidget(MaterialApp(home: ManageRuleGroupsPage(groups: groups, onChanged: () => changes++)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<VoidCallback>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    expect(groups.length, greaterThan(1));
    expect(changes, 1);
  });

  test('a group says what is in it', () {
    expect(ruleGroupSummary(RuleGroup(id: 'a', name: 'a', ruleSets: ['x', 'y'], domains: ['a.example'], ports: [443])),
        '规则集 2 · 域名 1 · 端口 1');
    expect(ruleGroupSummary(RuleGroup(id: 'a', name: 'a')), '还没有匹配内容');
  });
}
