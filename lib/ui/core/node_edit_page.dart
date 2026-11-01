import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/profile.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'design.dart';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// 协议的显示名，认不出来的原样显示
String nodeTypeLabel(Map<String, dynamic> node) {
  final type = node['type']?.toString() ?? '';
  return switch (type) {
    'shadowsocks' => 'Shadowsocks',
    'shadowtls' => 'ShadowTLS',
    'vmess' => 'VMess',
    'vless' => 'VLESS',
    'trojan' => 'Trojan',
    'hysteria' => 'Hysteria',
    'hysteria2' => 'Hysteria2',
    'tuic' => 'TUIC',
    'anytls' => 'AnyTLS',
    'socks' => 'SOCKS',
    'http' => 'HTTP',
    'ssh' => 'SSH',
    'tor' => 'Tor',
    'naive' => 'Naive',
    _ => type,
  };
}

/// 节点的完整配置。里面有密码，只在用户点开时显示
Future<void> showNodeJson(BuildContext context, Map<String, dynamic> node) {
  final text = _pretty.convert(node);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(node['tag'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
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

/// 分享节点。内容是 sing-box 格式，RsProxy 扫码或粘贴都能直接添加
Future<void> showNodeShare(BuildContext context, Map<String, dynamic> node) {
  final text = jsonEncode({
    'outbounds': [node]
  });
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(node['tag'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(width: 260, height: 260, child: QrImageView(data: text, backgroundColor: Colors.white)),
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

/// 编辑节点。各协议的字段太多，内核又在不断加新选项，所以直接改 JSON，名称和前置节点单独列出来
class NodeEditPage extends StatefulWidget {
  final String tag;
  final Map<String, dynamic> node;

  const NodeEditPage({super.key, required this.tag, required this.node});

  @override
  State<NodeEditPage> createState() => _NodeEditPageState();
}

class _NodeEditPageState extends State<NodeEditPage> {
  final CoreManager _manager = CoreManager.instance;
  late final TextEditingController _tag = TextEditingController(text: widget.tag);
  late final TextEditingController _detour = TextEditingController(text: widget.node['detour']?.toString());
  final FocusNode _detourFocus = FocusNode();
  late final TextEditingController _json = TextEditingController(
    text: _pretty.convert({...widget.node}
      ..remove('tag')
      ..remove('detour')),
  );
  String? _error;

  @override
  void dispose() {
    _tag.dispose();
    _detour.dispose();
    _detourFocus.dispose();
    _json.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final tag = _tag.text.trim();
    final detour = _detour.text.trim();
    final Object? parsed;
    try {
      parsed = jsonDecode(_json.text);
    } on FormatException catch (e) {
      setState(() => _error = 'JSON 格式不对：${e.message}');
      return;
    }
    if (parsed is! Map<String, dynamic> || parsed['type'] == null) {
      setState(() => _error = '要有 type 字段');
      return;
    }
    if (tag.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }

    final navigator = Navigator.of(context);
    try {
      await _manager.updateNode(widget.tag, {...parsed, 'tag': tag, if (detour.isNotEmpty) 'detour': detour});
      navigator.pop();
    } on DuplicateProfileException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final others = _manager.listedNodes.map((e) => e['tag'].toString()).where((e) => e != widget.tag).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('编辑节点'), actions: [
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: ContentColumn(children: [
        TextField(
          controller: _tag,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        const SizedBox(height: 12),
        Autocomplete<String>(
          textEditingController: _detour,
          focusNode: _detourFocus,
          optionsBuilder: (value) => others.where((e) => e.toLowerCase().contains(value.text.toLowerCase())),
          fieldViewBuilder: (context, controller, focus, _) => TextField(
            controller: controller,
            focusNode: focus,
            decoration: const InputDecoration(
              labelText: '前置节点',
              helperText: '流量先经过它再到这个节点，留空表示没有',
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _json,
          autocorrect: false,
          minLines: 10,
          maxLines: 24,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(labelText: '其他参数', errorText: _error, errorMaxLines: 3),
        ),
      ]),
    );
  }
}

/// 往本地配置里手动加节点：贴分享链接或节点 JSON，也可以从协议模板改起
class AddNodePage extends StatefulWidget {
  final Profile profile;

  const AddNodePage({super.key, required this.profile});

  @override
  State<AddNodePage> createState() => _AddNodePageState();
}

class _AddNodePageState extends State<AddNodePage> {
  /// 官方内核支持的协议。参数是占位内容，用户改成自己的
  static const Map<String, Map<String, dynamic>> _templates = {
    'Shadowsocks': {'type': 'shadowsocks', 'method': '2022-blake3-aes-128-gcm', 'password': ''},
    'VMess': {'type': 'vmess', 'uuid': '', 'security': 'auto'},
    'VLESS': {'type': 'vless', 'uuid': '', 'flow': 'xtls-rprx-vision'},
    'Trojan': {'type': 'trojan', 'password': ''},
    'Hysteria2': {'type': 'hysteria2', 'password': ''},
    'Hysteria': {'type': 'hysteria', 'auth_str': '', 'up_mbps': 100, 'down_mbps': 100},
    'TUIC': {'type': 'tuic', 'uuid': '', 'password': ''},
    'AnyTLS': {'type': 'anytls', 'password': ''},
    'ShadowTLS': {'type': 'shadowtls', 'version': 3, 'password': ''},
    'SOCKS': {'type': 'socks', 'version': '5'},
    'HTTP': {'type': 'http'},
    'SSH': {'type': 'ssh', 'user': 'root', 'password': ''},
    'Naive': {'type': 'naive', 'username': '', 'password': ''},
  };

  final CoreManager _manager = CoreManager.instance;
  final TextEditingController _content = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  void _useTemplate(String name) {
    final template = _templates[name]!;
    final needsTls = !const {'shadowsocks', 'socks', 'http', 'ssh'}.contains(template['type']);
    setState(() {
      _error = null;
      _content.text = _pretty.convert({
        'tag': name,
        'server': 'example.com',
        'server_port': 443,
        ...template,
        if (needsTls) 'tls': {'enabled': true, 'server_name': 'example.com'},
      });
    });
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await _manager.addNodes(widget.profile, _content.text);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('已添加 $count 个节点')));
    } on FormatException {
      setState(() => _error = '看不懂这段内容，可以贴分享链接或节点 JSON');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加节点'), actions: [
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: ContentColumn(children: [
        Wrap(spacing: 8, children: [
          for (final name in _templates.keys) ActionChip(label: Text(name), onPressed: () => _useTemplate(name)),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _content,
          autocorrect: false,
          minLines: 10,
          maxLines: 24,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            labelText: '分享链接或节点 JSON',
            hintText: '选上面的协议从模板开始，或者直接粘贴',
            errorText: _error,
          ),
        ),
      ]),
    );
  }
}
