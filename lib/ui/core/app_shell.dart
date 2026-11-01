import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_platform.dart';
import 'package:proxypin/core/core_service.dart';
import 'package:proxypin/mcp/mcp_service.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/desktop.dart';
import 'package:proxypin/ui/desktop/widgets/windows_toolbar.dart';
import 'package:proxypin/ui/mobile/debug/breakpoint_executor.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/utils/desktop_tray.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

import 'connect_page.dart';
import 'design.dart';
import 'nodes_page.dart';
import 'profiles_page.dart';
import 'rule_groups_page.dart';
import 'settings_page.dart';

/// 五个入口，手机在底部，窗口宽时在左侧
class ShellTab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const ShellTab(this.label, this.icon, this.selectedIcon);

  static const List<ShellTab> all = [
    ShellTab('首页', Icons.space_dashboard_outlined, Icons.space_dashboard),
    ShellTab('节点', Icons.public, Icons.public),
    ShellTab('分流', Icons.alt_route, Icons.alt_route),
    ShellTab('解密', Icons.lock_open_outlined, Icons.lock_open),
    ShellTab('设置', Icons.tune, Icons.tune),
  ];

  static const int captureIndex = 3;
}

/// RsProxy 的整个界面。内核、解密和窗口的生命周期都在这里，页面只管显示
class AppShell extends StatefulWidget {
  final Configuration configuration;
  final AppConfiguration appConfiguration;

  const AppShell(this.configuration, this.appConfiguration, {super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener, WidgetsBindingObserver {
  late final ProxyServer _proxyServer = ProxyServer(widget.configuration);
  late final Future<void> _ready = CoreService.start(_proxyServer).then((_) {
    final pending = CoreManager.instance.pendingImport;
    pending.addListener(_openPendingImport);
    _openPendingImport();
    if (Platform.isWindows) DesktopTrayManager.instance.coreReady();
  });

  final ValueNotifier<int> _tab = ValueNotifier(0);
  final Set<int> _opened = {0, ShellTab.captureIndex};
  final List<GlobalKey<NavigatorState>> _navigators =
      List.generate(ShellTab.all.length, (_) => GlobalKey<NavigatorState>());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platforms.isDesktop()) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
      DesktopTrayManager.instance.setQuitHandler(_exit);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    HistoryTask.ensureInstance(widget.configuration, _captureList);
    _ready.ignore();
    _startMcp();
    _registerBreakpointWindow();
  }

  @override
  void dispose() {
    if (Platforms.isDesktop()) {
      windowManager.removeListener(this);
      DesktopTrayManager.instance.setQuitHandler(null);
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    WidgetsBinding.instance.removeObserver(this);
    if (CoreManager.isReady) CoreManager.instance.pendingImport.removeListener(_openPendingImport);
    _tab.dispose();
    super.dispose();
  }

  dynamic get _captureList => Platforms.isDesktop() ? DesktopCapture.container : MobileApp.container;

  void _startMcp() {
    final mobile = Platforms.isMobile();
    McpService.instance.clearUiSession = () async {
      if (mobile) {
        MobileApp.requestStateKey.currentState?.clean();
      } else {
        DesktopCapture.container.clear();
        DesktopCapture.requestListKey.currentState?.clean();
      }
    };
    if (!widget.appConfiguration.mcpEnabled) return;
    McpService.instance.attach(_proxyServer, existing: mobile ? MobileApp.container.source : DesktopCapture.container);
    unawaited(McpService.instance.start(widget.appConfiguration).catchError((e) {
      // 启动失败时关掉开关，否则每次打开都再失败一次
      logger.e('MCP auto-start failed: $e');
      widget.appConfiguration.mcpEnabled = false;
      widget.appConfiguration.flushConfig();
    }));
  }

  void _registerBreakpointWindow() {
    if (!Platforms.isMobile()) return;
    MultiWindow.onOpenWindow = (name, args) async {
      if (name != 'BreakpointExecutor' || args == null || !mounted) return;
      _navigators[_tab.value].currentState?.push(MaterialPageRoute(
            builder: (_) => BreakpointExecutor(
              requestId: args['requestId'],
              request: HttpRequest.fromJson(jsonDecode(jsonEncode(args['request']))),
              response: args['response'] == null ? null : HttpResponse.fromJson(jsonDecode(jsonEncode(args['response']))),
              isResponse: args['type'] == 'response',
            ),
          ));
    };
  }

  void _openPendingImport() {
    final pending = CoreManager.instance.pendingImport;
    final link = pending.value;
    if (link == null || !mounted) return;
    pending.value = null;
    _select(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigators[1].currentState?.push(MaterialPageRoute(
            builder: (_) => AddProfilePage(initialContent: link.url, initialName: link.name, outboundDns: link.outboundDns),
          ));
    });
  }

  void _select(int index) {
    if (_tab.value == index) {
      // 再点一次当前入口回到它的第一页
      _navigators[index].currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _opened.add(index));
    _tab.value = index;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return false;
    final navigator = _navigators[_tab.value].currentState;
    if (navigator == null || !navigator.canPop()) return false;
    navigator.maybePop();
    return true;
  }

  // ---- 窗口和进程 ----

  @override
  void onWindowClose() async {
    final configuration = AppConfiguration.current;
    if (configuration?.minimizeToTray != false) {
      if (configuration?.minimizeToTray == null) {
        final minimize = await _askCloseAction();
        if (!mounted) return;
        configuration?.minimizeToTray = minimize;
        await configuration?.flushConfig();
        if (!minimize) return _exit();
      }
      try {
        return await DesktopTrayManager.instance.showToTray();
      } catch (e) {
        logger.e('show to tray failed, fallback to exit', error: e);
      }
    }
    await _exit();
  }

  Future<bool> _askCloseAction() async {
    final minimize = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('关闭窗口时'),
        content: const Text('RsProxy 可以缩到托盘继续运行，也可以直接退出。之后可以在设置里修改。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('退出')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('缩到托盘')),
        ],
      ),
    );
    return minimize ?? false;
  }

  Future<void> _exit() async {
    // Windows 上内核跟着 App 退出，系统代理必须先清掉。iOS 的隧道是独立进程，继续运行
    if (Platform.isWindows && CoreManager.isReady) await CoreManager.instance.disconnect();
    await _proxyServer.stop();
    if (Platforms.isDesktop()) {
      await DesktopTrayManager.instance.exitApp();
      windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
    exit(0);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (Platforms.isDesktop() && !await windowManager.isPreventClose()) await _exit();
    return super.didRequestAppExit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && CoreManager.isReady) {
      CoreManager.instance.onResumed().catchError((e) => logger.w('resume core failed: $e'));
      if (_proxyServer.isRunning) {
        _proxyServer.retryBind().catchError((e) => logger.e('retryBind failed on resumed', error: e));
      }
    }
    if (state == AppLifecycleState.detached) _proxyServer.stop();
  }

  // ---- 界面 ----

  Widget _tabPage(int index) {
    final Widget root = switch (index) {
      0 => HomePage(configuration: widget.configuration, onOpenTab: _select),
      1 => const NodesPage(),
      2 => RuleGroupsPage(visibleTab: _tab, ownTab: 2),
      3 => Platforms.isDesktop()
          ? DesktopCaptureView(proxyServer: _proxyServer, appConfiguration: widget.appConfiguration)
          : MobileCaptureView(proxyServer: _proxyServer, appConfiguration: widget.appConfiguration),
      _ => SettingsPage(configuration: widget.configuration, appConfiguration: widget.appConfiguration),
    };
    return Navigator(
      key: _navigators[index],
      onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => root),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snapshot.error}'))));
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return ShellLayout(
          tab: _tab,
          onSelect: _select,
          titleBar: Platforms.isDesktop() ? const WindowsToolbar(showIcon: false) : null,
          pages: [
            for (var index = 0; index < ShellTab.all.length; index++)
              _opened.contains(index) ? _tabPage(index) : const SizedBox.shrink(),
          ],
        );
      },
    );
  }
}

