import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/http/codec.dart';

/// A relayed download must not outrun a client that reads slowly: without
/// backpressure the proxy reads the whole file into memory.
void main() {
  const host = '127.0.0.1';
  const total = 256 * 1024 * 1024;

  late Server proxy;
  late ServerSocket origin;
  late int proxyPort;
  final accepted = <Socket>[];

  setUp(() async {
    accepted.clear();
    HostFilter.blacklist.add(host);
    final config = Configuration.fromJson({'enableSsl': false, 'enableSocks5': false, 'enableSystemProxy': false});
    proxy = Server(config);
    proxy.initChannel((channel) {
      channel.dispatcher.handle(
        HttpRequestCodec(),
        HttpResponseCodec(),
        HttpProxyChannelHandler(listener: null, interceptors: []),
      );
    });
    proxyPort = (await proxy.bind(0)).port;
    origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    HostFilter.blacklist.remove(host);
    for (final socket in accepted) {
      socket.destroy();
    }
    await proxy.stop();
    await origin.close();
  });

  /// Completes on the client's first byte. The relay is only set up then, so an
  /// origin that speaks earlier would be parsed as an HTTP response.
  Future<void> firstByteFrom(Socket socket) {
    final started = Completer<void>();
    socket.listen((_) {
      if (!started.isCompleted) started.complete();
    }, onError: (_) {});
    return started.future;
  }

  /// Opens a tunnel and consumes the CONNECT reply through [iterator], which
  /// reads nothing further until the test asks it to.
  Future<(Socket, StreamIterator<Uint8List>)> connect() async {
    final client = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
    final iterator = StreamIterator(client);
    client.write('CONNECT $host:${origin.port} HTTP/1.1\r\nHost: $host:${origin.port}\r\n\r\n');
    await iterator.moveNext();
    expect(utf8.decode(iterator.current), startsWith('HTTP/1.1 200'));
    return (client, iterator);
  }

  test('a stalled client stops the proxy reading from the origin', () async {
    final chunk = Uint8List(64 * 1024);
    var sent = 0;
    var finished = false;

    origin.listen((socket) async {
      accepted.add(socket);
      await firstByteFrom(socket);
      while (sent < total) {
        socket.add(chunk);
        await socket.flush();
        sent += chunk.length;
      }
      finished = true;
      await socket.close();
    });

    final (client, iterator) = await connect();
    addTearDown(client.destroy);
    client.add([1]);
    await client.flush();

    await Future.delayed(const Duration(seconds: 2));
    expect(finished, isFalse, reason: 'origin wrote everything although nobody was reading');
    final stalledAt = sent;
    expect(stalledAt, lessThan(total ~/ 4));

    await Future.delayed(const Duration(milliseconds: 500));
    expect(sent - stalledAt, lessThan(Channel.writeHighWaterMark + chunk.length * 4), reason: 'origin is still flowing');

    var received = 0;
    while (received < total && await iterator.moveNext()) {
      received += iterator.current.length;
    }
    expect(received, total);
    expect(finished, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('every byte arrives in order through repeated throttling', () async {
    final payload = Uint8List(32 * 1024 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i ~/ 509 + i) & 255;
    }

    origin.listen((socket) async {
      accepted.add(socket);
      await firstByteFrom(socket);
      socket.add(payload);
      await socket.close();
    });

    final (client, iterator) = await connect();
    addTearDown(client.destroy);
    client.add([1]);

    final received = BytesBuilder(copy: false);
    var nextPause = 1024 * 1024;
    while (received.length < payload.length && await iterator.moveNext()) {
      received.add(iterator.current);
      if (received.length > nextPause) {
        nextPause += 4 * 1024 * 1024;
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(received.length, payload.length);
    expect(received.takeBytes(), payload);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the tunnel closes cleanly when the origin ends while throttled', () async {
    final chunk = Uint8List(1024 * 1024);
    origin.listen((socket) async {
      accepted.add(socket);
      await firstByteFrom(socket);
      for (var i = 0; i < 16; i++) {
        socket.add(chunk);
      }
      await socket.close();
    });

    final (client, iterator) = await connect();
    addTearDown(client.destroy);
    client.add([1]);

    await Future.delayed(const Duration(milliseconds: 300));
    var received = 0;
    while (await iterator.moveNext().timeout(const Duration(seconds: 15))) {
      received += iterator.current.length;
    }
    expect(received, 16 * chunk.length);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
