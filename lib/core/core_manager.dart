import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:proxypin/network/util/logger.dart';

import 'clash_api.dart';
import 'core_backup.dart';
import 'core_config.dart';
import 'core_platform.dart';
import 'core_settings.dart';
import 'profile.dart';
import 'profile_parser.dart';
import 'rule_group.dart';
import 'subscription.dart';

/// 解密端：RsProxy 自己的代理服务
abstract class MitmHost {
  int get port;

  /// 当前要解密的域名后缀，null 表示全部交给解密端判断
  List<String>? get domains;

  /// 用户编辑的名单原文，备份恢复时用
  List<String> get editableDomains;

  set editableDomains(List<String> value);

  /// 解密后的流量从 [upstreamPort] 回到 sing-box
  Future<void> attach(int upstreamPort);

  Future<void> detach();
}

/// 连接的总控：配置、模式、节点和内核的启停都从这里走
class CoreManager extends ChangeNotifier {
  static const Duration _apiTimeout = Duration(seconds: 10);

  static CoreManager? _instance;

  static CoreManager get instance => _instance!;

  static bool get isReady => _instance != null;

  static set instance(CoreManager manager) => _instance = manager;

  final CorePlatform platform;
  final CoreStore store;
  final MitmHost mitm;

  /// 读取内置规则集，名称不带扩展名。没有时返回 null
  final Future<Uint8List?> Function(String name) loadRuleSet;

  /// 代理的启动方式：iOS 始终走 TUN
  final bool alwaysTun;
  final ClashApi Function(int port, String secret) _apiFactory;

  CoreSettings settings = CoreSettings();
  List<Profile> profiles = [];
  CoreState state = CoreState.stopped;

  /// 最近一次启动失败的原因
  String? lastError;

  /// 节点 tag -> 最近一次测得的延迟（毫秒），不通时不在表里
  final Map<String, int> delays = {};

  /// 延迟测试进行中
  bool testing = false;
  StreamSubscription<CoreState>? _states;

  CoreManager({
    required this.platform,
    required this.store,
    required this.mitm,
    required this.loadRuleSet,
    this.alwaysTun = false,
    ClashApi Function(int port, String secret)? apiFactory,
  }) : _apiFactory = apiFactory ?? ((port, secret) => ClashApi(port: port, secret: secret));

  bool get isRunning => state == CoreState.running;

  bool get _tun => alwaysTun || settings.tun;

  ClashApi? _api;

  ClashApi get api => _api ??= _apiFactory(settings.clashPort, settings.clashSecret);

  Profile? get activeProfile {
    for (final profile in profiles) {
      if (profile.id == settings.activeProfileId) return profile;
    }
    return null;
  }

  List<Map<String, dynamic>> get nodes {
    final profile = activeProfile;
    if (profile == null) return const [];
    return profile.isMerged ? _mergedNodes(profile) : profile.activeNodes;
  }

