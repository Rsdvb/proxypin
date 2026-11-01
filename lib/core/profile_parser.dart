import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'clash_proxy.dart';
import 'share_link.dart';

/// 解析结果
class ParsedProfile {
  final List<Outbound> outbounds;

  /// 暂不支持而跳过的节点数
  final int skipped;

  const ParsedProfile(this.outbounds, this.skipped);
}

/// 配置内容解析，自动识别格式：sing-box、Clash、分享链接，以及 base64 后的分享链接
class ProfileParser {
  /// 这些 outbound 由 App 自己生成，订阅里的不要
  static const Set<String> _generatedTypes = {'direct', 'block', 'dns', 'selector', 'urltest'};

  /// App 配置里占用的 tag，节点重名时要避开
  static const Set<String> reservedTags = {'select', 'auto', 'direct', 'rs-mitm'};

  /// 不是任何已知格式时抛 [FormatException]
  static ParsedProfile parse(String content) {
    final text = content.trim();
    if (text.isEmpty) throw const FormatException('empty profile');

    if (text.startsWith('{')) {
      return _json(text);
    }
    if (RegExp(r'^proxies\s*:', multiLine: true).hasMatch(text)) {
      return _clash(text);
    }

    final lines = _lines(text);
    if (lines.any(ShareLink.isLink)) {
      return _links(lines);
    }

    final decoded = ShareLink.decodeBase64(text);
    if (decoded != null) {
      final decodedLines = _lines(decoded);
      if (decodedLines.any(ShareLink.isLink)) {
        return _links(decodedLines);
      }
    }
    throw const FormatException('unknown profile format');
  }

  static List<String> _lines(String text) =>
      text.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static ParsedProfile _json(String text) {
    final json = jsonDecode(text);
    if (json is! Map) throw const FormatException('not an object');

    if (json['proxies'] is List) {
      return _clashProxies(json['proxies'] as List);
    }

    final items = json['outbounds'];
    if (items is! List) throw const FormatException('no outbounds');
    final outbounds = <Outbound>[];
    var skipped = 0;
    for (final item in items) {
      if (item is! Map || item['type'] == null || item['tag'] == null) {
        skipped++;
        continue;
      }
      if (!_generatedTypes.contains(item['type'])) {
        outbounds.add(Map<String, dynamic>.from(item));
      }
    }
    return ParsedProfile(_uniqueTags(outbounds), skipped);
  }

  static ParsedProfile _clash(String text) {
    final Object? document;
    try {
      document = loadYaml(text);
    } on YamlException catch (e) {
      throw FormatException('invalid yaml: ${e.message}');
    }
    if (document is! Map || document['proxies'] is! List) {
      throw const FormatException('no proxies');
    }
    return _clashProxies(document['proxies'] as List);
  }

  static ParsedProfile _clashProxies(List proxies) {
    final outbounds = <Outbound>[];
    var skipped = 0;
    for (final proxy in proxies) {
      final outbound = proxy is Map ? ClashProxy.parse(proxy) : null;
      if (outbound == null) {
        skipped++;
      } else {
        outbounds.add(outbound);
      }
    }
    return ParsedProfile(_uniqueTags(outbounds), skipped);
  }

  static ParsedProfile _links(List<String> lines) {
    final outbounds = <Outbound>[];
    var skipped = 0;
    for (final line in lines) {
      final outbound = ShareLink.parse(line);
      if (outbound == null) {
        skipped++;
      } else {
        outbounds.add(outbound);
      }
    }
    return ParsedProfile(_uniqueTags(outbounds), skipped);
  }

  /// sing-box 要求 tag 唯一，而订阅里经常有同名节点
  static List<Outbound> _uniqueTags(List<Outbound> outbounds) {
    final used = <String>{...reservedTags};
    for (final outbound in outbounds) {
      final base = outbound['tag'].toString();
      var tag = base;
      for (var index = 2; !used.add(tag); index++) {
        tag = '$base $index';
      }
      outbound['tag'] = tag;
    }
    return outbounds;
  }
}
