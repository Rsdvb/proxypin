import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';

import 'connect_page.dart';

/// 选节点。点一下立即切换，不用再确认
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  String _keyword = '';
  bool _sortByDelay = false;

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final tags = _visibleTags(manager);
        final selected = manager.selectedNode ?? 'auto';
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
                    subtitle: _typeOf(manager, tag) == null ? null : Text(_typeOf(manager, tag)!),
                    trailing:
                        delay == null ? null : Text('$delay ms', style: TextStyle(color: delayColor(context, delay))),
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

  List<String> _visibleTags(CoreManager manager) {
    final nodes = manager.nodes.map((e) => e['tag'].toString()).toList();
    final matching = nodes.where((tag) => _keyword.isEmpty || tag.toLowerCase().contains(_keyword)).toList();
    if (_sortByDelay) {
      // 没测出延迟的排最后
      int delayOf(String tag) => manager.delays[tag] ?? 1 << 30;
      matching.sort((a, b) => delayOf(a).compareTo(delayOf(b)));
    }
    return [if (_keyword.isEmpty) ...[if (nodes.length > 1) 'auto', 'direct'], ...matching];
  }

  String? _typeOf(CoreManager manager, String tag) {
    for (final node in manager.nodes) {
      if (node['tag'] == tag) return node['type']?.toString();
    }
    return null;
  }
}
