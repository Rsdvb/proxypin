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

  /// 用户自己加的 User-Agent，所有配置都能选
  List<String> userAgents;

  /// X-HWID 发送的设备标识，安装时随机生成
  String deviceId;
  String webDavUrl;
  String webDavUsername;
  String webDavPassword;
  RouteMode mode;
  bool capture;

  /// 总开关：是否使用机场的分流规则，配置里选了保留才有
  bool providerRulesEnabled;

  /// Windows：是否走 TUN（需要管理员权限）。iOS 始终走 TUN
  bool tun;

  /// Windows：连接时是否设置系统代理
  bool systemProxy;

  /// 系统代理现在指向我们。崩溃后靠它知道要清掉，否则代理指着死端口，整机上不了网
  bool systemProxyActive;

  /// 启动 App 时自动连接
  bool autoConnect;
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
    List<String>? userAgents,
    String? deviceId,
    this.webDavUrl = '',
    this.webDavUsername = '',
    this.webDavPassword = '',
    this.mode = RouteMode.rule,
    this.capture = false,
    this.providerRulesEnabled = true,
    this.tun = false,
    this.systemProxy = true,
    this.systemProxyActive = false,
    this.autoConnect = false,
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
        userAgents = userAgents ?? [],
        deviceId = deviceId ?? _randomDeviceId(),
        groups = groups ?? RuleGroup.defaults(),
        clashSecret = clashSecret ?? _randomSecret();

  static String _randomDeviceId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 接口只监听本机，但同一台设备上的其他程序也能访问，所以每次安装生成一个
  static String _randomSecret() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }

  factory CoreSettings.fromJson(Map<String, dynamic> json) => CoreSettings(
        activeProfileId: json['activeProfileId'],
        selectedNodes: (json['selectedNodes'] as Map?)?.cast<String, String>(),
        favorites: (json['favorites'] as List?)?.map((e) => e.toString()).toSet(),
        userAgents: (json['userAgents'] as List?)?.map((e) => e.toString()).toList(),
        deviceId: json['deviceId'],
        webDavUrl: json['webDavUrl'] ?? '',
        webDavUsername: json['webDavUsername'] ?? '',
        webDavPassword: json['webDavPassword'] ?? '',
        mode: RouteMode.values.asNameMap()[json['mode']] ?? RouteMode.rule,
        capture: json['capture'] ?? false,
        providerRulesEnabled: json['providerRulesEnabled'] ?? true,
        tun: json['tun'] ?? false,
        systemProxy: json['systemProxy'] ?? true,
        systemProxyActive: json['systemProxyActive'] ?? false,
        autoConnect: json['autoConnect'] ?? false,
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
        'userAgents': userAgents,
        'deviceId': deviceId,
        'webDavUrl': webDavUrl,
        'webDavUsername': webDavUsername,
        'webDavPassword': webDavPassword,
        'mode': mode.name,
        'capture': capture,
        'providerRulesEnabled': providerRulesEnabled,
        'tun': tun,
        'systemProxy': systemProxy,
        'systemProxyActive': systemProxyActive,
        'autoConnect': autoConnect,
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
