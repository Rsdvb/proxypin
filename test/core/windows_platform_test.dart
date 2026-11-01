import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/core_platform.dart';

/// Starts the real sing-box.exe the way the app does. Needs SING_BOX_BIN, so CI only.
void main() {
  final singBox = Platform.environment['SING_BOX_BIN'];
  final skip = singBox == null || !Platform.isWindows ? 'needs sing-box on Windows' : null;

  late Directory work;

  setUp(() {
    work = Directory.systemTemp.createTempSync('rsproxy_platform_');
  });

  tearDown(() {
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      // ignored
    }
  });

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<bool> listening(int port) async {
    try {
      (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> writeConfig(int port) async {
    File('${work.path}/config.json').writeAsStringSync(jsonEncode({
      'inbounds': [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': port}
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'}
      ],
    }));
  }

  test('runs the core, and stopping releases its port', () async {
    final port = await freePort();
    await writeConfig(port);
    final platform = WindowsCorePlatform(executable: singBox, workingDirectory: work);

    await platform.start();
    expect(await platform.isRunning(), isTrue);
    for (var attempt = 0; attempt < 50 && !await listening(port); attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(await listening(port), isTrue);

    await platform.stop();
    expect(await listening(port), isFalse);
    expect(await platform.isRunning(), isFalse);
  }, skip: skip);

  test('reports when the core exits by itself', () async {
    File('${work.path}/config.json').writeAsStringSync('{"inbounds": "broken"}');
    final platform = WindowsCorePlatform(executable: singBox, workingDirectory: work);
    final stopped = platform.states.firstWhere((state) => state == CoreState.stopped);

    await platform.start();

    await stopped.timeout(const Duration(seconds: 10));
    expect(await platform.isRunning(), isFalse);
  }, skip: skip);

  test('reloading picks up a new configuration', () async {
    final first = await freePort();
    final second = await freePort();
    await writeConfig(first);
    final platform = WindowsCorePlatform(executable: singBox, workingDirectory: work);
    addTearDown(platform.stop);

    await platform.start();
    await writeConfig(second);
    await platform.reload();
    for (var attempt = 0; attempt < 50 && !await listening(second); attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    expect(await listening(second), isTrue);
    expect(await listening(first), isFalse);
  }, skip: skip);
}
