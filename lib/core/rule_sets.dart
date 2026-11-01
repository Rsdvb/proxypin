import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';
import 'package:proxypin/network/util/logger.dart';

/// 规则集的命名：geosite-x、geoip-x、acl-x 来自公开仓库，url-x 是用户填的地址。
/// 内置的只有常用的二十个，其余用到时才下载，所以安装包里只放名称列表（assets/rules/index.txt）
abstract class RuleSets {
  /// 内核支持的 .srs 最高版本，更新的文件它读不了
  static const int _maxBinaryVersion = 5;

  /// 某个地区走直连的规则集。各地区都有 geoip，geosite 只有中国大陆的数据是全的
  static List<String> ofRegion(String region) => [if (region == 'cn') 'geosite-cn', 'geoip-$region'];

  static String fileName(String name) => isSource(name) ? name : '$name.srs';

  /// JSON 格式的规则集，其余是二进制
  static bool isSource(String name) => name.endsWith('.json');

  /// 用户填的地址对应的规则集名称。地址可能很长，也不能直接当文件名
  static String tagOfUrl(String url) {
    final hash = SHA1Digest().process(utf8.encode(url)).take(8);
    final hex = hash.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return 'url-$hex${Uri.tryParse(url)?.path.endsWith('.json') == true ? '.json' : ''}';
  }

  /// 依次尝试的下载地址。raw.githubusercontent.com 在国内经常连不上，后面跟 jsDelivr
  static List<Uri> sources(String name) {
    final (String repository, String branch, String path) = switch (name) {
      _ when name.startsWith('geosite-') => ('SagerNet/sing-geosite', 'rule-set', '$name.srs'),
      _ when name.startsWith('geoip-') => ('SagerNet/sing-geoip', 'rule-set', '$name.srs'),
      _ when name.startsWith('acl-') => ('KaringX/karing-ruleset', 'sing', 'ACL4SSR/${name.substring(4)}.srs'),
      _ => ('', '', ''),
    };
    if (repository.isEmpty) return const [];
    return [
      Uri.https('raw.githubusercontent.com', '/$repository/$branch/$path'),
      Uri.https('cdn.jsdelivr.net', '/gh/$repository@$branch/$path'),
    ];
  }

  /// 坏文件写进配置，内核就起不来了，下载的内容要先过这一关
  static bool isValid(String name, Uint8List bytes) {
    if (isSource(name)) {
      try {
        final json = jsonDecode(utf8.decode(bytes));
        return json is Map && json['version'] is int && json['rules'] is List;
      } on FormatException {
        return false;
      }
    }
    return bytes.length > 4 &&
        bytes[0] == 0x53 &&
        bytes[1] == 0x52 &&
        bytes[2] == 0x53 &&
        bytes[3] <= _maxBinaryVersion;
  }

  static const Duration _timeout = Duration(seconds: 8);
  static const int _maxBytes = 32 << 20;

  /// [proxy] 是本地代理地址（host:port），空表示直连
  static Future<Uint8List> download(Uri uri, String? proxy) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('rule set returned ${response.statusCode}', uri: uri);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        builder.add(chunk);
        if (builder.length > _maxBytes) throw HttpException('rule set is too large', uri: uri);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}

/// 一个规则集的状态
class RuleSetState {
  final String name;

  /// 文件的修改时间，还没有文件时为空
  final DateTime? updatedAt;

  const RuleSetState(this.name, this.updatedAt);
}

/// 规则集目录。内核从这里读文件，文件变了会自己重新加载
class RuleSetStore {
  static const int _concurrency = 4;

  /// 连接时最多等这么久，下载不到的先跳过，不能让连接卡住
  static const Duration connectBudget = Duration(seconds: 12);

  /// 失败的规则集这段时间内不再试，免得每次重载都等一遍
  static const Duration _retryAfter = Duration(minutes: 5);

  final Directory directory;

  /// 读内置规则集，没有时返回 null
  final Future<Uint8List?> Function(String name) bundled;
  final Future<Uint8List> Function(Uri uri, String? proxy) fetch;
  final Map<String, DateTime> _failedAt = {};

  RuleSetStore(this.directory, {required this.bundled, this.fetch = RuleSets.download});

  File _file(String name) => File('${directory.path}/${RuleSets.fileName(name)}');

  /// 依次经 [routes] 下载，null 表示直连。写入先落到临时文件，内核不会读到写了一半的内容
  Future<bool> _download(String name, List<Uri> sources, List<String?> routes) async {
    for (final route in routes) {
      for (final uri in sources) {
        try {
          final bytes = await fetch(uri, route);
          if (!RuleSets.isValid(name, bytes)) {
            logger.w('rule set $name from $uri is not valid');
            continue;
          }
          final temporary = File('${_file(name).path}.tmp');
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(_file(name).path);
          _failedAt.remove(name);
          return true;
        } on Exception catch (e) {
          logger.d('download rule set $name from $uri failed: $e');
        }
      }
    }
    _failedAt[name] = DateTime.now();
    return false;
  }

  List<Uri> _sourcesOf(String name, Map<String, String> urls) {
    final url = urls[name];
    return url == null ? RuleSets.sources(name) : [Uri.parse(url)];
  }

  /// 放好 [names] 和 [urls]（名称 -> 地址），返回能用的。超过 [budget] 还没下完的先不算，
  /// 下载继续在后台跑，下次生成配置时就有了
  Future<Set<String>> prepare(
    Iterable<String> names, {
    Map<String, String> urls = const {},
    List<String?> routes = const [null],
    Duration budget = connectBudget,
  }) async {
    final available = <String>{};
    final missing = <String>[];
    for (final name in {...names, ...urls.keys}) {
      if (await _file(name).exists()) {
        available.add(name);
        continue;
      }
      final bytes = await bundled(name);
      if (bytes != null) {
        await _file(name).writeAsBytes(bytes);
        available.add(name);
        continue;
      }
      final failedAt = _failedAt[name];
      if (failedAt == null || DateTime.now().difference(failedAt) > _retryAfter) missing.add(name);
    }

    Future<void> worker() async {
      while (missing.isNotEmpty) {
        final name = missing.removeLast();
        if (await _download(name, _sourcesOf(name, urls), routes)) available.add(name);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker())).timeout(budget, onTimeout: () => const []);
    return {...available};
  }

  /// 重新下载 [names] 和 [urls]，内置的只有 [includeBundled] 时才更新。
  /// 返回 (成功数, 失败数)
  Future<(int, int)> refresh(
    Iterable<String> names, {
    Map<String, String> urls = const {},
    List<String?> routes = const [null],
    bool includeBundled = false,
  }) async {
    final queue = <String>[];
    for (final name in {...names, ...urls.keys}) {
      if (includeBundled || urls.containsKey(name) || await bundled(name) == null) queue.add(name);
    }

    var succeeded = 0, failed = 0;
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final name = queue.removeLast();
        if (await _download(name, _sourcesOf(name, urls), routes)) {
          succeeded++;
        } else {
          failed++;
        }
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    return (succeeded, failed);
  }

  /// 忘掉失败记录，比如连上节点以后值得马上再试一次
  void forgetFailures() => _failedAt.clear();

  Future<List<RuleSetState>> states(Iterable<String> names) async {
    final states = <RuleSetState>[];
    for (final name in names) {
      final file = _file(name);
      states.add(RuleSetState(name, await file.exists() ? await file.lastModified() : null));
    }
    return states;
  }
}
