import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'core_config.dart';
import 'profile.dart';
import 'rule_group.dart';

/// 连接相关的设置
class CoreSettings {
  String? activeProfileId;

  /// 配置 id -> 上次选中的节点
  Map<String, String> selectedNodes;

  /// 收藏的节点名。按名称存，订阅更新后仍然有效
  Set<String> favorites;
  String webDavUrl;
  String webDavUsername;
  String webDavPassword;
  RouteMode mode;
  bool capture;

  /// Windows：是否走 TUN（需要管理员权限）。iOS 始终走 TUN
  bool tun;

  /// Windows：连接时是否设置系统代理
  bool systemProxy;
  bool fakeIp;
  bool ipv6;
  String remoteDns;
  String directDns;
  String testUrl;
  List<RuleGroup> groups;
  int mixedPort;
  int upstreamPort;
  int clashPort;
  String clashSecret;

  CoreSettings({
    this.activeProfileId,
    Map<String, String>? selectedNodes,
    Set<String>? favorites,
    this.webDavUrl = '',
    this.webDavUsername = '',
    this.webDavPassword = '',
    this.mode = RouteMode.rule,
    this.capture = false,
    this.tun = false,
    this.systemProxy = true,
    this.fakeIp = true,
    this.ipv6 = true,
    this.remoteDns = 'https://1.1.1.1/dns-query',
    this.directDns = 'local',
    this.testUrl = 'https://www.gstatic.com/generate_204',
    List<RuleGroup>? groups,
    this.mixedPort = 17890,
    this.upstreamPort = 17891,
    this.clashPort = 17892,
    String? clashSecret,
  })  : selectedNodes = selectedNodes ?? {},
        favorites = favorites ?? {},
        groups = groups ?? RuleGroup.defaults(),
        clashSecret = clashSecret ?? _randomSecret();

  /// 接口只监听本机，但同一台设备上的其他程序也能访问，所以每次安装生成一个
  static String _randomSecret() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }

  factory CoreSettings.fromJson(Map<String, dynamic> json) => CoreSettings(
        activeProfileId: json['activeProfileId'],
        selectedNodes: (json['selectedNodes'] as Map?)?.cast<String, String>(),
        favorites: (json['favorites'] as List?)?.map((e) => e.toString()).toSet(),
        webDavUrl: json['webDavUrl'] ?? '',
        webDavUsername: json['webDavUsername'] ?? '',
        webDavPassword: json['webDavPassword'] ?? '',
        mode: RouteMode.values.asNameMap()[json['mode']] ?? RouteMode.rule,
        capture: json['capture'] ?? false,
        tun: json['tun'] ?? false,
        systemProxy: json['systemProxy'] ?? true,
        fakeIp: json['fakeIp'] ?? true,
        ipv6: json['ipv6'] ?? true,
        remoteDns: json['remoteDns'] ?? 'https://1.1.1.1/dns-query',
        directDns: json['directDns'] ?? 'local',
        testUrl: json['testUrl'] ?? 'https://www.gstatic.com/generate_204',
        groups: (json['groups'] as List?)?.map((e) => RuleGroup.fromJson(e)).toList(),
        mixedPort: json['mixedPort'] ?? 17890,
        upstreamPort: json['upstreamPort'] ?? 17891,
        clashPort: json['clashPort'] ?? 17892,
        clashSecret: json['clashSecret'],
      );

  Map<String, dynamic> toJson() => {
        'activeProfileId': activeProfileId,
        'selectedNodes': selectedNodes,
        'favorites': favorites.toList(),
        'webDavUrl': webDavUrl,
        'webDavUsername': webDavUsername,
        'webDavPassword': webDavPassword,
        'mode': mode.name,
        'capture': capture,
        'tun': tun,
        'systemProxy': systemProxy,
        'fakeIp': fakeIp,
        'ipv6': ipv6,
        'remoteDns': remoteDns,
        'directDns': directDns,
        'testUrl': testUrl,
        'groups': groups,
        'mixedPort': mixedPort,
        'upstreamPort': upstreamPort,
        'clashPort': clashPort,
        'clashSecret': clashSecret,
      };
}

/// 设置和配置的本地存储。写入先落到临时文件再改名，写到一半退出不会把文件写坏
class CoreStore {
  final Directory directory;

  CoreStore(this.directory);

  File get _settingsFile => File('${directory.path}/core_settings.json');

  File get _profilesFile => File('${directory.path}/profiles.json');

  Future<CoreSettings> loadSettings() async {
    final json = await _read(_settingsFile);
    return json is Map<String, dynamic> ? CoreSettings.fromJson(json) : CoreSettings();
  }

  Future<List<Profile>> loadProfiles() async {
    final json = await _read(_profilesFile);
    return json is List ? json.map((e) => Profile.fromJson(e)).toList() : [];
  }

  Future<void> saveSettings(CoreSettings settings) => _write(_settingsFile, settings);

  Future<void> saveProfiles(List<Profile> profiles) => _write(_profilesFile, profiles);

  Future<Object?> _read(File file) async {
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } on FormatException {
      return null;
    }
  }

  /// 依次写入，连续保存时后一次不会被前一次盖掉
  Future<void> _pending = Future.value();

  Future<void> _write(File file, Object? value) {
    final text = jsonEncode(value);
    return _pending = _pending.catchError((_) {}).then((_) async {
      await directory.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
  }
}
