import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/rule_sets.dart';

import 'design.dart';
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
  bool _regionChanged = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_regionChanged) _manager.applySettings();
    super.dispose();
  }

  Future<void> _load() async {
    final states = await _manager.ruleSetStates();
    if (mounted) setState(() => _states = states);
  }

  void _change(VoidCallback change) {
    setState(change);
    _manager.saveUiSettings();
  }

  Future<void> _pickRegion() async {
    final region = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => RegionPage(current: _manager.settings.region),
    ));
    if (region == null || !mounted) return;
    setState(() => _manager.settings.region = region);
    _regionChanged = true;
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
      body: SettingsList(children: [
        ListTile(
          title: const Text('地区'),
          subtitle: const Text('决定地区基础规则走哪里直连，设错可能导致分流错误'),
          trailing: Text(regionLabel(settings.region)),
          onTap: _pickRegion,
        ),
        SwitchListTile(
          title: const Text('自动追加地区基础规则'),
          subtitle: const Text('这个地区的网站和 IP 走直连，排在你的分流组后面'),
          value: settings.regionRules,
          onChanged: (value) {
            setState(() => settings.regionRules = value);
            _regionChanged = true;
          },
        ),
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

/// 地区的显示名。常见的给中文，其余显示代码
String regionLabel(String code) {
  const names = {
    'cn': '中国大陆', 'hk': '香港', 'mo': '澳门', 'tw': '台湾', 'jp': '日本', 'kr': '韩国', 'sg': '新加坡', 'my': '马来西亚',
    'th': '泰国', 'vn': '越南', 'id': '印度尼西亚', 'ph': '菲律宾', 'in': '印度', 'au': '澳大利亚', 'nz': '新西兰', 'us': '美国',
    'ca': '加拿大', 'mx': '墨西哥', 'br': '巴西', 'ar': '阿根廷', 'gb': '英国', 'de': '德国', 'fr': '法国', 'it': '意大利',
    'es': '西班牙', 'nl': '荷兰', 'se': '瑞典', 'no': '挪威', 'fi': '芬兰', 'dk': '丹麦', 'ch': '瑞士', 'at': '奥地利',
    'ru': '俄罗斯', 'ua': '乌克兰', 'tr': '土耳其', 'ir': '伊朗', 'af': '阿富汗', 'ae': '阿联酋', 'sa': '沙特阿拉伯', 'za': '南非',
  };
  return names[code] ?? code.toUpperCase();
}

/// 选地区。列表来自规则集清单，只列真有数据的地区
class RegionPage extends StatefulWidget {
  final String current;

  const RegionPage({super.key, required this.current});

  @override
  State<RegionPage> createState() => _RegionPageState();
}

class _RegionPageState extends State<RegionPage> {
  /// 这几个 geoip 规则集不是地区
  static const Set<String> _notRegions = {'private'};

  List<String> _regions = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<String> names = [widget.current];
    try {
      final text = await rootBundle.loadString('assets/rules/index.txt');
      names = text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.startsWith('geoip-'))
          .map((e) => e.substring('geoip-'.length))
          .where((e) => e.length == 2 && !_notRegions.contains(e))
          .toList();
    } on FlutterError {
      // 开发时没有跑 fetch_rule_sets.sh，这里只有当前地区
    }
    if (mounted) setState(() => _regions = names);
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final regions = _regions.where((e) => e.startsWith(query) || regionLabel(e).contains(_query)).toList()
      ..sort((a, b) {
        // 有中文名的常见地区排前面
        final known = (regionLabel(a) == a.toUpperCase() ? 1 : 0) - (regionLabel(b) == b.toUpperCase() ? 1 : 0);
        return known != 0 ? known : a.compareTo(b);
      });
    return Scaffold(
      appBar: AppBar(title: const Text('地区')),
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
            itemCount: regions.length,
            itemBuilder: (context, index) {
              final region = regions[index];
              return ListTile(
                dense: true,
                title: Text(regionLabel(region)),
                subtitle: Text(region.toUpperCase()),
                trailing: region == widget.current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, region),
              );
            },
          ),
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
