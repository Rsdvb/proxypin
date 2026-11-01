import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/rule_group.dart';

import 'connect_page.dart';

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

  static List<RuleGroup> _copy(List<RuleGroup> groups) => groups.map((e) => RuleGroup.fromJson(e.toJson())).toList();

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  @override
  void dispose() {
    if (_changed) _manager.saveGroups(_groups);
    super.dispose();
  }

  String _targetLabel(String target) => switch (target) {
        RuleTarget.selected => '跟随节点',
        RuleTarget.direct => '直连',
        RuleTarget.block => '拦截',
        _ => nodeLabel(target),
      };

  Future<void> _pickTarget(RuleGroup group) async {
    final nodes = _manager.nodes.map((e) => e['tag'].toString()).toList();
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            for (final choice in [RuleTarget.selected, RuleTarget.direct, RuleTarget.block, ...nodes])
              ListTile(
                title: Text(_targetLabel(choice), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: group.target == choice ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, choice),
              ),
          ]),
        ),
      ),
    );
    if (target != null) _change(() => group.target = target);
  }

  Future<void> _edit(RuleGroup? group) async {
    final result = await Navigator.of(context).push<_EditResult>(MaterialPageRoute(
      builder: (_) => EditRuleGroupPage(group: group),
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

  Future<void> _reset() async {
    _change(() => _groups = RuleGroup.defaults());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分流'), actions: [
        IconButton(tooltip: '添加分流组', icon: const Icon(Icons.add), onPressed: () => _edit(null)),
        PopupMenuButton<String>(
          onSelected: (_) => _reset(),
          itemBuilder: (context) => const [PopupMenuItem(value: 'reset', child: Text('恢复默认'))],
        ),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('从上到下匹配，都没有命中时跟随选中的节点。长按拖动调整顺序。', style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: _groups.length,
            onReorder: (oldIndex, newIndex) => _change(() {
              final item = _groups.removeAt(oldIndex);
              _groups.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, item);
            }),
            itemBuilder: (context, index) {
              final group = _groups[index];
              return ListTile(
                key: ValueKey(group.id),
                leading: Switch(value: group.enabled, onChanged: (value) => _change(() => group.enabled = value)),
                title: Text(group.name),
                subtitle: Text(_targetLabel(group.target), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                    tooltip: '编辑', icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _edit(group)),
                onTap: () => _pickTarget(group),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _EditResult {
  final RuleGroup? group;
  final bool remove;

  const _EditResult(this.group, {this.remove = false});
}

/// 编辑一个分流组的匹配内容，每行一条
class EditRuleGroupPage extends StatefulWidget {
  final RuleGroup? group;

  const EditRuleGroupPage({super.key, this.group});

  @override
  State<EditRuleGroupPage> createState() => _EditRuleGroupPageState();
}

class _EditRuleGroupPageState extends State<EditRuleGroupPage> {
  late final RuleGroup? _group = widget.group;
  late final TextEditingController _name = TextEditingController(text: _group?.name);
  late final TextEditingController _suffixes = _lines(_group?.domainSuffixes);
  late final TextEditingController _keywords = _lines(_group?.domainKeywords);
  late final TextEditingController _cidrs = _lines(_group?.ipCidrs);
  late final TextEditingController _processes = _lines(_group?.processNames);

  TextEditingController _lines(List<String>? values) => TextEditingController(text: values?.join('\n'));

  List<String> _parse(TextEditingController controller) =>
      controller.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  @override
  void dispose() {
    for (final controller in [_name, _suffixes, _keywords, _cidrs, _processes]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写名称')));
      return;
    }
    final json = _group?.toJson() ?? {'id': DateTime.now().microsecondsSinceEpoch.toString()};
    Navigator.of(context).pop(_EditResult(RuleGroup.fromJson({
      ...json,
      'name': name,
      'domainSuffixes': _parse(_suffixes),
      'domainKeywords': _parse(_keywords),
      'ipCidrs': _parse(_cidrs),
      'processNames': _parse(_processes),
    })));
  }

  Widget _field(TextEditingController controller, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        minLines: 2,
        maxLines: 6,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_group == null ? '添加分流组' : '编辑分流组'), actions: [
        if (_group != null)
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => Navigator.of(context).pop(const _EditResult(null, remove: true)),
          ),
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder()),
          ),
        ),
        if (_group?.ruleSets.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('内置规则：${_group!.ruleSets.join('、')}', style: Theme.of(context).textTheme.bodySmall),
          ),
        _field(_suffixes, '域名后缀，每行一个', 'example.com'),
        _field(_keywords, '域名关键字，每行一个', 'google'),
        _field(_cidrs, 'IP 段，每行一个', '1.2.3.0/24'),
        _field(_processes, 'Windows 进程名，每行一个', 'chrome.exe'),
      ]),
    );
  }
}
