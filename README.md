# RsProxy

RsProxy 是一个面向 Windows 和 iOS 的代理客户端，并带有 HTTPS 解密。网络由 [sing-box](https://github.com/SagerNet/sing-box) 负责，解密和抓包基于 [ProxyPin](https://github.com/wanghongenpin/proxypin) 修改而来。

## 主要特点

- **订阅和分流。** 支持订阅链接、Clash、sing-box 配置和分享链接，可以按服务设置走哪个节点。
- **只解密白名单域名。** 名单外的流量不经过解密，iOS 上不解密时主 App 不用留在后台，省电。
- **根证书在本机生成。** 不再内置公开的根证书，每台设备使用自己的私钥。
- **Windows 性能优化。** 查找连接所属进程改用 Win32 接口，新连接不再等待 netstat。
- **内存有上限。** 大响应和长连接不会让内存无限增长，客户端读不过来时会暂停读取源站。
- **崩溃有记录。** Windows 崩溃写入 `%LOCALAPPDATA%\RsProxy\crash.log`。

## 构建

使用 Flutter 3.47.9。规则集和 iOS 内核不在仓库里，构建前先生成：

```bash
flutter pub get
bash tool/fetch_rule_sets.sh assets/rules
bash tool/build_libbox.sh 1.14.4 ios/Libbox   # 仅 iOS，需要 macOS、Xcode 和 Go
flutter build windows --release
flutter build ios --release --no-codesign
```

Windows 版需要把 `sing-box.exe` 放到 `RsProxy.exe` 同目录。GitHub Actions 会自动完成以上步骤，配置见 `.github/workflows/build.yml`。

## 许可

ProxyPin 部分的代码以 Apache License 2.0 发布，见 [LICENSE](LICENSE)。发布的安装包包含 sing-box，整体受 GPL-3.0-or-later 约束，详见 [NOTICE](NOTICE)。