  /// 合并配置的节点。不同来源可能有同名节点，sing-box 要求 tag 唯一，重名的加上来源名
  List<Map<String, dynamic>> _mergedNodes(Profile merged) {
    final used = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final id in merged.sources) {
      for (final source in profiles.where((e) => e.id == id)) {
        for (final node in source.activeNodes) {
          final tag = node['tag'].toString();
          final unique = used.add(tag) ? tag : '${source.name} $tag';
          used.add(unique);
          result.add({...node, 'tag': unique});
        }
      }
    }
    return result;
  }

  /// 当前选中的节点 tag，空表示自动选择
  String? get selectedNode {
    final profile = activeProfile;
    return profile == null ? null : settings.selectedNodes[profile.id];
  }

  /// 本地代理地址，下载订阅时用。upstream-in 在两个平台都有，mixed-in 在 iOS 上不开
  String? get proxyAddress => isRunning ? '127.0.0.1:${settings.upstreamPort}' : null;

  Future<void> load() async {
    settings = await store.loadSettings();
    profiles = await store.loadProfiles();
    _states = platform.states.listen(_onState);

    // iOS 上隧道可能比 App 活得久
    if (await platform.isRunning()) {
      state = CoreState.running;
      await _applyCapture();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _states?.cancel();
    _api?.close();
    super.dispose();
  }

  void _onState(CoreState value) {
    if (state == value) return;
    state = value;
    notifyListeners();
  }

  // ---- 连接 ----

  Future<void> connect() async {
    if (state != CoreState.stopped) return;
    lastError = null;
    _setState(CoreState.starting);
    try {
      await _writeConfig();
      await platform.start();
      await _afterStart();
      _setState(CoreState.running);
    } catch (e) {
      logger.e('connect failed: $e');
      lastError = e.toString();
      await platform.stop().catchError((_) {});
      _setState(CoreState.stopped);
    }
  }

  Future<void> disconnect() async {
    if (state != CoreState.running) return;
    _setState(CoreState.stopping);
    try {
      await platform.unwatchCapture();
      await platform.setKeepAlive(false);
      await platform.setSystemProxy(null);
      await mitm.detach();
      await platform.stop();
    } finally {
      _setState(CoreState.stopped);
    }
  }

  void _setState(CoreState value) {
    state = value;
    notifyListeners();
  }

  /// 内核的接口起来以后才算连上。系统代理放在最后：太早设置的话，内核没起来这段时间整机上不了网
  Future<void> _afterStart() async {
    await _waitForApi();
    await _applyCapture();
    if (settings.systemProxy && !_tun) {
      await platform.setSystemProxy(settings.mixedPort);
    }
  }

  Future<void> _waitForApi() async {
    final deadline = DateTime.now().add(_apiTimeout);
    while (true) {
      try {
        await api.mode();
        return;
      } on Exception {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('sing-box did not start');
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  String get _clashMode => CoreConfig.clashModeOf(settings.mode, capture: settings.capture);

  /// sing-box 重启后会恢复缓存里的模式，这里总要重新设置一遍。解密端先准备好，模式最后切
  Future<void> _applyCapture() async {
    if (settings.capture) {
      await mitm.attach(settings.upstreamPort);
      await platform.setKeepAlive(true);
    }
    await api.setMode(_clashMode);
    if (settings.capture) {
      await platform.watchCapture(
        port: mitm.port,
        clashPort: settings.clashPort,
        secret: settings.clashSecret,
        fallbackMode: CoreConfig.clashModeOf(settings.mode, capture: false),
      );
    } else {
      await platform.unwatchCapture();
      await platform.setKeepAlive(false);
      await mitm.detach();
    }
  }

  /// App 回到前台。iOS 上隧道可能因为主 App 被挂起而退回了不解密，这里接回来
  Future<void> onResumed() async {
    if (isRunning && settings.capture) {
      await _applyCapture();
    }
  }

  Future<void> setMode(RouteMode mode) async {
    settings.mode = mode;
    await store.saveSettings(settings);
    if (isRunning) await api.setMode(_clashMode);
    notifyListeners();
  }

  Future<void> setCapture(bool enabled) async {
    settings.capture = enabled;
    await store.saveSettings(settings);
    if (isRunning) await _applyCapture();
    notifyListeners();
  }

  Future<void> setSystemProxy(bool enabled) async {
    settings.systemProxy = enabled;
    await store.saveSettings(settings);
    if (isRunning && !_tun) {
      await platform.setSystemProxy(enabled ? settings.mixedPort : null);
    }
    notifyListeners();
  }

  // ---- 配置生成 ----

  Future<void> _writeConfig() async {
    final directory = await platform.directory();
    final rules = Directory('${directory.path}/rules');
    await rules.create(recursive: true);

    final options = CoreOptions(
      nodes: nodes,
      selected: selectedNode,
      groups: await _usableGroups(rules),
      tun: _tun,
      mixedPort: alwaysTun ? 0 : settings.mixedPort,
      upstreamPort: settings.upstreamPort,
      mitmPort: mitm.port,
      mitmDomains: mitm.domains,
      clashPort: settings.clashPort,
      clashSecret: settings.clashSecret,
      clashDefaultMode: CoreConfig.modeRule,
      ruleSetDirectory: rules.path,
      cachePath: await platform.cachePath(),
      directDns: settings.directDns,
      remoteDns: settings.remoteDns,
      fakeIp: settings.fakeIp,
      ipv6: settings.ipv6,
      testUrl: settings.testUrl,
    );
    await File('${directory.path}/config.json').writeAsString(jsonEncode(CoreConfig.build(options)), flush: true);
  }

  /// 把用到的规则集放到内核读得到的位置。缺文件的规则集不能写进配置，否则内核起不来
  Future<List<RuleGroup>> _usableGroups(Directory directory) async {
    final usable = <RuleGroup>[];
    for (final group in settings.groups) {
      if (!group.enabled) continue;
      final available = <String>[];
      for (final name in group.ruleSets) {
        final file = File('${directory.path}/$name.srs');
        final bytes = await loadRuleSet(name);
        if (bytes != null) {
          await file.writeAsBytes(bytes);
          available.add(name);
        } else if (await file.exists()) {
          available.add(name);
        } else {
          logger.w('rule set $name is missing');
        }
      }
      usable.add(RuleGroup.fromJson(group.toJson())..ruleSets = available);
    }
    return usable;
  }

  /// 配置变了。运行中要重载内核，这会断开现有连接
  Future<void> _applyConfig() async {
    if (!isRunning) return;
    await _writeConfig();
    await platform.reload();
    await _waitForApi();
    await _applyCapture();
  }

  /// 解密名单变了
  Future<void> reloadConfig() => _applyConfig();

  // ---- 配置管理 ----

  /// 添加配置。[input] 是订阅地址，或配置内容本身。第一份配置自动成为当前配置
  Future<Profile> addProfile(String input, {String? name}) async {
    final text = input.trim();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final Profile profile;

    if (_isSubscriptionUrl(text)) {
      final result = await Subscription.fetch(text, proxy: proxyAddress);
      profile = Profile(
        id: id,
        name: _firstNotEmpty(name, result.title) ?? Subscription.nameFromUrl(text),
        url: text,
        info: result.info,
        website: result.website,
        updateHours: result.updateHours ?? Profile.defaultUpdateHours,
        updatedAt: DateTime.now(),
        nodes: result.parsed.outbounds,
        skipped: result.parsed.skipped,
      );
    } else {
      final parsed = ProfileParser.parse(text);
      profile = Profile(
        id: id,
        name: _firstNotEmpty(name) ?? '配置 ${profiles.length + 1}',
        updatedAt: DateTime.now(),
        nodes: parsed.outbounds,
        skipped: parsed.skipped,
      );
    }

    profiles = [...profiles, profile];
    await store.saveProfiles(profiles);
    if (activeProfile == null) {
      await setActiveProfile(profile.id);
    }
    notifyListeners();
    return profile;
  }

  static String? _firstNotEmpty(String? first, [String? second]) {
    if (first != null && first.trim().isNotEmpty) return first.trim();
    return second != null && second.trim().isNotEmpty ? second.trim() : null;
  }

  static bool _isSubscriptionUrl(String text) =>
      !text.contains(RegExp(r'\s')) && (text.startsWith('https://') || text.startsWith('http://'));

  /// 把几份配置合成一份，节点跟着来源走
  Future<Profile> mergeProfiles(String name, List<String> sources) async {
    final profile = Profile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      updatedAt: DateTime.now(),
      sources: sources,
    );
    profiles = [...profiles, profile];
    await store.saveProfiles(profiles);
    notifyListeners();
    return profile;
  }

  /// 更新订阅。失败时保留原来的节点
  Future<void> updateProfile(Profile profile) async {
    final url = profile.url;
    if (url == null) return;

    final result = await Subscription.fetch(url, userAgent: profile.userAgent, proxy: proxyAddress);
    profile
      ..nodes = result.parsed.outbounds
      ..skipped = result.parsed.skipped
      ..info = result.info ?? profile.info
      ..website = result.website ?? profile.website
      ..updatedAt = DateTime.now();
    await store.saveProfiles(profiles);
    if (profile.id == settings.activeProfileId) await _applyConfig();
    notifyListeners();
  }

  /// 更新到期的订阅，一份失败不影响其他
  Future<void> updateDueProfiles() async {
    final now = DateTime.now();
    for (final profile in profiles.where((e) => e.isDue(now)).toList()) {
      try {
        await updateProfile(profile);
      } on Exception catch (e) {
        logger.w('update ${profile.name} failed: $e');
      }
    }
  }

  Future<void> saveProfile(Profile profile) async {
    await store.saveProfiles(profiles);
    if (profile.id == settings.activeProfileId) await _applyConfig();
    notifyListeners();
  }

  Future<void> setActiveProfile(String id) async {
    settings.activeProfileId = id;
    delays.clear();
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }

  Future<void> removeProfile(String id) async {
    final wasActive = id == settings.activeProfileId;
    profiles = profiles.where((e) => e.id != id).toList();
    settings.selectedNodes.remove(id);
    if (wasActive) {
      settings.activeProfileId = profiles.isEmpty ? null : profiles.first.id;
      delays.clear();
    }
    await store.saveProfiles(profiles);
    await store.saveSettings(settings);
    if (wasActive) await _applyConfig();
    notifyListeners();
  }

  Future<void> reorderProfiles(int oldIndex, int newIndex) async {
    final list = [...profiles];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    profiles = list;
    await store.saveProfiles(profiles);
    notifyListeners();
  }

  // ---- 节点 ----

  Future<void> selectNode(String tag) async {
    final profile = activeProfile;
    if (profile == null) return;
    settings.selectedNodes[profile.id] = tag;
    await store.saveSettings(settings);
    if (isRunning) await api.select(RuleTarget.selected, tag);
    notifyListeners();
  }

  Future<void> toggleFavorite(String tag) async {
    if (!settings.favorites.remove(tag)) settings.favorites.add(tag);
    await store.saveSettings(settings);
    notifyListeners();
  }

  /// 测当前配置所有节点的延迟。内核没运行时无法测
  Future<void> testLatency() async {
    if (!isRunning || testing) return;
    testing = true;
    notifyListeners();
    try {
      final result = await api.groupDelay(RuleTarget.selected, url: settings.testUrl);
      delays
        ..clear()
        ..addAll(result);
    } finally {
      testing = false;
      notifyListeners();
    }
  }

  // ---- 分流 ----

  Future<void> saveGroups(List<RuleGroup> groups) async {
    settings.groups = groups;
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }

  Uint8List exportBackup() => CoreBackup.encode(BackupContent(profiles, settings, mitm.editableDomains));

  /// 用备份替换配置、分流和解密名单，这台设备自己的端口和密钥不动
  Future<void> restoreBackup(Uint8List bytes) async {
    final backup = CoreBackup.decode(bytes);
    final restored = backup.settings;
    profiles = backup.profiles;
    settings
      ..activeProfileId = restored.activeProfileId
      ..selectedNodes = restored.selectedNodes
      ..favorites = restored.favorites
      ..groups = restored.groups
      ..mode = restored.mode
      ..systemProxy = restored.systemProxy
      ..fakeIp = restored.fakeIp
      ..ipv6 = restored.ipv6
      ..remoteDns = restored.remoteDns
      ..directDns = restored.directDns
      ..testUrl = restored.testUrl;
    mitm.editableDomains = backup.decryptDomains;
    delays.clear();
    await store.saveProfiles(profiles);
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }

  Future<void> saveWebDav({required String url, required String username, required String password}) async {
    settings
      ..webDavUrl = url
      ..webDavUsername = username
      ..webDavPassword = password;
    await store.saveSettings(settings);
  }

  /// 空值保留原设置：这些字段没有填空的合理含义，填错了内核会起不来
  Future<void> saveAdvanced({
    required String remoteDns,
    required String directDns,
    required String testUrl,
    required bool fakeIp,
    required bool ipv6,
  }) async {
    if (remoteDns.isNotEmpty) settings.remoteDns = remoteDns;
    if (directDns.isNotEmpty) settings.directDns = directDns;
    if (testUrl.isNotEmpty) settings.testUrl = testUrl;
    settings
      ..fakeIp = fakeIp
      ..ipv6 = ipv6;
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }
}
