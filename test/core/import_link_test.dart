import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/core/import_link.dart';

void main() {
  const url = 'https://sub.example/api?token=abc&flag=meta';
  final encoded = Uri.encodeComponent(url);

  test('the common install-config form', () {
    for (final scheme in ['clash', 'clashx', 'clash-meta', 'karing', 'rsproxy']) {
      final link = ImportLink.parse('$scheme://install-config?url=$encoded&name=%E6%9C%BA%E5%9C%BA')!;
      expect(link.url, url, reason: scheme);
      expect(link.name, '机场');
    }
  });

  test('sing-box puts the name in the fragment', () {
    final link = ImportLink.parse('sing-box://import-remote-profile?url=$encoded#%E6%9C%BA%E5%9C%BA')!;
    expect(link.url, url);
    expect(link.name, '机场');
  });

  test('a name is optional', () {
    expect(ImportLink.parse('clash://install-config?url=$encoded')!.name, isNull);
  });

  test('shadowrocket wraps a base64 address', () {
    final body = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    final link = ImportLink.parse('shadowrocket://add/sub://$body?remarks=me')!;
    expect(link.url, url);
    expect(link.name, 'me');
    expect(ImportLink.parse('sub://$body')!.url, url);
  });

  test('anything else is refused, including addresses that are not web links', () {
    expect(ImportLink.parse('clash://install-config'), isNull);
    expect(ImportLink.parse('clash://install-config?url=file%3A%2F%2F%2Fetc%2Fpasswd'), isNull);
    expect(ImportLink.parse('https://example.com/sub'), isNull);
    expect(ImportLink.parse('not a link'), isNull);
  });
}
