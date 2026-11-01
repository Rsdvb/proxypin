/// 可选的 DNS 服务器
class DnsServer {
  final String provider;
  final String url;

  const DnsServer(this.provider, this.url);

  factory DnsServer.fromJson(Map<String, dynamic> json) => DnsServer(json['provider'], json['url']);

  Map<String, dynamic> toJson() => {'provider': provider, 'url': url};

  /// 地址是不是域名。用域名的服务器本身要先解析，所以不能拿来当“解析 DNS 服务器的 DNS”
  bool get usesHostName {
    if (url == DnsCatalog.local || url == DnsCatalog.dhcp) return false;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isNotEmpty && !host.contains(':') && !RegExp(r'^[\d.]+$').hasMatch(host);
  }
}

abstract class DnsCatalog {
  static const String local = 'local';
  static const String dhcp = 'dhcp://auto';

  /// 这个地址之外还有哪些协议可写
  static const Set<String> schemes = {'udp', 'tcp', 'tls', 'https', 'h3', 'quic', 'dhcp'};

  static const List<DnsServer> servers = [
    DnsServer('Local', local),
    DnsServer('DHCP', dhcp),
    DnsServer('AliDNS', 'udp://223.5.5.5'),
    DnsServer('AliDNS', 'udp://223.6.6.6'),
    DnsServer('AliDNS', 'tls://223.5.5.5'),
    DnsServer('AliDNS', 'tls://223.6.6.6'),
    DnsServer('AliDNS', 'tls://dns.alidns.com'),
    DnsServer('AliDNS', 'https://223.5.5.5/dns-query'),
    DnsServer('AliDNS', 'https://223.6.6.6/dns-query'),
    DnsServer('AliDNS', 'https://dns.alidns.com/dns-query'),
    DnsServer('AliDNS', 'udp://[2400:3200::1]'),
    DnsServer('DNSPod DNS', 'tls://dot.pub'),
    DnsServer('DNSPod DNS', 'tls://dns.pub'),
    DnsServer('DNSPod DNS', 'https://1.12.12.12/dns-query'),
    DnsServer('DNSPod DNS', 'https://120.53.53.53/dns-query'),
    DnsServer('DNSPod DNS', 'https://doh.pub/dns-query'),
    DnsServer('DNSPod DNS', 'udp://[2402:4e00::]'),
    DnsServer('Cloudflare DNS', 'udp://1.0.0.1'),
    DnsServer('Cloudflare DNS', 'udp://1.1.1.1'),
    DnsServer('Cloudflare DNS', 'tls://1.0.0.1'),
    DnsServer('Cloudflare DNS', 'tls://1.1.1.1'),
    DnsServer('Cloudflare DNS', 'https://1.0.0.1/dns-query'),
    DnsServer('Cloudflare DNS', 'https://1.1.1.1/dns-query'),
    DnsServer('Cloudflare DNS', 'https://cloudflare-dns.com/dns-query'),
    DnsServer('Cloudflare DNS', 'udp://[2606:4700:4700::1111]'),
    DnsServer('Cloudflare DNS', 'udp://[2606:4700:4700::1001]'),
    DnsServer('Cloudflare DNS', 'tls://[2606:4700:4700::1111]'),
    DnsServer('Cloudflare DNS', 'tls://[2606:4700:4700::1001]'),
    DnsServer('Google DNS', 'udp://8.8.8.8'),
    DnsServer('Google DNS', 'udp://8.8.4.4'),
    DnsServer('Google DNS', 'tls://8.8.8.8'),
    DnsServer('Google DNS', 'tls://8.8.4.4'),
    DnsServer('Google DNS', 'https://8.8.8.8/dns-query'),
    DnsServer('Google DNS', 'https://8.8.4.4/dns-query'),
    DnsServer('Google DNS', 'https://dns.google/dns-query'),
    DnsServer('Google DNS', 'h3://8.8.4.4/dns-query'),
    DnsServer('Google DNS', 'h3://8.8.8.8/dns-query'),
    DnsServer('Google DNS', 'udp://[2001:4860:4860::8888]'),
    DnsServer('Google DNS', 'udp://[2001:4860:4860::8844]'),
    DnsServer('Google DNS', 'tls://[2001:4860:4860::8888]'),
    DnsServer('Google DNS', 'tls://[2001:4860:4860::8844]'),
    DnsServer('TrafficRoute DNS', 'udp://180.184.1.1'),
    DnsServer('TrafficRoute DNS', 'udp://180.184.2.2'),
    DnsServer('OpenDNS', 'udp://208.67.222.222'),
    DnsServer('OpenDNS', 'udp://208.67.220.220'),
    DnsServer('Yandex DNS', 'udp://77.88.8.1'),
    DnsServer('Yandex DNS', 'udp://77.88.8.8'),
    DnsServer('Yandex DNS', 'udp://[2a02:6b8::feed:0ff]'),
    DnsServer('Yandex DNS', 'udp://[2a02:6b8:0:1::feed:0ff]'),
    DnsServer('Comodo DNS', 'udp://8.26.56.26'),
    DnsServer('Comodo DNS', 'udp://8.20.247.20'),
    DnsServer('AdGuard DNS', 'udp://94.140.14.14'),
    DnsServer('AdGuard DNS', 'udp://94.140.15.15'),
    DnsServer('AdGuard DNS', 'quic://dns.adguard.com'),
    DnsServer('AdGuard DNS', 'udp://[2a10:50c0::ad1:ff]'),
    DnsServer('AdGuard DNS', 'udp://[2a10:50c0::ad2:ff]'),
  ];

  /// 常见 DNS 服务器域名的真实地址。开启“优先静态解析”时直接用这些地址，防止它们自己被污染
  static const Map<String, List<String>> knownHosts = {
    'dns.alidns.com': ['223.5.5.5', '223.6.6.6'],
    'dot.pub': ['1.12.12.12', '120.53.53.53'],
    'dns.pub': ['1.12.12.12', '120.53.53.53'],
    'doh.pub': ['1.12.12.12', '120.53.53.53'],
    'cloudflare-dns.com': ['1.1.1.1', '1.0.0.1'],
    'dns.google': ['8.8.8.8', '8.8.4.4'],
    'dns.adguard.com': ['94.140.14.14', '94.140.15.15'],
  };
}
