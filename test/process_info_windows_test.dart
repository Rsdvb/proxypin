@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/util/process_info.dart';
import 'package:proxypin/network/util/process_info_windows.dart';
import 'package:proxypin/network/util/socket_address.dart';

void main() {
  late ServerSocket server;
  late Socket client;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((_) {});
    client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  });

  tearDown(() async {
    client.destroy();
    await server.close();
  });

  test('finds the owner of a connected socket by its local endpoint', () {
    expect(WindowsProcessInfo.findPidByLocalTcpEndpoint(client.address, client.port), pid);
  });

  test('ignores a port nobody is connected on', () {
    // The listening port has no connected row with this local address and
    // a port of 1 is never an ephemeral client port.
    expect(WindowsProcessInfo.findPidByLocalTcpEndpoint(InternetAddress.loopbackIPv4, 1), isNull);
  });

  test('does not match another local address on the same port', () {
    expect(WindowsProcessInfo.findPidByLocalTcpEndpoint(InternetAddress('192.0.2.1'), client.port), isNull);
  });

  test('skips IPv6 addresses instead of misreading them', () {
    expect(WindowsProcessInfo.findPidByLocalTcpEndpoint(InternetAddress.loopbackIPv6, client.port), isNull);
  });

  test('resolves the executable path of a PID', () {
    expect(WindowsProcessInfo.getProcessPath(pid), Platform.resolvedExecutable);
  });

  test('returns null for a PID that does not exist', () {
    expect(WindowsProcessInfo.getProcessPath(0x7FFFFFFC), isNull);
  });

  test('getProcessByPort resolves through the FFI lookups', () async {
    final info =
        await ProcessInfoUtils.getProcessByPort(InetSocketAddress(client.address, client.port), 'process-info-test');
    expect(info?.path, Platform.resolvedExecutable);
    expect(info?.id, Platform.resolvedExecutable.split(r'\').last);
  });
}
