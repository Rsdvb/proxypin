import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/rule_group.dart';

import 'connect_page.dart';
import 'design.dart';
import 'format.dart';
import 'node_edit_page.dart';
import 'profile_options.dart';

/// 列表里的一行。节点可能上千个，所以先摊平成一维再懒加载
sealed class _Row {
  const _Row();
}

class _Title extends _Row {
  final String text;
  final Widget? action;

  const _Title(this.text, {this.action});
}

class _Fixed extends _Row {
  final String tag;

  const _Fixed(this.tag);
}

class _Node extends _Row {
  final String tag;
  final int number;

  const _Node(this.tag, this.number);
}

class _Group extends _Row {
  final NodeGroup group;

  const _Group(this.group);
}

/// 选节点。点一下立即切换，不用再确认；长按或右键管理节点
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  /// 收起的分组，退出页面再进还在
  static final Set<String> _collapsed = {};
  static const int _recommendedLimit = 3;

  final CoreManager _manager = CoreManager.instance;
  final TextEditingController _search = TextEditingController();
  final Set<String> _updating = {};
  String _keyword = '';

  /// 地区，null 表示全部
  String? _filter;

  CoreSettings get _settings => _manager.settings;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _test([Iterable<String>? tags]) async {
    await _manager.testLatency(tags: tags, connectFirst: true);
    final error = _manager.lastError;
    if (error != null && !_manager.isRunning) _show(error);
  }

  Future<void> _select(String tag, Map<String, dynamic>? node) async {
    if (node != null && _manager.isDisabled(node)) return _show('这个节点已禁用，长按可以启用');
    await _manager.selectNode(tag);
    if (node == null) return;
    final server = node['server']?.toString() ?? '';
    if (server == '127.0.0.1' || server == 'localhost') {
      _show('这个节点的地址是本机，手机或别的设备上通常连不上');
    } else if (server.contains(':') && _settings.ipStrategy == IpStrategy.ipv4Only) {
      _show('这是 IPv6 节点，但 IPv6 没有开启，可能连不上');
    }
  }

  // ---- 过滤和排序 ----

  /// 节点名或协议包含关键词，或者关键词当正则能匹配节点名。正则写错了就只做包含匹配
  bool Function(String tag, String type) _matcher() {
    final keyword = _keyword.toLowerCase();
    if (keyword.isEmpty) return (_, __) => true;
    RegExp? regex;
    try {
      regex = RegExp(_keyword, caseSensitive: false);
    } on FormatException {
      regex = null;
    }
    return (tag, type) => tag.toLowerCase().contains(keyword) || type.contains(keyword) || regex?.hasMatch(tag) == true;
  }

  /// 正在测时不重排也不隐藏，否则节点在手指底下跳来跳去
  List<String> _arrange(NodeGroup group, bool Function(String) visible) {
    final tags = group.tags.where(visible).toList();
    if (group.tags.any(_manager.testingNodes.contains)) return tags;
    if (_settings.hideFailedNodes) tags.removeWhere(_manager.failedNodes.contains);
    if (_settings.sortNodesByDelay) {
      // 有延迟的在前，没测过的其次，不通的垫底
      int rank(String tag) => _manager.delays[tag] ?? (_manager.failedNodes.contains(tag) ? 1 << 31 : 1 << 30);
      tags.sort((a, b) => rank(a).compareTo(rank(b)));
    }
    return tags;
  }

  List<_Row> _rows(Map<String, Map<String, dynamic>> byTag) {
    final enabled = _manager.nodes.map((e) => e['tag'].toString()).toSet();
    final matches = _matcher();
    bool visible(String tag) =>
        matches(tag, byTag[tag]?['type']?.toString().toLowerCase() ?? '') && (_filter == null || NodeRegions.of(tag) == _filter);

    final rows = <_Row>[
      if (enabled.length > 1) const _Fixed(RuleTarget.auto),
      for (final group in _settings.autoGroups)
        if (group.membersIn(enabled).isNotEmpty) _Fixed(group.tag),
      const _Fixed(RuleTarget.direct),
    ];

    if (_keyword.isEmpty && _filter == null) {
      final fastest = enabled.where(_manager.delays.containsKey).toList()
        ..sort((a, b) => _manager.delays[a]!.compareTo(_manager.delays[b]!));
      if (!_settings.hideRecommendedNodes && fastest.isNotEmpty) {
        rows.add(const _Title('推荐'));
        rows.addAll(_numbered(fastest.take(_recommendedLimit)));
      }

      final recent = _settings.recentNodes.where(byTag.containsKey);
      if (!_settings.hideRecentNodes && recent.isNotEmpty) {
        rows.add(_Title('最近',
            action: IconButton(
              tooltip: '清空最近',
              icon: const Icon(Icons.close, size: 18),
              onPressed: _manager.clearRecentNodes,
            )));
        rows.addAll(_numbered(recent));
      }

      final favorites = byTag.keys.where(_settings.favorites.contains).toList();
      if (!_settings.hideFavoriteNodes && favorites.isNotEmpty) {
        rows.add(_Title('收藏',
            action: IconButton(
              tooltip: '测收藏节点的延迟',
              icon: const Icon(Icons.bolt_outlined, size: 20),
              onPressed: _manager.testing ? null : () => _test(favorites),
            )));
        rows.addAll(_numbered(favorites));
      }
    }

    final groups = _manager.nodeGroups;
    for (final group in groups) {
      rows.add(_Group(group));
      // 搜索时无视折叠，不然搜到了也看不见
      if (_keyword.isNotEmpty || _filter != null || !_collapsed.contains(group.profile.id)) {
        rows.addAll(_numbered(_arrange(group, visible)));
      }
    }
    return rows;
  }

  Iterable<_Node> _numbered(Iterable<String> tags) => tags.indexed.map((e) => _Node(e.$2, e.$1 + 1));

  // ---- 操作 ----

  Future<void> _updateGroup(Profile profile) async {
    setState(() => _updating.add(profile.id));
    try {
      await _manager.updateProfile(profile);
    } catch (e) {
      _show(describeProfileError(e));
    } finally {
      if (mounted) setState(() => _updating.remove(profile.id));
    }
  }

  Future<void> _openMenu(String tag, Map<String, dynamic> node) async {
    final disabled = _manager.isDisabled(node);
    final endpoint = CoreManager.endpointOf(node);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: Icon(disabled ? Icons.check_circle_outline : Icons.block),
            title: Text(disabled ? '启用' : '禁用'),
            subtitle: Text(endpoint, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(context, 'disable'),
          ),
          ListTile(
            leading: const Icon(Icons.data_object),
            title: const Text('查看'),
            onTap: () => Navigator.pop(context, 'view'),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text('分享'),
            onTap: () => Navigator.pop(context, 'share'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('编辑'),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
          if (!_manager.testingNodes.contains(tag))
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'disable':
        await _manager.setNodeDisabled(node, !disabled);
      case 'view':
        await showNodeJson(context, node);
      case 'share':
        await showNodeShare(context, node);
      case 'edit':
        await _edit(tag, node);
      case 'remove':
        await _remove(tag);
    }
  }

  Future<void> _edit(String tag, Map<String, dynamic> node) async {
    final profile = _manager.nodeGroups.where((e) => e.tags.contains(tag)).firstOrNull?.profile;
    if (profile?.isSubscription == true && !await _confirm('编辑节点', '这是订阅里的节点，订阅更新后修改会被还原。')) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NodeEditPage(tag: tag, node: node)));
  }

  Future<void> _remove(String tag) async {
    if (await _confirm('删除节点', '确定删除“$tag”？')) await _manager.removeNode(tag);
  }

  Future<bool> _confirm(String title, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _openKeywords() async {
    final word = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const SearchKeywordsPage()));
    if (word == null) return;
    _search.text = word;
    setState(() => _keyword = word);
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Widget toggle(String title, bool value, void Function(bool) apply) => SwitchListTile(
                title: Text(title),
                value: value,
                onChanged: (changed) {
                  setSheet(() => apply(changed));
                  setState(() {});
                  _manager.saveUiSettings();
                },
              );
          return SafeArea(
            child: ListView(shrinkWrap: true, children: [
              toggle('隐藏推荐', _settings.hideRecommendedNodes, (e) => _settings.hideRecommendedNodes = e),
              toggle('隐藏最近', _settings.hideRecentNodes, (e) => _settings.hideRecentNodes = e),
              toggle('隐藏收藏', _settings.hideFavoriteNodes, (e) => _settings.hideFavoriteNodes = e),
              toggle('隐藏不通的节点', _settings.hideFailedNodes, (e) => _settings.hideFailedNodes = e),
              toggle('按延迟排序', _settings.sortNodesByDelay, (e) => _settings.sortNodesByDelay = e),
            ]),
          );
        },
      ),
    );
  }

  void _toggleAllGroups() {
    final groups = _manager.nodeGroups.map((e) => e.profile.id);
    setState(() {
      if (groups.any((e) => !_collapsed.contains(e))) {
        _collapsed.addAll(groups);
      } else {
        _collapsed.removeAll(groups);
      }
    });
  }

  // ---- 界面 ----

  Widget _delayCell(String tag, {bool testable = true}) {
    final delay = _manager.delays[tag];
    if (_manager.testingNodes.contains(tag)) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (!testable) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final Widget content = delay != null
        ? Text('$delay ms', style: TextStyle(color: delayColor(context, delay)))
        : Icon(
            _manager.failedNodes.contains(tag) ? Icons.warning_amber : Icons.bolt_outlined,
            size: 18,
            color: _manager.failedNodes.contains(tag) ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
          );
    return InkWell(
      onTap: () => _test([tag]),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10), child: content),
    );
  }

  /// 自动选择、自定义组和直连
  Widget _fixedTile(String tag, String selected) {
    final group = _settings.autoGroups.where((e) => e.tag == tag).firstOrNull;
    final enabled = _manager.nodes.map((e) => e['tag'].toString());
    final members = group?.membersIn(enabled) ?? const <String>[];
    final delays = members.map((e) => _manager.delays[e]).nonNulls.toList()..sort();
    final actual = tag == selected ? _manager.activeNode : null;
    final delay = actual == null ? delays.firstOrNull : _manager.delays[actual];
    return ListTile(
      dense: true,
      selected: tag == selected,
      title: Text(nodeLabel(tag), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: actual != null
          ? Text('正在使用 $actual', maxLines: 1, overflow: TextOverflow.ellipsis)
          : group == null
              ? null
              : Text('${delays.length}/${members.length} 可用'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (delay != null) Text('$delay ms', style: TextStyle(color: delayColor(context, delay))),
        if (tag == RuleTarget.auto)
          IconButton(
            tooltip: '说明',
            icon: const Icon(Icons.info_outline, size: 18),
            onPressed: () => _show('定时测试全部节点，自动走延迟最低的那个。'),
          ),
      ]),
      onTap: () => _select(tag, null),
    );
  }

  Widget _nodeTile(_Node row, String selected, Map<String, Map<String, dynamic>> byTag) {
    final tag = row.tag;
    final node = byTag[tag]!;
    final theme = Theme.of(context);
    final disabled = _manager.isDisabled(node);
    final favorite = _settings.favorites.contains(tag);
    return GestureDetector(
      onSecondaryTap: () => _openMenu(tag, node),
      child: ListTile(
        dense: true,
        selected: tag == selected,
        tileColor: disabled ? theme.colorScheme.surfaceContainerHighest : null,
        minLeadingWidth: 20,
        leading: Text('${row.number}', style: theme.textTheme.bodySmall),
        title: Text(nodeLabel(tag), maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text(disabled ? '${nodeTypeLabel(node)} · 已禁用' : nodeTypeLabel(node)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          _delayCell(tag, testable: !disabled),
          IconButton(
            tooltip: '收藏',
            icon: Icon(favorite ? Icons.star : Icons.star_border, size: 20, color: favorite ? Colors.orange : null),
            onPressed: () => _manager.toggleFavorite(tag),
          ),
        ]),
        onTap: () => _select(tag, node),
        onLongPress: () => _openMenu(tag, node),
      ),
    );
  }

  Widget _groupHeader(NodeGroup group) {
    final theme = Theme.of(context);
    final profile = group.profile;
    final collapsed = _collapsed.contains(profile.id);
    final info = profile.info;
    return InkWell(
        onTap: () => setState(() => collapsed ? _collapsed.remove(profile.id) : _collapsed.add(profile.id)),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('${profile.name}[${group.tags.length}]', maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (profile.isSubscription)
                _updating.contains(profile.id)
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        tooltip: '更新',
                        icon: const Icon(Icons.cloud_download_outlined, size: 20),
                        onPressed: () => _updateGroup(profile),
                      ),
              IconButton(
                tooltip: '测这一组的延迟',
                icon: const Icon(Icons.bolt_outlined, size: 20),
                onPressed: _manager.testing ? null : () => _test(group.tags),
              ),
            ]),
            if (info != null && info.total > 0)
              Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 8),
                child: Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
                  TextSpan(
                    text: '↑ ${formatBytes(info.upload)} ↓ ${formatBytes(info.download)} / ${formatBytes(info.total)}',
                    style: info.used >= info.total ? TextStyle(color: theme.colorScheme.error) : null,
                  ),
                  if (info.expire != null)
                    TextSpan(
                      text: ' · ${formatDate(info.expire!)} 到期',
                      style: info.expire!.isBefore(DateTime.now().add(const Duration(days: 7)))
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                ])),
              ),
          ]),
        ),
    );
  }

  Widget _title(_Title row) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
      child: SectionLabel(row.text, action: row.action),
    );
  }

  /// 连续的行拼成一张卡片。节点可能上千个，只能一行一行画圆角
  Widget _card(List<_Row> rows, int index, Widget child) {
    final row = rows[index];
    final startsCard = index == 0 || rows[index - 1] is _Title || row is _Group;
    final endsCard = index == rows.length - 1 || rows[index + 1] is _Title || rows[index + 1] is _Group;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, row is _Group ? AppTheme.gap : 0, 16, 0),
      child: Material(
        color: Palette.of(context).panel,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(startsCard ? AppTheme.radius : 0),
          bottom: Radius.circular(endsCard ? AppTheme.radius : 0),
        ),
        child: child,
      ),
    );
  }

  Widget _filters() {
    final choices = NodeRegions.present(_manager.listedNodes.map((e) => e['tag'].toString()));
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        final byTag = {for (final node in _manager.listedNodes) node['tag'].toString(): node};
        final rows = _rows(byTag);
        final selected = _manager.selectedNode ?? RuleTarget.auto;
        final multipleGroups = _manager.nodeGroups.length > 1;
        return Scaffold(
          appBar: AppBar(title: const Text('节点'), actions: [
            if (multipleGroups)
              IconButton(tooltip: '全部展开或收起', icon: const Icon(Icons.unfold_more), onPressed: _toggleAllGroups),
            IconButton(
              tooltip: '测全部延迟',
              icon: _manager.testing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.speed),
              onPressed: _manager.testing ? null : _test,
            ),
            IconButton(tooltip: '显示设置', icon: const Icon(Icons.tune), onPressed: _openSettings),
          ]),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppPage.contentWidth),
              child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  hintText: '搜索节点，支持正则',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: _keyword.isEmpty
                      ? IconButton(tooltip: '候选词', icon: const Icon(Icons.chevron_right), onPressed: _openKeywords)
                      : IconButton(
                          tooltip: '清除',
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            setState(() => _keyword = '');
                          },
                        ),
                ),
                onChanged: (value) => setState(() => _keyword = value.trim()),
              ),
            ),
            _filters(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: rows.length,
                itemBuilder: (context, index) => switch (rows[index]) {
                  _Title row => _title(row),
                  _Fixed row => _card(rows, index, _fixedTile(row.tag, selected)),
                  _Node row => _card(rows, index, _nodeTile(row, selected, byTag)),
                  _Group row => _card(rows, index, _groupHeader(row.group)),
                },
              ),
            ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// 搜索候选词：常搜的关键词或正则存下来，点一下就能搜，也能用在自动选择组里
