import 'dart:async';
import 'dart:io';

import 'package:menu_base/menu_base.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class DesktopTrayManager with TrayListener {
  static final DesktopTrayManager instance = DesktopTrayManager._();

  DesktopTrayManager._();

  bool _initialized = false;
  Future<void> Function()? _quitHandler;

  void setQuitHandler(Future<void> Function()? handler) {
    _quitHandler = handler;
  }

  String _text(String zh, String en) => Platform.localeName.startsWith('zh') ? zh : en;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }

    _initialized = true;
    trayManager.addListener(this);
    await trayManager.setIcon('assets/icon.ico');
    await trayManager.setToolTip('RsProxy');
    await _updateMenu();
    if (CoreManager.isReady) CoreManager.instance.addListener(_updateMenu);
  }

  /// 内核层就绪。托盘可能比它先起来（启动后隐藏窗口时），这时菜单要补上连接项
  void coreReady() {
    if (!_initialized) return;
    CoreManager.instance.addListener(_updateMenu);
    unawaited(_updateMenu());
  }

  Future<void> _updateMenu() async {
    final connected = CoreManager.isReady && CoreManager.instance.isRunning;
    await trayManager.setContextMenu(
      Menu(
        items: [
          if (CoreManager.isReady)
            MenuItem(
              key: 'toggle_connection',
              label: connected ? _text('断开', 'Disconnect') : _text('连接', 'Connect'),
            ),
          MenuItem(
            key: 'show_window',
            label: _text('显示窗口', 'Show window'),
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'quit_app',
            label: _text('退出', 'Quit'),
          ),
        ],
      ),
    );
  }

  Future<void> showToTray() async {
    await ensureInitialized();
    await windowManager.hide();
  }

  Future<void> restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApp() async {
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (_) {
      // ignore tray cleanup errors during app shutdown
    } finally {
      _initialized = false;
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(restoreWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'toggle_connection':
        final manager = CoreManager.instance;
        unawaited(manager.isRunning ? manager.disconnect() : manager.connect());
        break;
      case 'show_window':
        unawaited(restoreWindow());
        break;
      case 'quit_app':
        unawaited(_quitHandler?.call() ?? exitApp());
        break;
    }
  }
}

