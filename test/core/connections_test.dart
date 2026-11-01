import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/connection_log.dart';
import 'package:proxypin/ui/core/connect_page.dart';
import 'package:proxypin/ui/core/connections_page.dart';
import 'package:proxypin/ui/core/rule_group_edit_page.dart';

const _second = Duration(seconds: 1);

CoreConnection _connection(
  String id, {
  String domain = 'a.example',
  String destination = '1.2.3.4',
  String port = '443',
  String network = 'tcp',
  String process = '',
  List<String> chains = const ['HK', 'select'],
  String rule = 'domain=a.example => route(HK)',
  int upload = 0,
  int download = 0,
  DateTime? start,
}) =>
    CoreConnection(id, '${domain.isNotEmpty ? domain : destination}:$port', network, rule, chains, upload, download, start,
        domain: domain, destination: destination, port: port, sourceIp: '127.0.0.1', sourcePort: '5000', processPath: process);

String _outbound(CoreConnection connection) => connection.chains.first;

void main() {
  group('reading the core', () {
    test('picks up everything the row shows', () {
      final connection = CoreConnection.fromJson({
        'id': '1',
        'metadata': {
          'network': 'tcp',
          'sourceIP': '127.0.0.1',
          'sourcePort': '5000',
          'destinationIP': '1.2.3.4',
          'destinationPort': '443',
          'host': 'a.example',
          'processPath': r'C:\Program Files\App\app.exe',
        },
        'upload': 10,
        'download': 20,
        'chains': ['HK', 'select'],
        'rule': 'domain_suffix=a.example => route(HK)',
      });

      expect(connection.host, 'a.example:443');
      expect(connection.domain, 'a.example');
      expect(connection.destination, '1.2.3.4');
      expect(connection.source, '127.0.0.1:5000');
      expect(connection.processName, 'app.exe');
      expect(connection.ruleName, 'domain_suffix=a.example');
    });

    test('drops the user the core appends on Linux, and copes with no process', () {
      final linux = CoreConnection.fromJson({
        'id': '1',
        'metadata': {'processPath': '/usr/bin/curl (root)'},
      });
      final none = CoreConnection.fromJson({'id': '2', 'metadata': <String, dynamic>{}});

      expect(linux.processName, 'curl');
      expect(none.processName, '');
    });

    test('an IPv6 source keeps its brackets', () {
      final connection = CoreConnection.fromJson({
        'id': '1',
        'metadata': {'sourceIP': '::1', 'sourcePort': '5000'},
      });
      expect(connection.source, '[::1]:5000');
    });
  });

  group('the log', () {
    test('same source, target and path become one row, whatever the port', () {
      final log = ConnectionLog()..update([_connection('1', port: '443'), _connection('2', port: '8443')], _second);

      expect(log.rows, hasLength(1));
      expect(log.rows.single.activeIds, {'1', '2'});
    });

    test('a different process, target or route is a different row', () {
      final log = ConnectionLog()
        ..update([
          _connection('1'),
          _connection('2', process: 'b.exe'),
          _connection('3', domain: 'b.example'),
          _connection('4', chains: const ['JP']),
          _connection('5', network: 'udp'),
        ], _second);

      expect(log.rows, hasLength(5));
    });

    test('speed is the change between frames, per second', () {
      final log = ConnectionLog()
        ..update([_connection('1', upload: 1000, download: 5000)], _second)
        ..update([_connection('1', upload: 3000, download: 9000)], const Duration(seconds: 2));
      final row = log.rows.single;

      expect(row.uploadSpeed, 1000);
      expect(row.downloadSpeed, 2000);
      expect(row.upload, 3000);
      expect(row.download, 9000);
    });

    test('what a connection carried before it was first seen is not speed', () {
      final log = ConnectionLog()..update([_connection('1', download: 1 << 30)], _second);
      expect(log.rows.single.downloadSpeed, 0);
    });

    test('a row stays after its connections end, keeps its traffic and stops counting time', () {
      final start = DateTime(2026, 1, 1, 12);
      final ended = DateTime(2026, 1, 1, 12, 0, 30);
      final log = ConnectionLog()
        ..update([_connection('1', download: 100, start: start)], _second, now: start)
        ..update([], _second, now: ended);
      final row = log.rows.single;

      expect(row.isActive, isFalse);
      expect(row.closed, 1);
      expect(row.download, 100);
      expect(row.downloadSpeed, 0);
      expect(row.durationAt(DateTime(2026, 1, 1, 13)), const Duration(seconds: 30));
    });

    test('totals carry over when a new connection joins a finished row', () {
      final log = ConnectionLog()
        ..update([_connection('1', download: 100)], _second)
        ..update([], _second)
        ..update([_connection('2', download: 50)], _second);
      final row = log.rows.single;

      expect(row.download, 150);
      expect(row.closed, 1);
      expect(row.isActive, isTrue);
      expect(row.end, isNull);
    });

    test('a long session does not grow without limit', () {
      final log = ConnectionLog();
      for (var i = 0; i < 2100; i++) {
        log
          ..update([_connection('$i', domain: 'n$i.example')], _second)
          ..update([], _second);
      }
      expect(log.rows.length, lessThanOrEqualTo(2000));
    });
  });

  group('sorting', () {
    ConnectionRow row(String id, {int upload = 0, int download = 0, bool active = true}) {
      final log = ConnectionLog()..update([_connection(id, domain: '$id.example')], _second);
      log.update([_connection(id, domain: '$id.example', upload: upload, download: download)], _second);
      if (!active) log.update([], _second);
      return log.rows.single;
    }

    test('active rows always come first', () {
      final rows = ConnectionView.sorted([
        row('dead', download: 900, active: false),
        row('live', download: 1),
      ], ConnectionSort.download);
      expect(rows.first.sample.domain, 'live.example');
    });

    test('by each measure, largest first', () {
      final a = row('a', upload: 100, download: 1);
      final b = row('b', upload: 1, download: 100);

      expect(ConnectionView.sorted([a, b], ConnectionSort.downloadSpeed).first, b);
      expect(ConnectionView.sorted([a, b], ConnectionSort.uploadSpeed).first, a);
      expect(ConnectionView.sorted([a, b], ConnectionSort.download).first, b);
      expect(ConnectionView.sorted([a, b], ConnectionSort.upload).first, a);
    });

    test('the default order does not depend on traffic, so rows hold still', () {
      final rows = ConnectionView.sorted([row('b', download: 900), row('a')], ConnectionSort.none);
      expect(rows.first.sample.domain, 'a.example');
    });
  });

  group('filtering', () {
    final rows = (ConnectionLog()
          ..update([
            _connection('1', domain: 'a.example', network: 'tcp'),
            _connection('2', domain: 'b.example', network: 'udp', port: '53'),
          ], _second))
        .rows;

    List<String?> shown(ConnectionFilter filter) =>
        rows.where((e) => filter.matches(e, _outbound)).map((e) => e.sample.domain).toList();

    test('nothing chosen shows everything', () {
      expect(shown(ConnectionFilter()), hasLength(2));
    });

    test('several values in one category widen, categories narrow', () {
      final filter = ConnectionFilter()..hosts.addAll(['a.example', 'b.example']);
      expect(shown(filter), hasLength(2));

      filter.networks.add('udp');
      expect(shown(filter), ['b.example']);
    });

    test('a connection without a domain is filtered by its IP', () {
      final log = ConnectionLog()..update([_connection('1', domain: '')], _second);
      final filter = ConnectionFilter()..hosts.add('1.2.3.4');
      expect(filter.matches(log.rows.single, _outbound), isTrue);
    });

    test('clearing resets every category', () {
      final filter = ConnectionFilter()
        ..ports.add('53')
        ..rules.add('x');
      expect(filter.isEmpty, isFalse);
      filter.clear();
      expect(filter.isEmpty, isTrue);
    });
  });

  group('text', () {
    test('long hosts keep both ends', () {
      final host = '${'a' * 30}.example.com:443';
      final short = ConnectionView.shortHost(host);

      expect(short.length, 43);
      expect(short, startsWith('a' * 20));
      expect(short, endsWith('.example.com:443'));
      expect(ConnectionView.shortHost('a.example:443'), 'a.example:443');
    });

    test('durations read like a clock', () {
      expect(ConnectionView.formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(ConnectionView.formatDuration(const Duration(seconds: 9)), '0:00:09');
    });

    test('csv escapes what would break the columns', () {
      final log = ConnectionLog()..update([_connection('1', domain: 'a,b.example', process: r'C:\a.exe', download: 7)], _second);
      final csv = ConnectionView.toCsv(log.rows, _outbound, now: DateTime(2026));

      expect(csv, startsWith(r'C:\a.exe,,127.0.0.1,5000,"a,b.example",1.2.3.4,443,'));
      expect(csv, endsWith(',0,7'));
    });
  });

  test('internal outbound names never reach the screen', () {
    expect(nodeLabel('select'), '当前选择');
    expect(nodeLabel('auto'), '自动选择');
    expect(nodeLabel('direct'), '直连');
    expect(nodeLabel('香港 01'), '香港 01');
  });

  group('the core snapshot', () {
    test('memory comes along with the connections', () {
      const snapshot = ConnectionSnapshot(1, 2, [], memory: 3);
      expect(snapshot.memory, 3);
    });
  });

  group('the rule editor', () {
    testWidgets('opens with the value from the connection, after what was there', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const MaterialApp(
        home: EditRuleGroupPage(prefill: {'domains': 'a.example'}),
      ));

      expect(find.text('a.example'), findsOneWidget, reason: 'its section starts open');
      expect(find.byType(ConnectionFilterPage), findsNothing);
    });
  });

  group('the filter page', () {
    testWidgets('lists what actually appeared and writes into the shared filter', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      final log = ConnectionLog()
        ..update([
          _connection('1', domain: 'a.example'),
          _connection('2', domain: 'b.example', network: 'udp'),
        ], _second);
      final filter = ConnectionFilter();
      await tester.pumpWidget(MaterialApp(home: ConnectionFilterPage(rows: log.rows, filter: filter, outboundOf: _outbound)));

      expect(find.text('a.example'), findsOneWidget);
      expect(find.text('udp'), findsOneWidget);

      await tester.tap(find.text('udp'));
      await tester.pump();
      expect(filter.networks, {'udp'});

      await tester.enterText(find.byType(TextField), r'^b\.');
      await tester.pump();
      expect(find.text('a.example'), findsNothing);
      expect(find.text('b.example'), findsOneWidget);

      await tester.tap(find.byTooltip('清空'));
      await tester.pump();
      expect(filter.isEmpty, isTrue);
    });
  });
}
