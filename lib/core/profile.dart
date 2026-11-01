import 'dart:io';

import 'package:proxypin/utils/app_identity.dart';

import 'clash_routing.dart';
import 'share_link.dart';

/// 下载订阅走哪条路
enum DownloadStrategy { preferProxy, preferDirect, onlyProxy, onlyDirect }

/// 节点过滤方式
enum NodeFilterMethod { all, include, exclude }

/// 下载订阅时发送的 User-Agent。机场按它决定下发哪种格式，所以可以多选
abstract class UserAgents {
  static const String coreVersion = '1.14.4';

  static const List<String> presets = [
    'mihomo/1.19.28',
    'clash-verge',
    'FLClash',
    'mihomo.party/v2.0.0 (clash.meta)',
    'ClashMeta',
    'v2ray',
    'sing-box $coreVersion',
    'NekoBox/Android/1.4.1 (Prefer ClashMeta Format)',
    'HiddifyNext',
  ];

  /// 列表第一行：本应用自己的标识
  static String get self => '${AppIdentity.name}/${AppIdentity.version} platform/${Platform.operatingSystem}';

  /// 多个之间用分号隔开。什么都没选时也要发点什么，空 UA 很多面板直接拒绝
  static String compose(bool append, List<String> selected) {
    final joined = selected.join(';');
    if (joined.isEmpty) return self;
    return append ? '$self $joined' : joined;
  }

  /// 不改选择时的简短显示：mihomo/...;clash-verge;FLClash
  static String short(List<String> selected) {
    return selected.map((e) => e.contains('/') ? '${e.substring(0, e.indexOf('/'))}/...' : e).join(';');
  }
}

/// 订阅的用量和到期时间，来自响应头 subscription-userinfo
class SubscriptionInfo {
  final int upload;
  final int download;
  final int total;
  final DateTime? expire;

  const SubscriptionInfo({this.upload = 0, this.download = 0, this.total = 0, this.expire});

  int get used => upload + download;

  /// upload=1; download=2; total=3; expire=1700000000
  static SubscriptionInfo? parse(String? header) {
    if (header == null || !header.contains('=')) return null;

    final values = <String, int>{};
    for (final part in header.split(';')) {
      final equals = part.indexOf('=');
      if (equals <= 0) continue;
      // 少数面板会给出小数
      final value = double.tryParse(part.substring(equals + 1).trim());
      if (value != null) values[part.substring(0, equals).trim().toLowerCase()] = value.toInt();
    }
    if (values.isEmpty) return null;

    final expire = values['expire'];
    return SubscriptionInfo(
      upload: values['upload'] ?? 0,
      download: values['download'] ?? 0,
      total: values['total'] ?? 0,
      expire: expire == null || expire <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(expire * 1000),
    );
  }

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) => SubscriptionInfo(
        upload: json['upload'] ?? 0,
        download: json['download'] ?? 0,
        total: json['total'] ?? 0,
        expire: json['expire'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['expire']),
      );

  Map<String, dynamic> toJson() => {
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire?.millisecondsSinceEpoch,
      };
}

/// 一份配置：订阅或手动粘贴的内容
class Profile {
  static const int defaultUpdateMinutes = 12 * 60;

  /// 更新间隔下限
  static const int minUpdateMinutes = 5;

  final String id;
  String name;

  /// 订阅地址，手动粘贴的配置为空
  String? url;

  /// User-Agent 是否带上本应用的标识
  bool userAgentAppend;

  /// 选中的 User-Agent，默认全选
  List<String> userAgents;

  /// 下载时发送设备标识，限制设备数的机场要用
  bool xhwid;

  /// 机场加密订阅时的解密密码
  String decryptPassword;

  NodeFilterMethod filterMethod;

  /// 过滤用的关键词或正则
  String filterPattern;

  /// 过滤时除了节点名，也匹配协议类型
  bool filterMatchType;

  /// 保留机场自带的分流规则
  bool keepProviderRules;
  DownloadStrategy downloadStrategy;

  /// 自动更新间隔（分钟），null 表示不自动更新
  int? updateMinutes;

  /// 更新后重新加载内核。关闭时等下次连接才生效
  bool reloadAfterUpdate;

  /// 自动更新后测延迟，要已连接并打开 [reloadAfterUpdate]
  bool testLatencyAfterUpdate;

  /// 延迟检测失败的节点自动移除
  bool autoRemoveFailed;

  /// 被自动移除的节点名。按名称存，订阅更新后还是不要它们
  Set<String> removedNodes;

  /// 导入链接自带的 DNS，用来解析节点域名
  List<String> outboundDns;
  bool preferOutboundDns;

  SubscriptionInfo? info;
  String? website;
  DateTime? updatedAt;
  List<Outbound> nodes;

  /// 机场的分流规则，只有 Clash 格式的订阅才有
  ProviderRouting? routing;

  /// 上次解析时跳过的不支持节点数
  int skipped;

  /// 合并配置的来源，节点实时取自这些配置，来源更新后跟着变。普通配置为空
  List<String> sources;

  Profile({
    required this.id,
    required this.name,
    this.url,
    this.userAgentAppend = true,
    List<String>? userAgents,
    this.xhwid = false,
    this.decryptPassword = '',
    this.filterMethod = NodeFilterMethod.all,
    this.filterPattern = '',
    this.filterMatchType = false,
    this.keepProviderRules = false,
    this.downloadStrategy = DownloadStrategy.preferProxy,
    this.updateMinutes = defaultUpdateMinutes,
    this.reloadAfterUpdate = false,
    this.testLatencyAfterUpdate = false,
    this.autoRemoveFailed = false,
    Set<String>? removedNodes,
    this.outboundDns = const [],
    this.preferOutboundDns = false,
    this.info,
    this.website,
    this.updatedAt,
    this.nodes = const [],
    this.routing,
    this.skipped = 0,
    this.sources = const [],
  })  : userAgents = userAgents ?? [...UserAgents.presets],
        removedNodes = removedNodes ?? {};

