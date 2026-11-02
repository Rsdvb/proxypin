import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/qr_decoder.dart';
import 'package:proxypin/core/subscription.dart';
import 'package:proxypin/ui/component/qrcode/qr_scan_view.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'connect_page.dart';
import 'design.dart';
import 'format.dart';
import 'node_edit_page.dart';
import 'profile_options.dart';

/// 我的配置。点一下切换，长按拖动排序，其余操作在右侧菜单里
class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  /// 不经订阅，自己一个个添加节点
  Future<void> _createLocal(BuildContext context) async {
    final manager = CoreManager.instance;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建空配置'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: '名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    try {
      final profile = await manager.createLocalProfile(name);
      await navigator.push(MaterialPageRoute(builder: (_) => AddNodePage(profile: profile)));
    } on DuplicateProfileException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('配置'), actions: [
          if (manager.profiles.length > 1)
            IconButton(
              tooltip: '合并配置',
              icon: const Icon(Icons.merge),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MergeProfilesPage())),
            ),
          if (manager.profiles.any((e) => e.isSubscription))
            IconButton(
              tooltip: '全部更新',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final failed = await manager.updateAllProfiles();
                messenger.showSnackBar(SnackBar(content: Text(failed == 0 ? '已全部更新' : '$failed 份更新失败')));
              },
            ),
          IconButton(
            tooltip: '新建空配置',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: () => _createLocal(context),
          ),
          IconButton(
            tooltip: '添加配置',
            icon: const Icon(Icons.add),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddProfilePage())),
          ),
        ]),
        body: manager.profiles.isEmpty
            ? const Center(child: Text('还没有配置，点右上角添加'))
            : ReorderableListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: manager.profiles.length,
                onReorder: (oldIndex, newIndex) {
                  manager.reorderProfiles(oldIndex, newIndex > oldIndex ? newIndex - 1 : newIndex);
                },
                itemBuilder: (context, index) {
                  final profile = manager.profiles[index];
                  return _ProfileCard(key: ValueKey(profile.id), profile: profile, manager: manager);
                },
              ),
      ),
    );
  }
}

class _ProfileCard extends StatefulWidget {
  final Profile profile;
  final CoreManager manager;

  const _ProfileCard({super.key, required this.profile, required this.manager});

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  bool _updating = false;

  Future<void> _update() async {
    setState(() => _updating = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.manager.updateProfile(widget.profile);
      messenger.showSnackBar(const SnackBar(content: Text('已更新')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeProfileError(e))));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  void _showQrCode() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.profile.name),
        content: SizedBox(width: 260, height: 260, child: QrImageView(data: widget.profile.url!, backgroundColor: Colors.white)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }

  Future<void> _copyLink() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: widget.profile.url!));
    messenger.showSnackBar(const SnackBar(content: Text('已复制')));
  }

  /// 导出成 sing-box 格式，别的客户端也能读
  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await Platforms.saveFileAdaptive(fileName: '${widget.profile.name}.json');
    if (path == null) return;
    final content = const JsonEncoder.withIndent('  ').convert({'outbounds': widget.profile.nodes});
    await File(path).writeAsString(content);
    messenger.showSnackBar(const SnackBar(content: Text('已导出')));
  }

  Future<void> _confirmRemove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除“${widget.profile.name}”？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) await widget.manager.removeProfile(widget.profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final active = widget.manager.settings.activeProfileId == profile.id;
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: active ? BorderSide(color: theme.colorScheme.primary, width: 1.4) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.manager.setActiveProfile(profile.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ProfileSummary(profile),
                const SizedBox(height: 4),
                Text(
                  '${profile.isMerged ? '合并 ${profile.sources.length} 份配置' : '${profile.nodes.length} 个节点'}'
                  '${profile.skipped > 0 ? ' · ${profile.skipped} 个暂不支持' : ''}'
                  '${profile.removedNodes.isEmpty ? '' : ' · ${profile.removedNodes.length} 个已移除'}'
                  '${profile.updatedAt == null ? '' : ' · ${formatDate(profile.updatedAt!)} 更新'}',
                  style: theme.textTheme.bodySmall,
                ),
              ]),
            ),
            if (active)
              Tag('使用中', color: theme.colorScheme.primary)
            else if (!profile.isMerged && !widget.manager.activeProfileIsEmpty)
              Tooltip(
                message: '节点和当前配置一起用',
                child: Switch(
                  value: widget.manager.alsoEnabledProfiles.contains(profile.id),
                  onChanged: (value) => widget.manager.setProfileAlsoEnabled(profile.id, value),
                ),
              ),
            if (_updating)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              PopupMenuButton<String>(
                onSelected: (value) => switch (value) {
                  'update' => _update(),
                  'qr' => _showQrCode(),
                  'copy' => _copyLink(),
                  'node' => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddNodePage(profile: profile))),
                  'export' => _export(),
                  'edit' => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => EditProfilePage(profile: profile))),
                  _ => _confirmRemove(),
                },
                itemBuilder: (context) => [
                  if (profile.isSubscription) ...const [
                    PopupMenuItem(value: 'update', child: Text('更新')),
                    PopupMenuItem(value: 'qr', child: Text('二维码')),
                    PopupMenuItem(value: 'copy', child: Text('复制链接')),
                  ],
                  if (!profile.isSubscription && !profile.isMerged) const PopupMenuItem(value: 'node', child: Text('添加节点')),
                  if (!profile.isMerged) const PopupMenuItem(value: 'export', child: Text('导出')),
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem(value: 'remove', child: Text('删除')),
                ],
              ),
          ]),
        ),
      ),
    );
  }
}

