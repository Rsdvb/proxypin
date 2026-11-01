import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dns_catalog.dart';

/// 经内核的探测入站发出去。用户名决定走直连还是当前节点，只有连接时才有
class ProbeRoute {
  final int port;
  final String user;
  final String password;

  /// 走当前节点。系统 DNS 没法经节点查询
  final bool viaNode;

  const ProbeRoute(this.port, this.user, this.password, {required this.viaNode});
}

/// 真的发一次 DNS 查询量耗时。内核没有开放查询单个服务器的接口，所以自己发。
///
/// 连接时必须经探测入站：应用自己的 UDP 请求会进隧道被内核接管，量到的是内核，不是那台服务器。
/// HTTP 代理的 CONNECT 又不能带 UDP，这时 udp:// 改用同一地址的 TCP 53。
/// Dart 没有 HTTP/3 和 QUIC，h3 和 quic 分别用同一服务器的 HTTPS 和 TLS 代替
class DnsProbe {
  /// 这条路测不了，和失败区分开
  static const int unsupported = -1;
  static const Duration _timeout = Duration(seconds: 3);
  static final Random _random = Random();

  /// 耗时（毫秒），失败返回 null，测不了返回 [unsupported]
  static Future<int?> measure(String url, String domain, {ProbeRoute? route}) async {
    final stopwatch = Stopwatch()..start();
    try {
      if (url == DnsCatalog.local || url == DnsCatalog.dhcp) {
        if (route?.viaNode == true) return unsupported;
        await InternetAddress.lookup(domain).timeout(_timeout);
        return stopwatch.elapsedMilliseconds;
      }

      final uri = Uri.tryParse(url.contains('://') ? url : 'udp://$url');
      if (uri == null || uri.host.isEmpty) return null;
      final id = _random.nextInt(0x10000);
      final answered = await _exchange(uri, encodeQuery(domain, id), id, route).timeout(_timeout);
      return answered ? stopwatch.elapsedMilliseconds : null;
    } on Exception {
      return null;
    }
  }

  static Uint8List encodeQuery(String domain, int id) {
    final bytes = BytesBuilder()..add([id >> 8, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in domain.split('.')) {
      final encoded = utf8.encode(label);
      bytes
        ..addByte(encoded.length)
        ..add(encoded);
    }
    return (bytes..add([0, 0, 1, 0, 1])).takeBytes();
  }

  /// 是对这次查询的应答，而且没有报错
  static bool isAnswer(List<int> response, int id) =>
      response.length >= 12 &&
      response[0] == id >> 8 &&
      response[1] == id & 0xff &&
      response[2] & 0x80 != 0 &&
      response[3] & 0x0f == 0;

  static Future<bool> _exchange(Uri uri, Uint8List query, int id, ProbeRoute? route) {
    int port(int fallback) => uri.hasPort ? uri.port : fallback;
    return switch (uri.scheme) {
      'https' || 'h3' => _https(uri, query, id, route),
      'tls' || 'quic' => _stream(uri.host, port(853), query, id, route, secure: true),
      'tcp' => _stream(uri.host, port(53), query, id, route),
      _ => route == null ? _udp(uri.host, port(53), query, id) : _stream(uri.host, port(53), query, id, route),
    };
  }

  static Future<bool> _udp(String host, int port, Uint8List query, int id) async {
    final target = InternetAddress.tryParse(host) ?? (await InternetAddress.lookup(host)).first;
    final socket = await RawDatagramSocket.bind(
        target.type == InternetAddressType.IPv4 ? InternetAddress.anyIPv4 : InternetAddress.anyIPv6, 0);
    try {
      socket.send(query, target, port);
      await for (final event in socket.timeout(_timeout)) {
        final datagram = event == RawSocketEvent.read ? socket.receive() : null;
        if (datagram != null && isAnswer(datagram.data, id)) return true;
      }
      return false;
    } finally {
      socket.close();
    }
  }

  static Future<bool> _https(Uri uri, Uint8List query, int id, ProbeRoute? route) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..badCertificateCallback = (_, __, ___) => true;
    if (route != null) {
      client.findProxy = (_) => 'PROXY ${route.user}:${route.password}@127.0.0.1:${route.port}';
    }
    try {
      final target = uri.replace(scheme: 'https', path: uri.path.isEmpty ? '/dns-query' : uri.path);
      final request = await client.postUrl(target);
      request.headers
        ..contentType = ContentType('application', 'dns-message')
        ..set(HttpHeaders.acceptHeader, 'application/dns-message');
      request.add(query);
      final response = await request.close();
      final body = BytesBuilder(copy: false);
      await response.forEach(body.add);
      return response.statusCode == HttpStatus.ok && isAnswer(body.takeBytes(), id);
    } finally {
      client.close(force: true);
    }
  }

