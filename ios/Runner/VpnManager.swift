let kProxyServiceVPNStatusNotification = "kProxyServiceVPNStatusNotification"

import Foundation
import NetworkExtension

enum VPNStatus {
    case off
    case connecting
    case on
    case disconnecting
}

/// 隧道的开关。sing-box 跑在隧道进程里，主 App 退出后继续工作
class VpnManager {
    private static let appGroup = "group.io.github.rsdvb.rsproxy"
    private static let tunnelBundleId = "io.github.rsdvb.rsproxy.tunnel"

    static let shared = VpnManager()

    private var manager: NETunnelProviderManager?

    /// 状态变化时回调，取值和 Dart 的 CoreState 同名
    var onStateChange: ((String) -> Void)?

    fileprivate(set) var vpnStatus = VPNStatus.off {
        didSet {
            NotificationCenter.default.post(name: Notification.Name(rawValue: kProxyServiceVPNStatusNotification), object: nil)
            onStateChange?(stateName)
        }
    }

    var stateName: String {
        switch vpnStatus {
        case .off: return "stopped"
        case .connecting: return "starting"
        case .on: return "running"
        case .disconnecting: return "stopping"
        }
    }

    init() {
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            if let connection = notification.object as? NEVPNConnection {
                self?.update(connection.status)
            }
        }
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let manager = managers?.first else { return }
            DispatchQueue.main.async {
                self?.manager = manager
                self?.update(manager.connection.status)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func update(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            vpnStatus = .on
        case .connecting, .reasserting:
            vpnStatus = .connecting
        case .disconnecting:
            vpnStatus = .disconnecting
        case .disconnected, .invalid:
            vpnStatus = .off
        @unknown default:
            break
        }
    }

    /// App Group 共享目录，隧道从这里读配置
    static func sharedDirectory(_ path: String) throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw NSError(domain: "VpnManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing app group container"])
        }
        let url = container.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start(_ completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error {
                completion(error)
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = Self.tunnelBundleId
            configuration.serverAddress = "RsProxy"
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "RsProxy"
            manager.isEnabled = true

            // 第一次保存时系统会弹窗请求添加 VPN，用户确认后才回调
            manager.saveToPreferences { error in
                if let error {
                    completion(error)
                    return
                }
                manager.loadFromPreferences { error in
                    if let error {
                        completion(error)
                        return
                    }
                    do {
                        self?.manager = manager
                        try manager.connection.startVPNTunnel()
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        }
    }

    func connect(host _: String?, port _: Int?, ipProxy _: Bool?) {
        start { _ in }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    func isRunning() -> Bool {
        return vpnStatus == .on
    }

    /// 给隧道进程发消息，隧道返回的文本视为错误
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession, isRunning() else {
            completion(nil)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            try session.sendProviderMessage(data) { response in
                if let response, !response.isEmpty {
                    let text = String(decoding: response, as: UTF8.self)
                    completion(NSError(domain: "VpnManager", code: 2, userInfo: [NSLocalizedDescriptionKey: text]))
                } else {
                    completion(nil)
                }
            }
        } catch {
            completion(error)
        }
    }
}