/// 窗口够宽时用侧边栏，否则用底部导航。内容一直留着，切走再回来不用重新加载
class ShellLayout extends StatelessWidget {
  static const double sidebarBreakpoint = 720;

  final ValueListenable<int> tab;
  final ValueChanged<int> onSelect;
  final List<Widget> pages;
  final Widget? titleBar;

  const ShellLayout({super.key, required this.tab, required this.onSelect, required this.pages, this.titleBar});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= sidebarBreakpoint;
      return ValueListenableBuilder<int>(
        valueListenable: tab,
        builder: (context, index, _) {
          final content = IndexedStack(index: index, children: pages);
          final column = Column(children: [
            if (titleBar != null)
              Container(
                height: 34,
                color: palette.canvas,
                child: titleBar,
              ),
            Expanded(child: content),
          ]);
          if (wide) {
            return Scaffold(
              body: Row(children: [
                _Sidebar(index: index, onSelect: onSelect),
                Expanded(child: column),
              ]),
            );
          }
          return Scaffold(
            body: column,
            bottomNavigationBar: DecoratedBox(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.line, width: 0.6))),
              child: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: onSelect,
                destinations: [
                  for (final item in ShellTab.all)
                    NavigationDestination(icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: item.label),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}

class _Sidebar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const _Sidebar({required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      width: 196,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(right: BorderSide(color: palette.line, width: 0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset('assets/icon.png', width: 26, height: 26, errorBuilder: (_, __, ___) => const SizedBox(width: 26)),
            ),
            const SizedBox(width: 10),
            Text('RsProxy', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: palette.ink, letterSpacing: 0.2)),
          ]),
        ),
        for (final (position, item) in ShellTab.all.indexed)
          _SidebarItem(item: item, selected: position == index, onTap: () => onSelect(position)),
        const Spacer(),
        if (CoreManager.isReady) ListenableBuilder(listenable: CoreManager.instance, builder: (_, __) => const _SidebarStatus()),
      ]),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final ShellTab item;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarItem({required this.item, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final color = selected ? accent : palette.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.11) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(selected ? item.selectedIcon : item.icon, size: 20, color: color),
              const SizedBox(width: 12),
              Text(item.label,
                  style: TextStyle(
                    fontSize: 14,
                    color: selected ? accent : palette.ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  )),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus();

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final manager = CoreManager.instance;
    final running = manager.state == CoreState.running;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 14, 16),
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: running ? Tone.good : palette.faint),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(running ? nodeLabel(manager.selectedNode) : '未连接',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: palette.muted)),
        ),
      ]),
    );
  }
}
