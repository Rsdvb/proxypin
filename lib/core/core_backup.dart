import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'core_settings.dart';
import 'profile.dart';

/// 备份包的内容：配置、分流组和解密名单。端口和接口密钥属于这台设备，不进备份
class BackupContent {
  final List<Profile> profiles;
  final CoreSettings settings;
  final List<String> decryptDomains;

  const BackupContent(this.profiles, this.settings, this.decryptDomains);
}

class CoreBackup {
  static const String _profilesEntry = 'profiles.json';
  static const String _settingsEntry = 'settings.json';
  static const String _domainsEntry = 'decrypt_domains.json';

  /// 这台设备自己的东西。WebDAV 密码也不进备份：备份文件就存在那个网盘上
  static const Set<String> _deviceFields = {
    'clashSecret',
    'mixedPort',
    'upstreamPort',
    'clashPort',
    'capture',
    'tun',
    'systemProxyActive',
    'webDavUrl',
    'webDavUsername',
    'webDavPassword',
  };

  static Uint8List encode(BackupContent content) {
    final settings = content.settings.toJson()..removeWhere((key, _) => _deviceFields.contains(key));
    final archive = Archive()
      ..add(_file(_profilesEntry, content.profiles))
      ..add(_file(_settingsEntry, settings))
      ..add(_file(_domainsEntry, content.decryptDomains));
    return ZipEncoder().encodeBytes(archive);
  }

  static ArchiveFile _file(String name, Object? value) => ArchiveFile.bytes(name, utf8.encode(jsonEncode(value)));

  /// 不是备份文件时抛 [FormatException]
  static BackupContent decode(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('not a backup file');
    }

    Object? read(String name) {
      final file = archive.findFile(name);
      if (file == null) throw const FormatException('not a backup file');
      return jsonDecode(utf8.decode(file.content));
    }

    return BackupContent(
      (read(_profilesEntry) as List).map((e) => Profile.fromJson(e)).toList(),
      CoreSettings.fromJson(read(_settingsEntry) as Map<String, dynamic>),
      (read(_domainsEntry) as List).map((e) => e.toString()).toList(),
    );
  }
}

/// WebDAV 同步，坚果云、Nextcloud 这类网盘都支持
class WebDavBackup {
  static const String _fileName = 'rsproxy-backup.zip';
  static const Duration _timeout = Duration(seconds: 30);

  final String url;
  final String username;
  final String password;

  /// 本地代理地址，网盘被墙时用
  final String? proxy;

  WebDavBackup({required this.url, required this.username, required this.password, this.proxy});

  Uri get _file => Uri.parse('${url.endsWith('/') ? url : '$url/'}$_fileName');

  HttpClient _client() {
    final client = HttpClient()..connectionTimeout = _timeout;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    return client;
  }

  void _authorize(HttpClientRequest request) {
    final credentials = base64.encode(utf8.encode('$username:$password'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
  }

  Future<void> upload(Uint8List bytes) async {
    final client = _client();
    try {
      final request = await client.openUrl('PUT', _file).timeout(_timeout);
      _authorize(request);
      request.headers.contentType = ContentType.binary;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      if (response.statusCode >= 300) {
        throw HttpException('WebDAV upload failed: ${response.statusCode}', uri: _file);
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> download() async {
    final client = _client();
    try {
      final request = await client.getUrl(_file).timeout(_timeout);
      _authorize(request);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('WebDAV download failed: ${response.statusCode}', uri: _file);
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
