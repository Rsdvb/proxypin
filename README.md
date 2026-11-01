# RsProxy

RsProxy 是一个面向 Windows 和 iOS 的 HTTP(S) 抓包与调试工具，基于 [ProxyPin](https://github.com/wanghongenpin/proxypin) 修改而来。

## 和 ProxyPin 的主要区别

- **只解密白名单域名。** iOS 上不在名单里的流量不经过 App，省电，也更不容易被系统杀后台。
- **根证书在本机生成。** 不再内置公开的根证书，每台设备使用自己的私钥。
- **Windows 性能优化。** 查找连接所属进程改用 Win32 接口，新连接不再等待 netstat。
- **内存有上限。** 大响应和长连接不会让内存无限增长，客户端读不过来时会暂停读取源站。
- **崩溃有记录。** Windows 崩溃写入 `%LOCALAPPDATA%\RsProxy\crash.log`。

## 构建

使用 Flutter 3.47.9：

```bash
flutter pub get
flutter build windows --release
flutter build ios --release --no-codesign
```

GitHub Actions 会自动编译 Windows 版本和未签名的 IPA，配置见 `.github/workflows/build.yml`。

## 许可

代码以 Apache License 2.0 发布，见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。
