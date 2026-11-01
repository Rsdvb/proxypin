import 'dart:math';

import 'clash_api.dart';

/// 同一个来源、目标和出站的连接合并成一行。一个网页开几十条连接，平铺开来什么也看不清
class ConnectionRow {
  final String key;

  /// 第一条连接，行上的地址和端口都取它的
  final CoreConnection sample;
  final Set<String> activeIds = {};

  /// 已结束的连接数
  int closed = 0;

  /// 累计流量，含已结束的连接
  int upload = 0;
  int download = 0;

  /// 字节/秒
  int uploadSpeed = 0;
  int downloadSpeed = 0;
  DateTime? start;

  /// 全部结束的时间
  DateTime? end;

  ConnectionRow(this.key, this.sample);

  bool get isActive => activeIds.isNotEmpty;

  /// 结束后时长不再增长
  Duration durationAt(DateTime now) {
    final begin = start;
    if (begin == null) return Duration.zero;
    return (end ?? now).difference(begin);
  }
}

/// 内核只给活动连接，要看结束了的，只能自己记着。离开页面就丢掉
class ConnectionLog {
  /// 一直开着也不至于把内存吃完，超过时先丢最早结束的
  static const int _maxRows = 2000;

  final Map<String, ConnectionRow> _rows = {};
  Map<String, CoreConnection> _live = {};

  static String keyOf(CoreConnection connection) => [
        connection.processPath,
        connection.sourceIp,
        connection.domain,
        connection.destination,
        connection.network,
        connection.chains.join('>'),
      ].join('|');

  List<ConnectionRow> get rows => _rows.values.toList();

  /// [elapsed] 是距离上一帧的时间。速度只算两帧都见过的连接，第一次见到时的流量不算速度
  void update(List<CoreConnection> connections, Duration elapsed, {DateTime? now}) {
    final time = now ?? DateTime.now();
    final seconds = max(elapsed.inMilliseconds, 1) / 1000;
    for (final row in _rows.values) {
      row
        ..uploadSpeed = 0
        ..downloadSpeed = 0;
    }

    final current = <String, CoreConnection>{};
    for (final connection in connections) {
      current[connection.id] = connection;
      final key = keyOf(connection);
      final row = _rows.putIfAbsent(key, () => ConnectionRow(key, connection));
      final previous = _live[connection.id];
      final up = connection.upload - (previous?.upload ?? 0);
      final down = connection.download - (previous?.download ?? 0);
      row
        ..upload += up
        ..download += down
        ..end = null;
      row.activeIds.add(connection.id);
      if (previous != null) {
        row
          ..uploadSpeed += (up / seconds).round()
          ..downloadSpeed += (down / seconds).round();
      }
      final start = connection.start;
      if (start != null && (row.start == null || start.isBefore(row.start!))) row.start = start;
    }

    for (final entry in _live.entries) {
      if (current.containsKey(entry.key)) continue;
      final row = _rows[keyOf(entry.value)];
      if (row == null) continue;
      row.activeIds.remove(entry.key);
      row.closed++;
      if (row.activeIds.isEmpty) row.end = time;
    }
    _live = current;
    _trim();
  }

  void _trim() {
    if (_rows.length <= _maxRows) return;
    final ended = _rows.values.where((e) => !e.isActive).toList()..sort((a, b) => a.end!.compareTo(b.end!));
    for (final row in ended.take(_rows.length - _maxRows)) {
      _rows.remove(row.key);
    }
  }
}

enum ConnectionSort { none, downloadSpeed, uploadSpeed, download, upload }

/// 同一类里多选是“或”，不同类之间是“且”，没选的类不参与
class ConnectionFilter {
  final Set<String> networks = {};
  final Set<String> hosts = {};
  final Set<String> ports = {};
  final Set<String> apps = {};
  final Set<String> rules = {};
  final Set<String> outbounds = {};

  bool get isEmpty =>
      networks.isEmpty && hosts.isEmpty && ports.isEmpty && apps.isEmpty && rules.isEmpty && outbounds.isEmpty;

  void clear() {
    for (final set in [networks, hosts, ports, apps, rules, outbounds]) {
      set.clear();
    }
  }

  bool matches(ConnectionRow row, String Function(CoreConnection) outboundOf) {
    final sample = row.sample;
    bool allowed(Set<String> set, String value) => set.isEmpty || set.contains(value);
    return allowed(networks, sample.network) &&
        allowed(hosts, sample.domain.isNotEmpty ? sample.domain : sample.destination) &&
        allowed(ports, sample.port) &&
        allowed(apps, sample.processName) &&
        allowed(rules, sample.ruleName) &&
        allowed(outbounds, outboundOf(sample));
  }
}

abstract class ConnectionView {
  /// 活动的始终在前，两段各自排序。默认顺序不抖动：连接数一变，手指底下的行不会跳走
  static List<ConnectionRow> sorted(List<ConnectionRow> rows, ConnectionSort sort) {
    int value(ConnectionRow row) => switch (sort) {
          ConnectionSort.none => 0,
          ConnectionSort.downloadSpeed => row.downloadSpeed,
          ConnectionSort.uploadSpeed => row.uploadSpeed,
          ConnectionSort.download => row.download,
          ConnectionSort.upload => row.upload,
        };
    String name(ConnectionRow row) => '${row.sample.processPath}|${row.sample.host}';
    return [...rows]..sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        final compared = value(b).compareTo(value(a));
        return compared != 0 ? compared : name(a).compareTo(name(b));
      });
  }

  /// 超过 40 个字符时留头尾，中间省略：域名的头尾最有辨识度
  static String shortHost(String host) =>
      host.length <= 40 ? host : '${host.substring(0, 20)}...${host.substring(host.length - 20)}';

  static String formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${duration.inHours}:$minutes:$seconds';
  }

  static String _csvField(String value) =>
      value.contains(RegExp(r'[",\n]')) ? '"${value.replaceAll('"', '""')}"' : value;

  /// 没有表头，方便直接贴进表格，和 Karing 的列顺序一致（内核不提供的包名留空）
  static String toCsv(List<ConnectionRow> rows, String Function(CoreConnection) outboundOf, {DateTime? now}) {
    final time = now ?? DateTime.now();
    return rows.map((row) {
      final sample = row.sample;
      return [
        sample.processPath,
        '',
        sample.sourceIp,
        sample.sourcePort,
        sample.domain,
        sample.destination,
        sample.port,
        row.start?.toIso8601String() ?? '',
        formatDuration(row.durationAt(time)),
        sample.network,
        '${row.activeIds.length}',
        '${row.closed}',
        shortHost(sample.domain.isNotEmpty ? sample.domain : sample.destination),
        sample.processName,
        outboundOf(sample),
        sample.ruleName,
        '${row.upload}',
        '${row.download}',
      ].map(_csvField).join(',');
    }).join('\n');
  }
}
