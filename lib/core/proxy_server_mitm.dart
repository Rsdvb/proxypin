import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/host_filter.dart';

import 'core_manager.dart';

/// 用 RsProxy 自己的代理服务做解密端
class ProxyServerMitm implements MitmHost {
  /// 证书安装页，它由代理服务本身提供，也要进解密端
  static const String _certificateHost = 'proxy.pin';

  final ProxyServer server;

  ProxyServerMitm(this.server) {
    // 只解密名单里的域名，其余流量根本不进 RsProxy
    HostFilter.whitelist.enabled = true;
    // 上网都走 sing-box，系统代理由它负责
    server.configuration.enableSystemProxy = false;
    // 上次退出时可能还连着 sing-box
    server.configuration.externalProxy = null;
  }

  @override
  int get port => server.port;

  @override
  List<String>? get domains {
    if (HostFilter.whitelist.list.isEmpty) return const [_certificateHost];
    final domains = HostFilter.whitelistDomains();
    return domains == null ? null : [...domains, _certificateHost];
  }

  @override
  Future<void> attach(int upstreamPort) async {
    server.configuration
      ..externalProxy = ProxyInfo.of('127.0.0.1', upstreamPort)
      ..enableSsl = true;
    if (!server.isRunning) {
      await server.start();
    }
  }

  @override
  Future<void> detach() async {
    server.configuration.externalProxy = null;
  }
}
