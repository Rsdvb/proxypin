import 'dart:io';

import 'package:proxypin/utils/app_identity.dart';

abstract class Constants {
  static const githubUrl = AppIdentity.repositoryUrl;
  static const githubReleasesApiUrl = "${AppIdentity.repositoryApiUrl}/releases";
  static const githubLatestReleaseUrl = "${AppIdentity.repositoryUrl}/releases/latest";

  static const String ignoreReleaseVersionKey = "ignored_release_version";

  /// GitHub 下载镜像前缀，仅中文环境使用。
  /// 设为空字符串可关闭镜像。
  static const githubMirror = "https://ghproxy.top/";

  /// 返回主 URL 和镜像 URL（仅中文环境有镜像）。
  /// 主 URL 在前，镜像在后，下载时优先直连。
  static List<String> mirrorUrls(String url) {
    final urls = <String>[url];
    if (githubMirror.isEmpty) return urls;
    if (!Platform.localeName.startsWith('zh')) return urls;
    final uri = Uri.tryParse(url);
    if (uri == null) return urls;
    if (uri.host == 'github.com' || uri.host == 'api.github.com') {
      urls.add('$githubMirror$url');
    }
    return urls;
  }
}

const kAnimationDuration = Duration(milliseconds: 250);
