import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:proxypin/network/util/logger.dart';

import 'clash_api.dart';
import 'clash_routing.dart';
import 'core_backup.dart';
import 'core_config.dart';
import 'core_platform.dart';
import 'core_settings.dart';
import 'core_tools.dart';
import 'device_identity.dart';
import 'dns_catalog.dart';
import 'dns_probe.dart';
import 'import_link.dart';
import 'profile.dart';
import 'profile_parser.dart';
import 'rule_group.dart';
import 'rule_sets.dart';
import 'share_link.dart';
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

/// 同一份配置的节点
class NodeGroup {
  final Profile profile;
  final List<String> tags;

  const NodeGroup(this.profile, this.tags);
}

/// 内核没能启动，内容是给用户看的
class CoreStartException implements Exception {
  final String message;

  const CoreStartException(this.message);

  @override
  String toString() => message;
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

  /// 查本机公网网段，测试时替换
  final Future<String?> Function() clientSubnetLookup;

  /// 下载规则集，测试时替换
  final Future<Uint8List> Function(Uri uri, String? proxy) fetchRuleSet;

  CoreSettings settings = CoreSettings();
  List<Profile> profiles = [];
  CoreState state = CoreState.stopped;

  /// 最近一次启动失败的原因
  String? lastError;

  /// 节点 tag -> 最近一次测得的延迟（毫秒），不通时不在表里
  final Map<String, int> delays = {};

  /// 最近一次测试不通的节点。和没测过要分开：一个是坏了，一个是不知道
  final Set<String> failedNodes = {};

  /// 排队或正在测的节点
  final Set<String> testingNodes = {};

  bool get testing => testingNodes.isNotEmpty;

  /// 配置已更新，但内核还在用旧的，重新加载或下次连接后生效
  bool needsReload = false;