/// 添加配置。一个输入框就能用，名称和格式都自动识别，其余选项收在“更多选项”里
class AddProfilePage extends StatefulWidget {
  /// 一键导入时预先填好，用户看过再点添加
  final String? initialContent;
  final String? initialName;
  final List<String> outboundDns;

  const AddProfilePage({super.key, this.initialContent, this.initialName, this.outboundDns = const []});

  @override
  State<AddProfilePage> createState() => _AddProfilePageState();
}

class _AddProfilePageState extends State<AddProfilePage> {
  late final TextEditingController _content = TextEditingController(text: widget.initialContent);
  late final TextEditingController _name = TextEditingController(text: widget.initialName);

  /// 只用来存选项，添加时抄给真正的配置
  late final Profile _options = Profile(id: '', name: '', outboundDns: widget.outboundDns)
    ..preferOutboundDns = widget.outboundDns.isNotEmpty
    ..userAgents = [...CoreManager.instance.settings.userAgents, ...UserAgents.presets];
  bool _adding = false;
  String? _error;

  /// 下载到但读不懂的内容，让用户能看看机场到底返回了什么
  String? _rawContent;

  @override
  void dispose() {
    _content.dispose();
    _name.dispose();
    super.dispose();
  }

  void _setContent(String text) {
    setState(() => _content.text = text);
    _fillName();
  }

  /// 链接自带名称时直接填上，用户已经填了就不动
  void _fillName() {
    if (_name.text.trim().isNotEmpty) return;
    final name = Subscription.nameInLink(_content.text);
    if (name != null) setState(() => _name.text = name);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null) _setContent(text);
  }

  Future<void> _scan() async {
    final result = await QrCodeScanner.scan(context);
    if (result != null && result != '-1' && mounted) _setContent(result);
  }

  Future<void> _importFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    if (mounted) _setContent(text);
  }

  void _useQrContent(String? text) {
    if (!mounted) return;
    if (text == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有找到二维码')));
    } else {
      _setContent(text);
    }
  }

  Future<void> _scanImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return;
    _useQrContent(await QrDecoder.decode(await file.readAsBytes()));
  }

  /// 截整个屏幕找二维码，网页或聊天窗口里的码不用另存成图片
  Future<void> _scanScreen() async {
    final screen = await QrDecoder.captureScreen();
    _useQrContent(screen == null ? null : await QrDecoder.decode(screen));
  }

  Future<void> _add() async {
    setState(() {
      _adding = true;
      _error = null;
      _rawContent = null;
    });
    try {
      final profile = await CoreManager.instance.addProfile(_content.text, name: _name.text, options: _options);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已添加“${profile.name}”，${profile.nodes.length} 个节点')));
      Navigator.of(context).pop();
    } on UnreadableProfileException catch (e) {
      setState(() {
        _error = describeProfileError(e);
        _rawContent = e.content;
      });
    } catch (e) {
      setState(() => _error = describeProfileError(e));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _showRawContent() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => _RawContentPage(_rawContent!)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加配置'), actions: [
        if (_rawContent != null)
          IconButton(tooltip: '查看下载到的内容', icon: const Icon(Icons.description_outlined), onPressed: _showRawContent),
      ]),
      body: ContentColumn(children: [
        TextField(
          controller: _content,
          minLines: 5,
          maxLines: 10,
          onChanged: (_) => _fillName(),
          decoration: const InputDecoration(
              hintText: '粘贴订阅链接或配置内容\n支持 Clash、Stash、sing-box、V2Ray（可批量）、Shadowsocks、Sub 和 GitHub 配置链接',
              hintMaxLines: 3),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 4, children: [
          TextButton.icon(onPressed: _paste, icon: const Icon(Icons.paste, size: 18), label: const Text('粘贴')),
          if (Platform.isIOS)
            TextButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner, size: 18), label: const Text('扫码')),
          if (Platform.isWindows)
            TextButton.icon(
              onPressed: _scanScreen,
              icon: const Icon(Icons.screenshot_monitor, size: 18),
              label: const Text('识别屏幕二维码'),
            ),
          TextButton.icon(onPressed: _scanImage, icon: const Icon(Icons.image_outlined, size: 18), label: const Text('二维码图片')),
          TextButton.icon(onPressed: _importFile, icon: const Icon(Icons.folder_open, size: 18), label: const Text('文件')),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '名称（可不填）'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _adding ? null : _add,
          child: _adding
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('添加'),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('更多选项'),
          subtitle: const Text('User-Agent、X-HWID、过滤、下载通道、更新间隔等'),
          tilePadding: EdgeInsets.zero,
          children: [ProfileOptionsForm(profile: _options)],
        ),
      ]),
    );
  }
}

