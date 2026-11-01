import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/single_instance.dart';

void main() {
  group('single instance', () {
    late int port;

    setUp(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
    });

    tearDown(SingleInstance.release);

    test('the first one stays and the second hands over its command line', () async {
      final received = Completer<List<String>>();
      expect(await SingleInstance.claim(const [], onOpen: received.complete, port: port), isTrue);

      final second = await SingleInstance.claim(const ['clash://install-config?url=https://a.example/sub'], onOpen: (_) {}, port: port);

      expect(second, isFalse);
      expect(await received.future, ['clash://install-config?url=https://a.example/sub']);
    });

    test('opening again with nothing to pass still reaches the first one, to show its window', () async {
      final received = Completer<List<String>>();
      await SingleInstance.claim(const [], onOpen: received.complete, port: port);

      expect(await SingleInstance.claim(const [], onOpen: (_) {}, port: port), isFalse);
      expect(await received.future, isEmpty);
    });

    test('chinese and spaces survive the trip', () async {
      final received = Completer<List<String>>();
      await SingleInstance.claim(const [], onOpen: received.complete, port: port);

      await SingleInstance.claim(const ['rsproxy://x?name=我的 配置'], onOpen: (_) {}, port: port);

      expect(await received.future, ['rsproxy://x?name=我的 配置']);
    });

    test('a different program on the port does not stop the app from starting', () async {
      final other = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(other.close);
      other.listen((client) => client.destroy());

      expect(await SingleInstance.claim(const [], onOpen: (_) {}, port: port), isTrue);
    });

    test('a silent program on the port does not hang the launch', () async {
      final other = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(other.close);
      final clients = <Socket>[];
      other.listen(clients.add);
      addTearDown(() {
        for (final client in clients) {
          client.destroy();
        }
      });

      final stopwatch = Stopwatch()..start();
      expect(await SingleInstance.claim(const [], onOpen: (_) {}, port: port), isTrue);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('links from the command line', () {
    test('wait for the core layer when it is not up yet, and are taken once', () {
      WindowsLinks.receive(const ['--flag', 'clash://install-config?url=https://a.example/sub']);

      expect(WindowsLinks.take(), 'clash://install-config?url=https://a.example/sub');
      expect(WindowsLinks.take(), isNull);
    });

    test('anything that is not an import link is ignored', () {
      WindowsLinks.receive(const ['multi_window', 'https://a.example', 'clash://no-url-here']);
      expect(WindowsLinks.take(), isNull);
    });

    test('go straight to whoever is listening', () async {
      final platform = WindowsCorePlatform();
      final link = platform.links.first;

      WindowsLinks.receive(const ['sing-box://import-remote-profile?url=https://a.example/sub#name']);

      expect(await link, startsWith('sing-box://'));
      expect(await platform.takePendingLink(), isNull);
    });
  });

  group('registering link schemes', () {
    const exe = r'C:\Program Files\RsProxy\RsProxy.exe';

    test('the command hands the link over as one argument', () {
      expect(WindowsSchemes.commandFor(exe), r'"C:\Program Files\RsProxy\RsProxy.exe" "%1"');
    });

    test('recognises its own entry, ignoring case, and nobody else\'s', () {
      const ours = r'    (Default)    REG_SZ    "c:\program files\rsproxy\RsProxy.exe" "%1"';
      const theirs = r'    (Default)    REG_SZ    "C:\Clash\Clash.exe" "%1"';

      expect(WindowsSchemes.pointsTo(ours, exe), isTrue);
      expect(WindowsSchemes.pointsTo(theirs, exe), isFalse);
    });
  });
}
