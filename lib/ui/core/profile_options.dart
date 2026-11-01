import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/core/subscription.dart';

/// 配置的全部选项，添加和编辑共用。直接改 [profile]，由调用方决定什么时候保存
class ProfileOptionsForm extends StatefulWidget {
  final Profile profile;

  /// 手动粘贴的配置不会更新，下载相关的选项不用显示
  final bool subscription;

  const ProfileOptionsForm({super.key, required this.profile, this.subscription = true});

  @override
  State<ProfileOptionsForm> createState() => _ProfileOptionsFormState();
}

class _ProfileOptionsFormState extends State<ProfileOptionsForm> {
  Profile get _profile => widget.profile;

  static const Map<DownloadStrategy, String> _strategies = {
    DownloadStrategy.preferProxy: '优先 当前选择',
    DownloadStrategy.preferDirect: '优先 直连',
    DownloadStrategy.onlyProxy: '仅 当前选择',
    DownloadStrategy.onlyDirect: '仅 直连',
  };

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  Future<void> _pickInterval() async {
    final result = await showDialog<_Interval>(
      context: context,
      builder: (_) => _IntervalDialog(_profile.updateMinutes),
    );
    if (result != null && mounted) setState(() => _profile.updateMinutes = result.minutes);
  }

  Widget _text(String label, String value, ValueChanged<String> onChanged, {bool obscure = false, String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextFormField(
        initialValue: value,
        obscureText: obscure,
        autocorrect: false,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: true),
        onChanged: onChanged,
      ),
    );
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged, {String? tip}) {
    return SwitchListTile(
      title: Text(title),
      subtitle: tip == null ? null : Text(tip),
      value: value,
      onChanged: (changed) => setState(() => onChanged(changed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _text('官网', profile.website ?? '', (value) => profile.website = value.trim(), hint: 'https://'),
      if (widget.subscription) ...[
        ListTile(
          title: const Text('User-Agent'),
          subtitle: Text(UserAgents.short(profile.userAgents), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(UserAgentPage(profile: profile)),
        ),
        _switch('X-HWID', profile.xhwid, (value) => profile.xhwid = value, tip: '发送设备标识，限制设备数的机场需要'),
        _text('解密密码', profile.decryptPassword, (value) => profile.decryptPassword = value,
            obscure: true, hint: '机场加密订阅时填写'),
      ],
      ListTile(
        title: const Text('过滤'),
        subtitle: Text(switch (profile.filterMethod) {
          NodeFilterMethod.all => '全部节点',
          NodeFilterMethod.include => '只保留：${profile.filterPattern}',
          NodeFilterMethod.exclude => '排除：${profile.filterPattern}',
        }, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _push(NodeFilterPage(profile: profile)),
      ),
      _switch('保留机场分流规则', profile.keepProviderRules, (value) => profile.keepProviderRules = value,
          tip: '机场提供的分流规则，V2Ray 类型的订阅没有。规则多时占内存'),
      if (widget.subscription) ...[
        ListTile(
          title: const Text('下载通道'),
          trailing: DropdownButton<DownloadStrategy>(
            value: profile.downloadStrategy,
            underline: const SizedBox.shrink(),
            items: [
              for (final entry in _strategies.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => profile.downloadStrategy = value);
            },
          ),
        ),
        ListTile(
          title: const Text('更新时间间隔'),
          subtitle: const Text('最小 5 分钟'),
          trailing: Text(formatInterval(profile.updateMinutes)),
          onTap: _pickInterval,
        ),
        _switch('配置更新后重新加载', profile.reloadAfterUpdate, (value) => profile.reloadAfterUpdate = value),
        _switch('配置自动更新后启动延迟检测', profile.testLatencyAfterUpdate, (value) => profile.testLatencyAfterUpdate = value,
            tip: '需要处于已连接状态，并且开启“配置更新后重新加载”'),
      ],
      _switch('自动移除延迟检测失败的服务器', profile.autoRemoveFailed, (value) => profile.autoRemoveFailed = value, tip: '最多尝试 3 次'),
      if (profile.outboundDns.isNotEmpty)
        _switch('优先使用配置自带 DNS 解析节点域名', profile.preferOutboundDns, (value) => profile.preferOutboundDns = value,
            tip: profile.outboundDns.join('\n')),
    ]);
  }
}

/// 720 -> 12 h，90 -> 1 h 30 m
String formatInterval(int? minutes) {
  if (minutes == null) return '关闭';
  final hours = minutes ~/ 60, rest = minutes % 60;
  if (hours == 0) return '$rest m';
  return rest == 0 ? '$hours h' : '$hours h $rest m';
}

class _Interval {
  final int? minutes;

  const _Interval(this.minutes);
}

class _IntervalDialog extends StatefulWidget {
  final int? minutes;

  const _IntervalDialog(this.minutes);

  @override
  State<_IntervalDialog> createState() => _IntervalDialogState();
}

class _IntervalDialogState extends State<_IntervalDialog> {
  late final TextEditingController _hours = TextEditingController(text: '${(widget.minutes ?? 720) ~/ 60}');
  late final TextEditingController _minutes = TextEditingController(text: '${(widget.minutes ?? 720) % 60}');

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _confirm() {
    final total = (int.tryParse(_hours.text) ?? 0) * 60 + (int.tryParse(_minutes.text) ?? 0);
    Navigator.pop(context, _Interval(total < Profile.minUpdateMinutes ? Profile.minUpdateMinutes : total));
  }

  Widget _field(TextEditingController controller, String label) {
    return Expanded(
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('更新时间间隔'),
      content: Row(children: [_field(_hours, '小时'), const SizedBox(width: 12), _field(_minutes, '分钟')]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, const _Interval(null)), child: const Text('关闭自动更新')),
        TextButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}

/// User-Agent 多选。机场按它决定下发什么格式，下载不到内容时换一组试试
class UserAgentPage extends StatefulWidget {
  final Profile profile;

  const UserAgentPage({super.key, required this.profile});

  @override
  State<UserAgentPage> createState() => _UserAgentPageState();
}

class _UserAgentPageState extends State<UserAgentPage> {
  final CoreManager _manager = CoreManager.instance;

  List<String> get _all => [..._manager.settings.userAgents, ...UserAgents.presets];

  @override
  void dispose() {
    // 按列表顺序发送，开关的先后不影响结果
    final selected = widget.profile.userAgents.toSet();
    widget.profile.userAgents = [..._all.where(selected.contains), ...selected.where((e) => !_all.contains(e))];
    super.dispose();
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 User-Agent'),
        content: TextField(controller: controller, autofocus: true, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('添加')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;

    await _manager.addUserAgent(text);
    if (!mounted) return;
    setState(() {
      if (!widget.profile.userAgents.contains(text.trim())) widget.profile.userAgents.add(text.trim());
    });
  }

  Future<void> _remove(String userAgent) async {
    await _manager.removeUserAgent(userAgent);
    if (mounted) setState(() => widget.profile.userAgents.remove(userAgent));
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('User-Agent'), actions: [
        IconButton(tooltip: '添加', icon: const Icon(Icons.add), onPressed: _add),
      ]),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('机场会根据 User-Agent 下发不同类型的订阅。实际发送：\n${profile.userAgent}',
              style: Theme.of(context).textTheme.bodySmall),
        ),
        SwitchListTile(
          title: Text(UserAgents.self),
          value: profile.userAgentAppend,
          onChanged: (value) => setState(() => profile.userAgentAppend = value),
        ),
        for (final userAgent in _all)
          SwitchListTile(
            title: Text(userAgent),
            secondary: UserAgents.presets.contains(userAgent)
                ? null
                : IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => _remove(userAgent),
                  ),
            value: profile.userAgents.contains(userAgent),
            onChanged: (value) => setState(() {
              value ? profile.userAgents.add(userAgent) : profile.userAgents.remove(userAgent);
            }),
          ),
      ]),
    );
  }
}

