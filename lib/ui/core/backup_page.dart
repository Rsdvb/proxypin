import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/core/core_backup.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/utils/platform.dart';

/// 备份到文件或 WebDAV。备份包含订阅地址，相当于账号，别发给别人
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

  Future<void> _run(String done, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      _show(done);
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
    final bytes = await file.readAsBytes();
    if (await _confirmRestore()) await _restore(bytes);
  }

  Future<bool> _confirmRestore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份'),
        content: const Text('当前的配置、分流和解密名单会被备份内容替换。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('恢复')),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _restore(Uint8List bytes) => _run('已恢复', () async {
        await _manager.restoreBackup(bytes);
        await widget.configuration.flushConfig();
      });

  WebDavBackup? _webDav() {
    final url = _url.text.trim();
    if (url.isEmpty) {
      _show('请先填写 WebDAV 地址');
      return null;
    }
    _manager.saveWebDav(url: url, username: _username.text.trim(), password: _password.text);
    return WebDavBackup(
        url: url, username: _username.text.trim(), password: _password.text, proxy: _manager.proxyAddress);
  }

  Future<void> _upload() async {
    final webDav = _webDav();
    if (webDav != null) await _run('已上传', () => webDav.upload(_manager.exportBackup()));
  }

  Future<void> _download() async {
    final webDav = _webDav();
    if (webDav == null || !await _confirmRestore()) return;
    await _run('已恢复', () async {
      await _manager.restoreBackup(await webDav.download());
      await widget.configuration.flushConfig();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与同步')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('备份包含订阅地址，相当于你的账号，不要发给别人。', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          Text('文件', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _exportFile, child: const Text('导出'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton(onPressed: _importFile, child: const Text('导入'))),
          ]),
          const SizedBox(height: 24),
          Text('WebDAV', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '地址', hintText: 'https://dav.example.com/rsproxy', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton(onPressed: _upload, child: const Text('上传'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton(onPressed: _download, child: const Text('从云端恢复'))),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 20), child: LinearProgressIndicator()),
        ]),
      ),
    );
  }
}
