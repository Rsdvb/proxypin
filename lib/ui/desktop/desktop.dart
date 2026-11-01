/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'package:flutter/material.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/ui/component/memory_cleanup.dart';
import 'package:proxypin/ui/component/split_view.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/core/capture_tools_page.dart';
import 'package:proxypin/ui/core/capture_widgets.dart';
import 'package:proxypin/ui/core/design.dart';
import 'package:proxypin/ui/desktop/left_menus/favorite.dart';
import 'package:proxypin/ui/desktop/left_menus/history.dart';
import 'package:proxypin/ui/desktop/request/list.dart';
import 'package:proxypin/ui/desktop/ssl/ssl.dart';
import 'package:proxypin/utils/listenable_list.dart';

/// 抓到的请求和列表的句柄，MCP 等独立组件也要用
abstract final class DesktopCapture {
  static final ListenableList<HttpRequest> container = ListenableList<HttpRequest>();
  static final GlobalKey<DesktopRequestListState> requestListKey = GlobalKey<DesktopRequestListState>();
}

/// 供 MCP 等独立组件一次性回填当前抓包列表
ListenableList<HttpRequest> get desktopCaptureContainer => DesktopCapture.container;

/// 解密页的桌面布局：左边请求，右边详情
class DesktopCaptureView extends StatefulWidget {
  final ProxyServer proxyServer;
  final AppConfiguration appConfiguration;

  const DesktopCaptureView({super.key, required this.proxyServer, required this.appConfiguration});

  @override
  State<DesktopCaptureView> createState() => _DesktopCaptureViewState();
}

class _DesktopCaptureViewState extends State<DesktopCaptureView> implements EventListener {
  late final NetworkTabController _panel =
      NetworkTabController(tabStyle: const TextStyle(fontSize: 12.5), proxyServer: widget.proxyServer);
  CaptureSection _section = CaptureSection.requests;

  DesktopRequestListState? get _list => DesktopCapture.requestListKey.currentState;

  @override
  void initState() {
    super.initState();
    widget.proxyServer.addListener(this);
  }

  @override
  void onRequest(Channel channel, HttpRequest request) {
    _list?.add(channel, request);

    if (request.attributes['quickShare'] == true) {
      setState(() => _section = CaptureSection.requests);
      _panel.change(request, request.response);
    }

    //监控内存 到达阈值清理
    MemoryCleanupMonitor.onMonitor(onCleanup: () => _list?.cleanupEarlyData(32));
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    _list?.addResponse(channelContext, response);
    _panel.updateResponse(response);
  }

  @override
  void onMessage(Channel channel, HttpMessage message, WebSocketFrame frame) {
    if (_panel.request.get() == message || _panel.response.get() == message) {
      _panel.changeState();
    }
  }

  void _clear() {
    if (AppConfiguration.current?.clearConfirm != true) {
      _list?.clean();
      return;
    }
    showConfirmDialog(context, title: '清空请求', onConfirm: () => _list?.clean());
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        titleSpacing: 16,
        title: Row(children: [
          const Text('解密'),
          const SizedBox(width: 16),
          SizedBox(
            width: 210,
            child: PillSwitch<CaptureSection>(
              options: const {
                CaptureSection.requests: '请求',
                CaptureSection.favorites: '收藏',
                CaptureSection.history: '历史',
              },
              value: _section,
              onChanged: (value) => setState(() => _section = value),
            ),
          ),
        ]),
        actions: [
          IconButton(tooltip: '清空', icon: const Icon(Icons.delete_outline, size: 20), onPressed: _clear),
          SslWidget(proxyServer: widget.proxyServer),
          IconButton(
            tooltip: '解密工具',
            icon: const Icon(Icons.handyman_outlined, size: 20),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CaptureToolsPage(proxyServer: widget.proxyServer),
            )),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        CaptureStatusBar(configuration: widget.proxyServer.configuration),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radius),
              child: ColoredBox(
                color: palette.panel,
                child: VerticalSplitView(
                  ratio: widget.appConfiguration.panelRatio,
                  minRatio: 0.15,
                  maxRatio: 0.9,
                  dividerBackground: palette.panel,
                  onRatioChanged: (ratio) {
                    widget.appConfiguration.panelRatio = double.parse(ratio.toStringAsFixed(2));
                    widget.appConfiguration.flushConfig();
                  },
                  left: LazyIndexedStack(index: _section.index, children: [
                    DesktopRequestListWidget(
                      key: DesktopCapture.requestListKey,
                      proxyServer: widget.proxyServer,
                      list: DesktopCapture.container,
                      panel: _panel,
                    ),
                    Favorites(panel: _panel),
                    HistoryPageWidget(proxyServer: widget.proxyServer, container: DesktopCapture.container, panel: _panel),
                  ]),
                  right: _panel,
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
