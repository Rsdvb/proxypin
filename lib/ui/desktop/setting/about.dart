import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/app_update/app_update_repository.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/app_identity.dart';
import 'package:url_launcher/url_launcher.dart';

class DesktopAbout extends StatefulWidget {
  const DesktopAbout({super.key});

  @override
  State<StatefulWidget> createState() {
    return _AppUpdateStateChecking();
  }
}

class _AppUpdateStateChecking extends State<DesktopAbout> {
  bool checkUpdating = false;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  Widget build(BuildContext context) {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');
    const String gitHub = AppIdentity.repositoryUrl;

    return AlertDialog(
      titlePadding: const EdgeInsets.only(left: 20, top: 10, right: 15),
      title: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Expanded(child: SizedBox()),
        Text(localizations.about, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
        const Expanded(child: SizedBox()),
        const Align(alignment: Alignment.topRight, child: CloseButton())
      ]),
      content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("RsProxy", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: .5)),
              const SizedBox(height: 10),
              Padding(
                  padding: const EdgeInsets.only(left: 10, right: 10),
                  child: Text(isCN ? "全平台开源免费抓包软件" : "Full platform open source free capture HTTP(S) traffic software",
                      textAlign: TextAlign.center, style: const TextStyle(height: 1.3))),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  "Version ${AppConfiguration.version}",
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: Theme.of(context).dividerColor.withValues(alpha: 0.4)),
              ListTile(
                  dense: true,
                  title: const Text('GitHub'),
                  trailing: const Icon(Icons.open_in_new, size: 21),
                  onTap: () => _safeLaunch(Uri.parse(gitHub))),
              ListTile(
                  dense: true,
                  title: Text(localizations.feedback),
                  trailing: const Icon(Icons.open_in_new, size: 21),
                  onTap: () => _safeLaunch(Uri.parse("$gitHub/issues"))),
              ListTile(
                  dense: true,
                  title: Text(localizations.appUpdateCheckVersion),
                  trailing: checkUpdating
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync, size: 21),
                  onTap: () async {
                    if (checkUpdating) return;
                    setState(() => checkUpdating = true);
                    await AppUpdateRepository.checkUpdate(context, canIgnore: false, showToast: true);
                    if (mounted) setState(() => checkUpdating = false);
                  }),
              ListTile(
                  dense: true,
                  title: Text(isCN ? "下载地址" : "Download"),
                  trailing: const Icon(Icons.open_in_new, size: 21),
                  onTap: () => _safeLaunch(Uri.parse("$gitHub/releases"))),
              ListTile(
                  dense: true,
                  title: Text(localizations.privacyPolicy),
                  trailing: const Icon(Icons.privacy_tip_outlined, size: 21),
                  onTap: () {
                    showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                              title: Text(localizations.privacyPolicy),
                              content: SingleChildScrollView(
                                  child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 385),
                                      child: Text(localizations.privacyContent, style: const TextStyle(height: 1.35)))),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(localizations.close))
                              ],
                            ));
                  }),
              ListTile(
                dense: true,
                title: Text(isCN ? "基于 ${AppIdentity.upstreamName}" : "Based on ${AppIdentity.upstreamName}"),
                subtitle: const Text("Apache-2.0", style: TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.open_in_new, size: 21),
                onTap: () => _safeLaunch(Uri.parse(AppIdentity.upstreamUrl)),
              ),
            ],
          )),
    );
  }

  Future<void> _safeLaunch(Uri uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
