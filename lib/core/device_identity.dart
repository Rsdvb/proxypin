import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// 限制设备数的机场（如 Remnawave）按这几个请求头计数，只有打开 X-HWID 的配置才发。
/// x-hwid 用安装时生成的随机值，不读取任何硬件标识。
class DeviceIdentity {
  static Future<Map<String, String>> headers(String deviceId) async {
    final headers = {'x-hwid': deviceId};
    final plugin = DeviceInfoPlugin();
    try {
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        headers['x-device-os'] = 'iOS';
        headers['x-ver-os'] = info.systemVersion;
        headers['x-device-model'] = info.modelName;
      } else if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        headers['x-device-os'] = 'Windows';
        headers['x-ver-os'] = '${info.majorVersion}.${info.minorVersion}';
        headers['x-device-model'] = info.productName;
      }
    } catch (_) {
      // 只有 x-hwid 是必需的，其余取不到就不发
    }
    return headers;
  }
}
