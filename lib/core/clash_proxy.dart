import 'share_link.dart';

/// Clash 配置 proxies 里的一项转 outbound
class ClashProxy {
  /// 协议或传输方式不支持时返回 null
  static Outbound? parse(Map map) {
    final proxy = map.map((key, value) => MapEntry(key.toString(), value));
    final name = _string(proxy['name']);
    final server = _string(proxy['server']);
    final port = _int(proxy['port']);
    if (name == null || server == null || port == null) return null;

    try {
      final outbound = switch (_string(proxy['type'])?.toLowerCase()) {
        'ss' || 'shadowsocks' => _shadowsocks(proxy),
        'vmess' => _vmess(proxy),
        'vless' => _vless(proxy),
        'trojan' => _trojan(proxy),
        'hysteria2' || 'hy2' => _hysteria2(proxy),
        'tuic' => _tuic(proxy),
        'anytls' => _anytls(proxy),
        'socks5' => _socks(proxy),
        'http' => _http(proxy),
        _ => null,
      };
      if (outbound == null) return null;
      return {'tag': name, 'server': server, 'server_port': port, ...outbound};
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static Outbound? _shadowsocks(Map<String, dynamic> proxy) {
    final cipher = _string(proxy['cipher']);
    final password = _string(proxy['password']);
    if (cipher == null || password == null) return null;

    final plugin = _string(proxy['plugin']);
    final options = _map(proxy['plugin-opts']);
    String? pluginName;
    String? pluginOptions;
    switch (plugin) {
      case null:
        break;
      case 'obfs':
        pluginName = 'obfs-local';
        pluginOptions = [
          'obfs=${_string(options['mode']) ?? 'http'}',
          if (_string(options['host']) != null) 'obfs-host=${_string(options['host'])}',
        ].join(';');
      case 'v2ray-plugin':
        pluginName = 'v2ray-plugin';
        pluginOptions = [
          'mode=${_string(options['mode']) ?? 'websocket'}',
          if (options['tls'] == true) 'tls',
          if (_string(options['host']) != null) 'host=${_string(options['host'])}',
          if (_string(options['path']) != null) 'path=${_string(options['path'])}',
        ].join(';');
      default:
        // shadow-tls 等要拆成两个 outbound，暂不支持
        return null;
    }

    return {
      'type': 'shadowsocks',
      'method': cipher,
      'password': password,
      if (pluginName != null) 'plugin': pluginName,
      if (pluginOptions != null) 'plugin_opts': pluginOptions,
    };
  }

  static Outbound? _vmess(Map<String, dynamic> proxy) {
    final uuid = _string(proxy['uuid']);
    if (uuid == null) return null;
    return {
      'type': 'vmess',
      'uuid': uuid,
      'security': _string(proxy['cipher']) ?? 'auto',
      'alter_id': _int(proxy['alterId']) ?? 0,
      'packet_encoding': 'xudp',
      if (proxy['tls'] == true) 'tls': _tls(proxy),
      ..._transport(proxy),
    };
  }

  static Outbound? _vless(Map<String, dynamic> proxy) {
    final uuid = _string(proxy['uuid']);
    if (uuid == null) return null;
    final flow = _string(proxy['flow']);
    return {
      'type': 'vless',
      'uuid': uuid,
      if (flow != null) 'flow': flow,
      'packet_encoding': 'xudp',
      if (proxy['tls'] == true) 'tls': _tls(proxy),
      ..._transport(proxy),
    };
  }

  static Outbound? _trojan(Map<String, dynamic> proxy) {
    final password = _string(proxy['password']);
    if (password == null) return null;
    return {
      'type': 'trojan',
      'password': password,
      // Clash 的 trojan 默认走 TLS
      if (proxy['tls'] != false) 'tls': _tls(proxy),
      ..._transport(proxy),
    };
  }

  static Outbound? _hysteria2(Map<String, dynamic> proxy) {
    final password = _string(proxy['password']) ?? _string(proxy['auth']);
    if (password == null) return null;
    final ports = ShareLink.hopPorts(_string(proxy['ports']));
    final obfs = _string(proxy['obfs']);
    final up = _bandwidth(proxy['up']), down = _bandwidth(proxy['down']);
    return {
      'type': 'hysteria2',
      'password': password,
      if (ports.isNotEmpty) 'server_ports': ports,
      if (up != null) 'up_mbps': up,
      if (down != null) 'down_mbps': down,
      if (obfs != null) 'obfs': {'type': obfs, 'password': _string(proxy['obfs-password']) ?? ''},
      'tls': _tls(proxy),
    };
  }

  static Outbound? _tuic(Map<String, dynamic> proxy) {
    final uuid = _string(proxy['uuid']), password = _string(proxy['password']);
    // 没有 uuid 的是 TUIC v4，sing-box 不支持
    if (uuid == null || password == null) return null;
    final congestion = _string(proxy['congestion-controller']);
    final relay = _string(proxy['udp-relay-mode']);
    return {
      'type': 'tuic',
      'uuid': uuid,
      'password': password,
      if (congestion != null) 'congestion_control': congestion,
      if (relay != null) 'udp_relay_mode': relay,
      if (proxy['reduce-rtt'] == true) 'zero_rtt_handshake': true,
      'tls': _tls(proxy),
    };
  }

  static Outbound? _anytls(Map<String, dynamic> proxy) {
    final password = _string(proxy['password']);
    if (password == null) return null;
    return {'type': 'anytls', 'password': password, 'tls': _tls(proxy)};
  }

  static Outbound _socks(Map<String, dynamic> proxy) => {
        'type': 'socks',
        'version': '5',
        ..._credentials(proxy),
      };

  static Outbound _http(Map<String, dynamic> proxy) => {
        'type': 'http',
        ..._credentials(proxy),
        if (proxy['tls'] == true) 'tls': _tls(proxy),
      };

  static Outbound _credentials(Map<String, dynamic> proxy) {
    final username = _string(proxy['username']), password = _string(proxy['password']);
    return {
      if (username != null) 'username': username,
      if (password != null) 'password': password,
    };
  }

  static Map<String, dynamic> _tls(Map<String, dynamic> proxy) {
    final reality = _map(proxy['reality-opts']);
    return ShareLink.tls(
      serverName: _string(proxy['servername']) ?? _string(proxy['sni']),
      insecure: proxy['skip-cert-verify'] == true,
      alpn: (proxy['alpn'] as List?)?.map((e) => e.toString()).toList(),
      fingerprint: _string(proxy['client-fingerprint']),
      publicKey: _string(reality['public-key']),
      shortId: _string(reality['short-id']),
    );
  }

  static Outbound _transport(Map<String, dynamic> proxy) {
    final network = _string(proxy['network']);
    Outbound? transport;
    switch (network?.toLowerCase()) {
      case 'ws':
        final options = _map(proxy['ws-opts']);
        final headers = _map(options['headers']);
        transport = ShareLink.transport('ws',
            path: _string(options['path']),
            headers: headers.isEmpty ? null : headers,
            maxEarlyData: _int(options['max-early-data']),
            earlyDataHeader: _string(options['early-data-header-name']));
      case 'grpc':
        transport = ShareLink.transport('grpc', serviceName: _string(_map(proxy['grpc-opts'])['grpc-service-name']));
      case 'h2':
        final options = _map(proxy['h2-opts']);
        final hosts = (options['host'] as List?)?.join(',');
        transport = ShareLink.transport('http', host: hosts, path: _string(options['path']));
      case 'http':
        final options = _map(proxy['http-opts']);
        final paths = options['path'] as List?;
        final hosts = (_map(options['headers'])['Host'] as List?)?.join(',');
        transport = ShareLink.transport('http', host: hosts, path: paths?.first?.toString());
      default:
        transport = ShareLink.transport(network);
    }
    return transport == null ? const {} : {'transport': transport};
  }

  static String? _string(Object? value) {
    final text = value?.toString();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _int(Object? value) => value is int ? value : int.tryParse(value?.toString() ?? '');

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? value.map((key, value) => MapEntry(key.toString(), value)) : const {};

  /// Clash 的带宽写法：100、"100"、"100 Mbps"
  static int? _bandwidth(Object? value) {
    final match = RegExp(r'\d+').stringMatch(value?.toString() ?? '');
    return match == null ? null : int.parse(match);
  }
}
