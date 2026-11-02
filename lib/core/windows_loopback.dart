import 'dart:convert';
import 'dart:io';

/// 一个 UWP 应用的网络隔离容器
class AppContainer {
  final String sid;
  final String name;
  final String moniker;

  const AppContainer(this.sid, this.name, this.moniker);
}

/// UWP 应用默认不能访问本机地址，所以连不上本机的代理端口。
/// CheckNetIsolation 给它们开回环豁免，要管理员权限
class WindowsLoopback {
  static const String _mappings =
      r'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Mappings';

  /// 本机所有的容器，按名称排序
  static Future<List<AppContainer>> containers() async {
    const script = '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-ChildItem '$_mappings' | ForEach-Object {
  \$item = Get-ItemProperty \$_.PSPath
  [pscustomobject]@{ sid = \$_.PSChildName; name = \$item.DisplayName; moniker = \$item.Moniker }
} | ConvertTo-Json -Compress
''';
    final result = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script],
        stdoutEncoding: utf8);
    if (result.exitCode != 0) throw ProcessException('powershell', const [], result.stderr.toString(), result.exitCode);
    return parseContainers(result.stdout.toString());
  }

  /// PowerShell 只有一项时输出对象而不是数组。DisplayName 可能是 @{...} 资源引用，这时用 moniker
  static List<AppContainer> parseContainers(String json) {
    if (json.trim().isEmpty) return const [];
    final decoded = jsonDecode(json);
    final items = decoded is List ? decoded : [decoded];
    final containers = [
      for (final item in items.cast<Map<String, dynamic>>())
        () {
          final moniker = item['moniker']?.toString() ?? '';
          final name = item['name']?.toString() ?? '';
          return AppContainer(item['sid'].toString(), name.isEmpty || name.startsWith('@{') ? moniker : name, moniker);
        }(),
    ];
    return containers..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// 已经豁免的 SID
  static Future<Set<String>> exempted() async {
    final result = await Process.run('CheckNetIsolation', ['LoopbackExempt', '-s']);
    return parseExempted(result.stdout.toString());
  }

  static Set<String> parseExempted(String output) => RegExp(r'S-1-15-2-[\d-]+').allMatches(output).map((e) => e.group(0)!).toSet();

  /// 失败时抛 [ProcessException]，没有管理员权限也在这里失败
  static Future<void> setExempted(String sid, bool exempt) async {
    final result = await Process.run('CheckNetIsolation', ['LoopbackExempt', exempt ? '-a' : '-d', '-p=$sid']);
    if (result.exitCode != 0) throw ProcessException('CheckNetIsolation', const [], result.stdout.toString(), result.exitCode);
  }
}
