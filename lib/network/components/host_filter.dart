/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

void main() {
  print(HostFilter.filter("stackoverflow.com"));
}

/// @author wanghongen
/// 2023/7/26
class HostFilter {
  /// 白名单
  static final Whites whitelist = Whites();

  /// 黑名单
  static final Blacks blacklist = Blacks();

  /// 是否过滤
  static bool filter(String? host) {
    if (host == null) {
      return false;
    }

    //如果白名单不为空，不在白名单里都是黑名单
    if (whitelist.enabled) {
      return whitelist.list.every((element) => !element.hasMatch(host));
    }

    if (blacklist.enabled) {
      return blacklist.list.any((element) => element.hasMatch(host));
    }
    return false;
  }

  static final RegExp _plainDomain = RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$');

  /// 白名单对应的域名后缀，用于在系统层分流，不在其中的连接不必进入代理。
  ///
  /// 白名单未启用或为空时返回 null；有规则不能表示成域名后缀（如正则）时也返回 null，
  /// 此时只能全部进入代理再过滤，否则这些规则匹配的请求就抓不到了。
  static List<String>? whitelistDomains() {
    if (!whitelist.enabled || whitelist.list.isEmpty) {
      return null;
    }

    final domains = <String>{};
    for (final rule in whitelist.list) {
      // add() 把 * 展开成了 .*，这里还原 *.example.com 的写法
      final pattern = rule.pattern;
      final domain = pattern.startsWith('.*.') ? pattern.substring(3) : pattern;
      if (!_plainDomain.hasMatch(domain)) {
        return null;
      }
      domains.add(domain);
    }
    return domains.toList();
  }
}

///
abstract class HostList {
  /// 列表
  final List<RegExp> list = [];
  bool enabled = false;

  ///加载配置
  void load(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    List? list = map['list'];
    this.list.clear();
    list?.forEach((element) {
      this.list.add(RegExp(element));
    });
    enabled = map['enabled'] == true;
  }

  void add(String reg) {
    var regExp = RegExp(reg.replaceAll("*", ".*"));
    list.removeWhere((element) => element.pattern == regExp.pattern);
    list.add(regExp);
  }

  void remove(String reg) {
    list.removeWhere((element) => element.pattern == reg.replaceAll("*", ".*"));
  }

  void removeIndex(List<int> index) {
    for (var element in index) {
      list.removeAt(element);
    }
  }

  // json序列化
  Map<String, dynamic> toJson() {
    return {
      'list': list.map((e) => e.pattern).toList(),
      'enabled': enabled,
    };
  }
}

///白名单
class Whites extends HostList {}

///黑名单
class Blacks extends HostList {
  Blacks() {
    enabled = true;
    list.add(RegExp(".*.apple.com"));
    list.add(RegExp(".*.icloud.com"));
  }
}
