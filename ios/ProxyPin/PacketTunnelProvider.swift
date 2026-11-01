import Foundation
import Libbox
import Network
import NetworkExtension

/// 隧道进程，运行 sing-box。
///
/// 配置由主 App 写到共享目录，这里只读文件。这样系统自己重新拉起隧道时不依赖主 App，
/// 主 App 被杀也不影响上网。
class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let appGroup = "group.io.github.rsdvb.rsproxy"

    private var commandServer: LibboxCommandServer?
    private lazy var platform = TunnelPlatform(self)
    private var captureWatchdog: CaptureWatchdog?
    private var configURL: URL?

    override func startTunnel(options _: [String: NSObject]?) async throws {
        let manager = FileManager.default
        guard let shared = manager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
            throw TunnelError("missing app group container")
        }
        // 放在 Caches 下：这里的文件不算共享容器的数据保护范围，挂起时持有文件锁不会被系统杀掉
        let cache = shared.appendingPathComponent("Library/Caches", isDirectory: true)
        let working = cache.appendingPathComponent("Working", isDirectory: true)
        try manager.createDirectory(at: working, withIntermediateDirectories: true)
        configURL = shared.appendingPathComponent("core/config.json")

        let options = LibboxSetupOptions()
        options.basePath = shared.path
        options.workingPath = working.path
        options.tempPath = cache.path
        options.logMaxLines = 300
        options.oomKillerEnabled = true

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw TunnelError("setup: \(setupError.localizedDescription)")
        }

        var serverError: NSError?
        commandServer = LibboxNewCommandServer(platform, platform, &serverError)
        if let serverError {
            throw TunnelError("create command server: \(serverError.localizedDescription)")
        }
        try commandServer?.start()
        try startService()
    }

    private func startService() throws {
        guard let configURL, let commandServer else {
            throw TunnelError("tunnel is not started")
        }
        let config = try String(contentsOf: configURL, encoding: .utf8)
        try commandServer.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    func stopService() {
        captureWatchdog?.stop()
        captureWatchdog = nil
        try? commandServer?.closeService()
        platform.reset()
    }

    func reloadService() throws {
        reasserting = true
        defer { reasserting = false }
        try startService()
    }

    override func stopTunnel(with _: NEProviderStopReason) async {
        stopService()
        commandServer?.close()
        commandServer = nil
    }

    /// 主 App 发来的消息，JSON 格式。返回错误文本，成功返回 nil
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String
        else {
            return Data("invalid message".utf8)
        }

        switch action {
        case "reload":
            do {
                try reloadService()
            } catch {
                return Data(error.localizedDescription.utf8)
            }
        case "watchCapture":
            captureWatchdog?.stop()
            captureWatchdog = CaptureWatchdog(message)
            captureWatchdog?.start()
        case "unwatchCapture":
            captureWatchdog?.stop()
            captureWatchdog = nil
        default:
            return Data("unknown action: \(action)".utf8)
        }
        return nil
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }
}

struct TunnelError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// 解密由主 App 完成，主 App 被系统杀掉后名单里的网站就打不开了。
/// 开着解密时定期探测解密端口，连续失败就把模式切回不解密，这些网站退回普通路由。
/// 主 App 回到前台时会重新打开解密。
final class CaptureWatchdog {
    private static let interval: TimeInterval = 15
    private static let failuresBeforeFallback = 2

    private let port: UInt16
    private let clashPort: Int
    private let secret: String
    private let fallbackMode: String
    private let queue = DispatchQueue(label: "rsproxy.capture-watchdog")
    private var timer: DispatchSourceTimer?
    private var failures = 0

    init?(_ message: [String: Any]) {
        guard let port = message["port"] as? Int, let clashPort = message["clashPort"] as? Int,
              let secret = message["secret"] as? String, let fallbackMode = message["fallbackMode"] as? String,
              let validPort = UInt16(exactly: port)
        else {
            return nil
        }
        self.port = validPort
        self.clashPort = clashPort
        self.secret = secret
        self.fallbackMode = fallbackMode
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 给足余量，让系统能和其他唤醒合并，减少耗电
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.probe() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func probe() {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        var finished = false

        let finish: (Bool) -> Void = { [weak self] reachable in
            guard !finished else { return }
            finished = true
            connection.cancel()
            self?.report(reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .waiting:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(false) }
    }

    private func report(_ reachable: Bool) {
        failures = reachable ? 0 : failures + 1
        guard failures >= Self.failuresBeforeFallback else { return }
        stop()
        switchToFallback()
    }

    private func switchToFallback() {
        guard let url = URL(string: "http://127.0.0.1:\(clashPort)/configs") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": fallbackMode])
        URLSession.shared.dataTask(with: request).resume()
    }
}
