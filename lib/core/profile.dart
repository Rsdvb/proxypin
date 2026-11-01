import 'share_link.dart';

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
  static const String defaultUserAgent = 'ClashMeta/1.19.0';
  static const int defaultUpdateHours = 12;

  final String id;
  String name;

  /// 订阅地址，手动粘贴的配置为空
  String? url;
  String userAgent;

  /// 自动更新间隔，0 表示不自动更新
  int updateHours;

  /// 只保留名称匹配的节点，正则，空表示不限
  String? include;

  /// 去掉名称匹配的节点，正则，空表示不限
  String? exclude;

  SubscriptionInfo? info;
  String? website;
  DateTime? updatedAt;
  List<Outbound> nodes;

  /// 上次解析时跳过的不支持节点数
  int skipped;

  Profile({
    required this.id,
    required this.name,
    this.url,
    this.userAgent = defaultUserAgent,
    this.updateHours = defaultUpdateHours,
    this.include,
    this.exclude,
    this.info,
    this.website,
    this.updatedAt,
    this.nodes = const [],
    this.skipped = 0,
  });

  bool get isSubscription => url != null;

  /// 过滤后的节点，配置里只放这些
  List<Outbound> get activeNodes {
    final keep = _regex(include), drop = _regex(exclude);
    return nodes.where((node) {
      final tag = node['tag'].toString();
      return (keep == null || keep.hasMatch(tag)) && (drop == null || !drop.hasMatch(tag));
    }).toList();
  }

  bool isDue(DateTime now) {
    if (!isSubscription || updateHours <= 0) return false;
    final last = updatedAt;
    return last == null || now.difference(last) >= Duration(hours: updateHours);
  }

  static RegExp? _regex(String? pattern) {
    if (pattern == null || pattern.isEmpty) return null;
    try {
      return RegExp(pattern, caseSensitive: false);
    } on FormatException {
      return null;
    }
  }

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'],
        name: json['name'],
        url: json['url'],
        userAgent: json['userAgent'] ?? defaultUserAgent,
        updateHours: json['updateHours'] ?? defaultUpdateHours,
        include: json['include'],
        exclude: json['exclude'],
        info: json['info'] == null ? null : SubscriptionInfo.fromJson(json['info']),
        website: json['website'],
        updatedAt: json['updatedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['updatedAt']),
        nodes: (json['nodes'] as List?)?.map((e) => Map<String, dynamic>.from(e)).toList() ?? [],
        skipped: json['skipped'] ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'userAgent': userAgent,
        'updateHours': updateHours,
        'include': include,
        'exclude': exclude,
        'info': info?.toJson(),
        'website': website,
        'updatedAt': updatedAt?.millisecondsSinceEpoch,
        'nodes': nodes,
        'skipped': skipped,
      };
}
