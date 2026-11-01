import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/system_proxy.dart';

enum CoreState { stopped, starting, running, stopping }

/// sing-box 跑在哪里：Windows 是子进程，iOS 是隧道扩展
abstract class CorePlatform {
  factory CorePlatform.current() => Platform.isIOS ? IosCorePlatform() : WindowsCorePlatform();

  Stream<CoreState> get states;

  /// 网页上点“一键导入”打开的链接
  Stream<String> get links;

  /// 由链接拉起 App 时，这条链接比 Dart 先到
  Future<String?> takePendingLink();

  /// 放 config.json 和规则集的目录，sing-box 要能读到
  Future<Directory> directory();

  /// 内核缓存文件路径
  Future<String> cachePath();

  /// 内核现在是否在运行。iOS 上 App 重开时隧道可能一直在跑
  Future<bool> isRunning();

  /// 配置已写到 [directory] 下的 config.json。[options] 是只在建立连接时生效的系统选项
  Future<void> start([Map<String, Object> options = const {}]);

  Future<void> reload();

  Future<void> stop();

  /// Windows 系统代理，null 表示清除。iOS 由 TUN 接管，不需要
  Future<void> setSystemProxy(int? port, {List<String> bypass = const []});

  /// iOS：解密时主 App 要留在后台
  Future<void> setKeepAlive(bool enabled);

  /// iOS：让隧道看着解密端口，主 App 被杀时退回 [fallbackMode]
  Future<void> watchCapture({required int port, required int clashPort, required String secret, required String fallbackMode});

  Future<void> unwatchCapture();

  /// 内核启动失败或意外退出的原因，还在运行时返回 null
  Future<String?> lastFailure();
}

/// 主 App 通过这个通道控制隧道
class IosCorePlatform implements CorePlatform {
  static const MethodChannel _channel = MethodChannel('rsproxy/core');

  final StreamController<CoreState> _states = StreamController.broadcast();
  final StreamController<String> _links = StreamController.broadcast();

  IosCorePlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') _states.add(_parse(call.arguments));
      if (call.method == 'openLink') _links.add(call.arguments as String);
    });
  }

  @override
  Stream<String> get links => _links.stream;

  @override
  Future<String?> takePendingLink() => _channel.invokeMethod<String>('takeLink');

  CoreState _parse(Object? state) => CoreState.values.asNameMap()[state] ?? CoreState.stopped;

  @override
  Stream<CoreState> get states => _states.stream;

  @override
  Future<Directory> directory() async {
    final path = await _channel.invokeMethod<String>('coreDirectory');
    return Directory(path!);
  }

  @override
  Future<String> cachePath() async => (await _channel.invokeMethod<String>('cachePath'))!;

  @override
  Future<bool> isRunning() async => _parse(await _channel.invokeMethod('state')) == CoreState.running;

  @override
  Future<void> start([Map<String, Object> options = const {}]) => _channel.invokeMethod('start', options);

  @override
  Future<void> reload() => _channel.invokeMethod('reload');

  @override
  Future<void> stop() => _channel.invokeMethod('stop');

  @override
  Future<void> setSystemProxy(int? port, {List<String> bypass = const []}) async {}

  @override
  Future<void> setKeepAlive(bool enabled) => _channel.invokeMethod('setKeepAlive', enabled);

  @override
  Future<void> watchCapture({required int port, required int clashPort, required String secret, required String fallbackMode}) {
    return _channel.invokeMethod('watchCapture', {
      'port': port,
      'clashPort': clashPort,
      'secret': secret,
      'fallbackMode': fallbackMode,
    });
  }

  @override
  Future<void> unwatchCapture() => _channel.invokeMethod('unwatchCapture');

  @override
  Future<String?> lastFailure() => _channel.invokeMethod<String>('lastFailure');
}

/// sing-box.exe 作为子进程运行，和 RsProxy.exe 放在同一目录
class WindowsCorePlatform implements CorePlatform {
  static const int _logLines = 50;

  final StreamController<CoreState> _states = StreamController.broadcast();
  final Queue<String> _log = Queue();
  final _KillOnExitJob _job = _KillOnExitJob();

