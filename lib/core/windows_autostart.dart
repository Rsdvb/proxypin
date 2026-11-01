import 'dart:ffi';
import 'dart:io';

/// TUN 要创建虚拟网卡，Windows 上需要管理员权限
class WindowsAdmin {
  static bool isAdmin() {
    if (!Platform.isWindows) return true;
    final isUserAnAdmin =
        DynamicLibrary.open('shell32.dll').lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
    return isUserAnAdmin() != 0;
  }
}

/// 局域网共享要放行入站。写防火墙规则需要管理员权限，普通权限下由系统第一次弹窗询问
class WindowsFirewall {
  static const String _rule = 'RsProxy';

  static String get _program => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}sing-box.exe';

  static Future<bool> allow() async {
    await Process.run('netsh', ['advfirewall', 'firewall', 'delete', 'rule', 'name=$_rule']);
    final result = await Process.run(
        'netsh', ['advfirewall', 'firewall', 'add', 'rule', 'name=$_rule', 'dir=in', 'action=allow', 'program=$_program', 'enable=yes']);
    return result.exitCode == 0;
  }

  static Future<void> remove() => Process.run('netsh', ['advfirewall', 'firewall', 'delete', 'rule', 'name=$_rule']);
}

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
