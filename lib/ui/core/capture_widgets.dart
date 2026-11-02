import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/native/native_method.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/desktop/ssl/cert_installer.dart';
import 'package:proxypin/ui/desktop/ssl/pc_cert.dart';
import 'package:proxypin/ui/mobile/setting/ssl.dart';

import 'decrypt_domains_page.dart';
import 'design.dart';

/// 解密页的三个分区
enum CaptureSection { requests, favorites, history }

/// 系统是否信任根证书，查不出来时返回 null
Future<bool?> rootCertificateTrusted() async {
  try {
    if (Platform.isIOS) {
      final pem = await CertificateManager.certificatePem();
      return await NativeMethod.isCaInstalled(pem) && await evaluateChainTrusted(pem);
    }
    final details = await CertificateManager.getCertificateDetails();
    return await CertInstaller.isCertInstalled(await CertificateManager.certificateFile(), details);
  } on Exception catch (e) {
    logger.w('certificate check failed: $e');
    return null;
  }
}

/// 解密页顶部：开关、名单数量和证书状态。解密是这个 App 的主要用途，不能藏起来
class CaptureStatusBar extends StatefulWidget {
  final Configuration configuration;
  final ProxyServer proxyServer;

  const CaptureStatusBar({super.key, required this.configuration, required this.proxyServer});

  @override
  State<CaptureStatusBar> createState() => _CaptureStatusBarState();
}

class _CaptureStatusBarState extends State<CaptureStatusBar> {
  bool? _trusted;

  @override
  void initState() {
    super.initState();
    _checkCertificate();
  }

  Future<void> _checkCertificate() async {
    final trusted = await rootCertificateTrusted();
    if (mounted) setState(() => _trusted = trusted);
  }

  Future<void> _installCertificate() async {
    if (Platform.isIOS) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MobileSslWidget(proxyServer: widget.proxyServer)));
    } else {
      await showDialog<void>(context: context, builder: (_) => const PCCert());
    }
    await _checkCertificate();
  }

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final count = HostFilter.whitelist.list.length;
        final on = manager.settings.capture;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Panel(children: [
            InfoRow(
              icon: on ? Icons.lock_open : Icons.lock_outline,
              iconColor: on ? Tone.good : Palette.of(context).faint,
              title: on ? 'HTTPS 解密已开启' : 'HTTPS 解密已关闭',
              subtitle: count == 0 ? '还没有域名，点这里添加' : '名单里有 $count 个域名，其余流量不经过解密',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DecryptDomainsPage(configuration: widget.configuration),
              )),
              chevron: false,
              trailing: Switch(value: on, onChanged: manager.setCapture),
            ),
            if (_trusted == false)
              InfoRow(
                icon: Icons.gpp_maybe_outlined,
                iconColor: Tone.warn,
                title: '根证书还没有安装',
                subtitle: '不装的话，名单里的 HTTPS 网站会打不开',
                onTap: _installCertificate,
              ),
          ]),
        );
      },
    );
  }
}
