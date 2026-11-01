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

  /// 备份里实际有的设置。旧版本的备份没有的字段不能用默认值盖掉现有的，所以恢复时看这份
  final Map<String, dynamic> settingsJson;

  const BackupContent(this.profiles, this.settings, this.decryptDomains, {this.settingsJson = const {}});
}

/// 恢复备份时选的内容
class RestoreParts {
  final bool profiles;
  final bool rules;
  final bool others;

  const RestoreParts({this.profiles = true, this.rules = true, this.others = true});
}

/// 本机留着的自动备份
class AutoBackup {
  final String name;
  final int size;

  const AutoBackup(this.name, this.size);
}

class CoreBackup {
  static const String _profilesEntry = 'profiles.json';
  static const String _settingsEntry = 'settings.json';
  static const String _domainsEntry = 'decrypt_domains.json';

  /// 恢复时属于“配置和节点”的设置
  static const Set<String> profileFields = {
    'activeProfileId',
    'selectedNodes',
    'favorites',
    'recentNodes',
    'disabledNodes',
    'userAgents',
    'searchKeywords',
  };

  /// 恢复时属于“分流”的设置
  static const Set<String> ruleFields = {
    'groups',
    'groupsEnabled',
    'hideDisabledGroups',
    'privateDirect',
    'providerRulesEnabled',
    'finalTarget',
    'chain',
    'chainFront',
    'autoGroups',
    'region',
    'regionRules',
    'ruleSetUpdateHours',
    'updateBundledRuleSets',
    'ruleSetDownload',
  };

  /// 这台设备自己的东西。WebDAV 密码也不进备份：备份文件就存在那个网盘上
  static const Set<String> deviceFields = {
    'clashSecret',
    'deviceId',
    'mixedPort',
    'upstreamPort',
    'clashPort',
    'probePort',
    'directPort',
    'globalPort',
    'lanEnabled',
    'lanPort',
    'lanGlobalPort',
    'lanUsername',
    'lanPassword',
    'mixedUsername',
    'mixedPassword',
    'capture',
    'tun',
    'systemProxyActive',
    'connectedAt',
    'ruleSetsUpdatedAt',
    'webDavUrl',
    'webDavUsername',
    'webDavPassword',
  };

  static Uint8List encode(BackupContent content) {
    final settings = content.settings.toJson()..removeWhere((key, _) => deviceFields.contains(key));
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

    final settings = read(_settingsEntry) as Map<String, dynamic>;
    return BackupContent(
      (read(_profilesEntry) as List).map((e) => Profile.fromJson(e)).toList(),
      CoreSettings.fromJson(settings),
      (read(_domainsEntry) as List).map((e) => e.toString()).toList(),
      settingsJson: settings,
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

  /// 每次上传一个新文件，云端能留下历史
  static String newName([DateTime? time]) {
    final stamp = (time ?? DateTime.now()).toIso8601String().substring(0, 19).replaceAll(RegExp('[-:T]'), '');
    return 'rsproxy-$stamp.zip';
  }

  Uri _file([String? name]) => Uri.parse('${url.endsWith('/') ? url : '$url/'}${name ?? _fileName}');

  /// 网盘返回的是 XML，各家的命名空间前缀不一样，只取 href
  static List<String> parseListing(String xml) {
    final names = <String>{};
    for (final match in RegExp(r'<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>', caseSensitive: false).allMatches(xml)) {
      final name = Uri.decodeComponent(match.group(1)!.split('/').where((e) => e.isNotEmpty).lastOrNull ?? '');
      if (name.startsWith('rsproxy-') && name.endsWith('.zip')) names.add(name);
    }
    return names.toList()..sort((a, b) => b.compareTo(a));
  }

  /// 云端的备份，新的在前
  Future<List<String>> list() async {
    final client = _client();
    try {
      final request = await client.openUrl('PROPFIND', _file('')).timeout(_timeout);
      _authorize(request);
      request.headers.set('Depth', '1');
      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 300) throw HttpException('WebDAV list failed: ${response.statusCode}');
      return parseListing(body);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> delete(String name) async {
    final client = _client();
    try {
      final request = await client.openUrl('DELETE', _file(name)).timeout(_timeout);
      _authorize(request);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      if (response.statusCode >= 300) throw HttpException('WebDAV delete failed: ${response.statusCode}');
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _client() {
    final client = HttpClient()..connectionTimeout = _timeout;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    return client;
  }

  void _authorize(HttpClientRequest request) {
    final credentials = base64.encode(utf8.encode('$username:$password'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
  }

  Future<void> upload(Uint8List bytes, {String? name}) async {
    final client = _client();
    try {
      final request = await client.openUrl('PUT', _file(name)).timeout(_timeout);
      _authorize(request);
      request.headers.contentType = ContentType.binary;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      if (response.statusCode >= 300) {
        throw HttpException('WebDAV upload failed: ${response.statusCode}', uri: _file(name));
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> download([String? name]) async {
    final client = _client();
    try {
      final request = await client.getUrl(_file(name)).timeout(_timeout);
      _authorize(request);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('WebDAV download failed: ${response.statusCode}', uri: _file(name));
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
