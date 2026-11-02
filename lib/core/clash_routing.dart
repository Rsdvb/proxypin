/// 机场自带的分流：Clash 配置里的 proxy-groups 和 rules。
///
/// 只存解析结果，生成内核配置时再对照当前节点，因为过滤可能去掉其中一部分节点。
class ProviderRouting {
  static const String _groupPrefix = 'group:';
  static const String direct = 'direct';
  static const String reject = 'reject';

  /// 名称、类型（select / urltest）、成员
  final List<ProviderGroup> groups;
  final List<ProviderRule> rules;

  /// MATCH 规则的去向，其余都没命中时走这里
  final String? finalTarget;

  /// 用户给组改的去向：组名 -> 成员名、direct 或 reject。存在设置里，订阅更新后还在
  final Map<String, String> targets;

  const ProviderRouting(this.groups, this.rules, this.finalTarget, {this.targets = const {}});

  bool get isEmpty => groups.isEmpty && rules.isEmpty && finalTarget == null;

  ProviderRouting withTargets(Map<String, String> targets) => ProviderRouting(groups, rules, finalTarget, targets: targets);

  /// 用到的规则集名称，要和内置规则集同名才可用
  Set<String> get ruleSets => {for (final rule in rules) ...rule.ruleSets};

  /// 从 Clash 配置解析。没有规则时返回 null
  static ProviderRouting? parse(Map document) {
    final groups = _groups(document['proxy-groups']);
    final items = document['rules'];
    if (items is! List || items.isEmpty) return null;

    final rules = <ProviderRule>[];
    String? finalTarget;
    for (final item in items) {
      final parts = item.toString().split(',').map((e) => e.trim()).toList();
      if (parts.length < 2) continue;
      final type = parts[0].toUpperCase();
      if (type == 'MATCH' || type == 'FINAL') {
        finalTarget = _target(parts[1]);
        break;
      }
      if (parts.length < 3) continue;
      _add(rules, type, parts[1], _target(parts[2]));
    }
    return ProviderRouting(groups, rules, finalTarget);
  }

  static String _target(String name) => switch (name.toUpperCase()) {
        'DIRECT' => direct,
        'REJECT' || 'REJECT-DROP' => reject,
        _ => name,
      };

