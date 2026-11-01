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
import 'device_identity.dart';
import 'import_link.dart';
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

/// 添加的配置已经有了
class DuplicateProfileException implements Exception {
  final String message;

  const DuplicateProfileException(this.message);

  @override
  String toString() => message;
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

  /// 配置已更新，但内核还在用旧的，重新加载或下次连接后生效
  bool needsReload = false;

  /// 等用户确认的一键导入。不直接添加：链接可能来自任何网页
  final ValueNotifier<ImportLink?> pendingImport = ValueNotifier(null);
  StreamSubscription<CoreState>? _states;
  StreamSubscription<String>? _links;

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

  /// 节点列表每个控件都会读，过滤和合并都要分配内存，所以算一次留着，配置变了才重算
  List<Map<String, dynamic>>? _nodes;

  List<Map<String, dynamic>> get nodes {
    final profile = activeProfile;
    if (profile == null) return const [];
    return _nodes ??= profile.isMerged ? _mergedNodes(profile) : profile.activeNodes;
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
    _nodes = null;
    _states = platform.states.listen(_onState);
    _links = platform.links.listen(_onLink);
    final link = await platform.takePendingLink();
    if (link != null) _onLink(link);

    // iOS 上隧道可能比 App 活得久
    if (await platform.isRunning()) {
      state = CoreState.running;
      await _applyCapture();
    } else if (settings.systemProxyActive) {
      // 上次崩溃时没来得及清
      await _setSystemProxy(null);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _states?.cancel();
    _links?.cancel();
    _autoUpdate?.cancel();
    pendingImport.dispose();
    _api?.close();
    super.dispose();
  }

  void _onLink(String link) {
    final parsed = ImportLink.parse(link);
    if (parsed != null) pendingImport.value = parsed;
  }

  /// 连接、断开、重载期间平台的状态是过程中的，以这几个流程的结果为准
  int _transitions = 0;

  Future<T> _transition<T>(Future<T> Function() action) async {
    _transitions++;
    try {
      return await action();
    } finally {
      _transitions--;
    }
  }

  void _onState(CoreState value) {
    if (_transitions > 0 || state == value) return;
    final crashed = value == CoreState.stopped && state == CoreState.running;
    state = value;
    if (crashed) {
      lastError = '内核意外退出';
      unawaited(_afterCrash());
    }
    notifyListeners();
  }

  Future<void> _afterCrash() async {
    await _setSystemProxy(null);
    await platform.setKeepAlive(false);
    await mitm.detach();
  }

  Future<void> _setSystemProxy(int? port) async {
    await platform.setSystemProxy(port);
    settings.systemProxyActive = port != null;
    await store.saveSettings(settings);
  }

  // ---- 连接 ----

  Future<void> connect() async {
    if (state != CoreState.stopped) return;
    lastError = null;
    _setState(CoreState.starting);
    await _transition(() async {
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
    });
  }

  Future<void> disconnect() async {
    if (state != CoreState.running) return;
    _setState(CoreState.stopping);
    await _transition(() async {
      try {
        await platform.unwatchCapture();
        await platform.setKeepAlive(false);
        // 先清代理再停内核：反过来的话，中间这段时间整机上不了网
        await _setSystemProxy(null);
        await mitm.detach();
        await platform.stop();
      } finally {
        _setState(CoreState.stopped);
      }
    });
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
      await _setSystemProxy(settings.mixedPort);
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
    unawaited(updateDueProfiles());
  }

  Timer? _autoUpdate;

  /// 定时检查到期的订阅。间隔最短 5 分钟，每分钟看一次足够了
  void startAutoUpdate() {
    _autoUpdate ??= Timer.periodic(const Duration(minutes: 1), (_) => unawaited(updateDueProfiles()));
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
      await _setSystemProxy(enabled ? settings.mixedPort : null);
    }
    notifyListeners();
  }

  // ---- 配置生成 ----

