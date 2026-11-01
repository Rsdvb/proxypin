import 'dart:io';

import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/util/logger.dart';

class Vpn {
  static const MethodChannel proxyVpnChannel = MethodChannel('com.proxy/proxyVpn');

  static bool isVpnStarted = false; //vpn是否已经启动

  static List<String> _proxyPassDomains(Configuration configuration) {
    return configuration.proxyPassDomains.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// 白名单变更后重新生成内核配置，否则还在按旧的域名分流
  static void refreshProxyDomains(Configuration configuration) {
    if (CoreManager.isReady) {
      CoreManager.instance.reloadConfig();
    }
  }

  static void startVpn(String host, int port, Configuration configuration, {bool? ipProxy = false}) {
    // iOS 上隧道由 sing-box 负责，抓包按钮只控制解密
    if (Platform.isIOS) {
      CoreManager.instance.setCapture(true);
      isVpnStarted = true;
      return;
    }

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
    });
    isVpnStarted = true;
  }

  static void stopVpn() {
    isVpnStarted = false;
    if (Platform.isIOS) {
      CoreManager.instance.setCapture(false);
      return;
    }
    proxyVpnChannel.invokeMethod("stopVpn");
  }

  //重启vpn
  static void restartVpn(String host, int port, Configuration configuration, {bool ipProxy = false}) {
    if (Platform.isIOS) return;

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
    });

    isVpnStarted = true;
  }

  static Future<bool> isRunning() async {
    if (Platform.isIOS) return CoreManager.isReady && CoreManager.instance.settings.capture;
    return await proxyVpnChannel.invokeMethod("isRunning");
  }
}
