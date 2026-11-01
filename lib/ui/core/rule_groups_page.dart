import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/dns_catalog.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/utils/platform.dart';

import 'connect_page.dart';
import 'rule_group_edit_page.dart';
import 'rule_sets_page.dart';

/// 分流组。在副本上改，离开页面时一次保存，避免每动一下就重启内核
class RuleGroupsPage extends StatefulWidget {
  const RuleGroupsPage({super.key});

  @override
  State<RuleGroupsPage> createState() => _RuleGroupsPageState();
}

class _RuleGroupsPageState extends State<RuleGroupsPage> {
  final CoreManager _manager = CoreManager.instance;
  late List<RuleGroup> _groups = _copy(_manager.settings.groups);
  bool _changed = false;

  /// 底部菜单里的动作，和去向放在同一个返回值里，所以用节点名里不会出现的字符
  static const String _editAction = '\u0000edit';
  static const String _dnsAction = '\u0000dns';
  static const String _jsonAction = '\u0000json';
  static const String _nodeAction = '\u0000node';

  static List<RuleGroup> _copy(List<RuleGroup> groups) => groups.map((e) => RuleGroup.fromJson(e.toJson())).toList();

  List<String> get _nodes => _manager.nodes.map((e) => e['tag'].toString()).toList();

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    if (_changed) {
      _manager.settings.groups = _groups;
      _manager.applySettings();
    }
    super.dispose();
  }

  String _targetLabel(String target) => switch (target) {
        RuleTarget.selected => '跟随节点',
        RuleTarget.auto => '自动选择',
        RuleTarget.direct => '直连',
        RuleTarget.block => '拦截',
        _ => nodeLabel(target),
      };

  /// 选的节点在订阅更新后没了，这时实际走的是首页选中的节点
  bool _isGone(String target) => !RuleTarget.builtIn.contains(target) && !_nodes.contains(target);

  Widget _targetText(String target, {bool enabled = true}) {
    final theme = Theme.of(context);
    final color = enabled && _isGone(target) ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 150),
      child: Text(enabled ? _targetLabel(target) : '已关闭',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
    );
  }

  /// 去向选项：常用的几个直接点，节点进单独的页面搜
  List<Widget> _targetChoices(BuildContext context, String current) {
    final nodes = _nodes;
    return [
      for (final choice in [
        RuleTarget.selected,
        if (nodes.length > 1) RuleTarget.auto,
        RuleTarget.direct,
        RuleTarget.block,
      ])
        ListTile(
          title: Text(_targetLabel(choice)),
          trailing: current == choice ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, choice),
        ),
      if (nodes.isNotEmpty)
        ListTile(
          title: const Text('选择节点'),
          subtitle: RuleTarget.builtIn.contains(current) ? null : Text(_targetLabel(current), maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.pop(context, _nodeAction),
        ),
    ];
  }

  Future<String?> _pickNode(String current) => Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => NodePickerPage(nodes: _nodes, current: current)));

  Future<void> _openGroup(RuleGroup group) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑规则'),
              onTap: () => Navigator.pop(context, _editAction),
            ),
            if (group.target != RuleTarget.block)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('单独的 DNS'),
                subtitle: Text(group.dnsServer.isEmpty ? '按全局设置' : group.dnsServer, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(context, _dnsAction),
              ),
            ListTile(
              leading: const Icon(Icons.data_object),
              title: const Text('查看 JSON'),
              onTap: () => Navigator.pop(context, _jsonAction),
            ),
            SwitchListTile(
              title: const Text('启用'),
              value: group.enabled,
              onChanged: (value) {
                _change(() => group.enabled = value);
                Navigator.pop(context);
              },
            ),
            const Divider(height: 1),
            ..._targetChoices(context, group.target),
          ]),
        ),
      ),
    );

    switch (action) {
      case null:
        return;
      case _editAction:
        await _edit(group);
      case _dnsAction:
        await _pickDns(group);
      case _jsonAction:
        await _showJson(group);
      case _nodeAction:
        final node = await _pickNode(group.target);
        if (node != null) _change(() => group.target = node);
      default:
        _change(() => group.target = action);
    }
  }

  Future<void> _pickFinal() async {
    final current = _manager.settings.finalTarget;
    var target = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: _targetChoices(context, current))),
    );
    if (target == _nodeAction) target = await _pickNode(current);
    if (target != null) _change(() => _manager.settings.finalTarget = target!);
  }

  Future<void> _pickDns(RuleGroup group) async {
    final url = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => GroupDnsPage(custom: _manager.settings.dns.custom.map(DnsServer.fromJson).toList(), current: group.dnsServer),
    ));
    if (url != null) _change(() => group.dnsServer = url);
  }

  Future<void> _showJson(RuleGroup group) async {
    final text = const JsonEncoder.withIndent('  ').convert(group.toJson()..remove('id'));
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(group.name),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(context);
            },
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _edit(RuleGroup? group) async {
    final result = await Navigator.of(context).push<RuleGroupEdit>(MaterialPageRoute(
      builder: (_) => EditRuleGroupPage(
        group: group,
        otherNames: {for (final other in _groups) if (!identical(other, group)) other.name},
      ),
    ));
    if (result == null) return;
    _change(() {
      if (result.remove) {
        _groups.remove(group);
      } else if (group == null) {
        // 新组放最前面：自定义规则通常要优先于内置规则
        _groups.insert(0, result.group!);
      } else {
        _groups[_groups.indexOf(group)] = result.group!;
      }
    });
  }

  /// 同 id 的替换，其余放最前面
  void _merge(List<RuleGroup> incoming) {
    _change(() {
      for (final group in incoming.reversed) {
        final index = _groups.indexWhere((e) => e.id == group.id);
        if (index >= 0) {
          _groups[index] = group;
        } else {
          _groups.insert(0, group);
        }
      }
    });
  }

  Future<void> _addPresets() async {
    final chosen = await Navigator.of(context).push<List<RuleGroup>>(MaterialPageRoute(
      builder: (_) => PresetGroupsPage(existing: _groups.map((e) => e.id).toSet()),
    ));
    if (chosen != null) _merge(chosen);
  }

  Future<void> _import() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    if (file == null) return;
    try {
      final json = jsonDecode(utf8.decode(await file.readAsBytes()));
      final groups = (json as List).map((e) => RuleGroup.fromJson(e as Map<String, dynamic>)).toList();
      final problem = groups.map((e) => e.firstProblem()).nonNulls.firstOrNull;
      if (problem != null) return _show(problem);
      _merge(groups);
      _show('已导入 ${groups.length} 组');
    } on FormatException {
      _show('文件内容不对');
    } on TypeError {
      _show('文件内容不对');
    }
  }

  Future<void> _export() async {
    final path = await Platforms.saveFileAdaptive(fileName: 'rsproxy-rules.json');
    if (path == null) return;
    await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(_groups));
    _show('已导出');
  }

  void _reset() => _change(() => _groups = RuleGroup.defaults());

  Future<void> _openRuleSets() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RuleSetsPage()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = _manager.settings;
    final theme = Theme.of(context);
    final missing = _manager.missingRuleSets.length;
    final visible = settings.hideDisabledGroups ? _groups.where((e) => e.enabled).toList() : _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('分流'), actions: [
        IconButton(tooltip: '添加分流组', icon: const Icon(Icons.add), onPressed: () => _edit(null)),
        PopupMenuButton<VoidCallback>(
          onSelected: (action) => action(),
          itemBuilder: (context) => [
            PopupMenuItem(value: _addPresets, child: const Text('添加预置')),
            PopupMenuItem(value: _import, child: const Text('导入')),
            PopupMenuItem(value: _export, child: const Text('导出')),
            PopupMenuItem(value: _reset, child: const Text('恢复默认')),
          ],
        ),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('从上到下匹配，都没有命中时走最后的“其余流量”。长按拖动调整顺序。', style: theme.textTheme.bodySmall),
        ),
        if (missing > 0)
          ListTile(
            dense: true,
            leading: Icon(Icons.warning_amber, color: theme.colorScheme.error),
            title: Text('$missing 个规则集还没下载成功，对应的规则暂未生效'),
            onTap: _openRuleSets,
          ),
        ExpansionTile(
          title: const Text('分流开关'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            ListTile(title: const Text('规则集'), trailing: const Icon(Icons.chevron_right), onTap: _openRuleSets),
            SwitchListTile(
              title: const Text('隐藏未启用的分流规则'),
              value: settings.hideDisabledGroups,
              onChanged: (value) {
                setState(() => settings.hideDisabledGroups = value);
                _manager.saveUiSettings();
              },
            ),
            SwitchListTile(
              title: const Text('私有网络直连'),
              value: settings.privateDirect,
              onChanged: (value) => _change(() => settings.privateDirect = value),
            ),
            SwitchListTile(
              title: const Text('禁用机场分流规则'),
              value: !settings.providerRulesEnabled,
              onChanged: (value) => _change(() => settings.providerRulesEnabled = !value),
            ),
            SwitchListTile(
              title: const Text('自定义分流组'),
              value: settings.groupsEnabled,
              onChanged: (value) => _change(() => settings.groupsEnabled = value),
            ),
          ],
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: visible.length,
            footer: ListTile(
              title: const Text('其余流量'),
              subtitle: const Text('上面都没有命中时走这里'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                _targetText(settings.finalTarget),
                const Icon(Icons.chevron_right),
              ]),
              onTap: _pickFinal,
            ),
            onReorder: (oldIndex, newIndex) => _change(() {
              final target = visible[newIndex > oldIndex ? newIndex - 1 : newIndex];
              final item = visible[oldIndex];
              _groups
                ..remove(item)
                ..insert(_groups.indexOf(target) + (newIndex > oldIndex ? 1 : 0), item);
            }),
            itemBuilder: (context, index) {
              final group = visible[index];
              return ListTile(
                key: ValueKey(group.id),
                leading: group.dnsServer.isEmpty ? null : const Icon(Icons.dns_outlined, size: 18),
                minLeadingWidth: 0,
                title: Text(group.name,
                    style: group.enabled ? null : TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _targetText(group.target, enabled: group.enabled),
                  const Icon(Icons.chevron_right),
                ]),
                onTap: () => _openGroup(group),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// 选节点。节点可能上千个，列表要懒加载，还要能搜
class NodePickerPage extends StatefulWidget {
  final List<String> nodes;
  final String? current;

  const NodePickerPage({super.key, required this.nodes, this.current});

  @override
  State<NodePickerPage> createState() => _NodePickerPageState();
}

class _NodePickerPageState extends State<NodePickerPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final nodes = query.isEmpty ? widget.nodes : widget.nodes.where((e) => e.toLowerCase().contains(query)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('选择节点')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            decoration: const InputDecoration(hintText: '搜索', prefixIcon: Icon(Icons.search), isDense: true),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: nodes.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(nodeLabel(nodes[index]), maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: widget.current == nodes[index] ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, nodes[index]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// 给分流组单独选 DNS。返回地址，空字符串表示按全局设置
class GroupDnsPage extends StatelessWidget {
  final List<DnsServer> custom;
  final String current;

  const GroupDnsPage({super.key, this.custom = const [], required this.current});

  @override
  Widget build(BuildContext context) {
    final servers = [...custom, ...DnsCatalog.servers];
    return Scaffold(
      appBar: AppBar(title: const Text('单独的 DNS')),
      body: ListView.builder(
        itemCount: servers.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListTile(
              title: const Text('按全局设置'),
              trailing: current.isEmpty ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, ''),
            );
          }
          final server = servers[index - 1];
          return ListTile(
            dense: true,
            title: Text(server.provider),
            subtitle: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: server.url == current ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, server.url),
          );
        },
      ),
    );
  }
}

/// 从默认分流组里挑几个加回来
class PresetGroupsPage extends StatefulWidget {
  final Set<String> existing;

  const PresetGroupsPage({super.key, required this.existing});

  @override
  State<PresetGroupsPage> createState() => _PresetGroupsPageState();
}

class _PresetGroupsPageState extends State<PresetGroupsPage> {
  final List<RuleGroup> _presets = RuleGroup.defaults();
  final Set<String> _chosen = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加预置'), actions: [
        IconButton(
          tooltip: '完成',
          icon: const Icon(Icons.check),
          onPressed: () => Navigator.pop(context, _presets.where((e) => _chosen.contains(e.id)).toList()),
        ),
      ]),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('勾选的组会添加到分流规则，已有的同名组会被覆盖。', style: Theme.of(context).textTheme.bodySmall),
        ),
        for (final preset in _presets)
          CheckboxListTile(
            title: Text(preset.name),
            subtitle: widget.existing.contains(preset.id) ? const Text('已有') : null,
            value: _chosen.contains(preset.id),
            onChanged: (value) => setState(() => value == true ? _chosen.add(preset.id) : _chosen.remove(preset.id)),
          ),
      ]),
    );
  }
}
