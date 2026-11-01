import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'profile.dart';
import 'profile_decrypt.dart';
import 'profile_parser.dart';
import 'share_link.dart';

/// 下载到的订阅
class SubscriptionResult {
  final ParsedProfile parsed;
  final SubscriptionInfo? info;

  /// 面板给的名称，没有时为 null
  final String? title;
  final String? website;

  const SubscriptionResult(this.parsed, {this.info, this.title, this.website});
}

/// 订阅地址返回了错误状态码
class SubscriptionStatusException extends HttpException {
  final int statusCode;

  SubscriptionStatusException(this.statusCode, Uri uri) : super('subscription returned $statusCode', uri: uri);
}

/// 下载成功但内容读不懂。带上内容，让用户能看到机场到底返回了什么
class UnreadableProfileException extends FormatException {
  final String content;

  const UnreadableProfileException(super.message, this.content);
}

class Subscription {
  static const Duration _timeout = Duration(seconds: 20);

  /// 订阅一般只有几百 KB，防止错误的地址把整个文件读进内存
  static const int _maxBodyBytes = 16 << 20;

  /// 下载并解析。[proxy] 是本地代理地址（host:port），没连接时为空，这时只能直连
  static Future<SubscriptionResult> fetch(
    String url, {
    String? userAgent,
    DownloadStrategy strategy = DownloadStrategy.preferProxy,
    String? proxy,
    Map<String, String> headers = const {},
    String decryptPassword = '',
  }) async {
    final routes = strategy.routes(proxy);
    if (routes.isEmpty) {
      throw const SocketException('未连接，无法通过当前节点下载');
    }

    for (var index = 0;; index++) {
      try {
        return await _fetch(url, userAgent ?? UserAgents.compose(true, UserAgents.presets), routes[index], headers, decryptPassword);
      } on Exception {
        if (index == routes.length - 1) rethrow;
      }
    }
  }

  static Future<SubscriptionResult> _fetch(
      String url, String userAgent, String? proxy, Map<String, String> headers, String decryptPassword) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = userAgent;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';

    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri).timeout(_timeout);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw SubscriptionStatusException(response.statusCode, uri);
      }

      var body = await _read(response);
      final responseHeaders = response.headers;
      if (responseHeaders.value('subscription-encryption')?.trim() == 'true') {
        if (decryptPassword.isEmpty) throw const FormatException('这份订阅是加密的，请填写解密密码');
        final decrypted = ProfileDecrypt.decrypt(decryptPassword, body);
        if (decrypted == null) throw const FormatException('解密失败，请检查解密密码');
        body = decrypted;
      }

      final ParsedProfile parsed;
      try {
        parsed = ProfileParser.parse(body);
      } on FormatException catch (e) {
        throw UnreadableProfileException(e.message, body);
      }

      return SubscriptionResult(
        parsed,
        info: SubscriptionInfo.parse(responseHeaders.value('subscription-userinfo')),
        title: _title(responseHeaders.value('profile-title')) ?? fileName(responseHeaders.value('content-disposition')),
        website: responseHeaders.value('profile-web-page-url'),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _read(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_timeout)) {
      builder.add(chunk);
      if (builder.length > _maxBodyBytes) throw const FormatException('内容太大，这不像订阅');
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  /// profile-title 可能是 base64:xxx
  static String? _title(String? header) {
    if (header == null || header.isEmpty) return null;
    if (header.startsWith('base64:')) return ShareLink.decodeBase64(header.substring(7));
    return header;
  }

  /// attachment; filename*=UTF-8''my%20name.yaml 或 filename="name.yaml"，去掉扩展名
  static String? fileName(String? header) {
    if (header == null) return null;

    final encoded = RegExp(r"filename\*\s*=\s*[^']*'[^']*'([^;]+)", caseSensitive: false).firstMatch(header);
    String? name;
    if (encoded != null) {
      try {
        name = Uri.decodeComponent(encoded.group(1)!.trim());
      } on ArgumentError {
        name = encoded.group(1)!.trim();
      }
    } else {
      final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(header);
      name = plain?.group(1)?.trim();
    }
    if (name == null || name.isEmpty) return null;
    return name.replaceFirst(RegExp(r'\.(ya?ml|json|txt|conf)$', caseSensitive: false), '');
  }

  /// 没有名称时用地址里的域名
  static String nameFromUrl(String url) => Uri.tryParse(url)?.host ?? url;

  /// 链接自己带的名称：#名称、?remarks= 或 ?name=，不需要联网就能拿到
  static String? nameInLink(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority) return null;
    final name = uri.fragment.isNotEmpty ? uri.fragment : (uri.queryParameters['remarks'] ?? uri.queryParameters['name']);
    if (name == null || name.isEmpty) return null;
    try {
      return Uri.decodeComponent(name);
    } on ArgumentError {
      return name;
    }
  }

  /// GitHub 网页地址换成原始文件地址，否则下载到的是网页
  static String normalizeUrl(String url) {
    final match = RegExp(r'^https://github\.com/([^/]+)/([^/]+)/(?:blob|raw)/(.+)$').firstMatch(url);
    return match == null
        ? url
        : 'https://raw.githubusercontent.com/${match.group(1)}/${match.group(2)}/${match.group(3)}';
  }

  /// 面板首页的标题，订阅没给名称时用。超过 [_maxTitleLength] 的多半不是名称
  static Future<String?> siteTitle(String url, String userAgent, {String? proxy}) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..userAgent = userAgent;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final site = Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
      final request = await client.getUrl(site).timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(const Duration(seconds: 5));
      final body = await _read(response);
      final start = body.indexOf('<title>'), end = body.indexOf('</title>');
      if (start < 0 || end <= start) return null;
      final title = body.substring(start + '<title>'.length, end).trim();
      return title.isEmpty || title.length >= _maxTitleLength ? null : title;
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static const int _maxTitleLength = 32;
}