  /// TCP 和 TLS。升级 TLS 要用原始套接字：Socket 取消监听时会关掉读方向，CONNECT 的回复读完就没法接着用了
  static Future<bool> _stream(String host, int port, Uint8List query, int id, ProbeRoute? route, {bool secure = false}) async {
    var socket = await RawSocket.connect(route == null ? host : InternetAddress.loopbackIPv4, route?.port ?? port,
        timeout: _timeout);
    try {
      var subscription = route == null ? null : await _openTunnel(socket, host, port, route);
      if (secure) {
        socket = await RawSecureSocket.secure(socket, subscription: subscription, host: host, onBadCertificate: (_) => true);
        subscription = null;
      }
      return await _framed(socket, subscription, query, id);
    } finally {
      socket.close();
    }
  }

  static Future<StreamSubscription<RawSocketEvent>> _openTunnel(RawSocket socket, String host, int port, ProbeRoute route) {
    final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
    final credentials = base64.encode(utf8.encode('${route.user}:${route.password}'));
    final request = ascii.encode('CONNECT $target HTTP/1.1\r\nHost: $target\r\nProxy-Authorization: Basic $credentials\r\n\r\n');
    final opened = Completer<StreamSubscription<RawSocketEvent>>();
    final reply = BytesBuilder();
    var sent = 0;
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = socket.listen((event) {
      if (opened.isCompleted) return;
      if (event == RawSocketEvent.write) {
        sent += socket.write(request, sent);
        if (sent < request.length) socket.writeEventsEnabled = true;
      } else if (event == RawSocketEvent.read) {
        reply.add(socket.read() ?? const []);
        final text = latin1.decode(reply.toBytes());
        if (!text.contains('\r\n\r\n')) return;
        if (text.startsWith(RegExp(r'HTTP/\d\.\d 200'))) {
          opened.complete(subscription);
        } else {
          opened.completeError(const SocketException('tunnel refused'));
        }
      } else {
        opened.completeError(const SocketException('tunnel closed'));
      }
    }, onError: (Object error) {
      if (!opened.isCompleted) opened.completeError(error);
    });
    return opened.future;
  }

  /// DNS over TCP：前面两个字节是长度
  static Future<bool> _framed(RawSocket socket, StreamSubscription<RawSocketEvent>? subscription, Uint8List query, int id) {
    final framed = Uint8List(query.length + 2)
      ..[0] = query.length >> 8
      ..[1] = query.length & 0xff
      ..setRange(2, query.length + 2, query);
    final done = Completer<bool>();
    final received = BytesBuilder();
    var sent = 0;

    void onEvent(RawSocketEvent event) {
      if (done.isCompleted) return;
      if (event == RawSocketEvent.write) {
        sent += socket.write(framed, sent);
        if (sent < framed.length) socket.writeEventsEnabled = true;
      } else if (event == RawSocketEvent.read) {
        received.add(socket.read() ?? const []);
        final data = received.toBytes();
        if (data.length >= 2 && data.length >= (data[0] << 8 | data[1]) + 2) done.complete(isAnswer(data.sublist(2), id));
      } else {
        done.complete(false);
      }
    }

    void onError(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    if (subscription == null) {
      socket.listen(onEvent, onError: onError);
    } else {
      subscription
        ..onData(onEvent)
        ..onError(onError);
    }
    socket.writeEventsEnabled = true;
    return done.future;
  }
}
