import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_tools.dart';

import 'connect_page.dart';

/// 选节点。点一下立即切换，不用再确认
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  static const String _favoriteFilter = '收藏';

  String _keyword = '';
  bool _sortByDelay = false;

  /// 地区或收藏，null 表示全部
  String? _filter;

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final tags = _visibleTags(manager);
        final selected = manager.selectedNode ?? 'auto';
        final types = {for (final node in manager.nodes) node['tag']: node['type']?.toString()};
        return Scaffold(
          appBar: AppBar(title: const Text('节点'), actions: [
            IconButton(
              tooltip: '按延迟排序',
              isSelected: _sortByDelay,
              icon: const Icon(Icons.sort),
              onPressed: () => setState(() => _sortByDelay = !_sortByDelay),
            ),
            IconButton(
              tooltip: manager.isRunning ? '测延迟' : '连接后才能测延迟',
              icon: manager.testing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.speed),
              onPressed: manager.isRunning && !manager.testing ? manager.testLatency : null,
            ),
          ]),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                    hintText: '搜索节点', prefixIcon: Icon(Icons.search), isDense: true, border: OutlineInputBorder()),
                onChanged: (value) => setState(() => _keyword = value.trim().toLowerCase()),
              ),
            ),
            _filters(manager),
            Expanded(
              child: ListView.builder(
                itemCount: tags.length,
                itemBuilder: (context, index) {
                  final tag = tags[index];
                  final delay = manager.delays[tag];
                  return ListTile(
                    selected: tag == selected,
                    leading: Icon(tag == selected ? Icons.radio_button_checked : Icons.radio_button_off, size: 20),
                    title: Text(nodeLabel(tag), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: types[tag] == null ? null : Text(types[tag]!),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (delay != null) Text('$delay ms', style: TextStyle(color: delayColor(context, delay))),
                      if (tag != 'auto' && tag != 'direct')
                        IconButton(
                          tooltip: '收藏',
                          icon: Icon(manager.settings.favorites.contains(tag) ? Icons.star : Icons.star_border, size: 20),
                          onPressed: () => manager.toggleFavorite(tag),
                        ),
                    ]),
                    onTap: () => manager.selectNode(tag),
                  );
                },
              ),
            ),
          ]),
        );
      },
    );
  }

  /// 地区只列节点里有的，收藏为空时不显示，没有可筛选的就整行不占位
  Widget _filters(CoreManager manager) {
    final tags = manager.nodes.map((e) => e['tag'].toString());
    final choices = [
      if (tags.any(manager.settings.favorites.contains)) _favoriteFilter,
      ...NodeRegions.present(tags),
    ];
    if (choices.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
        for (final choice in choices)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(choice),
              selected: _filter == choice,
              onSelected: (selected) => setState(() => _filter = selected ? choice : null),
            ),
          ),
      ]),
    );
  }

  bool _matchesFilter(CoreManager manager, String tag) {
    final filter = _filter;
    if (filter == null) return true;
    if (filter == _favoriteFilter) return manager.settings.favorites.contains(tag);
    return NodeRegions.of(tag) == filter;
  }

  List<String> _visibleTags(CoreManager manager) {
    final nodes = manager.nodes.map((e) => e['tag'].toString()).toList();
    final matching = nodes
        .where((tag) => (_keyword.isEmpty || tag.toLowerCase().contains(_keyword)) && _matchesFilter(manager, tag))
        .toList();
    if (_sortByDelay) {
      // 没测出延迟的排最后
      int delayOf(String tag) => manager.delays[tag] ?? 1 << 30;
      matching.sort((a, b) => delayOf(a).compareTo(delayOf(b)));
    }
    return [if (_keyword.isEmpty && _filter == null) ...[if (nodes.length > 1) 'auto', 'direct'], ...matching];
  }
}
