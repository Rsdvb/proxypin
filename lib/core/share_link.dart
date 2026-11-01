import 'dart:convert';

/// sing-box 的 outbound 配置，节点在 App 里一律以这种形式保存
typedef Outbound = Map<String, dynamic>;

/// 分享链接转 outbound
class ShareLink {
  static const Set<String> _schemes = {
    'ss',
    'vmess',
    'vless',
    'trojan',
    'hysteria2',
    'hy2',
    'tuic',
    'anytls',
    'socks',
    'socks5',
  };

  static bool isLink(String text) {
    final index = text.indexOf('://');
    return index > 0 && _schemes.contains(text.substring(0, index).toLowerCase());
  }

  /// 协议或传输方式不支持时返回 null
  static Outbound? parse(String link) {
    final text = link.trim();
    if (!isLink(text)) return null;

    try {
      return switch (text.substring(0, text.indexOf('://')).toLowerCase()) {
        'ss' => _shadowsocks(text),
        'vmess' => _vmess(text),
        'vless' => _vless(text),
        'trojan' => _trojan(text),
        'hysteria2' || 'hy2' => _hysteria2(text),
        'tuic' => _tuic(text),
        'anytls' => _anytls(text),
        _ => _socks(text),
      };
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static Outbound _shadowsocks(String text) {
    var link = _Link.parse(text);
    // 旧格式把 method:password@host:port 整个 base64
    if (link.userInfo.isEmpty) {
      final decoded = decodeBase64(link.raw);
      if (decoded == null || !decoded.contains('@')) throw const FormatException('ss');
      link = _Link.parse('ss://$decoded').withName(link.name);
    }

    final plain = _percentDecode(link.userInfo);
    final credentials = plain.contains(':') ? plain : decodeBase64(link.userInfo);
    final separator = credentials?.indexOf(':') ?? -1;
    if (credentials == null || separator <= 0) throw const FormatException('ss credentials');

    final plugin = link.query['plugin'];
    final pluginName = plugin?.split(';').first;
    return {
      'type': 'shadowsocks',
      'tag': link.tag('ss'),
      'server': link.host,
      'server_port': link.port,
      'method': credentials.substring(0, separator),
      'password': credentials.substring(separator + 1),
      if (pluginName != null && pluginName.isNotEmpty) 'plugin': pluginName,
      if (plugin != null && plugin.contains(';')) 'plugin_opts': plugin.substring(plugin.indexOf(';') + 1),
    };
  }

  static Outbound _vmess(String text) {
    final body = text.substring(text.indexOf('://') + 3).split('#').first.split('?').first;
    final decoded = decodeBase64(body);
    if (decoded == null) throw const FormatException('vmess');
    final json = jsonDecode(decoded) as Map<String, dynamic>;

    String? field(String key) {
      final value = json[key]?.toString();
      return value == null || value.isEmpty ? null : value;
    }

    final server = field('add'), id = field('id');
    final port = int.tryParse(field('port') ?? '');
    if (server == null || id == null || port == null) throw const FormatException('vmess fields');

    final network = field('net');
    return {
      'type': 'vmess',
      'tag': field('ps') ?? 'vmess-$server:$port',
      'server': server,
      'server_port': port,
      'uuid': id,
      'security': field('scy') ?? 'auto',
      'alter_id': int.tryParse(field('aid') ?? '') ?? 0,
      'packet_encoding': 'xudp',
      if (field('tls') == 'tls')
        'tls': tls(
            serverName: field('sni') ?? field('host'),
            insecure: field('allowInsecure') == '1' || field('skip-cert-verify') == 'true',
            alpn: field('alpn')?.split(','),
            fingerprint: field('fp')),
      ..._withTransport(transport(network,
          host: field('host'), path: field('path'), serviceName: field('path'), headerType: field('type'))),
    };
  }

  static Outbound _vless(String text) {
    final link = _Link.parse(text);
    final query = link.query;
    final security = query['security'] ?? '';
    return {
      'type': 'vless',
      'tag': link.tag('vless'),
      'server': link.host,
      'server_port': link.port,
      'uuid': _percentDecode(link.userInfo),
      if (query['flow']?.isNotEmpty == true) 'flow': query['flow'],
      'packet_encoding': query['packetEncoding'] ?? 'xudp',
      if (security == 'tls' || security == 'reality' || security == 'xtls')
        'tls': tls(
            serverName: query['sni'] ?? query['peer'],
            insecure: link.insecure,
            alpn: query['alpn']?.split(','),
            fingerprint: query['fp'],
            publicKey: query['pbk'],
            shortId: query['sid']),
      ..._withTransport(transport(query['type'],
          host: query['host'],
          path: query['path'],
          serviceName: query['serviceName'],
          headerType: query['headerType'])),
    };
  }

  static Outbound _trojan(String text) {
    final link = _Link.parse(text);
    final query = link.query;
    return {
      'type': 'trojan',
      'tag': link.tag('trojan'),
      'server': link.host,
      'server_port': link.port,
      'password': _percentDecode(link.userInfo),
      if (query['security'] != 'none')
        'tls': tls(
            serverName: query['sni'] ?? query['peer'],
            insecure: link.insecure,
            alpn: query['alpn']?.split(','),
            fingerprint: query['fp'],
            publicKey: query['pbk'],
            shortId: query['sid']),
      ..._withTransport(transport(query['type'],
          host: query['host'],
          path: query['path'],
          serviceName: query['serviceName'],
          headerType: query['headerType'])),
    };
  }

  static Outbound _hysteria2(String text) {
    final link = _Link.parse(text);
    final query = link.query;
    final ports = hopPorts(query['mport'] ?? link.portList);
    return {
      'type': 'hysteria2',
      'tag': link.tag('hysteria2'),
      'server': link.host,
      'server_port': link.port,
      if (ports.isNotEmpty) 'server_ports': ports,
      'password': _percentDecode(link.userInfo),
      if (query['obfs']?.isNotEmpty == true)
        'obfs': {'type': query['obfs'], 'password': query['obfs-password'] ?? ''},
      'tls': tls(
          serverName: query['sni'] ?? query['peer'],
          insecure: link.insecure,
          alpn: query['alpn']?.split(','),
          fingerprint: query['fp']),
    };
  }

  static Outbound _tuic(String text) {
    final link = _Link.parse(text);
    final query = link.query;
    final separator = link.userInfo.indexOf(':');
    if (separator <= 0) throw const FormatException('tuic credentials');
    return {
      'type': 'tuic',
      'tag': link.tag('tuic'),
      'server': link.host,
      'server_port': link.port,
      'uuid': _percentDecode(link.userInfo.substring(0, separator)),
      'password': _percentDecode(link.userInfo.substring(separator + 1)),
      if (query['congestion_control']?.isNotEmpty == true) 'congestion_control': query['congestion_control'],
      if (query['udp_relay_mode']?.isNotEmpty == true) 'udp_relay_mode': query['udp_relay_mode'],
      'tls': tls(serverName: query['sni'], insecure: link.insecure, alpn: query['alpn']?.split(',')),
    };
  }

  static Outbound _anytls(String text) {
    final link = _Link.parse(text);
    final query = link.query;
    return {
      'type': 'anytls',
      'tag': link.tag('anytls'),
      'server': link.host,
      'server_port': link.port,
      'password': _percentDecode(link.userInfo),
      'tls': tls(
          serverName: query['sni'],
          insecure: link.insecure,
          alpn: query['alpn']?.split(','),
          fingerprint: query['fp']),
    };
  }

  static Outbound _socks(String text) {
    final link = _Link.parse(text);
    final plain = _percentDecode(link.userInfo);
    final credentials = plain.contains(':') ? plain : (decodeBase64(link.userInfo) ?? plain);
    final separator = credentials.indexOf(':');
    return {
      'type': 'socks',
      'tag': link.tag('socks'),
      'server': link.host,
      'server_port': link.port,
      'version': '5',
      if (separator > 0) 'username': credentials.substring(0, separator),
      if (separator > 0) 'password': credentials.substring(separator + 1),
    };
  }

  static Outbound _withTransport(Outbound? transport) => transport == null ? const {} : {'transport': transport};

  /// TLS 配置，分享链接和 Clash 共用
  static Map<String, dynamic> tls({
    String? serverName,
    bool insecure = false,
    List<String>? alpn,
    String? fingerprint,
    String? publicKey,
    String? shortId,
  }) {
    final reality = publicKey != null && publicKey.isNotEmpty;
    // REALITY 依赖 uTLS，没有指定指纹时也要开
    final fp = fingerprint?.isNotEmpty == true ? fingerprint! : (reality ? 'chrome' : '');
    return {
      'enabled': true,
      if (serverName?.isNotEmpty == true) 'server_name': serverName,
      if (insecure) 'insecure': true,
      if (alpn != null && alpn.any((e) => e.isNotEmpty)) 'alpn': alpn.where((e) => e.isNotEmpty).toList(),
      if (fp.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fp},
      if (reality) 'reality': {'enabled': true, 'public_key': publicKey, 'short_id': shortId ?? ''},
    };
  }

  /// 传输层配置，分享链接和 Clash 共用。普通 TCP 返回 null，sing-box 不支持的方式抛 [FormatException]
  static Outbound? transport(
    String? network, {
    String? host,
    String? path,
    String? serviceName,
    String? headerType,
    Map<String, dynamic>? headers,
    int? maxEarlyData,
    String? earlyDataHeader,
  }) {
    final hosts = host?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList() ?? const [];

    switch ((network ?? 'tcp').toLowerCase()) {
      case '' || 'tcp' || 'raw':
        if (headerType != 'http') return null;
        return {
          'type': 'http',
          if (hosts.isNotEmpty) 'host': hosts,
          if (path?.isNotEmpty == true) 'path': path,
        };
      case 'ws' || 'websocket':
        var wsPath = path ?? '/';
        var earlyData = maxEarlyData;
        var header = earlyDataHeader;
        // xray 把 early data 写在路径里：/ws?ed=2560
        final mark = wsPath.indexOf('?');
        if (mark >= 0) {
          final query = Uri.splitQueryString(wsPath.substring(mark + 1));
          final ed = int.tryParse(query['ed'] ?? '');
          if (ed != null) {
            earlyData ??= ed;
            header ??= 'Sec-WebSocket-Protocol';
            query.remove('ed');
            wsPath = wsPath.substring(0, mark);
            if (query.isNotEmpty) wsPath = '$wsPath?${Uri(queryParameters: query).query}';
          }
        }
        return {
          'type': 'ws',
          'path': wsPath,
          if (headers != null && headers.isNotEmpty) 'headers': headers,
          if ((headers == null || headers.isEmpty) && hosts.isNotEmpty) 'headers': {'Host': hosts.first},
          if (earlyData != null && earlyData > 0) 'max_early_data': earlyData,
          if (earlyData != null && earlyData > 0 && header?.isNotEmpty == true) 'early_data_header_name': header,
        };
      case 'grpc':
        return {'type': 'grpc', 'service_name': serviceName ?? ''};
      case 'http' || 'h2':
        return {
          'type': 'http',
          if (hosts.isNotEmpty) 'host': hosts,
          if (path?.isNotEmpty == true) 'path': path,
        };
      case 'httpupgrade':
        return {
          'type': 'httpupgrade',
          if (hosts.isNotEmpty) 'host': hosts.first,
          if (path?.isNotEmpty == true) 'path': path,
          if (headers != null && headers.isNotEmpty) 'headers': headers,
        };
      case 'quic':
        return {'type': 'quic'};
      default:
        throw FormatException('unsupported transport: $network');
    }
  }

  /// hysteria2 端口跳跃：443,8000-9000 -> [443:443, 8000:9000]
  static List<String> hopPorts(String? ports) {
    if (ports == null || !(ports.contains(',') || ports.contains('-'))) return const [];
    return ports.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).map((e) {
      final range = e.split('-');
      return range.length == 2 ? '${range[0]}:${range[1]}' : '$e:$e';
    }).toList();
  }

  /// base64 或 base64url，不要求补齐。解不开或不是文本时返回 null
  static String? decodeBase64(String text) {
    var normalized = text.trim().replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
    normalized = normalized.replaceAll('=', '');
    if (normalized.isEmpty || normalized.length % 4 == 1) return null;
    normalized = normalized.padRight(normalized.length + (4 - normalized.length % 4) % 4, '=');
    try {
      return utf8.decode(base64.decode(normalized));
    } on FormatException {
      return null;
    }
  }

  static String _percentDecode(String text) {
    try {
      return Uri.decodeComponent(text);
    } on ArgumentError {
      return text;
    }
  }
}

/// 分享链接的各个部分。密码里常有 Uri 不接受的字符，hysteria2 的端口也可能是一个列表，所以手工拆
class _Link {
  /// 去掉 scheme、查询参数和名称后的部分
  final String raw;
  final String userInfo;
  final String host;
  final int port;

