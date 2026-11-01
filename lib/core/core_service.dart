import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/logger.dart';

import 'core_manager.dart';
import 'core_platform.dart';
import 'core_settings.dart';
import 'proxy_server_mitm.dart';

/// 应用启动时调用一次
class CoreService {
  /// [CoreManager.instance] 可用后完成
  static Future<void> start(ProxyServer proxyServer) async {
    if (CoreManager.isReady) return;

    final support = await getApplicationSupportDirectory();
    final mitm = ProxyServerMitm(proxyServer);
    // 证书安装页由它提供，解密没开时也要在，所以先于自动连接启动
    try {
      await proxyServer.start();
    } on SocketException catch (e) {
      logger.e('proxy server failed to start: $e');
    }

    final manager = CoreManager(
      platform: CorePlatform.current(),
      store: CoreStore(Directory('${support.path}${Platform.pathSeparator}core_data')),
      mitm: mitm,
      alwaysTun: Platform.isIOS,
      loadRuleSet: _bundledRuleSet,
    );
    await manager.load();
    CoreManager.instance = manager;

    if (manager.settings.autoConnect) unawaited(manager.connect());
    manager.startAutoUpdate();
    unawaited(manager.updateDueProfiles().catchError((e) => logger.w('profile update failed: $e')));
  }

  static Future<Uint8List?> _bundledRuleSet(String name) async {
    try {
      final data = await rootBundle.load('assets/rules/$name.srs');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on FlutterError {
      return null;
    }
  }
}
