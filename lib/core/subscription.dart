import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'profile.dart';
import 'profile_parser.dart';
import 'share_link.dart';

/// 下载到的订阅
class SubscriptionResult {
  final ParsedProfile parsed;
  final SubscriptionInfo? info;

  /// 面板给的名称，没有时为 null
  final String? title;
  final String? website;

  /// 面板建议的更新间隔（小时）
  final int? updateHours;

  const SubscriptionResult(this.parsed, {this.info, this.title, this.website, this.updateHours});
}

class Subscription {
  static const Duration _timeout = Duration(seconds: 20);

  /// 下载并解析。[proxy] 是本地代理地址（host:port），不为空时先走代理，失败再直连：
  /// 订阅地址被墙时靠代理，代理节点挂了时靠直连。
  static Future<SubscriptionResult> fetch(String url, {String userAgent = Profile.defaultUserAgent, String? proxy}) async {
    if (proxy != null) {
      try {
        return await _fetch(url, userAgent, proxy);
      } on Exception {
        return _fetch(url, userAgent, null);
      }
    }
    return _fetch(url, userAgent, null);
  }

  static Future<SubscriptionResult> _fetch(String url, String userAgent, String? proxy) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = userAgent;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('subscription returned ${response.statusCode}', uri: Uri.parse(url));
      }

      final body = await response.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(_timeout);
      final headers = response.headers;
      return SubscriptionResult(
        ProfileParser.parse(body),
        info: SubscriptionInfo.parse(headers.value('subscription-userinfo')),
        title: _title(headers.value('profile-title')) ?? fileName(headers.value('content-disposition')),
        website: headers.value('profile-web-page-url'),
        updateHours: int.tryParse(headers.value('profile-update-interval') ?? ''),
      );
    } finally {
      client.close(force: true);
    }
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
}
