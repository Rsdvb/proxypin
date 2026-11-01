import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/profile.dart';

import 'connect_page.dart';
import 'format.dart';

/// 我的配置。点一下切换，长按拖动排序，其余操作在右侧菜单里
class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('配置'), actions: [
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
      messenger.showSnackBar(SnackBar(content: Text('更新失败：$e')));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
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
      color: active ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.manager.setActiveProfile(profile.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ProfileSummary(profile),
                const SizedBox(height: 4),
                Text(
                  '${profile.nodes.length} 个节点'
                  '${profile.skipped > 0 ? ' · ${profile.skipped} 个暂不支持' : ''}'
                  '${profile.updatedAt == null ? '' : ' · ${formatDate(profile.updatedAt!)} 更新'}',
                  style: theme.textTheme.bodySmall,
                ),
              ]),
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
                  'edit' => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => EditProfilePage(profile: profile))),
                  _ => _confirmRemove(),
                },
                itemBuilder: (context) => [
                  if (profile.isSubscription) const PopupMenuItem(value: 'update', child: Text('更新')),
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

/// 添加配置：一个输入框就够了。订阅和配置内容自动识别，名称自动取
class AddProfilePage extends StatefulWidget {
  const AddProfilePage({super.key});

  @override
  State<AddProfilePage> createState() => _AddProfilePageState();
}

class _AddProfilePageState extends State<AddProfilePage> {
  final TextEditingController _content = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _adding = false;
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null) setState(() => _content.text = text);
  }

  Future<void> _add() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final profile = await CoreManager.instance.addProfile(_content.text, name: _name.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已添加“${profile.name}”，${profile.nodes.length} 个节点')));
      Navigator.of(context).pop();
    } on FormatException {
      setState(() => _error = '看不懂这段内容。支持订阅链接、Clash、sing-box 配置和分享链接');
    } catch (e) {
      setState(() => _error = '添加失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加配置')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _content,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(hintText: '粘贴订阅链接或配置内容', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: _paste, icon: const Icon(Icons.paste, size: 18), label: const Text('从剪贴板粘贴')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '名称（可不填）', border: OutlineInputBorder()),
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
      ]),
    );
  }
}

/// 编辑配置。常用的放外面，订阅相关的选项收起来
class EditProfilePage extends StatefulWidget {
  final Profile profile;

  const EditProfilePage({super.key, required this.profile});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _name = TextEditingController(text: widget.profile.name);
  late final TextEditingController _url = TextEditingController(text: widget.profile.url);
  late final TextEditingController _userAgent = TextEditingController(text: widget.profile.userAgent);
  late final TextEditingController _hours = TextEditingController(text: widget.profile.updateHours.toString());
  late final TextEditingController _include = TextEditingController(text: widget.profile.include);
  late final TextEditingController _exclude = TextEditingController(text: widget.profile.exclude);

  @override
  void dispose() {
    for (final controller in [_name, _url, _userAgent, _hours, _include, _exclude]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final profile = widget.profile;
    final name = _name.text.trim();
    if (name.isNotEmpty) profile.name = name;
    if (profile.isSubscription) {
      profile
        ..url = _url.text.trim()
        ..userAgent = _userAgent.text.trim().isEmpty ? Profile.defaultUserAgent : _userAgent.text.trim()
        ..updateHours = int.tryParse(_hours.text.trim()) ?? profile.updateHours;
    }
    profile
      ..include = _include.text.trim().isEmpty ? null : _include.text.trim()
      ..exclude = _exclude.text.trim().isEmpty ? null : _exclude.text.trim();
    await CoreManager.instance.saveProfile(profile);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _field(TextEditingController controller, String label, {String? hint, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subscription = widget.profile.isSubscription;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑配置'), actions: [
        IconButton(tooltip: '保存', icon: const Icon(Icons.check), onPressed: _save),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _field(_name, '名称'),
        if (subscription) _field(_url, '订阅链接', keyboard: TextInputType.url),
        ExpansionTile(
          title: const Text('高级'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 8),
          children: [
            _field(_include, '只保留名称匹配的节点', hint: '正则，如 香港|日本'),
            _field(_exclude, '去掉名称匹配的节点', hint: '正则，如 剩余|到期|官网'),
            if (subscription) ...[
              _field(_hours, '自动更新间隔（小时）', hint: '0 表示不自动更新', keyboard: TextInputType.number),
              _field(_userAgent, 'User-Agent'),
            ],
          ],
        ),
      ]),
    );
  }
}