/// 节点过滤：全部、包含或排除，支持关键词和正则
class NodeFilterPage extends StatefulWidget {
  final Profile profile;

  const NodeFilterPage({super.key, required this.profile});

  @override
  State<NodeFilterPage> createState() => _NodeFilterPageState();
}

class _NodeFilterPageState extends State<NodeFilterPage> {
  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('过滤')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<NodeFilterMethod>(
          segments: const [
            ButtonSegment(value: NodeFilterMethod.all, label: Text('全部')),
            ButtonSegment(value: NodeFilterMethod.include, label: Text('包含')),
            ButtonSegment(value: NodeFilterMethod.exclude, label: Text('排除')),
          ],
          selected: {profile.filterMethod},
          showSelectedIcon: false,
          onSelectionChanged: (value) => setState(() => profile.filterMethod = value.first),
        ),
        if (profile.filterMethod != NodeFilterMethod.all) ...[
          const SizedBox(height: 16),
          TextFormField(
            initialValue: profile.filterPattern,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: '关键词/正则', hintText: '香港|日本', helperText: '匹配节点名称', border: OutlineInputBorder()),
            onChanged: (value) => profile.filterPattern = value.trim(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('匹配属性'),
            subtitle: const Text('同时匹配协议类型，如 vless、trojan'),
            value: profile.filterMatchType,
            onChanged: (value) => setState(() => profile.filterMatchType = value),
          ),
        ],
      ]),
    );
  }
}

/// 把添加或更新失败的原因说成人话，并告诉用户下一步能做什么
String describeProfileError(Object error) {
  if (error is DuplicateProfileException) return error.message;
  if (error is UnreadableProfileException) return '格式错误，请订正后重新添加：${error.message}';
  if (error is FormatException) {
    return error.message == 'empty profile' || error.message == 'unknown profile format'
        ? '看不懂这段内容。支持 Clash、Stash、sing-box、V2Ray（可批量）、Shadowsocks、Sub 和 GitHub 配置链接'
        : error.message;
  }
  if (error is SubscriptionStatusException) {
    return switch (error.statusCode) {
      401 || 403 => '添加失败（${error.statusCode}）。请修改 User-Agent 后重试，或者用浏览器打开配置链接，把下载的文件导入',
      404 => '添加失败（404）。请检查链接；如果机场限制设备数，打开 X-HWID 后重试',
      _ => '添加失败（${error.statusCode}）',
    };
  }
  if (error is HandshakeException) return '添加失败：$error。请打开代理或者更换当前节点后重试';
  return '添加失败：$error';
}
