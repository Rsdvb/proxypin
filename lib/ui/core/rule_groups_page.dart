import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/clash_routing.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/dns_catalog.dart';
import 'package:proxypin/core/rule_group.dart';
import 'package:proxypin/utils/platform.dart';

import 'auto_select_page.dart';
import 'connect_page.dart';
import 'design.dart';
import 'rule_group_edit_page.dart';
import 'rule_sets_page.dart';
import 'tools_pages.dart';

/// 一个分流组里有什么，列表上一眼看到
String ruleGroupSummary(RuleGroup group) {
  final json = group.toJson();
  int count(List<String> keys) => keys.fold(0, (sum, key) => sum + ((json[key] as List?)?.length ?? 0));
  final parts = [
    if (count(const ['ruleSets', 'ruleSetUrls']) > 0) '规则集 ${count(const ['ruleSets', 'ruleSetUrls'])}',
    if (count(const ['domainSuffixes', 'domains', 'domainKeywords', 'domainRegexes']) > 0)
      '域名 ${count(const ['domainSuffixes', 'domains', 'domainKeywords', 'domainRegexes'])}',
    if (count(const ['ipCidrs']) > 0) 'IP ${count(const ['ipCidrs'])}',
    if (count(const ['ports', 'portRanges']) > 0) '端口 ${count(const ['ports', 'portRanges'])}',
    if (count(const ['processNames', 'processPaths', 'processDirs']) > 0)
      '进程 ${count(const ['processNames', 'processPaths', 'processDirs'])}',
    if (count(const ['wifiSsids', 'wifiBssids']) > 0) 'Wi-Fi ${count(const ['wifiSsids', 'wifiBssids'])}',
    if (count(const ['networks', 'protocols', 'networkTypes']) > 0)
      '协议 ${count(const ['networks', 'protocols', 'networkTypes'])}',
  ];
  return parts.isEmpty ? '还没有匹配内容' : parts.join(' · ');
}

/// 分流：每一行是“什么流量 → 走哪里”，点一下就能改去向。
/// 增删、排序和改匹配内容放在“管理”里，平时用不到
class RuleGroupsPage extends StatefulWidget {
  /// 分流是常驻的入口，不会被关掉，所以切走时保存
  final ValueListenable<int>? visibleTab;
  final int ownTab;

  const RuleGroupsPage({super.key, this.visibleTab, this.ownTab = 2});

  @override
  State<RuleGroupsPage> createState() => _RuleGroupsPageState();
}

class _RuleGroupsPageState extends State<RuleGroupsPage> {
  static const double _twoColumns = 860;
  static const double _sideWidth = 340;

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

  Iterable<String> get _usableGroups =>
      _manager.settings.autoGroups.where((e) => e.membersIn(_nodes).isNotEmpty).map((e) => e.tag);

  @override
  void initState() {
    super.initState();
    widget.visibleTab?.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    widget.visibleTab?.removeListener(_onTabChanged);
    _save();
    super.dispose();
  }

  void _onTabChanged() {
    if (widget.visibleTab!.value != widget.ownTab) return _apply();
    // 连接页也能往这里加规则，切回来时要看到
    if (!_changed) setState(() => _groups = _copy(_manager.settings.groups));
  }

  /// 在副本上改，一次保存：每动一下就重启内核，连接会一直断
  void _save() {
    if (!_changed) return;
    _changed = false;
    _manager.settings.groups = _copy(_groups);
    _manager.applySettings();
  }

  void _apply() => setState(_save);

  void _change(VoidCallback change) {
    setState(() {
      change();
      _changed = true;
    });
  }

  String _targetLabel(String target) => switch (target) {
        RuleTarget.selected => '跟随节点',
        RuleTarget.auto => '自动选择',
        RuleTarget.direct => '直连',
        RuleTarget.block => '拦截',
        _ => nodeLabel(target),
      };

  /// 选的节点在订阅更新后没了，或者自动选择组没有成员了，这时实际走的是首页选中的节点
  bool _isGone(String target) =>
      !RuleTarget.builtIn.contains(target) && !_nodes.contains(target) && !_usableGroups.contains(target);

  Color _targetColor(String target) {
    if (_isGone(target)) return Tone.bad;
    return switch (target) {
      RuleTarget.selected => Theme.of(context).colorScheme.primary,
      RuleTarget.direct => Tone.good,
      RuleTarget.block => Tone.bad,
      RuleTarget.auto => Tone.violet,
      _ when target.startsWith(RuleTarget.groupPrefix) => Tone.violet,
      _ => Palette.of(context).muted,
    };
  }

  Widget _targetTag(String target, {bool enabled = true}) {
    if (!enabled) return Tag('已关闭', color: Palette.of(context).faint);
    return Tag(_targetLabel(target), color: _targetColor(target));
  }