  /// 分流用到、这次没准备好的规则集。对应的规则暂时不生效
  Set<String> missingRuleSets = {};

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
    Future<String?> Function()? clientSubnetLookup,
    this.fetchRuleSet = RuleSets.download,
  })  : _apiFactory = apiFactory ?? ((port, secret) => ClashApi(port: port, secret: secret)),
        clientSubnetLookup = clientSubnetLookup ?? CoreTools.clientSubnet;

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

  /// [nodes] 的缓存，和算它时用的 [_nodes] 对应
  List<Map<String, dynamic>>? _enabledNodes;
  List<Map<String, dynamic>>? _enabledFrom;

  /// 合并配置里节点的来历：tag -> (来源配置, 它在来源里的 tag)
  final Map<String, (Profile, String)> _mergedOrigins = {};

  /// 界面上列出的节点，包括禁用的
  List<Map<String, dynamic>> get listedNodes {
    final profile = activeProfile;
    if (profile == null) return const [];
    return _nodes ??= profile.isMerged ? _mergedNodes(profile) : profile.activeNodes;
  }

  /// 写进内核配置的节点，不含禁用的
  List<Map<String, dynamic>> get nodes {
    final listed = listedNodes;
    if (settings.disabledNodes.isEmpty) return listed;
    if (!identical(_enabledFrom, listed)) {
      _enabledFrom = listed;
      _enabledNodes = listed.where((e) => !isDisabled(e)).toList();
    }
    return _enabledNodes!;
  }

  /// 合并配置的节点。不同来源可能有同名节点，sing-box 要求 tag 唯一，重名的加上来源名
  List<Map<String, dynamic>> _mergedNodes(Profile merged) {
    final used = <String>{};
    final result = <Map<String, dynamic>>[];
    _mergedOrigins.clear();
    for (final id in merged.sources) {
      for (final source in profiles.where((e) => e.id == id)) {
        for (final node in source.activeNodes) {
          final tag = node['tag'].toString();
          final unique = used.add(tag) ? tag : '${source.name} $tag';
          used.add(unique);
          result.add({...node, 'tag': unique});
          _mergedOrigins[unique] = (source, tag);
        }
      }
    }
    return result;
  }

  /// 节点按配置分组。合并配置按来源分，其余就是一组
  List<NodeGroup> get nodeGroups {
    final profile = activeProfile;
    if (profile == null) return const [];
    final tags = listedNodes.map((e) => e['tag'].toString());
    if (!profile.isMerged) return [NodeGroup(profile, tags.toList())];
    final groups = <Profile, List<String>>{};
    for (final tag in tags) {
      (groups[_mergedOrigins[tag]!.$1] ??= []).add(tag);
    }
    return [for (final entry in groups.entries) NodeGroup(entry.key, entry.value)];
  }

  /// 节点的来历：所在的配置和它在那份配置里的 tag
  (Profile, String)? _originOf(String tag) {
    final profile = activeProfile;
    if (profile == null) return null;
    listedNodes;
    return profile.isMerged ? _mergedOrigins[tag] : (profile, tag);
  }

  /// 当前选中的节点 tag，空表示自动选择
  String? get selectedNode {
    final profile = activeProfile;
    return profile == null ? null : settings.selectedNodes[profile.id];
  }

  /// 本地代理地址，下载订阅时用。upstream-in 在两个平台都有，mixed-in 在 iOS 上不开
  String? get proxyAddress => isRunning ? '127.0.0.1:${settings.upstreamPort}' : null;

  /// 测 DNS 的两条路，没连接时为空
  ProbeRoute? get directProbe =>
      isRunning ? ProbeRoute(settings.probePort, CoreConfig.probeDirect, settings.clashSecret, viaNode: false) : null;

  ProbeRoute? get nodeProbe =>
      isRunning ? ProbeRoute(settings.probePort, CoreConfig.probeNode, settings.clashSecret, viaNode: true) : null;

  Future<void> load() async {
    settings = await store.loadSettings();
    profiles = await store.loadProfiles();
    _nodes = null;
    (await store.loadLatency()).forEach((tag, delay) {
      if (delay < 0) {
        failedNodes.add(tag);
      } else {
        delays[tag] = delay;
      }
    });
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
    await _setConnectedAt(null);
    final failure = await platform.lastFailure();
    if (failure != null) {
      lastError = CoreTools.describeFailure(failure);
      notifyListeners();
    }
    await _setSystemProxy(null);
    await platform.setKeepAlive(false);
    await mitm.detach();
  }

  Future<void> _setSystemProxy(int? port) async {
    await platform.setSystemProxy(port, bypass: settings.proxyBypass ? settings.bypassDomains : const []);
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
        await _refreshClientSubnet();
        await _writeConfig();
        await platform.start(_tun ? settings.tunSettings.tunnelOptions : const {});
        await _afterStart();
        await _setConnectedAt(DateTime.now());
        _setState(CoreState.running);
        unawaited(_retryRuleSets());
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
        await _setConnectedAt(null);
        _setState(CoreState.stopped);
      }
    });
  }

  Future<void> _setConnectedAt(DateTime? time) async {
    settings.connectedAt = time;
    await store.saveSettings(settings);
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
        // 内核已经退出了就不用等到超时
        final failure = await platform.lastFailure();
        if (failure != null) throw CoreStartException(CoreTools.describeFailure(failure));
        if (DateTime.now().isAfter(deadline)) throw const CoreStartException('内核没有响应，请重试');
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
    final rules = await _ruleSetStore();

    final profile = activeProfile;
    final routing = _providerRouting;
    final dns = profile != null && profile.preferOutboundDns && profile.outboundDns.isNotEmpty ? profile.outboundDns.first : null;

    final (names, urls) = _usedRuleSets();
    final available = await rules.prepare(names, urls: urls, routes: _ruleSetRoutes);
    missingRuleSets = {...names, ...urls.keys}.difference(available);

    final options = CoreOptions(
      nodes: nodes,
      selected: selectedNode,
      groups: _activeGroups.map((e) => e.usableOn(ios: alwaysTun, available: available)).nonNulls.toList(),
      providerRouting: routing,
      providerRuleSets: routing == null ? const {} : available.intersection(routing.ruleSets.toSet()),
      finalTarget: settings.finalTarget,
      chain: settings.chain,
      chainFront: settings.chainFront,
      autoGroups: settings.autoGroups,
      autoTestMinutes: settings.autoTestMinutes,
      autoTolerance: settings.autoTolerance,
      autoFavorites: settings.autoPreferFavorites ? settings.favorites : const {},
      autoNodeLimit: settings.autoNodeLimit,
      outboundDns: dns,
      dns: settings.dns,
      tunSettings: settings.tunSettings,
      ipStrategy: settings.ipStrategy,
      privateDirect: settings.privateDirect,
      avoidLocalDns: _tun && Platform.isWindows,
      tun: _tun,
      // iOS 上只有附加 HTTP 代理时才需要这个端口
      mixedPort: alwaysTun && !settings.tunSettings.appendHttpProxy ? 0 : settings.mixedPort,
      upstreamPort: settings.upstreamPort,
      mitmPort: mitm.port,
      probePort: settings.probePort,
      directPort: settings.directPort,
      globalPort: settings.globalPort,
      lanPort: settings.lanEnabled ? settings.lanPort : 0,
      lanGlobalPort: settings.lanEnabled ? settings.lanGlobalPort : 0,
      lanUsername: settings.lanUsername,
      lanPassword: settings.lanPassword,
      mixedUsername: settings.mixedUsername,
      mixedPassword: settings.mixedPassword,
      tuning: settings.tuning,
      proxyBypass: settings.proxyBypass ? settings.bypassDomains : const [],
      mitmDomains: mitm.domains,
      clashPort: settings.clashPort,
      clashSecret: settings.clashSecret,
      clashDefaultMode: CoreConfig.modeRule,
      ruleSetDirectory: rules.directory.path,
      cachePath: await platform.cachePath(),
      testUrl: settings.testUrl,
    );
    await File('${directory.path}/config.json').writeAsString(jsonEncode(CoreConfig.build(options)), flush: true);
    needsReload = false;
  }

  ProviderRouting? get _providerRouting {
    final profile = activeProfile;
    return profile != null && profile.keepProviderRules && settings.providerRulesEnabled ? profile.routing : null;
  }

  List<RuleGroup> get _activeGroups =>
      settings.groupsEnabled ? settings.groups.where((e) => e.enabled).toList() : const [];

  List<String?> get _ruleSetRoutes => settings.ruleSetDownload.routes(proxyAddress);

  RuleSetStore? _ruleSets;

  Future<RuleSetStore> _ruleSetStore() async {
    final store = _ruleSets;
    if (store != null) return store;
    final directory = Directory('${(await platform.directory()).path}/rules');
    await directory.create(recursive: true);
    return _ruleSets = RuleSetStore(directory, bundled: loadRuleSet, fetch: fetchRuleSet);
  }

  /// 当前配置用到的规则集：名称，和用户填的地址（名称 -> 地址）
  (Set<String>, Map<String, String>) _usedRuleSets() => (
        {for (final group in _activeGroups) ...group.ruleSets, ...?_providerRouting?.ruleSets},
        {
          for (final group in _activeGroups)
            for (final url in group.ruleSetUrls) RuleSets.tagOfUrl(url): url,
        },
      );

  /// 连接前下载不到的规则集，连上之后再试一次：很多时候只有走节点才下载得到
  Future<void> _retryRuleSets() async {
    if (missingRuleSets.isEmpty) return;
    try {
      final store = await _ruleSetStore();
      final (names, urls) = _usedRuleSets();
      store.forgetFailures();
      final available = await store.prepare(names, urls: urls, routes: _ruleSetRoutes, budget: const Duration(minutes: 1));
      final missing = {...names, ...urls.keys}.difference(available);
      if (missing.length == missingRuleSets.length) return;
      missingRuleSets = missing;
      needsReload = true;
      notifyListeners();
    } on Exception catch (e) {
      logger.w('retry rule sets failed: $e');
    }
  }

  /// 分流页展示的状态
  Future<List<RuleSetState>> ruleSetStates() async {
    final (names, urls) = _usedRuleSets();
    return (await _ruleSetStore()).states([...names, ...urls.keys]..sort());
  }

  /// 立即更新。返回 (成功数, 失败数)
  Future<(int, int)> updateRuleSets({bool? includeBundled}) async {
    final rules = await _ruleSetStore();
    final (names, urls) = _usedRuleSets();
    final result = await rules.refresh(names,
        urls: urls, routes: _ruleSetRoutes, includeBundled: includeBundled ?? settings.updateBundledRuleSets);
    settings.ruleSetsUpdatedAt = DateTime.now();
    await store.saveSettings(settings);
    // 已经在用的文件内核会自己重新加载，新下载到的要写进配置才生效
    if (result.$1 > 0 && missingRuleSets.isNotEmpty) needsReload = true;
    notifyListeners();
    return result;
  }

  Future<void> _updateDueRuleSets() async {
    final last = settings.ruleSetsUpdatedAt;
    final interval = Duration(hours: settings.ruleSetUpdateHours);
    if (last != null && DateTime.now().difference(last) < interval) return;
    final (succeeded, failed) = await updateRuleSets();
    // 全失败多半是没网，一小时后再试，不用等一整个周期
    if (succeeded == 0 && failed > 0) {
      settings.ruleSetsUpdatedAt = DateTime.now().subtract(interval).add(const Duration(hours: 1));
      await store.saveSettings(settings);
    }
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
    if (settings.autoBackupOnAdd) await _autoBackup();
    notifyListeners();
    return profile;
  }

  ///自动取的名称重复时加序号。用户自己填的重名会提示，不替他改
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
      await _updateDueRuleSets();
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
    }
    await store.saveProfiles(profiles);
    await store.saveSettings(settings);
    if (wasActive) await _applyConfig();
    if (settings.autoBackupOnRemove && profiles.isNotEmpty) await _autoBackup();
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

  static const int _recentLimit = 5;

  Future<void> selectNode(String tag) async {
    final profile = activeProfile;
    if (profile == null) return;
    settings.selectedNodes[profile.id] = tag;
    if (listedNodes.any((e) => e['tag'] == tag)) {
      settings.recentNodes = [tag, ...settings.recentNodes.where((e) => e != tag)].take(_recentLimit).toList();
    }
    await store.saveSettings(settings);
    if (isRunning) await api.select(RuleTarget.selected, tag);
    notifyListeners();
  }

  Future<void> clearRecentNodes() async {
    settings.recentNodes = [];
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> toggleFavorite(String tag) async {
    if (!settings.favorites.remove(tag)) settings.favorites.add(tag);
    await store.saveSettings(settings);
    // 自动选择只在收藏里挑时，收藏变了配置也变了
    if (settings.autoPreferFavorites) _markReload();
    notifyListeners();
  }

  void _markReload() {
    if (isRunning) needsReload = true;
  }

  static String endpointOf(Map<String, dynamic> node) => '${node['type']};${node['server']};${node['server_port']}';

  bool isDisabled(Map<String, dynamic> node) => settings.disabledNodes.contains(endpointOf(node));

  /// 禁用节点。所有配置里指向同一个地址的节点一起生效，要重新加载才影响内核
  Future<void> setNodeDisabled(Map<String, dynamic> node, bool disabled) async {
    final endpoint = endpointOf(node);
    settings.disabledNodes = {...settings.disabledNodes}..removeWhere((e) => e == endpoint);
    if (disabled) settings.disabledNodes = {...settings.disabledNodes, endpoint};
    _enabledFrom = null;
    await store.saveSettings(settings);
    _markReload();
    notifyListeners();
  }

  /// 节点改完后保存。不马上重载：连着改几个时不用反复断开连接
  Future<void> _saveNodes(Profile profile) async {
    _nodes = null;
    await store.saveProfiles(profiles);
    if (_usesProfile(profile)) _markReload();
    notifyListeners();
  }

  /// 删除节点。订阅里的要记下来，否则更新后又回来了
  Future<void> removeNode(String tag) async {
    final origin = _originOf(tag);
    if (origin == null) return;
    final (profile, original) = origin;
    if (profile.isSubscription) {
      profile.removedNodes = {...profile.removedNodes, original};
    } else {
      profile.nodes = profile.nodes.where((e) => e['tag'] != original).toList();
    }
    await _saveNodes(profile);
  }

  /// 改节点。[tag] 是原来的名字，新名字重复时抛 [DuplicateProfileException]
  Future<void> updateNode(String tag, Outbound node) async {
    final origin = _originOf(tag);
    if (origin == null) return;
    final (profile, original) = origin;
    final renamed = node['tag'].toString();
    if (renamed != original &&
        (ProfileParser.reservedTags.contains(renamed) || profile.nodes.any((e) => e['tag'] == renamed))) {
      throw const DuplicateProfileException('已经有同名的节点了');
    }
    profile.nodes = [for (final item in profile.nodes) item['tag'] == original ? node : item];
    if (renamed != tag) _renameNode(tag, renamed);
    await _saveNodes(profile);
  }

  void _renameNode(String from, String to) {
    settings.selectedNodes.updateAll((_, value) => value == from ? to : value);
    if (settings.favorites.remove(from)) settings.favorites.add(to);
    settings.recentNodes = [for (final item in settings.recentNodes) item == from ? to : item];
    settings.chain = [for (final item in settings.chain) item == from ? to : item];
    final delay = delays.remove(from);
    if (delay != null) delays[to] = delay;
    if (failedNodes.remove(from)) failedNodes.add(to);
  }

  /// 往本地配置里加节点。[content] 是分享链接或 sing-box 的节点 JSON，读不懂时抛 [FormatException]
  Future<int> addNodes(Profile profile, String content) async {
    final added = ProfileParser.parse(content).outbounds;
    if (added.isEmpty) throw const FormatException('no nodes');
    ProfileParser.uniqueTags(added, taken: profile.nodes.map((e) => e['tag'].toString()).toSet());
    profile.nodes = [...profile.nodes, ...added];
    await _saveNodes(profile);
    return added.length;
  }

  /// 新建没有节点的本地配置，节点之后手动添加
  Future<Profile> createLocalProfile(String name) async {
    final text = name.trim();
    if (text.isEmpty) throw const DuplicateProfileException('请填写名称');
    if (profiles.any((e) => e.name == text)) throw const DuplicateProfileException('已经有同名的配置了');
    final profile = Profile(id: DateTime.now().microsecondsSinceEpoch.toString(), name: text, updatedAt: DateTime.now());
    profiles = [...profiles, profile];
    settings.activeProfileId ??= profile.id;
    await store.saveProfiles(profiles);
    await store.saveSettings(settings);
    notifyListeners();
    return profile;
  }

  /// 同时测的节点数，和内核自己测组时一样
  static const int _testConcurrency = 10;

  /// 测节点延迟，[tags] 为空时测全部。[connectFirst] 时没连接就先连上：延迟要经过内核才测得出来。
  /// 逐个测而不是整组一起：这样每个节点都能显示自己的进度，失败的也知道是谁
  Future<void> testLatency({Iterable<String>? tags, bool connectFirst = false}) async {
    if (connectFirst && state == CoreState.stopped) await connect();
    if (!isRunning) return;

    final all = nodes.map((e) => e['tag'].toString()).toList();
    final batch = (tags ?? all).where((e) => all.contains(e) && !testingNodes.contains(e)).toList();
    if (batch.isEmpty) return;

    testingNodes.addAll(batch);
    notifyListeners();
    // 节点多时结果来得很快，一秒刷一次界面就够了
    final refresh = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    final queue = batch.reversed.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty && isRunning) {
        final tag = queue.removeLast();
        _recordDelay(tag, await api.delay(tag, url: settings.testUrl));
        testingNodes.remove(tag);
      }
    }

    try {
      await Future.wait(List.generate(_testConcurrency, (_) => worker()));
      if (tags == null) {
        _forgetGoneNodes();
        await _removeFailedNodes(batch);
      }
      await _saveLatency();
      _refreshAutoGroup();
    } finally {
      refresh.cancel();
      testingNodes.removeAll(batch);
      notifyListeners();
    }
  }

  void _recordDelay(String tag, int? delay) {
    if (delay == null) {
      delays.remove(tag);
      failedNodes.add(tag);
    } else {
      delays[tag] = delay;
      failedNodes.remove(tag);
    }
  }

  /// 所有配置里都没有的节点不用留着，别的配置的结果还有用
  void _forgetGoneNodes() {
    final known = {
      for (final profile in profiles) ...profile.nodes.map((e) => e['tag'].toString()),
      ...listedNodes.map((e) => e['tag'].toString()),
    };
    delays.removeWhere((tag, _) => !known.contains(tag));
    failedNodes.removeWhere((tag) => !known.contains(tag));
  }

  Future<void> _saveLatency() =>
      store.saveLatency({...delays, for (final tag in failedNodes) tag: -1});

  /// 自动选择组只看自己测的结果，要让它重测一轮才会换节点
  void _refreshAutoGroup() {
    final selected = selectedNode ?? RuleTarget.auto;
    if (!settings.autoUpdateAfterTest || selected != RuleTarget.auto || !isRunning) return;
    unawaited(api.groupDelay(RuleTarget.auto, url: settings.testUrl).then((_) {}, onError: (_) {}));
  }

  static const int _removeAttempts = 3;

  /// 自动移除失败节点，一个节点最多试 3 次。全部失败时不动：那多半是本机断网了
  Future<void> _removeFailedNodes(List<String> tested) async {
    final profile = activeProfile;
    if (profile == null || profile.isMerged || !profile.autoRemoveFailed) return;

    var failed = tested.where(failedNodes.contains).toList();
    if (failed.length == tested.length) return;
    for (var attempt = 1; attempt < _removeAttempts && failed.isNotEmpty; attempt++) {
      final stillFailing = <String>[];
      for (final tag in failed) {
        final delay = await api.delay(tag, url: settings.testUrl);
        _recordDelay(tag, delay);
        if (delay == null) stillFailing.add(tag);
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

  /// 用备份替换选中的内容，这台设备自己的端口和密钥不动。
  /// 字段按名字分类，不列清单：以后加的设置不会悄悄漏掉
  Future<void> restoreBackup(Uint8List bytes, {RestoreParts parts = const RestoreParts()}) async {
    final backup = CoreBackup.decode(bytes);
    final merged = jsonDecode(jsonEncode(settings)) as Map<String, dynamic>;
    final incoming = jsonDecode(jsonEncode(backup.settingsJson)) as Map<String, dynamic>;
    incoming.forEach((key, value) {
      if (CoreBackup.deviceFields.contains(key)) return;
      final wanted = CoreBackup.profileFields.contains(key)
          ? parts.profiles
          : (CoreBackup.ruleFields.contains(key) ? parts.rules : parts.others);
      if (wanted) merged[key] = value;
    });
    settings = CoreSettings.fromJson(merged);

    if (parts.profiles) {
      profiles = backup.profiles;
      delays.clear();
      failedNodes.clear();
    }
    _nodes = null;
    if (parts.rules) mitm.editableDomains = backup.decryptDomains;
    await store.saveProfiles(profiles);
    await store.saveSettings(settings);
    await _applyConfig();
    notifyListeners();
  }

  static const int _autoBackupsKept = 5;

  Directory get _autoBackupDirectory => Directory('${store.directory.path}/backups');

  /// 一天一份，文件名就是日期，只留最近几份
  Future<void> _autoBackup() async {
    try {
      final directory = _autoBackupDirectory;
      await directory.create(recursive: true);
      final name = DateTime.now().toIso8601String().substring(0, 10);
      await File('${directory.path}/$name.zip').writeAsBytes(exportBackup());

      final kept = await autoBackups();
      for (final old in kept.skip(_autoBackupsKept)) {
        await deleteAutoBackup(old.name);
      }
    } on Exception catch (e) {
      logger.w('auto backup failed: $e');
    }
  }

  /// 新的在前
  Future<List<AutoBackup>> autoBackups() async {
    final directory = _autoBackupDirectory;
    if (!await directory.exists()) return const [];
    final backups = <AutoBackup>[];
    await for (final entry in directory.list()) {
      if (entry is File && entry.path.endsWith('.zip')) {
        backups.add(AutoBackup(entry.uri.pathSegments.last, await entry.length()));
      }
    }
    return backups..sort((a, b) => b.name.compareTo(a.name));
  }

  Future<Uint8List> readAutoBackup(String name) => File('${_autoBackupDirectory.path}/$name').readAsBytes();

  Future<void> deleteAutoBackup(String name) => File('${_autoBackupDirectory.path}/$name').delete();

  Future<void> saveWebDav({required String url, required String username, required String password}) async {
    settings
      ..webDavUrl = url
      ..webDavUsername = username
      ..webDavPassword = password;
    await store.saveSettings(settings);
  }

  /// 只影响界面的设置，不用重载内核
  Future<void> saveUiSettings() => store.saveSettings(settings);

  /// 首页跟着换刷新的内容
  Future<void> saveHomeStats(List<String> stats) async {
    settings.homeStats = stats;
    await store.saveSettings(settings);
    notifyListeners();
  }

  /// 设置页改完后调用。运行中会重载内核，所以页面都是离开时才保存一次
  Future<void> applySettings() async {
    await store.saveSettings(settings);
    await _refreshClientSubnet();
    await _applyConfig();
    // 绕过的域名可能改了
    if (settings.systemProxyActive) await _setSystemProxy(settings.mixedPort);
    notifyListeners();
  }

  static const Duration _clientSubnetMaxAge = Duration(days: 1);

  /// 本机网段一天测一次。直连 DNS 是系统 DNS 时不需要
  Future<void> _refreshClientSubnet() async {
    final dns = settings.dns;
    if (!dns.clientSubnet || dns.direct == DnsCatalog.local) return;
    final updated = dns.clientSubnetUpdatedAt;
    if (updated != null && DateTime.now().difference(updated) < _clientSubnetMaxAge) return;

    final subnet = await clientSubnetLookup();
    if (subnet == null) return;
    dns
      ..clientSubnetValue = subnet
      ..clientSubnetUpdatedAt = DateTime.now();
    await store.saveSettings(settings);
  }
}