class SearchKeywordsPage extends StatefulWidget {
  const SearchKeywordsPage({super.key});

  @override
  State<SearchKeywordsPage> createState() => _SearchKeywordsPageState();
}

class _SearchKeywordsPageState extends State<SearchKeywordsPage> {
  final CoreManager _manager = CoreManager.instance;

  CoreSettings get _settings => _manager.settings;

  Future<String?> _ask(String initial) async {
    final controller = TextEditingController(text: initial);
    final word = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关键词或正则'),
        content: TextField(controller: controller, autofocus: true, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return word == null || word.isEmpty ? null : word;
  }

  void _save(List<String> words) {
    setState(() => _settings.searchKeywords = words..sort());
    _manager.saveUiSettings();
  }

  Future<void> _add() async {
    final word = await _ask('');
    if (word != null && !_settings.searchKeywords.contains(word)) _save([..._settings.searchKeywords, word]);
  }

  /// 自动选择组里用到的词一起改，要不然组的成员就悄悄变了
  void _replaceInGroups(String word, String? replacement) {
    for (final group in _settings.autoGroups) {
      group.keywords = [
        for (final item in group.keywords)
          if (item != word)
            item
          else if (replacement != null)
            replacement,
      ];
    }
  }

  Future<void> _rename(String word) async {
    final renamed = await _ask(word);
    if (renamed == null || renamed == word || _settings.searchKeywords.contains(renamed)) return;
    _replaceInGroups(word, renamed);
    _save([for (final item in _settings.searchKeywords) item == word ? renamed : item]);
  }

  void _remove(String word) {
    _replaceInGroups(word, null);
    _save(_settings.searchKeywords.where((e) => e != word).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索候选词'), actions: [
        IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
      ]),
      body: SettingsList(children: [
        for (final word in _settings.searchKeywords)
          ListTile(
            title: Text(word),
            onTap: () => Navigator.pop(context, word),
            onLongPress: () => _rename(word),
            trailing: IconButton(tooltip: '删除', icon: const Icon(Icons.close, size: 20), onPressed: () => _remove(word)),
          ),
      ]),
    );
  }
}
