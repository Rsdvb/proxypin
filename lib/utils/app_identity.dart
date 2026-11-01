/// 应用身份。Bundle ID 等平台标识在各平台工程里，这里只放 Dart 用到的部分。
abstract class AppIdentity {
  static const String name = 'RsProxy';
  static const String version = '1.4.0';
  static const String repositoryUrl = 'https://github.com/Rsdvb/proxypin';
  static const String repositoryApiUrl = 'https://api.github.com/repos/Rsdvb/proxypin';

  /// 本应用基于的开源项目，Apache 2.0 要求保留署名
  static const String upstreamName = 'ProxyPin';
  static const String upstreamUrl = 'https://github.com/wanghongenpin/proxypin';
}
