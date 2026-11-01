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
  Future<Directory> directory() async => Directory.systemTemp;

  @override
  Future<String> cachePath() async => 'cache.db';

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<void> start() async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setSystemProxy(int? port) async {}

  @override
  Future<void> setKeepAlive(bool enabled) async {}

  @override
  Future<void> watchCapture({required int port, required int clashPort, required String secret, required String fallbackMode}) async {}

  @override
  Future<void> unwatchCapture() async {}
}

class _Mitm implements MitmHost {
  @override
  int get port => 9099;

  @override
  List<String>? get domains => const [];

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
    expect(find.text('自动选择'), findsNothing);
  });

  testWidgets('choosing a node takes effect on tap', (tester) async {
    await tester.runAsync(() => manager.addProfile('trojan://p@a.example:443#A\ntrojan://p@b.example:443#B'));
    await pump(tester, const NodesPage());

    await tester.tap(find.text('B'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));

    expect(manager.selectedNode, 'B');
  });

  testWidgets('rule groups are saved once, on leaving the page', (tester) async {
    manager.settings.groups = [RuleGroup(id: 'a', name: '分组 A', domainSuffixes: ['a.example'])];
    await tester.pumpWidget(MaterialApp(home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RuleGroupsPage())),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(manager.settings.groups.single.enabled, isTrue, reason: 'nothing is applied while editing');

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));

    expect(manager.settings.groups.single.enabled, isFalse);
  });
}
