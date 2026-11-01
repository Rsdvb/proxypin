/*
 * Copyright 2023 Hongen Wang
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
import 'package:date_format/date_format.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/ui/mobile/mobile.dart';

/// 请求列表的更多菜单
class MoreMenu extends StatelessWidget {
  static bool sortDesc = true;

  final ProxyServer proxyServer;

  const MoreMenu({super.key, required this.proxyServer});

  @override
  Widget build(BuildContext context) {
    AppLocalizations localizations = AppLocalizations.of(context)!;

    return PopupMenuButton<VoidCallback>(
      tooltip: '更多',
      onSelected: (action) => action(),
      itemBuilder: (BuildContext context) => [
        PopupMenuItem(
          value: () => MobileApp.searchStateKey.currentState?.showSearch(),
          child: Text(localizations.search),
        ),
        PopupMenuItem(
          value: () {
            var name = formatDate(DateTime.now(), [m, '-', d, ' ', HH, ':', nn, ':', ss]);
            MobileApp.requestStateKey.currentState?.export(context, 'RsProxy$name');
          },
          child: Text(localizations.viewExport),
        ),
        PopupMenuItem(
          value: MobileApp.multiSelectController.toggleSelectionMode,
          child: Text(localizations.select),
        ),
        PopupMenuItem(
          value: () {
            sortDesc = !sortDesc;
            MobileApp.requestStateKey.currentState?.sort(sortDesc);
          },
          child: Text(sortDesc ? localizations.timeAsc : localizations.timeDesc),
        ),
      ],
    );
  }
}
