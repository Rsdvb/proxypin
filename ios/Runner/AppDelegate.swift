import UIKit
import Flutter
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate {

    var backgroundAudioEnable: Bool = true

    override func application(_ application: UIApplication,
                              didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
        let vpnChannel = FlutterMethodChannel.init(name: "com.proxy/proxyVpn", binaryMessenger: controller as! FlutterBinaryMessenger);
            vpnChannel.setMethodCallHandler({(call: FlutterMethodCall, result: FlutterResult) -> Void in
                if ("stopVpn" == call.method) {
                    VpnManager.shared.disconnect()
                } else if ("isRunning" == call.method){
                    result(Bool(VpnManager.shared.isRunning()))
                } else if ("restartVpn" == call.method){
                    let arguments = call.arguments as? Dictionary<String, AnyObject>
//                     VpnManager.shared.disconnect()
                    VpnManager.shared.restartConnect(host: arguments?["proxyHost"] as? String ,port: arguments?["proxyPort"] as? Int, ipProxy: arguments?["ipProxy"] as? Bool, proxyPassDomains: arguments?["proxyPassDomains"] as? [String])
                } else {
                    let arguments = call.arguments as? Dictionary<String, AnyObject>
                    VpnManager.shared.connect(host: arguments?["proxyHost"] as? String ,port: arguments?["proxyPort"] as? Int, ipProxy: arguments?["ipProxy"] as? Bool, proxyPassDomains: arguments?["proxyPassDomains"] as? [String])
              }
          })

        if #available(iOS 13.0.0, *) {
            PictureInPictureManager.regirst(flutter: controller as! FlutterBinaryMessenger)
            MethodHandler.register(with: self.registrar(forPlugin: MethodHandler.name)!)
        }

        if let window = self.window {
            window.rootViewController = controller
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
   }

    override func applicationWillTerminate(_ application: UIApplication) {
        VpnManager.shared.disconnect()
    }

    var timer: Timer?
    var bgTask: UIBackgroundTaskIdentifier = .invalid

    override func applicationDidEnterBackground(_ application: UIApplication) {
        if (!VpnManager.shared.isRunning()) {
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

        if (UIApplication.shared.backgroundTimeRemaining < 60 && VpnManager.shared.isRunning()) {
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
        if (!VpnManager.shared.isRunning() || !self.backgroundAudioEnable) {
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

        // VPN 已停止时也要关：否则之后每次进后台都会继续播放无声音频
        if (AudioManager.shared.openBackgroundAudioAutoplay) {
            AudioManager.shared.openBackgroundAudioAutoplay = false
        }
    }

}
