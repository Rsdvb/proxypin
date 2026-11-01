import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'clash_api.dart';

/// 规则检测的结果
class RuleMatch {
  final String rule;

  /// 流量最终走的出站
  final String outbound;

  /// 经过的出站，内核的顺序是最后一跳在前
  final List<String> chain;

  const RuleMatch(this.rule, this.outbound, {this.chain = const []});
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

  /// 当前连接的 Wi-Fi，读不到时返回 null
  static Future<({String ssid, String bssid})?> currentWifi() async {
    try {
      if (Platform.isIOS) {
        final wifi = await const MethodChannel('rsproxy/core').invokeMapMethod<String, String>('wifiState');
        return wifi == null ? null : (ssid: wifi['ssid'] ?? '', bssid: (wifi['bssid'] ?? '').toLowerCase());
      }
      if (Platform.isWindows) {
        final result = await Process.run('netsh', ['wlan', 'show', 'interfaces']);
        return parseNetshWifi(result.stdout.toString());
      }
    } on Exception {
      return null;
    }
    return null;
  }

  /// netsh 的输出按系统语言翻译，只有 SSID 和 BSSID 这两个词不变，新版 Windows 写作 AP BSSID
  static ({String ssid, String bssid})? parseNetshWifi(String output) {
    final ssid = RegExp(r'^\s*SSID\s*:\s*(.+?)\s*$', multiLine: true).firstMatch(output)?.group(1);
    final bssid = RegExp(r'BSSID\s*:\s*([0-9a-fA-F:]{17})').firstMatch(output)?.group(1);
    return ssid == null ? null : (ssid: ssid, bssid: bssid?.toLowerCase() ?? '');
  }

  /// 本机公网 IPv4 的 /24 网段，给 ECS 用。失败返回 null，下次再试
  static Future<String?> clientSubnet() async {
    try {
      final body = await _body('https://www.cloudflare.com/cdn-cgi/trace', null, (text) => text).timeout(_timeout);
      final match = RegExp(r'^ip=(\d+)\.(\d+)\.(\d+)\.\d+$', multiLine: true).firstMatch(body);
      return match == null ? null : '${match.group(1)}.${match.group(2)}.${match.group(3)}.0/24';
    } on Exception {
      return null;
    }
  }

  /// 把内核的报错翻译成用户能处理的话，认不出来的原样给出最后一行
  static String describeFailure(String log) {
    final clean = log.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '').trim();
    final text = clean.toLowerCase();
    if (text.contains('address already in use') || text.contains('only one usage of each socket address')) {
      final port = RegExp(r'listen \w+ [^\s]*:(\d+)').firstMatch(clean)?.group(1);
      return '端口${port == null ? '' : ' $port '}被其他程序占用，请关闭它或换一个端口';
    }
    if (text.contains('wintun') || text.contains('failed to setup adapter')) {
      return 'TUN 网卡创建失败。请确认以管理员身份运行，没有其他 TUN 软件在用，还不行就重启电脑';
    }
    if (text.contains('access is denied') || text.contains('requires elevation')) {
      return 'TUN 模式需要管理员权限，请以管理员身份重新启动 RsProxy';
    }
    if (text.contains('rule-set')) return '规则集读取失败，请到分流页的规则集里重新更新：${_lastLine(clean)}';
    return clean.isEmpty ? '内核意外退出' : _lastLine(clean);
  }

  static String _lastLine(String text) => text.split('\n').last.replaceFirst(RegExp(r'^(FATAL|ERROR)\[\d+\]\s*'), '').trim();

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
            return RuleMatch(connection.rule, connection.chains.isEmpty ? '' : connection.chains.first,
                chain: connection.chains);
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
