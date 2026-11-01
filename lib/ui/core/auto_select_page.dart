import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/rule_group.dart';

import 'connect_page.dart';
import 'rule_groups_page.dart';

/// 自动选择的参数和自定义组。返回改名记录（旧 tag -> 新 tag），分流组里引用它们的要一起改
class AutoSelectPage extends StatefulWidget {
  const AutoSelectPage({super.key});

  @override
  State<AutoSelectPage> createState() => _AutoSelectPageState();
}

class _AutoSelectPageState extends State<AutoSelectPage> {
  final CoreManager _manager = CoreManager.instance;
  final Map<String, String> _renamed = {};

  CoreSettings get _settings => _manager.settings;

  List<String> get _nodes => _manager.nodes.map((e) => e['tag'].toString()).toList();

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _ask(String title, String initial, {bool number = false}) async {
    final controller = TextEditingController(text: initial);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return text;
  }

  /// 不能为空、不能超过 32 个字、不能重名。[current] 是改名时的原名
  String? _nameProblem(String name, {String? current}) {
    if (name.isEmpty) return '请填写名称';
    if (name.length > 32) return '名称不能超过 32 个字';
    return name != current && _settings.autoGroups.any((e) => e.name == name) ? '已经有同名的组了' : null;
  }

  Future<void> _add() async {
    final name = await _ask('添加自动选择组', '');
    if (name == null) return;
    final problem = _nameProblem(name);
    if (problem != null) return _show(problem);
    setState(() => _settings.autoGroups = [..._settings.autoGroups, AutoGroup(name: name)]);
    await _manager.saveUiSettings();
  }

  Future<void> _rename(AutoGroup group) async {
    final name = await _ask('改名', group.name);
    if (name == null || name == group.name) return;
    final problem = _nameProblem(name, current: group.name);
    if (problem != null) return _show(problem);

    final oldTag = group.tag, oldName = group.name;
    setState(() {
      group.name = name;
      for (final other in _settings.autoGroups) {
        if (other.front == oldName) other.front = name;
      }
      _renamed[oldTag] = group.tag;
    });
  }

  void _delete(AutoGroup group) {
    setState(() {
      _settings.autoGroups = _settings.autoGroups.where((e) => !identical(e, group)).toList();
      for (final other in _settings.autoGroups) {
        if (other.front == group.name) other.front = '';
      }
    });
  }

  Future<void> _editMembers(AutoGroup group) async {
    final result = await Navigator.of(context).push<AutoGroup>(MaterialPageRoute(
      builder: (_) => GroupMembersPage(group: group, nodes: _nodes),
    ));
    if (result == null) return;
    setState(() {
      group
        ..nodes = result.nodes
        ..keywords = result.keywords;
    });
  }

  /// 这些组不能当前置：自己，以及已经经过自己的组，选了就成环
  Set<String> _dependents(AutoGroup group) {
    final blocked = {group.name};
    var grew = true;
    while (grew) {
      grew = false;
      for (final other in _settings.autoGroups) {
        if (blocked.contains(other.front) && blocked.add(other.name)) grew = true;
      }
    }
    return blocked;
  }

  Future<void> _pickFront(AutoGroup group) async {
    final blocked = _dependents(group);
    final choices = _settings.autoGroups.where((e) => !blocked.contains(e.name)).map((e) => e.name).toList();
    final front = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: const Text('不用前置'),
            trailing: group.front.isEmpty ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, ''),
          ),
          for (final name in choices)
            ListTile(
              title: Text(name),
              trailing: group.front == name ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, name),
            ),
        ]),
      ),
    );
    if (front != null) setState(() => group.front = front);
  }

  Future<void> _editNumber(String title, int current, int low, int high, void Function(int) apply) async {
    final value = int.tryParse(await _ask(title, '$current', number: true) ?? '');
    if (value != null) setState(() => apply(value.clamp(low, high)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final theme = Theme.of(context);
    final nodes = _nodes;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_renamed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('自动选择'), actions: [
          IconButton(tooltip: '添加自动选择组', icon: const Icon(Icons.add), onPressed: _add),
        ]),
        body: ListView(children: [
          ListTile(
            title: const Text('测试间隔'),
            trailing: Text('${settings.autoTestMinutes} 分钟'),
            onTap: () => _editNumber('测试间隔（分钟）', settings.autoTestMinutes, 3, 365 * 1440, (e) => settings.autoTestMinutes = e),
          ),
          ListTile(
            title: const Text('容差'),
            subtitle: const Text('新节点要快过当前节点这么多才切换'),
            trailing: Text('${settings.autoTolerance} ms'),
            onTap: () => _editNumber('容差（毫秒）', settings.autoTolerance, 0, 5000, (e) => settings.autoTolerance = e),
          ),
          SwitchListTile(
            title: const Text('收藏优先'),
            subtitle: const Text('有收藏的节点时，只在收藏里选'),
            value: settings.autoPreferFavorites,
            onChanged: (value) => setState(() => settings.autoPreferFavorites = value),
          ),
          SwitchListTile(
            title: const Text('手动测完延迟后换到最快的节点'),
            value: settings.autoUpdateAfterTest,
            onChanged: (value) => setState(() => settings.autoUpdateAfterTest = value),
          ),
          ListTile(
            title: const Text('节点数上限'),
            subtitle: const Text('节点太多时只测前面这些'),
            trailing: Text('${settings.autoNodeLimit}'),
            onTap: () => _editNumber('节点数上限', settings.autoNodeLimit, 2, 100000, (e) => settings.autoNodeLimit = e),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('自定义组。设了前置的组，流量先经过前置组里最快的节点。前置组不要放延迟高的节点，否则这个组也会跟着变慢。',
                style: theme.textTheme.bodySmall),
          ),
          for (final group in [...settings.autoGroups]..sort((a, b) => a.name.compareTo(b.name)))
            ListTile(
              title: Text(group.front.isEmpty ? group.name : '${group.name} >-> ${group.front}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${group.membersIn(nodes).length} 个节点',
                  style: group.membersIn(nodes).isEmpty ? TextStyle(color: theme.colorScheme.error) : null),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: '前置组', icon: const Icon(Icons.link, size: 20), onPressed: () => _pickFront(group)),
                IconButton(tooltip: '改名', icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _rename(group)),
                IconButton(tooltip: '删除', icon: const Icon(Icons.close, size: 20), onPressed: () => _delete(group)),
              ]),
              onTap: () => _editMembers(group),
            ),
        ]),
      ),
    );
  }
}

