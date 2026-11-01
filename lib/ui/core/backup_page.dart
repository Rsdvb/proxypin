import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/core/lan_sync.dart';
import 'package:proxypin/core/profile.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/ui/component/qrcode/qr_scan_view.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'format.dart';
import 'profile_options.dart';

/// 备份到文件、WebDAV 或另一台设备。备份包含订阅地址，相当于账号，别发给别人
class BackupPage extends StatefulWidget {
  final Configuration configuration;

  const BackupPage({super.key, required this.configuration});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final CoreManager _manager = CoreManager.instance;
  late final TextEditingController _url = TextEditingController(text: _manager.settings.webDavUrl);
  late final TextEditingController _username = TextEditingController(text: _manager.settings.webDavUsername);
  late final TextEditingController _password = TextEditingController(text: _manager.settings.webDavPassword);
  bool _busy = false;
  List<String> _remote = const [];
  List<AutoBackup> _local = const [];

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadLocal() async {
    final backups = await _manager.autoBackups();
    if (mounted) setState(() => _local = backups);
  }

  Future<void> _run(String done, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (done.isNotEmpty) _show(done);
    } on FormatException {
      _show('这不是 RsProxy 的备份文件');
    } catch (e) {
      _show('失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportFile() => _run('已导出', () async {
        final path = await Platforms.saveFileAdaptive(fileName: 'rsproxy-backup.zip');
        if (path != null) await File(path).writeAsBytes(_manager.exportBackup());
      });

