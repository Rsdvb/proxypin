import Foundation
import AVFoundation
import UIKit
class AudioManager: NSObject {
    
    static let shared = AudioManager()
    fileprivate let audioSession = AVAudioSession.sharedInstance()
    fileprivate var backgroundAudioPlayer: AVAudioPlayer?
    fileprivate var backgroundEnteredAt: Date?

    static let audioName = ""
    // 是否开启后台自动播放无声音乐
    var openBackgroundAudioAutoplay = false {
        didSet {
            if self.openBackgroundAudioAutoplay {
                self.setupAudioSession()
                self.setupBackgroundAudioPlayer()
            } else {
                if let player = self.backgroundAudioPlayer {
                    if player.isPlaying {
                        player.stop()
                    }
                }
                self.backgroundAudioPlayer = nil
                try? self.audioSession.setActive(false, options:  AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
            }
        }
    }
    
    override init() {
        super.init()
        self.setupListener()
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    private func setupAudioSession() {
        do {
            try self.audioSession.setCategory(AVAudioSession.Category.playback, options: AVAudioSession.CategoryOptions.mixWithOthers)
            try self.audioSession.setActive(false)
        } catch let error {
            debugPrint("\(type(of:self)):\(error)")
        }
    }
    private func setupBackgroundAudioPlayer() {
        do {
            self.backgroundAudioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: Bundle.main.path(forResource: "silence", ofType: "mp3")!))
        } catch let error {
            debugPrint("\(type(of:self)):\(error)")
        }
        self.backgroundAudioPlayer?.numberOfLoops = -1
        self.backgroundAudioPlayer?.volume = 0
        self.backgroundAudioPlayer?.delegate = self
    }
    
    private func setupListener() {
        
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(audioSessionInterruption(notification:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaServicesWereReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(vpnStatusDidChange), name: Notification.Name(rawValue: kProxyServiceVPNStatusNotification), object: nil)

    }

    private func playInBackground() {
        do {
            try self.audioSession.setActive(true)
        } catch let error {
            debugPrint("\(type(of:self)):\(error))")
        }
        self.backgroundAudioPlayer?.prepareToPlay()
        self.backgroundAudioPlayer?.play()
    }
}

// MARK: - 扩展 监听通知
extension AudioManager {
    /// 进入后台 播放无声音乐
    @objc public func didEnterBackground() {
        self.backgroundEnteredAt = Date()
        guard self.openBackgroundAudioAutoplay else {return}

        self.playInBackground()
    }

    /// 媒体服务重启后原有的会话和播放器全部失效，不重建的话无声音频就停了，应用随后被挂起
    @objc fileprivate func mediaServicesWereReset() {
        guard self.openBackgroundAudioAutoplay else {return}

        self.setupAudioSession()
        self.setupBackgroundAudioPlayer()
        if UIApplication.shared.applicationState == .background {
            self.playInBackground()
        }
    }

    /// VPN 已断开，代理没有在工作，继续播放只是耗电
    @objc fileprivate func vpnStatusDidChange() {
        if self.openBackgroundAudioAutoplay && VpnManager.shared.vpnStatus == .off {
            self.openBackgroundAudioAutoplay = false
        }
    }

    /// 进入前台，暂停播放音乐
    @objc public func didBecomeActive() {
        self.hintBackgroundTimeLength()
        self.backgroundEnteredAt = nil
        guard self.openBackgroundAudioAutoplay else {return}
        
        self.backgroundAudioPlayer?.pause()
        do {
            try self.audioSession.setActive(false, options:  AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
        } catch let error {
            debugPrint("\(type(of:self)):\(error))")
        }
        
        
    }
    
    /// 音乐中断处理
    @objc fileprivate func audioSessionInterruption(notification: NSNotification) {
        guard self.openBackgroundAudioAutoplay else {return}
        guard let userinfo = notification.userInfo else {return}
        guard let interruptionType: UInt = userinfo[AVAudioSessionInterruptionTypeKey] as! UInt?  else {return}
        if interruptionType == AVAudioSession.InterruptionType.began.rawValue {
            // 中断开始，音乐被暂停
            debugPrint("\(type(of:self)): 中断开始 userinfo:\(userinfo)")
        } else if interruptionType == AVAudioSession.InterruptionType.ended.rawValue {
            // 中断结束，恢复播放
            debugPrint("\(type(of:self)): 中断结束 userinfo:\(userinfo)")
            guard let player = self.backgroundAudioPlayer else {return}
            if player.isPlaying == false {
                debugPrint("\(type(of:self)): 音乐未播放，准备开始播放")
                do {
                    try self.audioSession.setActive(true)
                } catch let error {
                    debugPrint("\(type(of:self)):\(error)")
                }
                player.prepareToPlay()
                player.play()
            } else {
                debugPrint("\(type(of:self)): 音乐正在播放")
            }
        }
    }
}

// MARK: - 扩展 后台时长
extension AudioManager {
    fileprivate func hintBackgroundTimeLength() {
        guard let enteredAt = self.backgroundEnteredAt else {return}
        let message = "本次后台持续时间:\(Int(Date().timeIntervalSince(enteredAt)))s"
        print(message)
    }
}
// MARK: - 扩展 播放代理
extension AudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        debugPrint("\(type(of:self))" + error.debugDescription)
    }
}
