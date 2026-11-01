import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/channel_dispatcher.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/handle/relay_handle.dart';
import 'package:proxypin/network/http/codec.dart';
import 'package:proxypin/network/http/http.dart';

const _relayHost = '127.0.0.1';

class _Capture extends EventListener {
  final responses = <HttpResponse>[];

  @override
  void onRequest(Channel channel, HttpRequest request) {}

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) => responses.add(response);
}

/// A TCP client that collects everything it reads and can wait for a byte count.
class _Client {
  final Socket socket;
  final _received = BytesBuilder(copy: false);
  final _done = Completer<void>();
  Completer<void>? _waiter;
  int _expected = 0;

  _Client(this.socket) {
    socket.listen((data) {
      _received.add(data);
      _check();
    }, onDone: () {
      if (!_done.isCompleted) _done.complete();
      _check();
    }, onError: (_) {});
  }

  void _check() {
    if (_waiter != null && (_received.length >= _expected || _done.isCompleted)) {
      _waiter!.complete();
      _waiter = null;
    }
  }

  int get length => _received.length;

  Future<void> waitFor(int bytes) {
    _expected = bytes;
    _waiter = Completer<void>();
    _check();
    return _waiter!.future.timeout(const Duration(seconds: 20));
  }

  Future<void> get done => _done.future.timeout(const Duration(seconds: 20));

  Uint8List take() => _received.takeBytes();
}

Uint8List _pattern(int length, [int seed = 0]) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i ~/ 251 + i * 7 + seed) & 255;
  }
  return bytes;
}

void main() {
  late Server proxy;
  late ServerSocket origin;
  late _Capture capture;
  late int proxyPort;
  final accepted = <Socket>[];
  late void Function(Socket) onOriginAccept;

  setUp(() async {
    accepted.clear();
    capture = _Capture();
    // A filtered host is what switches a CONNECT tunnel to raw relay; other
    // tunnels to a non-443 port keep being parsed as HTTP.
    HostFilter.blacklist.add(_relayHost);

    origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((socket) {
      accepted.add(socket);
      onOriginAccept(socket);
    });

    final config = Configuration.fromJson({
      'enableSsl': false,
      'enableSocks5': false,
      'enableSystemProxy': false,
      'enabledHttp2': false,
    });
    proxy = Server(config, listener: capture);
    proxy.initChannel((channel) {
      channel.dispatcher.handle(
        HttpRequestCodec(),
        HttpResponseCodec(),
        HttpProxyChannelHandler(listener: capture, interceptors: []),
      );
    });
    final serverSocket = await proxy.bind(0);
    proxyPort = serverSocket.port;
  });

  tearDown(() async {
    HostFilter.blacklist.remove(_relayHost);
    for (final socket in accepted) {
      socket.destroy();
    }
    await proxy.stop();
    await origin.close();
  });

  Future<_Client> connectTunnel() async {
    final client = _Client(await Socket.connect(InternetAddress.loopbackIPv4, proxyPort));
    final target = '$_relayHost:${origin.port}';
    client.socket.write('CONNECT $target HTTP/1.1\r\nHost: $target\r\n\r\n');
    await client.waitFor(1);
    expect(utf8.decode(client.take()), startsWith('HTTP/1.1 200'));
    return client;
  }

  test('a tunnel carries bytes both ways, in order and exactly once', () async {
    onOriginAccept = (socket) => socket.listen(socket.add, onError: (_) {});

    final client = await connectTunnel();
    final payload = _pattern(6 * 1024 * 1024);

    // Irregular writes so the proxy sees many differently sized read events,
    // some before and some after the relay has been set up.
    var offset = 0, step = 1;
    while (offset < payload.length) {
      final end = (offset + step).clamp(0, payload.length);
      client.socket.add(Uint8List.sublistView(payload, offset, end));
      offset = end;
      step = step * 3 % 70001 + 1;
      if (offset % 7 == 0) await client.socket.flush();
    }

    await client.waitFor(payload.length);
    expect(client.length, payload.length);
    expect(client.take(), payload);
    client.socket.destroy();
  });

  test('a tunnel keeps relaying a first byte that looks like another protocol', () async {
    onOriginAccept = (socket) => socket.listen(socket.add, onError: (_) {});

    final client = await connectTunnel();

    // Once tunnelled, bytes must never be sniffed as TLS or SOCKS5 again.
    for (final bytes in [
      [0x16, 0x03, 0x01, 0x00, 0x05, 1, 2, 3],
      [0x05, 0x01, 0x00],
    ]) {
      client.socket.add(bytes);
      await client.socket.flush();
      await client.waitFor(bytes.length);
      expect(client.take(), bytes);
    }
    client.socket.destroy();
  });

  test('closing the origin closes the tunnel', () async {
    onOriginAccept = (socket) {
      socket.listen((_) {
        socket.add(utf8.encode('bye'));
        socket.close();
      }, onError: (_) {});
    };

    final client = await connectTunnel();
    client.socket.add([1]);
    await client.socket.flush();

    await client.done;
    expect(utf8.decode(client.take()), 'bye');
    client.socket.destroy();
  });

  group('oversized response', () {
    setUp(() => HostFilter.blacklist.remove(_relayHost));

    Future<_Client> request() async {
      final client = _Client(await Socket.connect(InternetAddress.loopbackIPv4, proxyPort));
      client.socket.write('GET http://$_relayHost:${origin.port}/big HTTP/1.1\r\n'
          'Host: $_relayHost:${origin.port}\r\n\r\n');
      return client;
    }

    test('reaches the client before the body has been buffered', () async {
      const length = Codec.maxBodyLength + 1024;
      final headers = 'HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: $length\r\n\r\n';
      final release = Completer<void>();
      onOriginAccept = (socket) {
        socket.listen((_) async {
          // Far less than the buffering limit, then wait for the client.
          socket.add(utf8.encode(headers));
          socket.add(_pattern(64 * 1024));
          await socket.flush();
          await release.future;
          socket.add(_pattern(length - 64 * 1024));
        }, onError: (_) {});
      };

      final client = await request();
      await client.waitFor(headers.length + 64 * 1024);
      expect(client.length, greaterThanOrEqualTo(headers.length + 64 * 1024));
      expect(capture.responses, hasLength(1));
      expect(capture.responses.single.status.code, 200);

      release.complete();
      await client.waitFor(headers.length + length);
      expect(client.length, headers.length + length);
      client.socket.destroy();
    });

    test('a body within the limit is still parsed and reported whole', () async {
      const length = 256 * 1024;
      final body = _pattern(length);
      onOriginAccept = (socket) {
        socket.listen((_) {
          socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: $length\r\n\r\n'));
          socket.add(body);
        }, onError: (_) {});
      };

      final client = await request();
      await client.waitFor(length);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(capture.responses.single.body, body);
      client.socket.destroy();
    });
  });

  test('relay state requires both the relay handler and the raw codec', () {
    final dispatcher = ChannelDispatcher()..handle(HttpRequestCodec(), HttpResponseCodec(), _NoopHandler());
    expect(dispatcher.isRawRelay, isFalse);

    final remote = Channel(_NullSocket());
    dispatcher.handler = RelayHandler(remote);
    expect(dispatcher.isRawRelay, isFalse, reason: 'bytes are still decoded until relay() swaps the codec');

    dispatcher.channelHandle(RawCodec(), RelayHandler(remote));
    expect(dispatcher.isRawRelay, isTrue);
  });
}

class _NoopHandler extends ChannelHandler<Object> {}

class _NullSocket implements Socket {
  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;

  @override
  int get remotePort => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
