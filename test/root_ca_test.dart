import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/util/crts.dart';

/// The app ships no root certificate: a private key in a public repository would
/// let anyone impersonate any site to whoever trusts it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;

  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('rsproxy_ca_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => supportDir.path);
    await CertificateManager.generateNewRootCA();
    await File('${supportDir.path}/ca.crt').delete();
    await File('${supportDir.path}/ca_key.pem').delete();
  });

  tearDown(() async {
    await supportDir.delete(recursive: true);
  });

  test('the bundle no longer carries a root certificate', () {
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('assets/certs')));
  });

  test('first use creates one certificate and key, even when asked concurrently', () async {
    final files = await Future.wait(
        [CertificateManager.certificateFile(), CertificateManager.privateKeyFile(), CertificateManager.certificateFile()]);
    expect(files[0].path, files[2].path);
    expect(await files[0].exists(), isTrue);
    expect(await files[1].exists(), isTrue);

    final pem = await files[0].readAsString();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(pem.codeUnits)
      ..usePrivateKeyBytes((await files[1].readAsString()).codeUnits);
    expect(context, isNotNull, reason: 'certificate and key must be a pair');
  });

  test('a leaf signed by the generated root verifies against it', () async {
    await CertificateManager.initCAConfig();
    final caPem = await CertificateManager.certificatePem();

    final context = await CertificateManager.getCertificateContext('localhost');
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(server.close);
    server.listen((socket) => socket.listen((_) {}, onError: (_) {}));

    // No onBadCertificate: the handshake only succeeds if the chain really verifies.
    final trust = SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(caPem.codeUnits);
    final client = await SecureSocket.connect('localhost', server.port, context: trust);
    addTearDown(client.destroy);
    expect(client.peerCertificate!.issuer, contains('RsProxy CA'));
  });

  test('two installs do not share a root', () async {
    final first = await CertificateManager.certificatePem();
    await CertificateManager.generateNewRootCA();
    expect(await CertificateManager.certificatePem(), isNot(first));
  });
}