  Future<void> _writeConfig() async {
    final directory = await platform.directory();
    final rules = Directory('${directory.path}/rules');
    await rules.create(recursive: true);

    final profile = activeProfile;
    final routing = profile != null && profile.keepProviderRules && settings.providerRulesEnabled ? profile.routing : null;
    final dns = profile != null && profile.preferOutboundDns && profile.outboundDns.isNotEmpty ? profile.outboundDns.first : null;

    final options = CoreOptions(
      nodes: nodes,
      selected: selectedNode,
      groups: await _usableGroups(rules),
      providerRouting: routing,
      providerRuleSets: routing == null ? const {} : await _installRuleSets(rules, routing.ruleSets),
      outboundDns: dns,
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
    needsReload = false;
  }

  /// 把用到的规则集放到内核读得到的位置。缺文件的规则集不能写进配置，否则内核起不来
  Future<List<RuleGroup>> _usableGroups(Directory directory) async {
    final usable = <RuleGroup>[];
    for (final group in settings.groups) {
      if (!group.enabled) continue;
      final available = await _installRuleSets(directory, group.ruleSets);
      usable.add(RuleGroup.fromJson(group.toJson())..ruleSets = available.toList());
    }
    return usable;
  }

  /// 装好 [names] 里能找到的规则集，返回可用的。已经装过的不再读内置文件
  Future<Set<String>> _installRuleSets(Directory directory, Iterable<String> names) async {
    final available = <String>{};
    for (final name in names) {
      final file = File('${directory.path}/$name.srs');
      if (await file.exists()) {
        available.add(name);
        continue;
      }
      final bytes = await loadRuleSet(name);
      if (bytes == null) {
        logger.w('rule set $name is missing');
        continue;
      }
      await file.writeAsBytes(bytes);
      available.add(name);
    }
    return available;
  }

  /// 配置变了。运行中要重载内核，这会断开现有连接
  Future<void> _applyConfig() async {
    if (!isRunning) return;
    await _writeConfig();
    await _transition(() async {
      await platform.reload();
      await _waitForApi();
      await _applyCapture();
    });
  }

  /// 解密名单变了
  Future<void> reloadConfig() => _applyConfig();

  // ---- 配置管理 ----

  /// 添加配置。[input] 是订阅地址、一键导入链接，或配置内容本身。[options] 带着用户选好的选项。
  /// 第一份配置自动成为当前配置
  Future<Profile> addProfile(String input, {String? name, Profile? options}) async {
    var text = input.trim();
    final explicitName = _firstNotEmpty(name);
    if (explicitName != null && profiles.any((e) => e.name == explicitName)) {
      throw const DuplicateProfileException('已经有同名的配置了');
    }

    final link = ImportLink.parse(text);
    if (link != null) text = link.url;
    text = Subscription.normalizeUrl(text);
    if (profiles.any((e) => e.url == text)) {
      throw const DuplicateProfileException('这份配置已经添加过了');
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final profile = Profile(id: id, name: explicitName ?? '');
    if (options != null) profile.copyOptionsFrom(options);
    if (link != null && link.outboundDns.isNotEmpty) {
      profile
        ..outboundDns = link.outboundDns
        ..preferOutboundDns = true;
    }

    if (_isSubscriptionUrl(text)) {
      profile.url = text;
      final result = await _download(profile);
      _apply(profile, result);
      final automatic = _firstNotEmpty(link?.name ?? Subscription.nameInLink(text), result.title) ??
          await Subscription.siteTitle(text, profile.userAgent, proxy: proxyAddress) ??
          Subscription.nameFromUrl(text);
      profile.name = explicitName ?? _uniqueName(automatic);
    } else {
      final parsed = ProfileParser.parse(text);
      profile
        ..name = explicitName ?? _uniqueName('配置 ${profiles.length + 1}')
        ..updatedAt = DateTime.now()
        ..nodes = parsed.outbounds
        ..routing = parsed.routing
        ..skipped = parsed.skipped;
    }

    profiles = [...profiles, profile];
    await store.saveProfiles(profiles);
    if (activeProfile == null) {
      await setActiveProfile(profile.id);
    }
    notifyListeners();
    return profile;
  }

  /// 自动取的名称重复时加序号。用户自己填的重名会提示，不替他改
  String _uniqueName(String name) {
    var candidate = name;
    for (var index = 2; profiles.any((e) => e.name == candidate); index++) {
      candidate = '$name $index';
    }
    return candidate;
  }

  Future<SubscriptionResult> _download(Profile profile) async {
    return Subscription.fetch(
      profile.url!,
      userAgent: profile.userAgent,
      strategy: profile.downloadStrategy,
      proxy: proxyAddress,
      headers: profile.xhwid ? await DeviceIdentity.headers(settings.deviceId) : const {},
      decryptPassword: profile.decryptPassword,
    );
  }

  void _apply(Profile profile, SubscriptionResult result) {
    profile
      ..nodes = result.parsed.outbounds
      ..routing = result.parsed.routing
      ..skipped = result.parsed.skipped
      ..info = result.info ?? profile.info
      ..website = profile.website?.isNotEmpty == true ? profile.website : result.website
      ..updatedAt = DateTime.now();
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

  /// 更新订阅。失败时保留原来的节点。没开“更新后重新加载”时内核继续用旧配置，不打断现有连接
  Future<void> updateProfile(Profile profile, {bool automatic = false}) async {
    if (profile.url == null) return;

    _apply(profile, await _download(profile));
    _nodes = null;
    await store.saveProfiles(profiles);

    if (_usesProfile(profile) && isRunning) {
      if (profile.reloadAfterUpdate) {
        await _applyConfig();
        if (automatic && profile.testLatencyAfterUpdate) unawaited(testLatency());
      } else {
        needsReload = true;
      }
    }
    notifyListeners();
  }

  /// 当前配置就是它，或者是用到它的合并配置
  bool _usesProfile(Profile profile) {
    final active = activeProfile;
    return active != null && (active.id == profile.id || active.sources.contains(profile.id));
  }

  bool _updatingDue = false;

  /// 更新到期的订阅，一份失败不影响其他
  Future<void> updateDueProfiles() async {
    if (_updatingDue) return;
    _updatingDue = true;
    try {
      await _updateDue();
    } finally {
      _updatingDue = false;
    }
  }

  Future<void> _updateDue() async {
    final now = DateTime.now();
    for (final profile in profiles.where((e) => e.isDue(now)).toList()) {
      try {
        await updateProfile(profile, automatic: true);
      } on Exception catch (e) {
        logger.w('update ${profile.name} failed: $e');
      }
    }
  }

  Future<void> saveProfile(Profile profile) async {
    _nodes = null;
    await store.saveProfiles(profiles);
    if (_usesProfile(profile)) await _applyConfig();
    notifyListeners();
  }

  /// 把自动移除的节点放回来
  Future<void> restoreRemovedNodes(Profile profile) async {
    profile.removedNodes = {};
    await saveProfile(profile);
  }

  Future<void> setActiveProfile(String id) async {
    settings.activeProfileId = id;
    delays.clear();
    _nodes = null;
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }

  Future<void> removeProfile(String id) async {
    final wasActive = id == settings.activeProfileId;
    profiles = profiles.where((e) => e.id != id).toList();
    settings.selectedNodes.remove(id);
    _nodes = null;
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
      await _removeFailedNodes();
    } finally {
      testing = false;
      notifyListeners();
    }
  }

  static const int _removeAttempts = 3;

  /// 自动移除失败节点，一个节点最多试 3 次。全部失败时不动：那多半是本机断网了
  Future<void> _removeFailedNodes() async {
    final profile = activeProfile;
    if (profile == null || profile.isMerged || !profile.autoRemoveFailed || delays.isEmpty) return;

    var failed = nodes.map((e) => e['tag'].toString()).where((tag) => !delays.containsKey(tag)).toList();
    for (var attempt = 1; attempt < _removeAttempts && failed.isNotEmpty; attempt++) {
      final stillFailing = <String>[];
      for (final tag in failed) {
        final delay = await api.delay(tag, url: settings.testUrl);
        if (delay == null) {
          stillFailing.add(tag);
        } else {
          delays[tag] = delay;
        }
      }
      failed = stillFailing;
    }

    if (failed.isEmpty) return;
    profile.removedNodes = {...profile.removedNodes, ...failed};
    await saveProfile(profile);
  }

  // ---- User-Agent ----

  Future<void> addUserAgent(String userAgent) async {
    final text = userAgent.trim();
    if (text.isEmpty || UserAgents.presets.contains(text) || settings.userAgents.contains(text)) return;
    settings.userAgents = [...settings.userAgents, text];
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> removeUserAgent(String userAgent) async {
    settings.userAgents = settings.userAgents.where((e) => e != userAgent).toList();
    await store.saveSettings(settings);
    notifyListeners();
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
    _nodes = null;
    settings
      ..activeProfileId = restored.activeProfileId
      ..selectedNodes = restored.selectedNodes
      ..favorites = restored.favorites
      ..userAgents = restored.userAgents
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
    bool? tun,
    bool? autoConnect,
  }) async {
    if (remoteDns.isNotEmpty) settings.remoteDns = remoteDns;
    if (directDns.isNotEmpty) settings.directDns = directDns;
    if (testUrl.isNotEmpty) settings.testUrl = testUrl;
    settings
      ..fakeIp = fakeIp
      ..ipv6 = ipv6
      ..tun = tun ?? settings.tun
      ..autoConnect = autoConnect ?? settings.autoConnect;
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }
}
