import 'dart:io';

import 'package:flutter/services.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/util/logger.dart';

class Vpn {
  static const MethodChannel proxyVpnChannel = MethodChannel('com.proxy/proxyVpn');

  /// 代理自身的地址，证书下载页 http://proxy.pin/ssl 要经过它
  static const String _localProxyHost = '127.0.0.1';
  static const String _certificateHost = 'proxy.pin';

  static bool isVpnStarted = false; //vpn是否已经启动

  static String? _host;
  static int? _port;
  static bool _ipProxy = false;

  static List<String> _proxyPassDomains(Configuration configuration) {
    return configuration.proxyPassDomains.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// iOS 上只让这些域名走代理，其余流量不经过 App：不必为它们保活耗电，App 被挂起时也不会断网。
  /// 空列表表示全部走代理。只对本机代理生效，转发到其他设备时本机白名单不适用。
  static List<String> _proxyDomains(String host, bool? ipProxy) {
    if (!Platform.isIOS || ipProxy == true || host != _localProxyHost) {
      return const [];
    }
    final domains = HostFilter.whitelistDomains();
    return domains == null ? const [] : [...domains, _certificateHost];
  }

  /// 白名单变更后重启 VPN，否则系统还在按旧的域名分流
  static void refreshProxyDomains(Configuration configuration) {
    final host = _host, port = _port;
    if (Platform.isIOS && isVpnStarted && host != null && port != null) {
      restartVpn(host, port, configuration, ipProxy: _ipProxy);
    }
  }

  static void startVpn(String host, int port, Configuration configuration, {bool? ipProxy = false}) {
    List<String>? appList = configuration.appWhitelistEnabled ? configuration.appWhitelist : [];

    List<String>? disallowApps;
    if (appList.isEmpty) {
      disallowApps = configuration.appBlacklist ?? [];
    }

    final proxyPassDomains = _proxyPassDomains(configuration);
    logger.d("Starting VPN with host: $host, port: $port,  proxyPassDomains: $proxyPassDomains");
    proxyVpnChannel.invokeMethod("startVpn", {
      "proxyHost": host,
      "proxyPort": port,
      "allowApps": appList,
      "disallowApps": disallowApps,
      "ipProxy": ipProxy,
      "setSystemProxy": configuration.enableSystemProxy,
      "proxyPassDomains": proxyPassDomains,
      "proxyDomains": _proxyDomains(host, ipProxy),
    });
    isVpnStarted = true;
    _host = host;
    _port = port;
    _ipProxy = ipProxy == true;
  }

  static void stopVpn() {
    proxyVpnChannel.invokeMethod("stopVpn");
    isVpnStarted = false;
  }

  //重启vpn
  static void restartVpn(String host, int port, Configuration configuration, {bool ipProxy = false}) {
    List<String>? appList = configuration.appWhitelistEnabled ? configuration.appWhitelist : [];

    List<String>? disallowApps;
    if (appList.isEmpty) {
      disallowApps = configuration.appBlacklist ?? [];
    }
    final proxyPassDomains = _proxyPassDomains(configuration);
    proxyVpnChannel.invokeMethod("restartVpn", {
      "proxyHost": host,
      "proxyPort": port,
      "allowApps": appList,
      "disallowApps": disallowApps,
      "ipProxy": ipProxy,
      "setSystemProxy": configuration.enableSystemProxy,
      "proxyPassDomains": proxyPassDomains,
      "proxyDomains": _proxyDomains(host, ipProxy),
    });

    isVpnStarted = true;
    _host = host;
    _port = port;
    _ipProxy = ipProxy;
  }

  static Future<bool> isRunning() async {
    return await proxyVpnChannel.invokeMethod("isRunning");
  }
}
