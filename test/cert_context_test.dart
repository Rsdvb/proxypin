import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/util/cert/x509.dart';
import 'package:proxypin/network/util/crts.dart';

/// Leaf certificates are signed on a background isolate. These cover what that
/// must keep true: the certificates still chain to the CA, concurrent handshakes
/// share one signature, and a context with no trusted roots can serve TLS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('proxypin_cert_');
    await File('test/fixtures/certs/ca.crt').copy('${supportDir.path}/ca.crt');
    await File('test/fixtures/certs/ca_key.pem').copy('${supportDir.path}/ca_key.pem');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => supportDir.path);
    await CertificateManager.initCAConfig();
  });

  tearDownAll(() async {
    await supportDir.delete(recursive: true);
  });

  setUp(CertificateManager.cleanCache);

  Future<X509Certificate> handshake(String host) async {
    final context = await CertificateManager.getCertificateContext(host);
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(server.close);
    server.listen((socket) => socket.listen((_) {}, onError: (_) {}));

    final client =
        await SecureSocket.connect(InternetAddress.loopbackIPv4, server.port, onBadCertificate: (_) => true);
    addTearDown(client.destroy);
    return client.peerCertificate!;
  }

  test('a generated context serves TLS for its host', () async {
    final certificate = await handshake('perf.example.test');
    expect(certificate.subject, contains('perf.example.test'));
  });

  test('the leaf issuer matches the CA subject byte for byte', () async {
    final certificate = await handshake('issuer.example.test');
    final caBytes = X509Utils.subjectDnBytesFromPem(await CertificateManager.certificatePem());
    expect(_issuerDn(certificate.der), caBytes);
  });

  test('concurrent handshakes for one host share a single context', () async {
    final contexts = await Future.wait(
        List.generate(8, (_) => CertificateManager.getCertificateContext('shared.example.test')));
    expect(contexts.toSet(), hasLength(1));
    expect(CertificateManager.get('shared.example.test'), same(contexts.first));
  });

  test('different hosts get their own context', () async {
    final results = await Future.wait(
        ['a.example.test', 'b.example.test'].map(CertificateManager.getCertificateContext));
    expect(results.first, isNot(same(results.last)));
  });

  test('signing does not hold up the calling isolate', () async {
    var ticks = 0;
    final timer = Timer.periodic(Duration.zero, (_) => ticks++);
    addTearDown(timer.cancel);

    await CertificateManager.getCertificateContext('responsive.example.test');

    // A blocking signature would leave the event loop no chance to run.
    expect(ticks, greaterThan(2));
  });

  test('a signature still running when the cache is cleared is not cached', () async {
    final stale = await () {
      final pending = CertificateManager.getCertificateContext('stale.example.test');
      CertificateManager.cleanCache();
      return pending;
    }();
    expect(await CertificateManager.getCertificateContext('stale.example.test'), isNot(same(stale)));
  });

  test('a plain signature finishing late does not replace the remote-cert one', () async {
    const host = 'late.example.test';
    final origin = await handshake('origin.example.test');

    final plain = CertificateManager.getCertificateContext(host);
    expect(await CertificateManager.generateByRemoteCert(host, origin), isTrue);
    final fromRemote = await CertificateManager.getCertificateContext(host);

    await plain;
    expect(await CertificateManager.getCertificateContext(host), same(fromRemote));
  });

  test('each ALPN list gets its own context and reuses the signature', () async {
    const host = 'alpn.example.test';
    final h2 = await CertificateManager.getCertificateContext(host, alpnProtocols: ['h2', 'http/1.1']);
    final h1 = await CertificateManager.getCertificateContext(host, alpnProtocols: ['http/1.1']);
    final none = await CertificateManager.getCertificateContext(host);
    expect({h2, h1, none}, hasLength(3));

    expect(await CertificateManager.getCertificateContext(host, alpnProtocols: ['h2', 'http/1.1']), same(h2));
    expect(CertificateManager.get(host, alpnProtocols: ['http/1.1']), same(h1));
  });

  test('concurrent handshakes with different ALPN lists each get their own protocol', () async {
    const host = 'alpn-race.example.test';

    Future<SecureServerSocket> serve(List<String> protocols) async {
      final context = await CertificateManager.getCertificateContext(host, alpnProtocols: protocols);
      final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
      addTearDown(server.close);
      server.listen((socket) => socket.listen((_) {}, onError: (_) {}));
      return server;
    }

    final h2 = await serve(['h2']), h1 = await serve(['http/1.1']);

    Future<String?> negotiate(SecureServerSocket server) async {
      final client = await SecureSocket.connect(InternetAddress.loopbackIPv4, server.port,
          onBadCertificate: (_) => true, supportedProtocols: const ['h2', 'http/1.1']);
      final selected = client.selectedProtocol;
      client.destroy();
      return selected;
    }

    final results = await Future.wait([for (var i = 0; i < 40; i++) negotiate(i.isEven ? h2 : h1)]);
    for (var i = 0; i < results.length; i++) {
      expect(results[i], i.isEven ? 'h2' : 'http/1.1', reason: 'connection $i');
    }
  });

  test('a host can be signed again after the cache is cleared', () async {
    final first = await CertificateManager.getCertificateContext('again.example.test');
    CertificateManager.cleanCache();
    final second = await CertificateManager.getCertificateContext('again.example.test');
    expect(second, isNot(same(first)));
    expect(CertificateManager.get('again.example.test'), same(second));
  });
}

/// Extracts the raw issuer Name from a DER certificate:
/// Certificate ::= SEQ { tbsCertificate SEQ { [0] version, serial, sigAlg, issuer, ... } ... }
List<int> _issuerDn(List<int> der) {
  (int, int) header(int offset) {
    var length = der[offset + 1];
    var size = 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7F;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length << 8 | der[offset + 2 + i];
      }
      size += count;
    }
    return (size, length);
  }

  int skip(int offset) {
    final (size, length) = header(offset);
    return offset + size + length;
  }

  final tbs = 0 + header(0).$1;
  var offset = tbs + header(tbs).$1;
  offset = skip(offset); // [0] version
  offset = skip(offset); // serial
  offset = skip(offset); // signature algorithm
  return der.sublist(offset, skip(offset));
}
