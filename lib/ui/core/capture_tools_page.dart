import 'package:flutter/material.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/network_condition_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/desktop/request/report_servers.dart';
import 'package:proxypin/ui/desktop/setting/environment.dart';
import 'package:proxypin/ui/desktop/setting/request_block.dart';
import 'package:proxypin/ui/desktop/setting/weak_network.dart';
import 'package:proxypin/ui/desktop/toolbar/mcp_panel.dart';
import 'package:proxypin/ui/desktop/widgets/highlight.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/ui/mobile/request/favorite.dart';
import 'package:proxypin/ui/mobile/request/history.dart';
import 'package:proxypin/ui/mobile/setting/environment.dart';
import 'package:proxypin/ui/mobile/setting/mcp.dart';
import 'package:proxypin/ui/mobile/setting/report_servers.dart';
import 'package:proxypin/ui/mobile/setting/request_block.dart';
import 'package:proxypin/ui/mobile/setting/request_breakpoint.dart';
import 'package:proxypin/ui/mobile/setting/request_crypto.dart';
import 'package:proxypin/ui/mobile/setting/request_map.dart';
import 'package:proxypin/ui/mobile/setting/request_rewrite.dart';
import 'package:proxypin/ui/mobile/setting/script.dart';
import 'package:proxypin/ui/mobile/setting/ssl.dart';
import 'package:proxypin/ui/mobile/setting/weak_network.dart';
import 'package:proxypin/ui/mobile/widgets/highlight.dart';
import 'package:proxypin/ui/toolbox/toolbox.dart';
import 'package:proxypin/utils/platform.dart';

import 'design.dart';

/// 解密之后对请求做的事。和翻墙无关，所以都放在解密页下面，不进设置
class CaptureToolsPage extends StatefulWidget {
  final ProxyServer proxyServer;

  const CaptureToolsPage({super.key, required this.proxyServer});

  @override
  State<CaptureToolsPage> createState() => _CaptureToolsPageState();
}

class _CaptureToolsPageState extends State<CaptureToolsPage> {
  bool get _desktop => Platforms.isDesktop();

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  /// 桌面端这些编辑器是独立窗口，手机上是普通页面
  void _openWindow(String title, String widgetName, Size size, Widget mobile) {
    _desktop ? MultiWindow.openWindow(title, widgetName, size: size) : _push(mobile);
  }

  Future<void> _openBlock() async {
    final manager = await RequestBlockManager.instance;
    if (!mounted) return;
    _desktop
        ? showDialog(context: context, barrierDismissible: false, builder: (_) => RequestBlock(requestBlockManager: manager))
        : _push(MobileRequestBlock(requestBlockManager: manager));
  }

  Future<void> _openRewrite() async {
    final manager = await RequestRewriteManager.instance;
    if (!mounted) return;
    _openWindow('请求重写', 'RequestRewriteWidget', const Size(800, 750), MobileRequestRewrite(requestRewrites: manager));
  }

  Future<void> _openBreakpoint() async {
    final manager = await RequestBreakpointManager.instance;
    if (!mounted) return;
    _openWindow('断点', 'RequestBreakpointPage', const Size(800, 750), MobileRequestBreakpointPage(manager: manager));
  }

  Future<void> _openWeakNetwork() async {
    final manager = await NetworkConditionManager.instance;
    if (!mounted) return;
    _desktop
        ? showDialog(context: context, barrierDismissible: false, builder: (_) => WeakNetworkDialog(manager: manager))
        : _push(MobileWeakNetwork(manager: manager));
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.proxyServer;
    return AppPage(title: '解密工具', children: [
      if (!_desktop) ...[
        const SectionLabel('证书和记录'),
        Panel(children: [
          InfoRow(
            icon: Icons.verified_user_outlined,
            iconColor: Tone.good,
            title: '根证书',
            subtitle: '解密前要安装并信任',
            onTap: () => _push(MobileSslWidget(proxyServer: server)),
          ),
          InfoRow(
            icon: Icons.star_outline,
            iconColor: Tone.warn,
            title: '收藏',
            onTap: () => _push(MobileFavorites(proxyServer: server)),
          ),
          InfoRow(
            icon: Icons.history,
            iconColor: Tone.teal,
            title: '历史',
            onTap: () => _push(MobileHistory(
              proxyServer: server,
              container: MobileApp.container,
              historyTask: HistoryTask.ensureInstance(server.configuration, MobileApp.container),
            )),
          ),
        ]),
      ],
      const SectionLabel('修改请求'),
      Panel(children: [
        InfoRow(icon: Icons.edit_note, iconColor: Tone.violet, title: '请求重写', onTap: _openRewrite),
        InfoRow(
          icon: Icons.swap_horiz,
          iconColor: Tone.teal,
          title: '请求映射',
          onTap: () => _openWindow('请求映射', 'RequestMapPage', const Size(800, 720), MobileRequestMapPage()),
        ),
        InfoRow(icon: Icons.block, iconColor: Tone.bad, title: '请求屏蔽', onTap: _openBlock),
        InfoRow(
          icon: Icons.key_outlined,
          iconColor: Tone.warn,
          title: '请求加解密',
          onTap: () => _openWindow('请求加解密', 'RequestCryptoPage', const Size(820, 750), const MobileRequestCryptoPage()),
        ),
        InfoRow(
          icon: Icons.code,
          iconColor: Tone.good,
          title: '脚本',
          onTap: () => _openWindow('脚本', 'ScriptWidget', const Size(800, 780), const MobileScript()),
        ),
        InfoRow(icon: Icons.pause_circle_outline, iconColor: Tone.bad, title: '断点', onTap: _openBreakpoint),
      ]),
      const SectionLabel('调试'),
      Panel(children: [
        InfoRow(icon: Icons.network_check, iconColor: Tone.teal, title: '弱网模拟', onTap: _openWeakNetwork),
        InfoRow(
          icon: Icons.data_object,
          iconColor: Tone.violet,
          title: '环境变量',
          onTap: () => _desktop ? showEnvironmentDialog(context) : _push(const MobileEnvironmentPage()),
        ),
        InfoRow(
          icon: Icons.cloud_upload_outlined,
          title: '上报服务器',
          onTap: () => _desktop ? showReportServersDialog(context) : _push(const ReportServersPageMobile()),
        ),
        InfoRow(
          icon: Icons.highlight_outlined,
          iconColor: Tone.warn,
          title: '关键词高亮',
          onTap: () => _desktop
              ? showDialog(context: context, builder: (_) => const DesktopKeywordHighlight())
              : _push(const KeywordHighlight()),
        ),
        InfoRow(
          icon: Icons.handyman_outlined,
          iconColor: Tone.teal,
          title: '工具箱',
          subtitle: '编解码、JSON、时间戳、二维码等',
          onTap: () => _push(Scaffold(
            appBar: AppBar(title: const Text('工具箱')),
            body: Toolbox(proxyServer: server),
          )),
        ),
        InfoRow(
          icon: Icons.smart_toy_outlined,
          iconColor: Tone.violet,
          title: 'MCP 服务',
          subtitle: '让 AI 读取抓到的请求',
          onTap: () => _desktop ? McpServiceDialog.show(context, server) : _push(MobileMcpSetting(proxyServer: server)),
        ),
      ]),
    ]);
  }
}
