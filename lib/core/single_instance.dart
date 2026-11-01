import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'import_link.dart';

/// Windows 上只留一个实例。再次打开 RsProxy，或者点网页上的一键导入时，系统会新开一个进程，
/// 它把命令行交给已经在运行的那个，自己退出。
///
/// 用本机端口而不是互斥量：除了判断有没有实例，还要把参数传过去
class SingleInstance {
  static const int defaultPort = 17899;
  static const Duration _timeout = Duration(seconds: 1);

  /// 回这句话才说明对面真是 RsProxy，端口可能被别的程序占着
  static const String _reply = 'rsproxy';

  static ServerSocket? _server;

  /// 成为第一个实例时返回 true，[onOpen] 之后每次有新进程打开时收到它的命令行。
  /// 已有实例时把 [args] 交过去，返回 false
  static Future<bool> claim(List<String> args, {required void Function(List<String> args) onOpen, int port = defaultPort}) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      server.listen((client) => _serve(client, onOpen));
      return true;
    } on SocketException {
      return !await _handOver(args, port);
    }
  }

  static Future<void> release() async {
    await _server?.close();
    _server = null;
  }

  static void _serve(Socket client, void Function(List<String> args) onOpen) {
    utf8.decoder.bind(client).transform(const LineSplitter()).first.then((line) {
      client.writeln(_reply);
      unawaited(client.close());
      onOpen((jsonDecode(line) as List).map((e) => e.toString()).toList());
    }).catchError((_) => client.destroy());
  }

  /// 对面确实收下了才算交接成功。否则端口是别的程序占的，这个实例照常运行
  static Future<bool> _handOver(List<String> args, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: _timeout);
      socket.writeln(jsonEncode(args));
      await socket.flush();
      final reply = await utf8.decoder.bind(socket).transform(const LineSplitter()).first.timeout(_timeout);
      return reply == _reply;
    } on Exception {
      return false;
    } on StateError {
      // 对面没回话就断开了
      return false;
    } finally {
      socket?.destroy();
    }
  }
}

/// 从命令行收到的一键导入链接。收到时内核层可能还没起来，先存着
class WindowsLinks {
  static final StreamController<String> _incoming = StreamController.broadcast();
  static String? _pending;

  static Stream<String> get stream => _incoming.stream;

  static void receive(List<String> args) {
    final link = args.where((e) => ImportLink.parse(e) != null).firstOrNull;
    if (link == null) return;
    if (_incoming.hasListener) {
      _incoming.add(link);
    } else {
      _pending = link;
    }
  }

  static String? take() {
    final link = _pending;
    _pending = null;
    return link;
  }
}

/// 让系统把 clash:// 这类链接交给 RsProxy，写在当前用户的注册表里，不需要管理员权限
class WindowsSchemes {
  static const List<String> supported = ['rsproxy', 'clash', 'sing-box', 'karing'];

  static String _key(String scheme) => 'HKCU\\Software\\Classes\\$scheme';

  static String commandFor(String executable) => '"$executable" "%1"';

  /// 只有指向这个程序才算注册了。别的软件注册的不算，也不会被关闭开关时删掉
  static bool pointsTo(String registryOutput, String executable) =>
      registryOutput.toLowerCase().contains(commandFor(executable).toLowerCase());

  static Future<bool> isRegistered(String scheme) async {
    final result = await Process.run('reg', ['query', '${_key(scheme)}\\shell\\open\\command', '/ve']);
    return result.exitCode == 0 && pointsTo(result.stdout.toString(), Platform.resolvedExecutable);
  }

  static Future<void> setRegistered(String scheme, bool enabled) async {
    final key = _key(scheme);
    final commands = enabled
        ? [
            ['add', key, '/ve', '/d', 'URL:$scheme', '/f'],
            ['add', key, '/v', 'URL Protocol', '/d', '', '/f'],
            ['add', '$key\\shell\\open\\command', '/ve', '/d', commandFor(Platform.resolvedExecutable), '/f'],
          ]
        : [
            ['delete', key, '/f'],
          ];
    for (final command in commands) {
      final result = await Process.run('reg', command);
      if (result.exitCode != 0) throw ProcessException('reg', command, result.stderr.toString(), result.exitCode);
    }
  }
}