/// 选自动选择组的成员：勾节点，或者写关键词
class GroupMembersPage extends StatefulWidget {
  final AutoGroup group;
  final List<String> nodes;

  const GroupMembersPage({super.key, required this.group, required this.nodes});

  @override
  State<GroupMembersPage> createState() => _GroupMembersPageState();
}

class _GroupMembersPageState extends State<GroupMembersPage> {
  late final Set<String> _chosen = {...widget.group.nodes};
  late final TextEditingController _keywords = TextEditingController(text: widget.group.keywords.join('\n'));
  String _query = '';

  @override
  void dispose() {
    _keywords.dispose();
    super.dispose();
  }

  void _done() {
    final keywords = _keywords.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    Navigator.of(context).pop(AutoGroup(name: widget.group.name, nodes: _chosen.toList(), keywords: keywords));
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final nodes = query.isEmpty ? widget.nodes : widget.nodes.where((e) => e.toLowerCase().contains(query)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.group.name), actions: [
        IconButton(tooltip: '完成', icon: const Icon(Icons.check), onPressed: _done),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _keywords,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '节点名包含，每行一个',
              hintText: '香港',
              helperText: '订阅更新后，新节点也会自动进这个组',
              border: OutlineInputBorder(),
            ),
          ),
        ),
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
            itemBuilder: (context, index) {
              final node = nodes[index];
              return CheckboxListTile(
                dense: true,
                title: Text(nodeLabel(node), maxLines: 1, overflow: TextOverflow.ellipsis),
                value: _chosen.contains(node),
                onChanged: (value) => setState(() => value == true ? _chosen.add(node) : _chosen.remove(node)),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// 链式代理：流量多经过几个节点
class ChainProxyPage extends StatefulWidget {
  const ChainProxyPage({super.key});

  @override
  State<ChainProxyPage> createState() => _ChainProxyPageState();
}

class _ChainProxyPageState extends State<ChainProxyPage> {
  final CoreManager _manager = CoreManager.instance;

  CoreSettings get _settings => _manager.settings;

  List<String> get _nodes => _manager.nodes.map((e) => e['tag'].toString()).toList();

  Future<void> _add() async {
    final available = _nodes.where((e) => !_settings.chain.contains(e)).toList();
    final node = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => NodePickerPage(nodes: available),
    ));
    if (node != null) setState(() => _settings.chain = [..._settings.chain, node]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = _settings;
    final nodes = _nodes;
    return Scaffold(
      appBar: AppBar(title: const Text('链式代理'), actions: [
        IconButton(tooltip: '添加节点', icon: const Icon(Icons.add), onPressed: _add),
      ]),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('放在当前节点前面'),
          subtitle: Text(settings.chainFront
              ? '应用 → 下面的节点 → 当前节点 → 网站'
              : '应用 → 当前节点 → 下面的节点 → 网站。下面的节点不能再选为当前节点'),
          value: settings.chainFront,
          onChanged: (value) => setState(() => settings.chainFront = value),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('从上到下依次经过。节点已不在当前配置里时标红，并被跳过。', style: theme.textTheme.bodySmall),
        ),
        for (final node in settings.chain)
          ListTile(
            title: Text(nodeLabel(node),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nodes.contains(node) ? null : TextStyle(color: theme.colorScheme.error)),
            trailing: IconButton(
              tooltip: '移除',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => setState(() => settings.chain = settings.chain.where((e) => e != node).toList()),
            ),
          ),
      ]),
    );
  }
}