class _RawContentPage extends StatelessWidget {
  /// 太长的内容只显示开头，这里只是用来看一眼
  static const int _maxLength = 200000;

  final String content;

  const _RawContentPage(this.content);

  @override
  Widget build(BuildContext context) {
    final text = content.length > _maxLength ? content.substring(0, _maxLength) : content;
    return Scaffold(
      appBar: AppBar(title: const Text('下载到的内容')),
      body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(text)),
    );
  }
}

/// 把几份配置合成一份，一个分流方案同时用多家机场的节点
class MergeProfilesPage extends StatefulWidget {
  const MergeProfilesPage({super.key});

  @override
  State<MergeProfilesPage> createState() => _MergeProfilesPageState();
}

class _MergeProfilesPageState extends State<MergeProfilesPage> {
  final TextEditingController _name = TextEditingController(text: '合并配置');
  final Set<String> _selected = {};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _merge() async {
    final manager = CoreManager.instance;
    final sources = manager.profiles.map((e) => e.id).where(_selected.contains).toList();
    await manager.mergeProfiles(_name.text.trim().isEmpty ? '合并配置' : _name.text.trim(), sources);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = CoreManager.instance.profiles.where((e) => !e.isMerged).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('合并配置'), actions: [
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _selected.length < 2 ? null : _merge),
      ]),
      body: SettingsList(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
        ),
        for (final profile in profiles)
          CheckboxListTile(
            title: Text(profile.name),
            subtitle: Text('${profile.nodes.length} 个节点'),
            value: _selected.contains(profile.id),
            onChanged: (value) => setState(() => value == true ? _selected.add(profile.id) : _selected.remove(profile.id)),
          ),
      ]),
    );
  }
}

/// 编辑配置。在副本上改，保存时才生效
class EditProfilePage extends StatefulWidget {
  final Profile profile;

  const EditProfilePage({super.key, required this.profile});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _name = TextEditingController(text: widget.profile.name);
  late final TextEditingController _url = TextEditingController(text: widget.profile.url);
  late final Profile _draft = Profile(id: '', name: '')..copyOptionsFrom(widget.profile);

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final profile = widget.profile;
    final name = _name.text.trim();
    if (name.isNotEmpty) profile.name = name;
    if (profile.isSubscription) profile.url = _url.text.trim();
    profile.copyOptionsFrom(_draft);
    await CoreManager.instance.saveProfile(profile);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final subscription = widget.profile.isSubscription;
    final removed = _draft.removedNodes.length;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑配置'), actions: [
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: SettingsList(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
        ),
        if (subscription)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '订阅链接'),
            ),
          ),
        ProfileOptionsForm(profile: _draft, subscription: subscription),
        if (removed > 0)
          ListTile(
            title: Text('恢复 $removed 个已移除的节点'),
            trailing: const Icon(Icons.restore),
            onTap: () => setState(() => _draft.removedNodes = {}),
          ),
      ]),
    );
  }
}