  static List<ProviderGroup> _groups(Object? items) {
    if (items is! List) return const [];
    final groups = <ProviderGroup>[];
    for (final item in items) {
      if (item is! Map || item['name'] == null) continue;
      final type = item['type']?.toString().toLowerCase();
      final members = (item['proxies'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
      groups.add(ProviderGroup(
        item['name'].toString(),
        type == 'select' ? 'selector' : 'urltest',
        members.map(_target).toList(),
        includeAll: item['include-all'] == true || item['include-all-proxies'] == true,
      ));
    }
    return groups;
  }

  /// 连续去向相同的规则合成一条，机场的规则动辄几千行，这样能省不少内存
  static void _add(List<ProviderRule> rules, String type, String value, String target) {
    final field = switch (type) {
      'DOMAIN' => 'domain',
      'DOMAIN-SUFFIX' => 'domain_suffix',
      'DOMAIN-KEYWORD' => 'domain_keyword',
      'DOMAIN-REGEX' => 'domain_regex',
      'IP-CIDR' || 'IP-CIDR6' => 'ip_cidr',
      'PROCESS-NAME' => 'process_name',
      'GEOIP' || 'GEOSITE' => 'rule_set',
      _ => null,
    };
    if (field == null) return;

    final item = switch (type) {
      'GEOIP' => 'geoip-${value.toLowerCase()}',
      'GEOSITE' => 'geosite-${value.toLowerCase()}',
      _ => value,
    };

    final last = rules.isEmpty ? null : rules.last;
    if (last != null && last.target == target) {
      (last.match[field] ??= []).add(item);
    } else {
      rules.add(ProviderRule(target, {
        field: [item]
      }));
    }
  }

  /// 机场的节点组对应的 outbound。成员对不上的去掉，一个都不剩的组退回直连
  List<Map<String, dynamic>> outbounds(List<String> nodeTags, {required String testUrl}) {
    final groupNames = groups.map((e) => e.name).toSet();
    return [
      for (final group in groups)
        () {
          final members = <String>[
            if (group.includeAll) ...nodeTags,
            for (final member in group.members)
              if (groupNames.contains(member))
                '$_groupPrefix$member'
              else if (member == direct || nodeTags.contains(member))
                member,
          ];
          final outbounds = members.isEmpty ? [direct] : members.toSet().toList();
          final chosen = _chosen(group.name, groupNames, nodeTags);
          // 自动测速的组改了去向也变成手动选择，否则内核还是会自己换
          if (chosen != null) {
            return {
              'type': 'selector',
              'tag': '$_groupPrefix${group.name}',
              'outbounds': {...outbounds, chosen}.toList(),
              'default': chosen,
            };
          }
          return {
            'type': group.type,
            'tag': '$_groupPrefix${group.name}',
            'outbounds': outbounds,
            if (group.type == 'urltest') ...{'url': testUrl, 'interval': '10m', 'idle_timeout': '30m'},
          };
        }(),
    ];
  }

  /// 用户给这个组选的 outbound。选的节点被过滤掉或订阅里没了，就当没选
  String? _chosen(String group, Set<String> groupNames, List<String> nodeTags) {
    final target = targets[group];
    if (target == null || target == reject) return null;
    if (target == direct || nodeTags.contains(target)) return target;
    return groupNames.contains(target) && target != group ? '$_groupPrefix$target' : null;
  }

  /// 内核的路由规则。[available] 是可用的规则集，其余的要去掉，否则内核起不来
  List<Map<String, dynamic>> routeRules(List<String> nodeTags, Set<String> available, {required String fallback}) {
    final result = <Map<String, dynamic>>[];
    for (final rule in rules) {
      final match = <String, dynamic>{};
      rule.match.forEach((field, values) {
        final usable = field == 'rule_set' ? values.where(available.contains).toList() : values;
        if (usable.isNotEmpty) match[field] = usable;
      });
      if (match.isEmpty) continue;
      result.add({...match, ...action(rule.target, nodeTags, fallback: fallback)});
    }
    return result;
  }

  /// 去向对应的路由动作。节点可能已被过滤掉，这时走 [fallback]
  Map<String, dynamic> action(String target, List<String> nodeTags, {required String fallback}) {
    if (target == reject || targets[target] == reject) return {'action': 'reject'};
    final outbound = switch (target) {
      direct => direct,
      _ when groups.any((e) => e.name == target) => '$_groupPrefix$target',
      _ when nodeTags.contains(target) => target,
      _ => fallback,
    };
    return {'action': 'route', 'outbound': outbound};
  }

  factory ProviderRouting.fromJson(Map<String, dynamic> json) => ProviderRouting(
        (json['groups'] as List?)?.map((e) => ProviderGroup.fromJson(e)).toList() ?? const [],
        (json['rules'] as List?)?.map((e) => ProviderRule.fromJson(e)).toList() ?? const [],
        json['final'],
      );

  Map<String, dynamic> toJson() => {'groups': groups, 'rules': rules, 'final': finalTarget};
}

class ProviderGroup {
  final String name;

  /// sing-box 的类型：selector 或 urltest
  final String type;
  final List<String> members;

  /// mihomo 的 include-all：包含全部节点
  final bool includeAll;

  const ProviderGroup(this.name, this.type, this.members, {this.includeAll = false});

  factory ProviderGroup.fromJson(Map<String, dynamic> json) => ProviderGroup(
        json['name'],
        json['type'],
        (json['members'] as List).map((e) => e.toString()).toList(),
        includeAll: json['includeAll'] ?? false,
      );

  Map<String, dynamic> toJson() => {'name': name, 'type': type, 'members': members, 'includeAll': includeAll};
}

class ProviderRule {
  final String target;

  /// sing-box 规则字段 -> 取值，如 domain_suffix: [example.com]
  final Map<String, List<String>> match;

  const ProviderRule(this.target, this.match);

  Iterable<String> get ruleSets => match['rule_set'] ?? const [];

  factory ProviderRule.fromJson(Map<String, dynamic> json) => ProviderRule(
        json['target'],
        (json['match'] as Map).map((key, value) => MapEntry(key.toString(), (value as List).map((e) => e.toString()).toList())),
      );

  Map<String, dynamic> toJson() => {'target': target, 'match': match};
}
