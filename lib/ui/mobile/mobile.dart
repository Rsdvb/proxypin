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
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/core/capture_tools_page.dart';
import 'package:proxypin/ui/core/capture_widgets.dart';
import 'package:proxypin/ui/mobile/menu/menu.dart';
import 'package:proxypin/ui/mobile/request/list.dart';
import 'package:proxypin/ui/mobile/request/search.dart';
import 'package:proxypin/utils/listenable_list.dart';

class MobileApp {
  ///请求列表key
  static final GlobalKey<RequestListState> requestStateKey = GlobalKey<RequestListState>();

  ///搜索key
  static final GlobalKey<MobileSearchState> searchStateKey = GlobalKey<MobileSearchState>();

  ///请求列表容器
  static final container = ListenableList<HttpRequest>();

  static final multiSelectController = MultiSelectController();
}

/// 解密页的手机布局：请求列表，点开看详情
class MobileCaptureView extends StatefulWidget {
  final ProxyServer proxyServer;
  final AppConfiguration appConfiguration;

  const MobileCaptureView({super.key, required this.proxyServer, required this.appConfiguration});

  @override
  State<MobileCaptureView> createState() => _MobileCaptureViewState();
}

class _MobileCaptureViewState extends State<MobileCaptureView> with WidgetsBindingObserver implements EventListener {
  ProxyServer get _server => widget.proxyServer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _server.addListener(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onRequest(Channel channel, HttpRequest request) {
    MobileApp.requestStateKey.currentState?.add(channel, request);

    //监控内存 到达阈值清理
    MemoryCleanupMonitor.onMonitor(onCleanup: () {
      MobileApp.requestStateKey.currentState?.cleanupEarlyData(32);
    });
  }

  /// 系统内存紧张时立即释放抓包数据。后台时内存占用高的应用最先被系统终止
  @override
  void didHaveMemoryPressure() {
    MobileApp.requestStateKey.currentState?.cleanupEarlyData(32);
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    MobileApp.requestStateKey.currentState?.addResponse(channelContext, response);
    NetworkTabController.current?.updateResponse(response);
  }

  @override
  void onMessage(Channel channel, HttpMessage message, WebSocketFrame frame) {
    var panel = NetworkTabController.current;
    if (panel?.request.get() == message || panel?.response.get() == message) {
      panel?.changeState();
    }
  }

  void _clear() {
    if (!widget.appConfiguration.clearConfirm) {
      MobileApp.requestStateKey.currentState?.clean();
      return;
    }
    showConfirmDialog(context, title: '清空请求', onConfirm: () => MobileApp.requestStateKey.currentState?.clean());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: MobileSearch(
          key: MobileApp.searchStateKey,
          onSearch: (value) => MobileApp.requestStateKey.currentState?.search(value),
        ),
        actions: [
          IconButton(tooltip: '清空', icon: const Icon(Icons.delete_outline), onPressed: _clear),
          IconButton(
            tooltip: '解密工具',
            icon: const Icon(Icons.handyman_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CaptureToolsPage(proxyServer: _server),
            )),
          ),
          MoreMenu(proxyServer: _server),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(children: [
        CaptureStatusBar(configuration: _server.configuration, proxyServer: _server),
        Expanded(
          child: RequestListWidget(
            key: MobileApp.requestStateKey,
            proxyServer: _server,
            list: MobileApp.container,
            selectionController: MobileApp.multiSelectController,
          ),
        ),
      ]),
    );
  }
}
