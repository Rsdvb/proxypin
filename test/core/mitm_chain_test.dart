import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/core_config.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/http/codec.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/crts.dart';

/// Runs the whole path against real sing-box processes:
///
///   client -> mixed-in -> rs-mitm -> RsProxy -> upstream-in -> node -> origin
///
/// Needs a sing-box binary, so it only runs where SING_BOX_BIN is set (CI).
void main() {
  final singBox = Platform.environment['SING_BOX_BIN'];
  final skip = singBox == null ? 'SING_BOX_BIN is not set' : null;

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late HttpServer origin;
  late Server mitm;
  late Process nodeProcess;
  late Process clientProcess;
  late int mixedPort;
  late int clashPort;
  final nodeLog = StringBuffer();
  final captured = <String>[];

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> waitForPort(int port) async {
    // Windows runners sometimes scan a fresh sing-box.exe for longer than ten seconds
    for (var attempt = 0; attempt < 400; attempt++) {
      try {
        (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
        return;
      } on SocketException {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError('nothing listening on $port');
  }

  Future<Process> run(String name, Map<String, dynamic> config, StringBuffer log) async {
    final file = File('${work.path}/$name.json')..writeAsStringSync(jsonEncode(config));
    final process = await Process.start(singBox!, ['run', '-c', file.path, '-D', work.path]);
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);
    return process;
  }

  Future<String> fetch(String path) async {
    final client = HttpClient(
        context: SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(await CertificateManager.certificatePem())))
      ..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
    try {
      final request = await client.getUrl(Uri.parse('https://localhost:${origin.port}$path'));
      final response = await request.close();
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  setUpAll(() async {
    if (singBox == null) return;
    HttpOverrides.global = null;

    work = await Directory.systemTemp.createTemp('rsproxy_chain_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => work.path);
    await CertificateManager.initCAConfig();

    origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, await CertificateManager.getCertificateContext('localhost'));
    origin.listen((request) {
      request.response
        ..write('origin saw ${request.uri.path}')
        ..close();
    });

    final nodePort = await freePort();
    final upstreamPort = await freePort();
    final mitmPort = await freePort();
    mixedPort = await freePort();
    clashPort = await freePort();

    nodeProcess = await run(
        'node',
        {
          'log': {'level': 'info'},
          'inbounds': [
            {
              'type': 'shadowsocks',
              'listen': '127.0.0.1',
              'listen_port': nodePort,
              'method': 'aes-128-gcm',
              'password': 'chain-test',
            }
          ],
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'}
          ],
        },
        nodeLog);

    HostFilter.whitelist.enabled = true;
    HostFilter.whitelist.add('localhost');

    final configuration = Configuration.fromJson({
      'enableSsl': true,
      'enableSocks5': false,
      'enableSystemProxy': false,
      'enabledHttp2': false,
    });
    configuration.port = mitmPort;
    configuration.externalProxy = ProxyInfo.of('127.0.0.1', upstreamPort);
    mitm = Server(configuration);
    mitm.initChannel((channel) {
      channel.dispatcher.handle(HttpRequestCodec(), HttpResponseCodec(),
          HttpProxyChannelHandler(listener: _Recorder(captured), interceptors: []));
    });
    await mitm.bind(mitmPort);

    clientProcess = await run(
        'client',
        CoreConfig.build(CoreOptions(
          nodes: [
            {
              'type': 'shadowsocks',
              'tag': 'node',
              'server': '127.0.0.1',
              'server_port': nodePort,
              'method': 'aes-128-gcm',
              'password': 'chain-test',
            }
          ],
          mixedPort: mixedPort,
          upstreamPort: upstreamPort,
          mitmPort: mitmPort,
          mitmDomains: const ['localhost'],
          clashPort: clashPort,
          clashSecret: 'chain-secret',
          clashDefaultMode: CoreConfig.modeCaptureRule,
          ruleSetDirectory: 'rules',
          cachePath: '${work.path}/cache.db',
          logLevel: 'info',
        )),
        StringBuffer());

    await Future.wait([nodePort, mixedPort, upstreamPort, clashPort].map(waitForPort));
  });

  tearDownAll(() async {
    if (singBox == null) return;
    clientProcess.kill();
    nodeProcess.kill();
    // Windows keeps the folder locked until the processes are really gone
    await clientProcess.exitCode;
    await nodeProcess.exitCode;
    await mitm.stop();
    await origin.close(force: true);
    try {
      await work.delete(recursive: true);
    } on FileSystemException {
      // a leftover temp folder is harmless
    }
  });

  test('a listed domain is decrypted, then leaves through the node', () async {
    final body = await fetch('/decrypted');

    expect(body, 'origin saw /decrypted');
    expect(captured, contains('/decrypted'), reason: 'RsProxy saw the request in the clear');
    expect(nodeLog.toString(), contains('localhost'), reason: 'the node carried it to the origin');
  }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));

  test('turning capture off needs no reload and takes decryption out of the path', () async {
    final api = ClashApi(port: clashPort, secret: 'chain-secret');
    addTearDown(api.close);
    await api.setMode(CoreConfig.modeRule);
    expect(await api.mode(), CoreConfig.modeRule, reason: 'sing-box must have accepted the switch');

    final body = await fetch('/passthrough');

    expect(body, 'origin saw /passthrough');
    expect(captured, isNot(contains('/passthrough')));
  }, skip: skip, timeout: const Timeout(Duration(seconds: 30)));
}

class _Recorder extends EventListener {
  final List<String> paths;

  _Recorder(this.paths);

  @override
  void onRequest(Channel channel, HttpRequest request) {
    paths.add(request.requestUri?.path ?? request.uri);
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {}
}
