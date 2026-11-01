import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 节点组的当前状态
class ProxyGroup {
  final String name;
  final String type;

  /// 当前选中的成员
  final String? now;
  final List<String> members;

  const ProxyGroup(this.name, this.type, this.now, this.members);
}

/// 一条活动连接
class CoreConnection {
  final String id;
  final String host;
  final String network;
  final String rule;

  /// 经过的出站，由外到内：节点组 -> 节点
  final List<String> chains;
  final int upload;
  final int download;
  final DateTime? start;

  /// 域名，内核不知道时为空
  final String domain;

  /// 目标 IP
  final String destination;
  final String port;
  final String sourceIp;
  final String sourcePort;

  /// 发起连接的程序。iOS 上拿不到
  final String processPath;

  const CoreConnection(
    this.id,
    this.host,
    this.network,
    this.rule,
    this.chains,
    this.upload,
    this.download,
    this.start, {
    this.domain = '',
    this.destination = '',
    this.port = '',
    this.sourceIp = '',
    this.sourcePort = '',
    this.processPath = '',
  });

  String get source => sourceIp.contains(':') ? '[$sourceIp]:$sourcePort' : '$sourceIp:$sourcePort';

  String get processName => processPath.split(RegExp(r'[\\/]')).last;

  /// 内核的规则文本是“条件 => 动作”，只留条件
  String get ruleName => rule.split('=>').first.trim();

