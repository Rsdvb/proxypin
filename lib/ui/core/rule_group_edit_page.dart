import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/rule_group.dart';

import 'rule_sets_page.dart';

/// 编辑页的结果
class RuleGroupEdit {
  final RuleGroup? group;
  final bool remove;

  const RuleGroupEdit(this.group, {this.remove = false});
}

/// 编辑一个分流组的匹配内容，文本框每行一条。条件很多，平时用不到的收起来，有内容的才展开
class EditRuleGroupPage extends StatefulWidget {
  final RuleGroup? group;

  /// 其他组的名称，不能重名
  final Set<String> otherNames;

  /// 从连接列表带来的内容：字段 -> 值，追加到已有内容后面
  final Map<String, String> prefill;

  const EditRuleGroupPage({super.key, this.group, this.otherNames = const {}, this.prefill = const {}});

  @override
  State<EditRuleGroupPage> createState() => _EditRuleGroupPageState();
}

class _EditRuleGroupPageState extends State<EditRuleGroupPage> {
  static const List<String> _textKeys = [
    'ruleSetUrls',
    'domainSuffixes',
    'domains',
    'domainKeywords',
    'domainRegexes',
    'ipCidrs',
    'ports',
    'portRanges',
    'wifiSsids',
    'wifiBssids',
    'processNames',
    'processPaths',
    'processDirs',
  ];
  static const List<String> _networks = ['tcp', 'udp', 'icmp'];
  static const List<String> _protocols = ['http', 'tls', 'quic', 'dns', 'stun', 'bittorrent', 'dtls', 'ssh', 'rdp', 'ntp'];
  static const Map<String, String> _networkTypes = {
    'wifi': 'Wi-Fi',
    'cellular': '蜂窝',
    'ethernet': '以太网',
    'other': '其他',
  };

  late final RuleGroup? _group = widget.group;
  late final Map<String, dynamic> _json = _group?.toJson() ?? {'id': DateTime.now().microsecondsSinceEpoch.toString()};
  late final TextEditingController _name = TextEditingController(text: _group?.name);
  late final Map<String, TextEditingController> _text = {
    for (final key in _textKeys) key: TextEditingController(text: (_json[key] as List?)?.join('\n')),
  };
  late final List<String> _ruleSets = [...?_group?.ruleSets];
  late final Set<String> _chosenNetworks = {...?_group?.networks};
  late final Set<String> _chosenProtocols = {...?_group?.protocols};
  late final Set<String> _chosenNetworkTypes = {...?_group?.networkTypes};
  late bool _matchOr = _group?.matchOr ?? false;

  @override
  void initState() {
    super.initState();
    widget.prefill.forEach(_append);
  }

  bool _filled(List<String> keys) => keys.any((key) => _text[key]!.text.isNotEmpty);

  List<String> _lines(TextEditingController controller) =>
      controller.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();

