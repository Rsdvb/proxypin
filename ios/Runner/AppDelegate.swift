import UIKit
import Flutter
import NetworkExtension

/// 导入链接可能比 Flutter 先到，先存着，等 Dart 来取
final class ImportLinks {
    static let shared = ImportLinks()

    var channel: FlutterMethodChannel?
    private var pending: String?

    func receive(_ link: String) {
        if let channel {
            channel.invokeMethod("openLink", arguments: link)
        } else {
            pending = link
        }
    }

    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

@main
@objc class AppDelegate: FlutterAppDelegate {

    var backgroundAudioEnable: Bool = true

    /// 解密时主 App 要留在后台。不解密时隧道自己工作，主 App 不需要保活，也就不耗电
    var keepAlive: Bool = false

    override func application(_ application: UIApplication,
                              didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
        self.registerCoreChannel(controller as! FlutterBinaryMessenger)

        if #available(iOS 13.0.0, *) {
            PictureInPictureManager.regirst(flutter: controller as! FlutterBinaryMessenger)
            MethodHandler.register(with: self.registrar(forPlugin: MethodHandler.name)!)
        }

        if let window = self.window {
            window.rootViewController = controller
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
   }

    /// Dart 侧的 IosCorePlatform 通过这个通道控制隧道
    private func registerCoreChannel(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "rsproxy/core", binaryMessenger: messenger)
        ImportLinks.shared.channel = channel
        VpnManager.shared.onStateChange = { state in
            channel.invokeMethod("stateChanged", arguments: state)
        }

        channel.setMethodCallHandler { [weak self] call, result in
            let finish: (Error?) -> Void = { error in
                DispatchQueue.main.async {
                    if let error {
                        result(FlutterError(code: "core", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

            switch call.method {
            case "coreDirectory":
                do {
                    result(try VpnManager.sharedDirectory("core").path)
                } catch {
                    finish(error)
                }
            case "cachePath":
                do {
                    result(try VpnManager.sharedDirectory("Library/Caches/Working").appendingPathComponent("cache.db").path)
                } catch {
                    finish(error)
                }
            case "state":
                result(VpnManager.shared.stateName)
            case "takeLink":
                result(ImportLinks.shared.take())
            case "start":
                VpnManager.shared.start(call.arguments as? [String: Any] ?? [:], finish)
            case "stop":
                VpnManager.shared.disconnect()
                result(nil)
            case "reload":
                VpnManager.shared.send(["action": "reload"], completion: finish)
            case "watchCapture":
                var message = call.arguments as? [String: Any] ?? [:]
                message["action"] = "watchCapture"
                VpnManager.shared.send(message, completion: finish)
            case "unwatchCapture":
                VpnManager.shared.send(["action": "unwatchCapture"], completion: finish)
            case "setKeepAlive":
                self?.keepAlive = call.arguments as? Bool ?? false
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    var timer: Timer?
    var bgTask: UIBackgroundTaskIdentifier = .invalid

    override func applicationDidEnterBackground(_ application: UIApplication) {
        if (!self.keepAlive) {
            return
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(timerAction), userInfo: nil, repeats: true)
        RunLoop.current.add(timer!, forMode: RunLoop.Mode.common)
        self.beginBgTask(application)
    }

    /// 后台任务必须在到期前结束，否则系统会直接终止应用，所以一定要带到期处理
    private func beginBgTask(_ application: UIApplication) {
        self.endBgTask(application)
        bgTask = application.beginBackgroundTask(expirationHandler: { [weak self] in
            self?.endBgTask(application)
        })
    }

    private func endBgTask(_ application: UIApplication) {
        if (bgTask != .invalid) {
            application.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    @objc func timerAction() {
        print(UIApplication.shared.backgroundTimeRemaining)
        let application = UIApplication.shared

        self.endBgTask(application)

        if (UIApplication.shared.backgroundTimeRemaining < 60 && self.keepAlive) {
            self.beginBgTask(application)
        }

        if (application.backgroundTimeRemaining <= 0 || application.applicationState == .active || AudioManager.shared.openBackgroundAudioAutoplay) {
            timer?.invalidate();
            timer = nil;
        }
        
        if (application.backgroundTimeRemaining <= 10) {
            self.backgroundAudio()
        }

    }

    override func applicationWillResignActive(_ application: UIApplication) {
        self.backgroundAudio();
    }
    override  func applicationDidBecomeActive(_ application: UIApplication) {
        timer?.invalidate()
        timer = nil
        self.endBgTask(application)
        self.endBackgroundUpdateTask()
    }
    
    private func backgroundAudio() {
        if (!self.keepAlive || !self.backgroundAudioEnable) {
            return
        }
        if (AudioManager.shared.openBackgroundAudioAutoplay) {
            return;
        }
        
        AudioManager.shared.openBackgroundAudioAutoplay = true
        // 到期只结束任务，不关音频：来电打断时任务可能到期，通话结束后还要恢复播放
        self.backgroundUpdateTask = UIApplication.shared.beginBackgroundTask(expirationHandler: {
            self.endAudioStartTask()
        })
    }

    var backgroundUpdateTask: UIBackgroundTaskIdentifier = .invalid

    private func endAudioStartTask() {
        if (self.backgroundUpdateTask != .invalid) {
            UIApplication.shared.endBackgroundTask(self.backgroundUpdateTask)
            self.backgroundUpdateTask = .invalid
        }
    }

    func endBackgroundUpdateTask() {
        self.endAudioStartTask()

        // 解密已关闭时也要关：否则之后每次进后台都会继续播放无声音频
        if (AudioManager.shared.openBackgroundAudioAutoplay) {
            AudioManager.shared.openBackgroundAudioAutoplay = false
        }
    }

}
