import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 同一局域网里两台设备之间传备份。一台开服务显示二维码，另一台扫码连过来。
///
/// 备份里有订阅地址，相当于账号，所以链接带一次性口令，没有口令的请求一律拒绝
class LanSyncLink {
  /// 对方来取备份
  static const String download = 'download';

  /// 对方把备份传过来
  static const String upload = 'upload';

  final List<String> addresses;
  final int port;
  final String token;
  final String action;

  const LanSyncLink(this.addresses, this.port, this.token, this.action);

  @override
  String toString() => Uri(scheme: 'rsproxy', host: 'sync', queryParameters: {
        'ips': addresses.join(','),
        'port': '$port',
        'token': token,
        'action': action,
      }).toString();

  /// 不是同步链接时返回 null
  static LanSyncLink? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'rsproxy' || uri.host != 'sync') return null;
    final query = uri.queryParameters;
    final port = int.tryParse(query['port'] ?? '');
    final ips = query['ips']?.split(',').where((e) => e.isNotEmpty).toList();
    final token = query['token'];
    final action = query['action'];
    if (port == null || ips == null || ips.isEmpty || token == null || token.isEmpty) return null;
    if (action != download && action != upload) return null;
    return LanSyncLink(ips, port, token, action!);
  }
}

class LanSyncServer {
  static const int _maxBytes = 100 << 20;
  static const String _path = '/backup';

  final HttpServer _server;
  final Uint8List? _outgoing;
  final void Function(Uint8List bytes)? _onReceived;
  final String _token;

  LanSyncServer._(this._server, this._outgoing, this._onReceived, this._token);

  /// 给了 [outgoing] 就等对方来取，给了 [onReceived] 就等对方传过来
  static Future<LanSyncServer> start({Uint8List? outgoing, void Function(Uint8List bytes)? onReceived}) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final random = Random.secure();
    final token = base64Url.encode(List.generate(18, (_) => random.nextInt(256)));
    return LanSyncServer._(server, outgoing, onReceived, token).._listen();
  }

  int get port => _server.port;

  LanSyncLink link(List<String> addresses) =>
      LanSyncLink(addresses, port, _token, _outgoing != null ? LanSyncLink.download : LanSyncLink.upload);

  void _listen() {
    _server.listen((request) async {
      try {
        await _handle(request);
      } on Exception {
        request.response.statusCode = HttpStatus.internalServerError;
      }
      await request.response.close();
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path == '/' && request.method == 'GET') return;
    if (request.uri.path != _path) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    if (request.uri.queryParameters['token'] != _token) {
      response.statusCode = HttpStatus.forbidden;
      return;
    }

    final outgoing = _outgoing;
    final onReceived = _onReceived;
    if (request.method == 'GET' && outgoing != null) {
      response.headers.contentType = ContentType.binary;
      response.add(outgoing);
    } else if (request.method == 'POST' && onReceived != null) {
      final body = BytesBuilder(copy: false);
      await for (final chunk in request) {
        body.add(chunk);
        if (body.length > _maxBytes) {
          response.statusCode = HttpStatus.requestEntityTooLarge;
          return;
        }
      }
      onReceived(body.takeBytes());
    } else {
      response.statusCode = HttpStatus.methodNotAllowed;
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// 另一台设备那一端
class LanSyncClient {
  static const Duration _probeTimeout = Duration(seconds: 3);
  static const Duration _transferTimeout = Duration(seconds: 30);

  /// 对方网卡可能有好几个地址，挑一个连得上的
  static Future<String?> reachable(LanSyncLink link) async {
    for (final address in link.addresses) {
      final client = HttpClient()
        ..connectionTimeout = _probeTimeout
        ..findProxy = (_) => 'DIRECT';
      try {
        final request = await client.getUrl(Uri.http('$address:${link.port}', '/')).timeout(_probeTimeout);
        final response = await request.close().timeout(_probeTimeout);
        await response.drain<void>();
        if (response.statusCode == HttpStatus.ok) return address;
      } on Exception {
        // 换下一个地址
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  static Uri _uri(LanSyncLink link, String address) =>
      Uri.http('$address:${link.port}', '/backup', {'token': link.token});

  static Future<Uint8List> download(LanSyncLink link, String address) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(_uri(link, address)).timeout(_transferTimeout);
      final response = await request.close().timeout(_transferTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('sync failed: ${response.statusCode}');
      }
      final body = BytesBuilder(copy: false);
      await response.forEach(body.add);
      return body.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> upload(LanSyncLink link, String address, Uint8List bytes) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.postUrl(_uri(link, address)).timeout(_transferTimeout);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(_transferTimeout);
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) throw HttpException('sync failed: ${response.statusCode}');
    } finally {
      client.close(force: true);
    }
  }
}