  factory CoreConnection.fromJson(Map<String, dynamic> json) {
    final metadata = (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final host = metadata['host']?.toString() ?? '';
    final destination = metadata['destinationIP']?.toString() ?? '';
    final port = metadata['destinationPort']?.toString() ?? '';
    return CoreConnection(
      json['id'].toString(),
      '${host.isNotEmpty ? host : destination}:$port',
      metadata['network']?.toString() ?? '',
      json['rule']?.toString() ?? '',
      (json['chains'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      (json['upload'] as num?)?.toInt() ?? 0,
      (json['download'] as num?)?.toInt() ?? 0,
      DateTime.tryParse(json['start']?.toString() ?? ''),
      domain: host,
      destination: destination,
      port: port,
      sourceIp: metadata['sourceIP']?.toString() ?? '',
      sourcePort: metadata['sourcePort']?.toString() ?? '',
      // Linux 上内核会在后面加“ (用户)”
      processPath: (metadata['processPath']?.toString() ?? '').replaceFirst(RegExp(r' \(.*\)$'), ''),
    );
  }
}

/// 总流量和活动连接
class ConnectionSnapshot {
  final int uploadTotal;
  final int downloadTotal;
  final List<CoreConnection> connections;

  /// 内核占用的内存，字节
  final int memory;

  const ConnectionSnapshot(this.uploadTotal, this.downloadTotal, this.connections, {this.memory = 0});
}

/// 实时速度（字节/秒）
class TrafficSample {
  final int up;
  final int down;

  const TrafficSample(this.up, this.down);
}

/// 一行内核日志
class CoreLog {
  final String level;
  final String message;

  const CoreLog(this.level, this.message);
}

/// sing-box 内置的 Clash API。Windows 和 iOS 都走它，界面不用区分内核跑在哪个进程
class ClashApi {
  static const Duration _timeout = Duration(seconds: 5);

  final String host;
  final int port;
  final String secret;
  final HttpClient _client = HttpClient()..connectionTimeout = _timeout;

  ClashApi({this.host = '127.0.0.1', required this.port, required this.secret}) {
    // 这是本机接口，不能走代理，否则内核刚起来时请求会绕回自己
    _client.findProxy = (_) => 'DIRECT';
  }

  void close() => _client.close(force: true);

  Future<HttpClientResponse> _send(String method, String path, {Object? body}) async {
    final request = await _client.openUrl(method, Uri.parse('http://$host:$port$path')).timeout(_timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    return request.close().timeout(_timeout);
  }

  Future<Object?> _json(String method, String path, {Object? body}) async {
    final response = await _send(method, path, body: body);
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300) {
      throw HttpException('$method $path: ${response.statusCode} $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<void> setMode(String mode) => _json('PATCH', '/configs', body: {'mode': mode});

  Future<String?> mode() async => ((await _json('GET', '/configs')) as Map?)?['mode']?.toString();

  /// 所有节点组，键是组名
  Future<Map<String, ProxyGroup>> groups() async {
    final json = (await _json('GET', '/proxies')) as Map<String, dynamic>;
    final proxies = (json['proxies'] as Map).cast<String, dynamic>();
    return {
      for (final entry in proxies.entries)
        if (entry.value['all'] is List)
          entry.key: ProxyGroup(
            entry.key,
            entry.value['type']?.toString() ?? '',
            entry.value['now']?.toString(),
            (entry.value['all'] as List).map((e) => e.toString()).toList(),
          ),
    };
  }

  Future<void> select(String group, String node) =>
      _json('PUT', '/proxies/${Uri.encodeComponent(group)}', body: {'name': node});

  /// 单个节点的延迟（毫秒），不通时返回 null
  Future<int?> delay(String node, {required String url, int timeoutMs = 5000}) async {
    final query = 'url=${Uri.encodeComponent(url)}&timeout=$timeoutMs';
    try {
      final json = await _json('GET', '/proxies/${Uri.encodeComponent(node)}/delay?$query');
      final value = (json as Map?)?['delay'];
      return value is num && value > 0 ? value.toInt() : null;
    } on Exception {
      // 不通时内核回错误状态码；刚好超时的话本地请求也会先超时
      return null;
    }
  }

  /// 测一组节点的延迟，返回通的节点及延迟（毫秒）
  Future<Map<String, int>> groupDelay(String group, {required String url, int timeoutMs = 5000}) async {
    final query = 'url=${Uri.encodeComponent(url)}&timeout=$timeoutMs';
    final json = await _json('GET', '/group/${Uri.encodeComponent(group)}/delay?$query');
    return {
      for (final entry in ((json as Map?) ?? const {}).entries)
        if (entry.value is num && (entry.value as num) > 0) entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  Future<ConnectionSnapshot> connections() async {
    final json = (await _json('GET', '/connections')) as Map<String, dynamic>;
    return ConnectionSnapshot(
      (json['uploadTotal'] as num?)?.toInt() ?? 0,
      (json['downloadTotal'] as num?)?.toInt() ?? 0,
      (json['connections'] as List?)?.map((e) => CoreConnection.fromJson((e as Map).cast())).toList() ?? const [],
      memory: (json['memory'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> closeConnection(String id) => _json('DELETE', '/connections/${Uri.encodeComponent(id)}');

  Future<void> closeAllConnections() => _json('DELETE', '/connections');

  /// 内核日志，取消订阅时断开。没有日志时内核连响应头都不回，所以不能设超时，
  /// 也不能用生成器：取消时还卡在等响应，要关掉连接才退得出来
  Stream<CoreLog> logs({String level = 'info'}) {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    late final StreamController<CoreLog> controller;
    controller = StreamController(
      onListen: () async {
        try {
          final uri = Uri.parse('http://$host:$port/logs?level=$level');
          final request = await client.getUrl(uri).timeout(_timeout);
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
          final response = await request.close();
          await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
            if (line.trim().isEmpty) continue;
            final json = jsonDecode(line) as Map<String, dynamic>;
            controller.add(CoreLog(json['type']?.toString() ?? '', json['payload']?.toString() ?? ''));
          }
        } on Exception catch (e) {
          if (!controller.isClosed) controller.addError(e);
        } finally {
          if (!controller.isClosed) unawaited(controller.close());
        }
      },
      onCancel: () => client.close(force: true),
    );
    return controller.stream;
  }

  /// 每秒一个样本，取消订阅时断开。只在界面可见时才订阅，省电
  Stream<TrafficSample> traffic() async* {
    final response = await _send('GET', '/traffic');
    await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final json = jsonDecode(line) as Map<String, dynamic>;
      yield TrafficSample((json['up'] as num?)?.toInt() ?? 0, (json['down'] as num?)?.toInt() ?? 0);
    }
  }
}
