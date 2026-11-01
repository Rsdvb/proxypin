import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/host_filter.dart';

void main() {
  void whitelist(List<String> rules, {bool enabled = true}) {
    HostFilter.whitelist.list.clear();
    HostFilter.whitelist.enabled = enabled;
    rules.forEach(HostFilter.whitelist.add);
  }

  tearDown(() => whitelist([], enabled: false));

  test('plain domains and leading wildcards become suffixes', () {
    whitelist(['example.com', '*.api.example.org', 'sub-domain.example.net']);
    expect(HostFilter.whitelistDomains(), ['example.com', 'api.example.org', 'sub-domain.example.net']);
  });

  test('the same domain written twice is listed once', () {
    whitelist(['example.com', '*.example.com']);
    expect(HostFilter.whitelistDomains(), ['example.com']);
  });

  test('a disabled or empty whitelist does not narrow the proxy', () {
    whitelist(['example.com'], enabled: false);
    expect(HostFilter.whitelistDomains(), isNull);

    whitelist([]);
    expect(HostFilter.whitelistDomains(), isNull);
  });

  for (final rule in ['example', '*example.com', 'exam*.com', 'example.*', 'example.com/path', '^api\\.example\\.com\$']) {
    test('one rule that is not a domain suffix keeps everything on the proxy: $rule', () {
      whitelist(['good.example.com', rule]);
      expect(HostFilter.whitelistDomains(), isNull);
    });
  }

  test('rules loaded from config are read the same way', () {
    HostFilter.whitelist.load({
      'enabled': true,
      'list': ['example.com', '.*.example.org'],
    });
    expect(HostFilter.whitelistDomains(), ['example.com', 'example.org']);
  });
}