  /// 测试时指定，默认是 RsProxy.exe 旁边的 sing-box.exe 和应用数据目录
  final String? executable;
  final Directory? workingDirectory;
  Process? _process;
  bool _stopping = false;

  WindowsCorePlatform({this.executable, this.workingDirectory});

  @override
  Stream<CoreState> get states => _states.stream;

  @override
  Stream<String> get links => const Stream.empty();

  @override
  Future<String?> takePendingLink() async => null;

  @override
  Future<Directory> directory() async {
    if (workingDirectory != null) return workingDirectory!;
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}${Platform.pathSeparator}core');
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<String> cachePath() async => '${(await directory()).path}${Platform.pathSeparator}cache.db';

  @override
  Future<bool> isRunning() async => _process != null;

  String get _executable =>
      executable ?? '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}sing-box.exe';

  @override
  Future<void> start([Map<String, Object> options = const {}]) async {
    if (_process != null) return;
    final working = await directory();
    _states.add(CoreState.starting);
    _log.clear();

    final process = await Process.start(
        _executable, ['run', '-c', '${working.path}${Platform.pathSeparator}config.json', '-D', working.path],
        workingDirectory: working.path);
    _process = process;
    _job.assign(process.pid);

    for (final stream in [process.stdout, process.stderr]) {
      stream.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_appendLog);
    }

    unawaited(process.exitCode.then((code) {
      if (!identical(_process, process)) return;
      _process = null;
      if (!_stopping) logger.e('sing-box exited with $code:\n${_log.join('\n')}');
      _states.add(CoreState.stopped);
    }));
    _states.add(CoreState.running);
  }

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > _logLines) _log.removeFirst();
  }

  /// Windows 上没有 SIGHUP，重载就是重启
  @override
  Future<void> reload() async {
    await stop();
    await start();
  }

  @override
  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _stopping = true;
    _states.add(CoreState.stopping);
    process.kill();
    await process.exitCode;
    _stopping = false;
  }

  @override
  Future<void> setSystemProxy(int? port, {List<String> bypass = const []}) {
    return SystemProxy.setSystemProxyEnable(port ?? 0, port != null, true, passDomains: bypass.join(';'));
  }

  @override
  Future<void> setKeepAlive(bool enabled) async {}

  @override
  Future<void> watchCapture({required int port, required int clashPort, required String secret, required String fallbackMode}) async {}

  @override
  Future<void> unwatchCapture() async {}

  @override
  Future<String?> lastFailure() async => _process == null && _log.isNotEmpty ? _log.join('\n') : null;
}

/// 把子进程放进“句柄关闭即终止”的作业对象。RsProxy 崩溃或被结束时系统会回收句柄，
/// sing-box 跟着退出，不会留下占着端口的孤儿进程。
class _KillOnExitJob {
  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _killOnJobClose = 0x2000;
  static const int _setQuotaAndTerminate = 0x0100 | 0x0001;

  /// JOBOBJECT_EXTENDED_LIMIT_INFORMATION 在 x64 上的大小和 LimitFlags 的偏移
  static const int _limitInformationSize = 144;
  static const int _limitFlagsOffset = 16;

  int _job = 0;

  void assign(int pid) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createJob = kernel32
          .lookupFunction<IntPtr Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>(
              'CreateJobObjectW');
      final setInformation = kernel32.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)>('SetInformationJobObject');
      final openProcess =
          kernel32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
      final assignProcess =
          kernel32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('AssignProcessToJobObject');
      final closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

      if (_job == 0) {
        _job = createJob(nullptr, nullptr);
        final information = calloc<Uint8>(_limitInformationSize);
        (information + _limitFlagsOffset).cast<Uint32>().value = _killOnJobClose;
        setInformation(_job, _jobObjectExtendedLimitInformation, information.cast(), _limitInformationSize);
        calloc.free(information);
      }

      final process = openProcess(_setQuotaAndTerminate, 0, pid);
      if (process != 0) {
        assignProcess(_job, process);
        closeHandle(process);
      }
    } catch (e) {
      logger.w('could not tie sing-box to this process: $e');
    }
  }
}
