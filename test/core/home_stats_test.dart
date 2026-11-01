import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/ui/core/home_stats.dart';

class _Platform implements CorePlatform {
  final Directory root;
  bool running = false;
  final StreamController<CoreState> stateChanges = StreamController.broadcast();

  _Platform(this.root);

  @override
  Stream<CoreState> get states => stateChanges.stream;

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
  int snapshots = 0;
  int trafficSubscriptions = 0;
  bool closedAll = false;

  _Api() : super(port: 1, secret: 's');

  @override
  Future<String?> mode() async => 'Rule';

  @override
  Future<void> setMode(String mode) async {}

  @override
  Future<ConnectionSnapshot> connections() async {
    snapshots++;
    return const ConnectionSnapshot(2048, 4096, [], memory: 8192);
  }

  @override
  Stream<TrafficSample> traffic() async* {
    trafficSubscriptions++;
    yield const TrafficSample(1024, 2048);
  }

  @override
  Future<void> closeAllConnections() async => closedAll = true;
}

void main() {
  late Directory root;
  late _Platform platform;
  late _Api api;
  late CoreManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('rsproxy_home_');
    platform = _Platform(root);
    api = _Api();
    manager = CoreManager(
      platform: platform,
      store: CoreStore(root),
      mitm: _Mitm(),
      loadRuleSet: (_) async => Uint8List(0),
      apiFactory: (_, __) => api,
    );
    CoreManager.instance = manager;
    await manager.load();
    manager.settings.groups = [];
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A save may still be finishing on Windows; a leftover temp folder is harmless.
    }
  });

  group('how long the connection has been up', () {
    test('is set on connecting and cleared on disconnecting', () async {
      expect(manager.settings.connectedAt, isNull);

      await manager.connect();
      expect(manager.settings.connectedAt, isNotNull);

      await manager.disconnect();
      expect(manager.settings.connectedAt, isNull);
    });

    test('survives the app restarting, because the iOS tunnel outlives it', () async {
      await manager.connect();
      final started = manager.settings.connectedAt;

      final restarted = CoreManager(
        platform: platform,
        store: CoreStore(root),
        mitm: _Mitm(),
        loadRuleSet: (_) async => Uint8List(0),
        apiFactory: (_, __) => api,
      );
      await restarted.load();

      expect(restarted.settings.connectedAt, started);
    });

    test('a crash clears it', () async {
      await manager.connect();
      platform.stateChanges.add(CoreState.stopped);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(manager.settings.connectedAt, isNull);
    });

    test('stays out of backups, it means nothing on another device', () async {
      await manager.connect();
      final restored = CoreBackup.decode(manager.exportBackup());
      expect(restored.settings.connectedAt, isNull);
    });
  });

  group('settings', () {
    test('only speed by default, the home page stays clean', () {
      expect(CoreSettings().homeStats, [HomeStat.speed]);
    });

    test('the choice and its order survive saving', () {
      final settings = CoreSettings(homeStats: [HomeStat.memory, HomeStat.runtime]);
      final restored = CoreSettings.fromJson(jsonDecode(jsonEncode(settings)));
      expect(restored.homeStats, [HomeStat.memory, HomeStat.runtime]);
    });
  });

  group('the home stats', () {
    Future<void> pump(WidgetTester tester, List<String> stats) async {
      manager.settings.homeStats = stats;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HomeStats(manager, Configuration.fromJson(const {}), key: const ValueKey('stats'))),
      ));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('show what the core reports', (tester) async {
      await pump(tester, [HomeStat.traffic, HomeStat.memory, HomeStat.connections]);

      expect(find.textContaining('2.0 KB'), findsOneWidget);
      expect(find.textContaining('4.0 KB'), findsOneWidget);
      expect(find.text('8.0 KB'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('speed alone polls nothing', (tester) async {
      await pump(tester, [HomeStat.speed]);
      await tester.pump(const Duration(seconds: 5));

      expect(api.trafficSubscriptions, 1);
      expect(api.snapshots, 0);
    });

    testWidgets('nothing chosen takes no room and no polling', (tester) async {
      await pump(tester, const []);

      expect(find.byType(Wrap), findsNothing);
      expect(api.snapshots, 0);
      expect(api.trafficSubscriptions, 0);
    });

    testWidgets('going to the background stops the polling', (tester) async {
      await pump(tester, [HomeStat.memory]);
      final before = api.snapshots;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      expect(api.snapshots, before);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.snapshots, greaterThan(before));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('holding the connection count closes everything', (tester) async {
      await pump(tester, [HomeStat.connections]);

      await tester.longPress(find.text('连接'));
      expect(api.closedAll, isTrue);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('choosing stats', () {
    testWidgets('ticking adds, unticking removes', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeStatsPage()));

      await tester.tap(find.text('内存'));
      await tester.pump();
      expect(manager.settings.homeStats, [HomeStat.speed, HomeStat.memory]);

      await tester.tap(find.text('速度'));
      await tester.pump();
      expect(manager.settings.homeStats, [HomeStat.memory]);
    });
  });
}