  bool get isSubscription => url != null;

  bool get isMerged => sources.isNotEmpty;

  String get userAgent => UserAgents.compose(userAgentAppend, userAgents);

  /// 过滤后的节点，配置里只放这些
  List<Outbound> get activeNodes {
    final matches = _filter();
    return nodes.where((node) => !removedNodes.contains(node['tag']) && matches(node)).toList();
  }

  bool Function(Outbound) _filter() {
    if (filterMethod == NodeFilterMethod.all || filterPattern.isEmpty) return (_) => true;

    final contains = _matcher(filterPattern);
    final include = filterMethod == NodeFilterMethod.include;
    return (node) {
      final tag = node['tag'].toString();
      final hit = contains(tag) || (filterMatchType && contains(node['type'].toString()));
      return hit == include;
    };
  }

  /// 关键词或正则。写的不是合法正则时就当关键词
  static bool Function(String) _matcher(String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false).hasMatch;
    } on FormatException {
      final keyword = pattern.toLowerCase();
      return (text) => text.toLowerCase().contains(keyword);
    }
  }

  bool isDue(DateTime now) {
    final minutes = updateMinutes;
    if (!isSubscription || minutes == null) return false;
    final last = updatedAt;
    return last == null || now.difference(last) >= Duration(minutes: minutes);
  }

  /// 把 [other] 的选项抄过来，节点和用量这些内容不动
  void copyOptionsFrom(Profile other) {
    userAgentAppend = other.userAgentAppend;
    userAgents = [...other.userAgents];
    xhwid = other.xhwid;
    decryptPassword = other.decryptPassword;
    filterMethod = other.filterMethod;
    filterPattern = other.filterPattern;
    filterMatchType = other.filterMatchType;
    keepProviderRules = other.keepProviderRules;
    downloadStrategy = other.downloadStrategy;
    updateMinutes = other.updateMinutes;
    reloadAfterUpdate = other.reloadAfterUpdate;
    testLatencyAfterUpdate = other.testLatencyAfterUpdate;
    autoRemoveFailed = other.autoRemoveFailed;
    removedNodes = {...other.removedNodes};
    outboundDns = [...other.outboundDns];
    preferOutboundDns = other.preferOutboundDns;
    website = other.website;
  }

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'],
        name: json['name'],
        url: json['url'],
        userAgentAppend: json['userAgentAppend'] ?? true,
        userAgents: (json['userAgents'] as List?)?.map((e) => e.toString()).toList(),
        xhwid: json['xhwid'] ?? false,
        decryptPassword: json['decryptPassword'] ?? '',
        filterMethod: NodeFilterMethod.values.asNameMap()[json['filterMethod']] ?? NodeFilterMethod.all,
        filterPattern: json['filterPattern'] ?? '',
        filterMatchType: json['filterMatchType'] ?? false,
        keepProviderRules: json['keepProviderRules'] ?? false,
        downloadStrategy: DownloadStrategy.values.asNameMap()[json['downloadStrategy']] ?? DownloadStrategy.preferProxy,
        updateMinutes: json.containsKey('updateMinutes') ? json['updateMinutes'] : defaultUpdateMinutes,
        reloadAfterUpdate: json['reloadAfterUpdate'] ?? false,
        testLatencyAfterUpdate: json['testLatencyAfterUpdate'] ?? false,
        autoRemoveFailed: json['autoRemoveFailed'] ?? false,
        removedNodes: (json['removedNodes'] as List?)?.map((e) => e.toString()).toSet(),
        outboundDns: (json['outboundDns'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        preferOutboundDns: json['preferOutboundDns'] ?? false,
        info: json['info'] == null ? null : SubscriptionInfo.fromJson(json['info']),
        website: json['website'],
        updatedAt: json['updatedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['updatedAt']),
        nodes: (json['nodes'] as List?)?.map((e) => Map<String, dynamic>.from(e)).toList() ?? [],
        routing: json['routing'] == null ? null : ProviderRouting.fromJson(json['routing']),
        skipped: json['skipped'] ?? 0,
        sources: (json['sources'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'userAgentAppend': userAgentAppend,
        'userAgents': userAgents,
        'xhwid': xhwid,
        'decryptPassword': decryptPassword,
        'filterMethod': filterMethod.name,
        'filterPattern': filterPattern,
        'filterMatchType': filterMatchType,
        'keepProviderRules': keepProviderRules,
        'downloadStrategy': downloadStrategy.name,
        'updateMinutes': updateMinutes,
        'reloadAfterUpdate': reloadAfterUpdate,
        'testLatencyAfterUpdate': testLatencyAfterUpdate,
        'autoRemoveFailed': autoRemoveFailed,
        'removedNodes': removedNodes.toList(),
        'outboundDns': outboundDns,
        'preferOutboundDns': preferOutboundDns,
        'info': info?.toJson(),
        'website': website,
        'updatedAt': updatedAt?.millisecondsSinceEpoch,
        'nodes': nodes,
        'routing': routing?.toJson(),
        'skipped': skipped,
        'sources': sources,
      };
}
