import 'dart:io';

/// 开机自启，写在当前用户的 Run 项里，不需要管理员权限
class WindowsAutostart {
  static const String _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _name = 'RsProxy';

  static Future<bool> isEnabled() async {
    final result = await Process.run('reg', ['query', _key, '/v', _name]);
    return result.exitCode == 0;
  }

  static Future<void> setEnabled(bool enabled) async {
    final result = enabled
        ? await Process.run(
            'reg', ['add', _key, '/v', _name, '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}"', '/f'])
        : await Process.run('reg', ['delete', _key, '/v', _name, '/f']);
    if (result.exitCode != 0) {
      throw ProcessException('reg', const [], result.stderr.toString(), result.exitCode);
    }
  }
}