  /// 去向选项：常用的几个直接点，节点进单独的页面搜
  List<Widget> _targetChoices(BuildContext context, String current) {
    final nodes = _nodes;
    return [
      for (final choice in [
        RuleTarget.selected,
        if (nodes.length > 1) RuleTarget.auto,
        ..._usableGroups,
        RuleTarget.direct,
        RuleTarget.block,
      ])
        ListTile(
          leading: Icon(Icons.circle, size: 10, color: _targetColor(choice)),
          title: Text(_targetLabel(choice)),
          trailing: current == choice ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () => Navigator.pop(context, choice),
        ),
      if (nodes.isNotEmpty)
        ListTile(
          leading: Icon(Icons.circle, size: 10, color: Palette.of(context).muted),
          title: const Text('选择节点'),
          subtitle: nodes.contains(current) ? Text(_targetLabel(current), maxLines: 1, overflow: TextOverflow.ellipsis) : null,
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
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(group.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(ruleGroupSummary(group), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            ..._targetChoices(context, group.target),
            const Divider(height: 12),
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
              secondary: const Icon(Icons.power_settings_new),
              title: const Text('启用'),
              value: group.enabled,
              onChanged: (value) {
                _change(() => group.enabled = value);
                Navigator.pop(context);
              },
            ),
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
      useRootNavigator: true,
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

  Future<void> _edit(RuleGroup group) async {
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
      } else {
        _groups[_groups.indexOf(group)] = result.group!;
      }
    });
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ManageRuleGroupsPage(groups: _groups, onChanged: () => _change(() {})),
    ));
    if (mounted) setState(() {});
  }

  /// 自动选择组和链式代理改的是设置本身，离开分流页时一起保存
  Future<void> _openAutoSelect() async {
    final renamed = await Navigator.of(context).push<Map<String, String>>(MaterialPageRoute(
      builder: (_) => const AutoSelectPage(),
    ));
    _change(() {
      final settings = _manager.settings;
      settings.finalTarget = renamed?[settings.finalTarget] ?? settings.finalTarget;
      for (final group in _groups) {
        group.target = renamed?[group.target] ?? group.target;
      }
    });
  }

  Future<void> _openChain() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChainProxyPage()));
    _change(() {});
  }

  Future<void> _openRuleSets() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RuleSetsPage()));
    if (mounted) setState(() {});
  }

  Widget _providerTag(ProviderGroup group) {
    final target = _manager.providerTarget(group.name);
    final palette = Palette.of(context);
    return switch (target) {
      null => Tag(group.type == 'selector' ? '默认' : '自动', color: palette.muted),
      ProviderRouting.direct => const Tag('直连', color: Tone.good),
      ProviderRouting.reject => const Tag('拦截', color: Tone.bad),
      _ => Tag(target, color: Theme.of(context).colorScheme.primary),
    };
  }

  /// 机场的组不改名字也不改规则，只换去向，订阅更新后还在
  Future<void> _pickProviderTarget(ProviderGroup group) async {
    final current = _manager.providerTarget(group.name);
    Widget choice(BuildContext context, String title, String value) => ListTile(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: (current ?? '') == value ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () => Navigator.pop(context, value),
        );

    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(group.name, style: Theme.of(context).textTheme.titleLarge),
            ),
            choice(context, group.type == 'selector' ? '按订阅默认' : '自动测速', ''),
            choice(context, '直连', ProviderRouting.direct),
            choice(context, '拦截', ProviderRouting.reject),
            const Divider(height: 12),
            for (final member in group.members.where((e) => e != ProviderRouting.direct && e != ProviderRouting.reject))
              choice(context, member, member),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    _change(() => _manager.setProviderTarget(group.name, picked.isEmpty ? null : picked));
  }

  Future<void> _openRegion() async {
    final region = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => RegionPage(current: _manager.settings.region),
    ));
    if (region != null && mounted) _change(() => _manager.settings.region = region);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _manager.settings;
    final missing = _manager.missingRuleSets.length;
    final visible = settings.hideDisabledGroups ? _groups.where((e) => e.enabled).toList() : _groups;
    final accent = Theme.of(context).colorScheme.primary;
    final providerGroups = _manager.providerGroups;
    return Scaffold(
      appBar: AppBar(title: const Text('分流')),
      bottomNavigationBar: _changed
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  const Expanded(child: Text('有改动，切换页面时自动生效')),
                  FilledButton(onPressed: _apply, child: const Text('立即生效')),
                ]),
              ),
            )
          : null,
      body: LayoutBuilder(builder: (context, constraints) {
        final rules = <Widget>[
          if (missing > 0)
            Panel(children: [
              InfoRow(
                icon: Icons.warning_amber,
                iconColor: Tone.warn,
                title: '$missing 个规则集还没下载成功',
                subtitle: '对应的规则暂未生效',
                onTap: _openRuleSets,
              ),
            ]),
          SectionLabel(
            '分流规则',
            hint: '从上到下匹配',
            action: TextButton(onPressed: _openManage, child: const Text('管理')),
          ),
          Panel(children: [
            SwitchRow(
              title: '启用自定义分流组',
              value: settings.groupsEnabled,
              onChanged: (value) => _change(() => settings.groupsEnabled = value),
            ),
            if (settings.groupsEnabled)
              for (final group in visible)
                InfoRow(
                  key: ValueKey(group.id),
                  title: group.name,
                  subtitle: ruleGroupSummary(group),
                  enabled: group.enabled,
                  onTap: () => _openGroup(group),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (group.dnsServer.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(Icons.dns_outlined, size: 15, color: Palette.of(context).muted),
                      ),
                    _targetTag(group.target, enabled: group.enabled),
                  ]),
                ),
          ]),
          if (settings.providerRulesEnabled && providerGroups.isNotEmpty) ...[
            const SectionLabel('机场分流组', hint: '订阅自带的规则，点一下改去向'),
            Panel(children: [
              for (final group in providerGroups)
                InfoRow(
                  key: ValueKey('provider:${group.name}'),
                  title: group.name,
                  subtitle: '${group.type == 'selector' ? '手动选择' : '自动测速'} · ${group.members.length} 个成员',
                  onTap: () => _pickProviderTarget(group),
                  trailing: _providerTag(group),
                ),
            ]),
          ],
          const SectionLabel('其余流量', hint: '上面都没有命中时走这里'),
          Panel(children: [
            InfoRow(title: '其余流量', onTap: _pickFinal, trailing: _targetTag(settings.finalTarget)),
          ]),
        ];
        final tools = <Widget>[
        const SectionLabel('基础规则'),
        Panel(children: [
          SwitchRow(
            title: '私有网络直连',
            subtitle: '局域网和本机地址不走节点',
            value: settings.privateDirect,
            onChanged: (value) => _change(() => settings.privateDirect = value),
          ),
          SwitchRow(
            title: '机场分流规则',
            subtitle: '使用订阅里自带的规则',
            value: settings.providerRulesEnabled,
            onChanged: (value) => _change(() => settings.providerRulesEnabled = value),
          ),
          SwitchRow(
            title: '隐藏未启用的规则',
            value: settings.hideDisabledGroups,
            onChanged: (value) {
              setState(() => settings.hideDisabledGroups = value);
              _manager.saveUiSettings();
            },
          ),
        ]),
        const SectionLabel('规则来源和出站'),
        Panel(children: [
          InfoRow(
            icon: Icons.flag_outlined,
            iconColor: Tone.good,
            title: '国家与地区',
            subtitle: regionLabel(settings.region),
            onTap: _openRegion,
          ),
          InfoRow(icon: Icons.inventory_2_outlined, iconColor: accent, title: '规则集', onTap: _openRuleSets),
          InfoRow(icon: Icons.auto_awesome_outlined, iconColor: Tone.violet, title: '自动选择组', onTap: _openAutoSelect),
          InfoRow(
            icon: Icons.link,
            iconColor: Tone.teal,
            title: '链式代理',
            subtitle: settings.chain.isEmpty ? null : '${settings.chain.length} 个节点',
            onTap: _openChain,
          ),
          InfoRow(
            icon: Icons.rule,
            iconColor: Tone.warn,
            title: '规则检测',
            subtitle: _manager.isRunning ? '看某个域名会走哪条规则' : '连接后可用',
            enabled: _manager.isRunning,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RuleCheckPage())),
          ),
        ]),
        ];
        if (constraints.maxWidth < _twoColumns) return ContentColumn(children: [...rules, ...tools]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: ContentColumn(maxWidth: double.infinity, children: rules)),
          SizedBox(width: _sideWidth, child: ContentColumn(children: tools)),
        ]);
      }),
    );
  }
}