  /// 端口原文，hysteria2 的端口跳跃要用
  final String portList;
  final Map<String, String> query;
  final String name;

  _Link(this.raw, this.userInfo, this.host, this.port, this.portList, this.query, this.name);

  bool get insecure =>
      const ['allowInsecure', 'insecure', 'allow_insecure', 'skip-cert-verify'].any((key) {
        final value = query[key];
        return value == '1' || value == 'true';
      });

  String tag(String type) => name.isNotEmpty ? name : '$type-$host:$port';

  _Link withName(String value) => _Link(raw, userInfo, host, port, portList, query, value);

  factory _Link.parse(String text) {
    var rest = text.substring(text.indexOf('://') + 3);

    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = ShareLink._percentDecode(rest.substring(hash + 1)).trim();
      rest = rest.substring(0, hash);
    }

    final query = <String, String>{};
    final mark = rest.indexOf('?');
    if (mark >= 0) {
      for (final pair in rest.substring(mark + 1).split('&')) {
        final equals = pair.indexOf('=');
        if (equals > 0) {
          query[pair.substring(0, equals)] = ShareLink._percentDecode(pair.substring(equals + 1));
        }
      }
      rest = rest.substring(0, mark);
    }

    // 密码里可能有 @，以最后一个为准
    final at = rest.lastIndexOf('@');
    final userInfo = at >= 0 ? rest.substring(0, at) : '';
    var authority = at >= 0 ? rest.substring(at + 1) : rest;
    final slash = authority.indexOf('/');
    if (slash >= 0) authority = authority.substring(0, slash);

    var host = '';
    var ports = '';
    if (authority.startsWith('[')) {
      final end = authority.indexOf(']');
      if (end > 0) {
        host = authority.substring(1, end);
        if (end + 2 <= authority.length) ports = authority.substring(end + 2);
      }
    } else {
      final colon = authority.indexOf(':');
      if (colon > 0) {
        host = authority.substring(0, colon);
        ports = authority.substring(colon + 1);
      }
    }

    // 旧格式 ss 没有 @，这里解析不出端口也不报错，由调用方解码后再解析
    final port = int.tryParse(RegExp(r'^\d+').stringMatch(ports) ?? '');
    if (userInfo.isNotEmpty && (host.isEmpty || port == null || port <= 0 || port > 65535)) {
      throw FormatException('invalid address: $authority');
    }
    return _Link(rest, userInfo, host, port ?? 0, ports, query, name);
  }
}