  @override
  void dispose() {
    _name.dispose();
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _save() {
    final name = _name.text.trim();
    if (widget.otherNames.contains(name)) return _show('已经有同名的分流组了');

    final lines = {for (final entry in _text.entries) entry.key: _lines(entry.value)};
    final badPort = lines['ports']!.where((e) => !RuleChecks.isPort(e)).firstOrNull;
    if (badPort != null) return _show('端口格式不对：$badPort');

    final group = RuleGroup.fromJson({
      ..._json,
      ...lines,
      'name': name,
      'ipCidrs': lines['ipCidrs']!.map(RuleChecks.normalizeCidr).toList(),
      'ruleSets': _ruleSets,
      'networks': _chosenNetworks.toList(),
      'protocols': _chosenProtocols.toList(),
      'networkTypes': _chosenNetworkTypes.toList(),
      'matchOr': _matchOr,
    });
    final problem = group.firstProblem();
    if (problem != null) return _show(problem);
    Navigator.of(context).pop(RuleGroupEdit(group));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分流组'),
        content: Text('确定删除“${_group!.name}”？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true && mounted) Navigator.of(context).pop(const RuleGroupEdit(null, remove: true));
  }

  Future<void> _pickRuleSets() async {
    final chosen = await Navigator.of(context).push<List<String>>(MaterialPageRoute(
      builder: (_) => RuleSetPickerPage(selected: _ruleSets),
    ));
    if (chosen != null) {
      setState(() => _ruleSets
        ..clear()
        ..addAll(chosen));
    }
  }

  /// 追加到文本框末尾，已有的跳过
  void _append(String key, String? value) {
    if (value == null || value.isEmpty) return;
    final controller = _text[key]!;
    final lines = _lines(controller);
    if (!lines.contains(value)) controller.text = [...lines, value].join('\n');
  }

  Future<void> _useCurrentWifi() async {
    final wifi = await CoreTools.currentWifi();
    if (wifi == null) return _show('读取不到当前 Wi-Fi，请手动填写');
    _append('wifiSsids', wifi.ssid);
    _append('wifiBssids', wifi.bssid);
  }

  Widget _field(String key, String label, String hint, {Widget? suffix, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _text[key],
        autocorrect: false,
        minLines: 1,
        maxLines: 6,
        keyboardType: keyboard ?? TextInputType.multiline,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), suffixIcon: suffix),
      ),
    );
  }

  Widget _section(String title, bool open, List<Widget> children) {
    return ExpansionTile(
      title: Text(title),
      initiallyExpanded: open,
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      children: children,
    );
  }

  Widget _chips(String label, Iterable<String> values, Set<String> chosen, {String Function(String)? text}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Wrap(spacing: 8, children: [
          for (final value in values)
            FilterChip(
              label: Text(text?.call(value) ?? value),
              selected: chosen.contains(value),
              onSelected: (selected) => setState(() => selected ? chosen.add(value) : chosen.remove(value)),
            ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = !Platform.isIOS;
    return Scaffold(
      appBar: AppBar(title: Text(_group == null ? '添加分流组' : '编辑分流组'), actions: [
        if (_group != null) IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _name,
            maxLength: 32,
            decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder(), counterText: ''),
          ),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('类别都要满足')),
            ButtonSegment(value: true, label: Text('满足任一条')),
          ],
          selected: {_matchOr},
          onSelectionChanged: (value) => setState(() => _matchOr = value.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            _matchOr ? '填的任何一条命中就走这个组。' : '域名和 IP 里任一条命中，同时还要满足填了的端口、协议、网络和进程。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        _section('规则集', _ruleSets.isNotEmpty || _filled(const ['ruleSetUrls']), [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final name in _ruleSets)
                InputChip(label: Text(name), onDeleted: () => setState(() => _ruleSets.remove(name))),
              ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('选择规则集'), onPressed: _pickRuleSets),
            ]),
          ),
          const SizedBox(height: 12),
          _field('ruleSetUrls', '规则集地址，每行一个', 'https://example.com/rules.srs'),
        ]),
        _section('域名', _filled(const ['domainSuffixes', 'domains', 'domainKeywords', 'domainRegexes']), [
          _field('domainSuffixes', '域名后缀，每行一个', 'example.com'),
          _field('domains', '完整域名，每行一个', 'www.example.com'),
          _field('domainKeywords', '域名关键字，每行一个', 'google'),
          _field('domainRegexes', '域名正则，每行一个', r'^ads?\.'),
        ]),
        _section('IP 和端口', _filled(const ['ipCidrs', 'ports', 'portRanges']), [
          _field('ipCidrs', 'IP 段，每行一个', '1.2.3.0/24'),
          _field('ports', '端口，每行一个', '443'),
          _field('portRanges', '端口范围，每行一个', '1000:2000'),
        ]),
        _section('网络和协议', _chosenNetworks.isNotEmpty || _chosenProtocols.isNotEmpty || _chosenNetworkTypes.isNotEmpty, [
          _chips('传输协议', _networks, _chosenNetworks),
          _chips('应用协议', _protocols, _chosenProtocols),
          if (!desktop) _chips('网络类型', _networkTypes.keys, _chosenNetworkTypes, text: (e) => _networkTypes[e]!),
        ]),
        _section('Wi-Fi', _filled(const ['wifiSsids', 'wifiBssids']), [
          _field('wifiSsids', 'Wi-Fi 名称，每行一个', ''),
          _field('wifiBssids', 'BSSID，每行一个', 'aa:bb:cc:dd:ee:ff'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.wifi),
              label: const Text('填入当前 Wi-Fi'),
              onPressed: _useCurrentWifi,
            ),
          ),
        ]),
        if (desktop)
          _section('应用', _filled(const ['processNames', 'processPaths', 'processDirs']), [
            _field('processNames', '进程名，每行一个', 'chrome.exe',
                suffix: IconButton(
                  tooltip: '选择程序',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['exe']);
                    _append('processNames', file?.name);
                  },
                )),
            _field('processPaths', '程序路径，每行一个', r'C:\Program Files\App\app.exe',
                suffix: IconButton(
                  tooltip: '选择程序',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['exe']);
                    _append('processPaths', file?.path);
                  },
                )),
            _field('processDirs', '程序目录，每行一个', r'C:\Program Files\App',
                suffix: IconButton(
                  tooltip: '选择目录',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async => _append('processDirs', await FilePicker.getDirectoryPath()),
                )),
          ]),
      ]),
    );
  }
}