  Future<void> _importFile() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['zip']);
    if (file == null) return;
    await _restore(await file.readAsBytes());
  }

  Future<void> _importUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从 URL 导入'),
        content: TextField(controller: controller, autofocus: true, autocorrect: false, keyboardType: TextInputType.url),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || !const {'http', 'https'}.contains(uri.scheme)) return _show('无效的地址');

    Uint8List? bytes;
    await _run('', () async => bytes = await CoreTools.downloadBytes(uri, proxy: _manager.proxyAddress));
    final downloaded = bytes;
    if (downloaded != null) await _restore(downloaded);
  }

  /// 先问要恢复哪些内容
  Future<void> _restore(Uint8List bytes) async {
    final parts = await showDialog<RestoreParts>(context: context, barrierDismissible: false, builder: (_) => const _RestoreDialog());
    if (parts == null) return;
    await _run('已恢复', () async {
      await _manager.restoreBackup(bytes, parts: parts);
      await widget.configuration.flushConfig();
    });
  }

  WebDavBackup? _webDav(String? proxy) {
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme) || !uri.hasAuthority) {
      _show('请填写正确的 WebDAV 地址');
      return null;
    }
    _manager.saveWebDav(url: url, username: _username.text.trim(), password: _password.text.trim());
    return WebDavBackup(url: url, username: _username.text.trim(), password: _password.text.trim(), proxy: proxy);
  }

  /// 按选定的路线逐个试，都失败时抛最后一个错误
  Future<T?> _overRoutes<T>(Future<T> Function(WebDavBackup webDav) action) async {
    final routes = _manager.settings.webDavDownload.routes(_manager.proxyAddress);
    if (routes.isEmpty) {
      _show('还没有连接，无法通过当前选择访问');
      return null;
    }
    for (var index = 0;; index++) {
      final webDav = _webDav(routes[index]);
      if (webDav == null) return null;
      try {
        return await action(webDav);
      } on Exception {
        if (index == routes.length - 1) rethrow;
      }
    }
  }

  Future<void> _listRemote() => _run('', () async {
        final names = await _overRoutes((webDav) => webDav.list());
        if (names != null && mounted) setState(() => _remote = names);
      });

  Future<void> _upload() => _run('已上传', () async {
        final name = WebDavBackup.newName();
        await _overRoutes((webDav) => webDav.upload(_manager.exportBackup(), name: name));
        final names = await _overRoutes((webDav) => webDav.list());
        if (names != null && mounted) setState(() => _remote = names);
      });

  Future<void> _restoreRemote(String name) async {
    Uint8List? bytes;
    await _run('', () async => bytes = await _overRoutes((webDav) => webDav.download(name)));
    final downloaded = bytes;
    if (downloaded != null) await _restore(downloaded);
  }

  Future<void> _deleteRemote(String name) => _run('', () async {
        await _overRoutes((webDav) => webDav.delete(name));
        if (mounted) setState(() => _remote = _remote.where((e) => e != name).toList());
      });

  Future<void> _openSync() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('发送到另一台设备'),
            subtitle: const Text('显示二维码，对方扫码取走这台设备的备份'),
            onTap: () => Navigator.pop(context, LanSyncLink.download),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('从另一台设备接收'),
            subtitle: const Text('显示二维码，对方扫码把备份传过来'),
            onTap: () => Navigator.pop(context, LanSyncLink.upload),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('扫描对方的二维码'),
            onTap: () => Navigator.pop(context, 'scan'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'scan') return _scanSync();

    final received = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(
      builder: (_) => _LanSyncPage(outgoing: action == LanSyncLink.download ? _manager.exportBackup() : null),
    ));
    if (received != null) await _restore(received);
  }

  /// 没有摄像头时（比如台式机）可以粘贴对方二维码下面的链接
  Future<String?> _readSyncLink() async {
    if (Platforms.isMobile()) {
      final result = await QrCodeScanner.scan(context);
      return result == '-1' ? null : result;
    }
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴对方的同步链接'),
        content: TextField(controller: controller, autofocus: true, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return text;
  }

  Future<void> _scanSync() async {
    final text = await _readSyncLink();
    if (text == null) return;
    final link = LanSyncLink.parse(text);
    if (link == null) return _show('这不是同步二维码');

    await _run('', () async {
      final address = await LanSyncClient.reachable(link);
      if (address == null) {
        _show('连接 ${link.addresses.join(', ')} 失败，请确认两台设备在同一个局域网内');
        return;
      }
      if (link.action == LanSyncLink.upload) {
        await LanSyncClient.upload(link, address, _manager.exportBackup());
        _show('已发送');
      } else {
        final bytes = await LanSyncClient.download(link, address);
        if (mounted) await _restore(bytes);
      }
    });
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

  @override
  Widget build(BuildContext context) {
    final settings = _manager.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('备份与同步')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('备份包含订阅地址，相当于你的账号，不要发给别人。', style: Theme.of(context).textTheme.bodySmall),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          _section('文件'),
          Text('iOS 上保存时可以选 iCloud 云盘，换手机时从“文件”里导入。', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _exportFile, child: const Text('导出'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton(onPressed: _importFile, child: const Text('导入'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton(onPressed: _importUrl, child: const Text('从 URL'))),
          ]),
          _section('局域网同步'),
          OutlinedButton(onPressed: _openSync, child: const Text('和另一台设备同步')),
          _section('WebDAV'),
          TextField(
            controller: _url,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '地址', hintText: 'https://dav.example.com/rsproxy'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码'),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('连接方式'),
            trailing: DropdownButton<DownloadStrategy>(
              value: settings.webDavDownload,
              underline: const SizedBox.shrink(),
              items: [
                for (final entry in downloadStrategyLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) {
                setState(() => settings.webDavDownload = value!);
                _manager.saveUiSettings();
              },
            ),
          ),
          Row(children: [
            Expanded(child: FilledButton(onPressed: _upload, child: const Text('上传'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton(onPressed: _listRemote, child: const Text('查看云端'))),
          ]),
          for (final name in _remote)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(name),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: '恢复', icon: const Icon(Icons.download_outlined, size: 20), onPressed: () => _restoreRemote(name)),
                IconButton(tooltip: '删除', icon: const Icon(Icons.close, size: 20), onPressed: () => _deleteRemote(name)),
              ]),
            ),
          _section('自动备份'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('添加配置后备份'),
            value: settings.autoBackupOnAdd,
            onChanged: (value) {
              setState(() => settings.autoBackupOnAdd = value);
              _manager.saveUiSettings();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('删除配置后备份'),
            value: settings.autoBackupOnRemove,
            onChanged: (value) {
              setState(() => settings.autoBackupOnRemove = value);
              _manager.saveUiSettings();
            },
          ),
          for (final backup in _local)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(backup.name),
              subtitle: Text(formatBytes(backup.size)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: '恢复',
                  icon: const Icon(Icons.download_outlined, size: 20),
                  onPressed: () async => _restore(await _manager.readAutoBackup(backup.name)),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () async {
                    await _manager.deleteAutoBackup(backup.name);
                    await _loadLocal();
                  },
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog();

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  bool _profiles = true;
  bool _rules = true;
  bool _settings = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('恢复备份'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('勾选的内容会覆盖这台设备现有的。'),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('配置和节点'),
          value: _profiles,
          onChanged: (value) => setState(() => _profiles = value!),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('分流和解密名单'),
          value: _rules,
          onChanged: (value) => setState(() => _rules = value!),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('其他设置'),
          value: _settings,
          onChanged: (value) => setState(() => _settings = value!),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: _profiles || _rules || _settings
              ? () => Navigator.pop(context, RestoreParts(profiles: _profiles, rules: _rules, others: _settings))
              : null,
          child: const Text('恢复'),
        ),
      ],
    );
  }
}

/// 开一个临时服务等对方连上来，离开页面就关掉
class _LanSyncPage extends StatefulWidget {
  /// 为空时是接收
  final Uint8List? outgoing;

  const _LanSyncPage({this.outgoing});

  @override
  State<_LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<_LanSyncPage> {
  LanSyncServer? _server;
  String? _link;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final addresses = await CoreTools.lanAddresses();
      if (addresses.isEmpty) throw const SocketException('没有连接局域网');
      final server = await LanSyncServer.start(
        outgoing: widget.outgoing,
        onReceived: widget.outgoing != null
            ? null
            : (bytes) {
                if (mounted) Navigator.of(context).pop(bytes);
              },
      );
      _server = server;
      if (mounted) setState(() => _link = server.link(addresses).toString());
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    return Scaffold(
      appBar: AppBar(title: Text(widget.outgoing == null ? '接收' : '发送')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null
              ? Text(_error!)
              : link == null
                  ? const CircularProgressIndicator()
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 240, height: 240, child: QrImageView(data: link, backgroundColor: Colors.white)),
                      const SizedBox(height: 16),
                      const Text('在另一台设备的“备份与同步”里扫描这个二维码。'),
                      const Text('同步完成前不要离开这个页面。'),
                      const SizedBox(height: 12),
                      SelectableText(link, style: Theme.of(context).textTheme.bodySmall),
                    ]),
        ),
      ),
    );
  }
}
