import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/rule_sets.dart';

import 'format.dart';
import 'profile_options.dart';

/// 规则集的更新方式和当前状态
class RuleSetsPage extends StatefulWidget {
  const RuleSetsPage({super.key});

  @override
  State<RuleSetsPage> createState() => _RuleSetsPageState();
}

class _RuleSetsPageState extends State<RuleSetsPage> {
  final CoreManager _manager = CoreManager.instance;
  List<RuleSetState> _states = const [];
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final states = await _manager.ruleSetStates();
    if (mounted) setState(() => _states = states);
  }

  void _change(VoidCallback change) {
    setState(change);
    _manager.saveUiSettings();
  }

  Future<void> _editInterval() async {
    final controller = TextEditingController(text: '${_manager.settings.ruleSetUpdateHours}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更新间隔（小时）'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    final hours = int.tryParse(text ?? '');
    if (hours != null) _change(() => _manager.settings.ruleSetUpdateHours = hours < 1 ? 1 : hours);
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    final (succeeded, failed) = await _manager.updateRuleSets();
    await _load();
    if (!mounted) return;
    setState(() => _updating = false);
    final message = succeeded + failed == 0 ? '没有需要下载的规则集' : '成功 $succeeded 个，失败 $failed 个';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = _manager.settings;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('规则集')),
      body: ListView(children: [
        ListTile(
          title: const Text('更新间隔'),
          trailing: Text('${settings.ruleSetUpdateHours} 小时'),
          onTap: _editInterval,
        ),
        SwitchListTile(
          title: const Text('内置规则集也从网上更新'),
          subtitle: const Text('关闭时只更新另外下载的规则集'),
          value: settings.updateBundledRuleSets,
          onChanged: (value) => _change(() => settings.updateBundledRuleSets = value),
        ),
        ListTile(
          title: const Text('下载方式'),
          trailing: DropdownButton<DownloadStrategy>(
            value: settings.ruleSetDownload,
            underline: const SizedBox.shrink(),
            items: [
              for (final entry in downloadStrategyLabels.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => _change(() => settings.ruleSetDownload = value!),
          ),
        ),
        ListTile(
          title: const Text('立即更新'),
          trailing: _updating
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          onTap: _updating ? null : _update,
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('正在使用 ${_states.length} 个', style: theme.textTheme.titleSmall),
        ),
        for (final state in _states)
          ListTile(
            dense: true,
            title: Text(state.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: state.updatedAt == null
                ? Text('未下载', style: TextStyle(color: theme.colorScheme.error))
                : Text(formatDate(state.updatedAt!), style: theme.textTheme.bodySmall),
          ),
      ]),
    );
  }
}

/// 选规则集。列表有两千多项，只把名称放进安装包，选中的用到时才下载
class RuleSetPickerPage extends StatefulWidget {
  final List<String> selected;

  const RuleSetPickerPage({super.key, required this.selected});

  @override
  State<RuleSetPickerPage> createState() => _RuleSetPickerPageState();
}

class _RuleSetPickerPageState extends State<RuleSetPickerPage> {
  static const Map<String, String> _kinds = {'geosite-': 'GeoSite', 'geoip-': 'GeoIP', 'acl-': 'ACL'};

  late final Set<String> _selected = {...widget.selected};
  List<String> _all = const [];
  bool _loaded = false;
  String _kind = _kinds.keys.first;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<String> names = const [];
    try {
      final text = await rootBundle.loadString('assets/rules/index.txt');
      names = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } on FlutterError {
      // 开发时没有跑 fetch_rule_sets.sh，这里就是空的
    }
    if (mounted) {
      setState(() {
        _all = names;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final names = _all.where((e) => e.startsWith(_kind) && e.toLowerCase().contains(query)).toList();
    return Scaffold(
      appBar: AppBar(title: Text('已选 ${_selected.length} 个'), actions: [
        IconButton(
          tooltip: '完成',
          icon: const Icon(Icons.check),
          onPressed: () => Navigator.pop(context, _selected.toList()),
        ),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<String>(
            segments: [for (final kind in _kinds.entries) ButtonSegment(value: kind.key, label: Text(kind.value))],
            selected: {_kind},
            onSelectionChanged: (value) => setState(() => _kind = value.first),
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
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : _all.isEmpty
                  ? const Center(child: Text('这个版本没有带规则集列表'))
                  : ListView.builder(
                      itemCount: names.length,
                      itemBuilder: (context, index) {
                        final name = names[index];
                        return CheckboxListTile(
                          dense: true,
                          title: Text(name.substring(_kind.length)),
                          value: _selected.contains(name),
                          onChanged: (value) =>
                              setState(() => value == true ? _selected.add(name) : _selected.remove(name)),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
