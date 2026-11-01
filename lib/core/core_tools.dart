import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'clash_api.dart';

/// 规则检测的结果
class RuleMatch {
  final String rule;

  /// 流量最终走的出站
  final String outbound;

  const RuleMatch(this.rule, this.outbound);
}

/// 一项网络检测
class CheckResult {
  final String name;
  final bool passed;
  final Duration? elapsed;
  final String? detail;

  const CheckResult(this.name, this.passed, {this.elapsed, this.detail});
}

class CoreTools {
  static const Duration _timeout = Duration(seconds: 8);

  /// 问内核一个域名会走哪条规则。sing-box 没有这样的接口，也读不了二进制规则集，
  /// 所以真的发起一条连接，再看内核给它记的规则，结果和实际上网时一致。
  static Future<RuleMatch?> matchRule(ClashApi api, int proxyPort, String domain, {int port = 443}) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort).timeout(_timeout);
    try {
      socket.write('CONNECT $domain:$port HTTP/1.1\r\nHost: $domain:$port\r\n\r\n');
      await socket.flush();

      for (var attempt = 0; attempt < 30; attempt++) {
        final snapshot = await api.connections();
        for (final connection in snapshot.connections) {
          if (connection.host == '$domain:$port') {
            await api.closeConnection(connection.id).catchError((_) {});
            return RuleMatch(connection.rule, connection.chains.isEmpty ? '' : connection.chains.first);
          }
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return null;
    } finally {
      socket.destroy();
    }
  }

  /// 下载测速，返回字节/秒。[onProgress] 每收到数据时回调当前速度
  static Future<double> downloadSpeed(
    String proxy, {
    String url = 'https://speed.cloudflare.com/__down?bytes=100000000',
    Duration duration = const Duration(seconds: 8),
    void Function(double bytesPerSecond)? onProgress,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..findProxy = ((_) => 'PROXY $proxy');
    final stopwatch = Stopwatch();
    var received = 0;
    double speed() => stopwatch.elapsedMicroseconds == 0 ? 0 : received * 1000000 / stopwatch.elapsedMicroseconds;

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('speed test returned ${response.statusCode}');
      }

      stopwatch.start();
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      subscription = response.listen((chunk) {
        received += chunk.length;
        onProgress?.call(speed());
        if (stopwatch.elapsed >= duration && !done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      });

      await done.future.timeout(duration + _timeout);
      await subscription.cancel();
      return speed();
    } finally {
      client.close(force: true);
    }
  }

  /// 逐项检查网络。一项失败不影响后面的，用户要看的就是哪一段断了
  static Future<List<CheckResult>> networkCheck(ClashApi api, String proxy, {required String testUrl}) async {
    return [
      await _timed('内核', () async => (await api.mode()) ?? ''),
      await _timed('直连网络', () => _status('https://connect.rom.miui.com/generate_204', null)),
      await _timed('通过节点上网', () => _status(testUrl, proxy)),
      await _timed('出口地址', () => _body('https://www.cloudflare.com/cdn-cgi/trace', proxy, _traceSummary)),
    ];
  }

  static Future<CheckResult> _timed(String name, Future<String> Function() check) async {
    final stopwatch = Stopwatch()..start();
    try {
      final detail = await check().timeout(_timeout);
      return CheckResult(name, true, elapsed: stopwatch.elapsed, detail: detail);
    } catch (e) {
      return CheckResult(name, false, detail: e.toString());
    }
  }

  static Future<String> _status(String url, String? proxy) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode >= 400) throw HttpException('HTTP ${response.statusCode}');
      return 'HTTP ${response.statusCode}';
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _body(String url, String? proxy, String Function(String) summarize) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      return summarize(await response.transform(const Utf8Decoder(allowMalformed: true)).join());
    } finally {
      client.close(force: true);
    }
  }

  /// cdn-cgi/trace 是 key=value 一行一个
  static String _traceSummary(String body) {
    final fields = {
      for (final line in const LineSplitter().convert(body))
        if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
    };
    return [fields['ip'], fields['loc']].whereType<String>().join(' · ');
  }
}

/// 按节点名称识别地区，节点列表的筛选用
class NodeRegions {
  static const Map<String, List<String>> _keywords = {
    '香港': ['香港', '🇭🇰', 'hong kong', 'hongkong', 'hk'],
    '台湾': ['台湾', '台灣', '🇹🇼', 'taiwan', 'tw'],
    '日本': ['日本', '🇯🇵', 'japan', 'tokyo', 'osaka', 'jp'],
    '新加坡': ['新加坡', '狮城', '🇸🇬', 'singapore', 'sg'],
    '美国': ['美国', '美國', '🇺🇸', 'united states', 'america', 'usa', 'us'],
    '韩国': ['韩国', '韓國', '🇰🇷', 'korea', 'seoul', 'kr'],
    '英国': ['英国', '🇬🇧', 'united kingdom', 'london', 'uk'],
    '德国': ['德国', '🇩🇪', 'germany', 'frankfurt', 'de'],
  };

  /// 英文缩写要按词匹配，否则 use 里的 us 也算美国
  static final Map<String, RegExp> _patterns = _keywords.map((region, words) {
    final escaped = words.map(RegExp.escape).map((word) => RegExp(r'^[a-z]{2,3}$').hasMatch(word)
        ? '(?<![a-z])$word(?![a-z])'
        : word);
    return MapEntry(region, RegExp(escaped.join('|'), caseSensitive: false));
  });

  static String? of(String name) {
    for (final entry in _patterns.entries) {
      if (entry.value.hasMatch(name)) return entry.key;
    }
    return null;
  }

  /// 出现过的地区，按固定顺序
  static List<String> present(Iterable<String> names) {
    final found = names.map(of).whereType<String>().toSet();
    return _keywords.keys.where(found.contains).toList();
  }
}