/// 管理分流组：增删、排序、导入导出
class ManageRuleGroupsPage extends StatefulWidget {
  final List<RuleGroup> groups;
  final VoidCallback onChanged;

  const ManageRuleGroupsPage({super.key, required this.groups, required this.onChanged});

  @override
  State<ManageRuleGroupsPage> createState() => _ManageRuleGroupsPageState();
}

class _ManageRuleGroupsPageState extends State<ManageRuleGroupsPage> {
  List<RuleGroup> get _groups => widget.groups;

  void _change(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

  void _reset() => _change(() {
        _groups
          ..clear()
          ..addAll(RuleGroup.defaults());
      });

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('管理分流组'), actions: [
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
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppPage.contentWidth),
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            header: Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text('拖动调整顺序，靠上的先匹配。点一下编辑匹配内容。', style: Theme.of(context).textTheme.bodySmall),
            ),
            itemCount: _groups.length,
            onReorder: (oldIndex, newIndex) => _change(() {
              _groups.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, _groups.removeAt(oldIndex));
            }),
            itemBuilder: (context, index) {
              final group = _groups[index];
              return Padding(
                key: ValueKey(group.id),
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: palette.panel,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: SizedBox(
                      width: 22,
                      child: Text('${index + 1}', textAlign: TextAlign.center, style: TextStyle(color: palette.faint, fontSize: 13)),
                    ),
                    title: Text(group.name),
                    subtitle: Text(ruleGroupSummary(group), maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Icon(Icons.drag_handle, color: palette.faint, size: 20),
                    onTap: () => _edit(group),
                  ),
                ),
              );
            },
          ),
        ),
      ),
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
            decoration: const InputDecoration(hintText: '搜索', prefixIcon: Icon(Icons.search)),
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
