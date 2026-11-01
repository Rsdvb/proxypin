import 'share_link.dart';

/// 网页上的“一键导入”链接，解析出订阅地址。各家客户端的写法不同，机场面板通常都会给
class ImportLink {
  final String url;
  final String? name;

  const ImportLink(this.url, {this.name});

  /// clash://install-config?url=...&name=...，sing-box 把名称放在 # 后面。不认识的链接返回 null
  static ImportLink? parse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) return null;

    switch (uri.scheme.toLowerCase()) {
      case 'rsproxy' || 'clash' || 'clashx' || 'clash-meta' || 'karing' || 'sing-box':
        final url = uri.queryParameters['url'];
        if (url == null || !_isHttp(url)) return null;
        final name = uri.queryParameters['name'] ?? (uri.fragment.isEmpty ? null : Uri.decodeComponent(uri.fragment));
        return ImportLink(url, name: name);
      case 'shadowrocket':
        return _shadowrocket(uri);
      case 'sub':
        return _subscription(link.trim());
      default:
        return null;
    }
  }

  /// shadowrocket://add/sub://<base64 地址>?remarks=名称
  static ImportLink? _shadowrocket(Uri uri) {
    final marker = uri.toString().indexOf('sub://');
    return marker < 0 ? null : _subscription(uri.toString().substring(marker));
  }

  static ImportLink? _subscription(String link) {
    final uri = Uri.tryParse(link);
    final body = link.substring('sub://'.length).split(RegExp(r'[?#]')).first;
    final url = ShareLink.decodeBase64(body);
    if (url == null || !_isHttp(url)) return null;
    return ImportLink(url.trim(), name: uri?.queryParameters['remarks']);
  }

  static bool _isHttp(String url) => url.startsWith('http://') || url.startsWith('https://');
}
