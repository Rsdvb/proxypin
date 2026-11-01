import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/profile_parser.dart';
import 'package:proxypin/core/share_link.dart';

void main() {
  group('share links', () {
    test('shadowsocks in SIP002 form', () {
      final userInfo = base64Url.encode(utf8.encode('aes-128-gcm:secret')).replaceAll('=', '');
      final outbound = ShareLink.parse('ss://$userInfo@example.com:8388#HK%2001')!;
      expect(outbound, containsPair('type', 'shadowsocks'));
      expect(outbound, containsPair('tag', 'HK 01'));
      expect(outbound, containsPair('server', 'example.com'));
      expect(outbound, containsPair('server_port', 8388));
      expect(outbound, containsPair('method', 'aes-128-gcm'));
      expect(outbound, containsPair('password', 'secret'));
    });

    test('shadowsocks in legacy form keeps its name', () {
      final body = base64.encode(utf8.encode('chacha20-ietf-poly1305:pa@ss@example.com:443'));
      final outbound = ShareLink.parse('ss://$body#old')!;
      expect(outbound, containsPair('tag', 'old'));
      expect(outbound, containsPair('password', 'pa@ss'));
      expect(outbound, containsPair('server', 'example.com'));
      expect(outbound, containsPair('server_port', 443));
    });

    test('shadowsocks 2022 keeps the key as plain text', () {
      final outbound = ShareLink.parse('ss://2022-blake3-aes-128-gcm:YWJj%2BZGVm%3D@1.2.3.4:443#x')!;
      expect(outbound, containsPair('method', '2022-blake3-aes-128-gcm'));
      expect(outbound, containsPair('password', 'YWJj+ZGVm='));
    });

    test('shadowsocks plugin is split into name and options', () {
      final userInfo = base64.encode(utf8.encode('aes-128-gcm:p'));
      final outbound = ShareLink.parse('ss://$userInfo@h.example:1?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Da.com#n')!;
      expect(outbound, containsPair('plugin', 'obfs-local'));
      expect(outbound, containsPair('plugin_opts', 'obfs=http;obfs-host=a.com'));
    });

    test('vmess over websocket with TLS', () {
      final body = base64.encode(utf8.encode(jsonEncode({
        'v': '2',
        'ps': 'JP',
        'add': 'vm.example',
        'port': '443',
        'id': '11111111-1111-1111-1111-111111111111',
        'aid': '0',
        'net': 'ws',
        'host': 'cdn.example',
        'path': '/ws?ed=2560',
        'tls': 'tls',
        'sni': 'sni.example',
      })));
      final outbound = ShareLink.parse('vmess://$body')!;
      expect(outbound, containsPair('tag', 'JP'));
      expect(outbound, containsPair('server_port', 443));
      expect(outbound['tls'], containsPair('server_name', 'sni.example'));
      expect(outbound['transport'], {
        'type': 'ws',
        'path': '/ws',
        'headers': {'Host': 'cdn.example'},
        'max_early_data': 2560,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      });
    });

    test('vless with reality', () {
      final outbound = ShareLink.parse('vless://11111111-1111-1111-1111-111111111111@r.example:443'
          '?security=reality&sni=www.apple.com&fp=safari&pbk=PUB&sid=ab&flow=xtls-rprx-vision&type=tcp#R')!;
      expect(outbound, containsPair('flow', 'xtls-rprx-vision'));
      expect(outbound['tls'], {
        'enabled': true,
        'server_name': 'www.apple.com',
        'utls': {'enabled': true, 'fingerprint': 'safari'},
        'reality': {'enabled': true, 'public_key': 'PUB', 'short_id': 'ab'},
      });
      expect(outbound.containsKey('transport'), isFalse);
    });

    test('vless reality without a fingerprint still enables uTLS', () {
      final outbound = ShareLink.parse('vless://u@r.example:443?security=reality&pbk=PUB#R')!;
      expect(outbound['tls']['utls'], {'enabled': true, 'fingerprint': 'chrome'});
    });

    test('trojan defaults to TLS and honours allowInsecure', () {
      final outbound = ShareLink.parse('trojan://p%40ss@t.example:443?sni=s.example&allowInsecure=1#T')!;
      expect(outbound, containsPair('password', 'p@ss'));
      expect(outbound['tls'], {'enabled': true, 'server_name': 's.example', 'insecure': true});
    });

    test('hysteria2 with obfuscation and port hopping', () {
      final outbound = ShareLink.parse('hy2://pass@h.example:443,8000-9000/?sni=s.example&obfs=salamander&obfs-password=o#H')!;
      expect(outbound, containsPair('type', 'hysteria2'));
      expect(outbound, containsPair('server_port', 443));
      expect(outbound['server_ports'], ['443:443', '8000:9000']);
      expect(outbound['obfs'], {'type': 'salamander', 'password': 'o'});
    });

    test('tuic splits uuid and password', () {
      final outbound =
          ShareLink.parse('tuic://uuid-1:pw@t.example:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=s#T')!;
      expect(outbound, containsPair('uuid', 'uuid-1'));
      expect(outbound, containsPair('password', 'pw'));
      expect(outbound, containsPair('congestion_control', 'bbr'));
      expect(outbound['tls']['alpn'], ['h3']);
    });

    test('anytls and socks', () {
      expect(ShareLink.parse('anytls://pw@a.example:443?sni=s#A'), containsPair('type', 'anytls'));
      final socks = ShareLink.parse('socks5://user:pw@s.example:1080#S')!;
      expect(socks, containsPair('username', 'user'));
      expect(socks, containsPair('password', 'pw'));
    });

    test('IPv6 hosts', () {
      final outbound = ShareLink.parse('trojan://p@[2001:db8::1]:443#v6')!;
      expect(outbound, containsPair('server', '2001:db8::1'));
      expect(outbound, containsPair('server_port', 443));
    });

    test('a node with no name is labelled by its address', () {
      expect(ShareLink.parse('trojan://p@t.example:443'), containsPair('tag', 'trojan-t.example:443'));
    });

    test('unsupported transports are skipped, not guessed at', () {
      expect(ShareLink.parse('vless://u@x.example:443?type=xhttp&security=tls#X'), isNull);
      expect(ShareLink.parse('vmess://not-base64'), isNull);
      expect(ShareLink.parse('https://example.com/sub'), isNull);
      expect(ShareLink.parse('trojan://p@no-port#x'), isNull);
    });
  });

  group('profiles', () {
    const links = 'trojan://p@a.example:443#A\nvless://u@b.example:443?security=tls#B\n';

    test('plain share links', () {
      final profile = ProfileParser.parse(links);
      expect(profile.outbounds.map((e) => e['tag']), ['A', 'B']);
      expect(profile.skipped, 0);
    });

    test('base64 subscription', () {
      final profile = ProfileParser.parse(base64.encode(utf8.encode(links)));
      expect(profile.outbounds, hasLength(2));
    });

    test('nodes it cannot read are counted', () {
      final profile = ProfileParser.parse('$links vless://u@c.example:443?type=xhttp#C');
      expect(profile.outbounds, hasLength(2));
      expect(profile.skipped, 1);
    });

    test('clash yaml', () {
      final profile = ProfileParser.parse('''
port: 7890
proxies:
  - {name: SS, type: ss, server: s.example, port: 8388, cipher: aes-128-gcm, password: pw}
  - name: VM
    type: vmess
    server: v.example
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
    alterId: 0
    cipher: auto
    tls: true
    servername: sni.example
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: cdn.example
  - name: VL
    type: vless
    server: r.example
    port: 443
    uuid: 22222222-2222-2222-2222-222222222222
    flow: xtls-rprx-vision
    tls: true
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: PUB
      short-id: ab
  - {name: HY, type: hysteria2, server: h.example, port: 443, password: pw, ports: 8000-9000, up: 50 Mbps, down: "100"}
  - {name: TU, type: tuic, server: t.example, port: 443, uuid: u, password: p, alpn: [h3], congestion-controller: bbr}
  - {name: TR, type: trojan, server: tr.example, port: 443, password: pw, sni: s.example, skip-cert-verify: true}
  - {name: OLD, type: tuic, server: t.example, port: 443, token: only-v4}
  - {name: SNELL, type: snell, server: s.example, port: 443, psk: x}
proxy-groups:
  - {name: G, type: select, proxies: [SS]}
rules:
  - MATCH,G
''');
      expect(profile.outbounds.map((e) => e['tag']), ['SS', 'VM', 'VL', 'HY', 'TU', 'TR']);
      expect(profile.skipped, 2);

      final vm = profile.outbounds[1];
      expect(vm['transport'], {
        'type': 'ws',
        'path': '/ws',
        'headers': {'Host': 'cdn.example'},
      });
      expect(vm['tls'], containsPair('server_name', 'sni.example'));

      final vl = profile.outbounds[2];
      expect(vl['tls']['reality'], {'enabled': true, 'public_key': 'PUB', 'short_id': 'ab'});

      final hy = profile.outbounds[3];
      expect(hy['server_ports'], ['8000:9000']);
      expect(hy['up_mbps'], 50);
      expect(hy['down_mbps'], 100);

      expect(profile.outbounds[5]['tls'], containsPair('insecure', true));
    });

    test('sing-box json keeps only real nodes', () {
      final profile = ProfileParser.parse(jsonEncode({
        'outbounds': [
          {'type': 'selector', 'tag': 'select', 'outbounds': ['a']},
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'shadowsocks', 'tag': 'a', 'server': 's', 'server_port': 1, 'method': 'none', 'password': ''},
        ],
      }));
      expect(profile.outbounds.map((e) => e['tag']), ['a']);
    });

    test('duplicate and reserved names are made unique', () {
      final profile = ProfileParser.parse('trojan://p@a.example:443#HK\ntrojan://p@b.example:443#HK\n'
          'trojan://p@c.example:443#direct\n');
      expect(profile.outbounds.map((e) => e['tag']), ['HK', 'HK 2', 'direct 2']);
    });

    test('garbage is rejected', () {
      expect(() => ProfileParser.parse(''), throwsFormatException);
      expect(() => ProfileParser.parse('hello world'), throwsFormatException);
      expect(() => ProfileParser.parse('{"a":1}'), throwsFormatException);
      expect(() => ProfileParser.parse('proxies: not-a-list'), throwsFormatException);
    });
  });
}
