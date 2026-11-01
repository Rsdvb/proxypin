// Adapted from sing-box-for-apple (GPL-3.0-or-later), trimmed to what an iOS packet tunnel needs.

import Foundation
import Libbox
import Network
import NetworkExtension

/// libbox 要求平台实现的接口。iOS 隧道只用到路由、网络变化和接口列表，其余是桌面或越狱环境才有的能力
final class TunnelPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private let tunnel: PacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkPath: String?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func reset() {
        networkSettings = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: Tunnel

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTunAsync(options, ret0_)
        }
    }

    private func openTunAsync(_ options: LibboxTunOptionsProtocol?, _ result: UnsafeMutablePointer<Int32>?) async throws {
        guard let options, let result else {
            throw TunnelError("missing tun options")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())
            settings.ipv4Settings = try ipv4Settings(options)
            settings.ipv6Settings = try ipv6Settings(options)

            if options.getDNSMode()!.value != LibboxDNSModeDisabled {
                let servers = try options.getDNSServerAddress().toArray()
                if !servers.isEmpty {
                    settings.dnsSettings = NEDNSSettings(servers: servers)
                }
            }
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)

        if let descriptor = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            result.pointee = descriptor
            return
        }
        let descriptor = LibboxGetTunnelFileDescriptor()
        guard descriptor != -1 else {
            throw TunnelError("missing tunnel file descriptor")
        }
        result.pointee = descriptor
    }

    private func ipv4Settings(_ options: LibboxTunOptionsProtocol) throws -> NEIPv4Settings {
        var addresses: [String] = []
        var masks: [String] = []
        let addressIterator = options.getInet4Address()!
        while addressIterator.hasNext() {
            let prefix = addressIterator.next()!
            addresses.append(prefix.address())
            masks.append(prefix.mask())
        }

        let result = NEIPv4Settings(addresses: addresses, subnetMasks: masks)
        var routes: [NEIPv4Route] = []
        let routeIterator = options.getInet4RouteAddress()!
        while routeIterator.hasNext() {
            let prefix = routeIterator.next()!
            routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
        result.includedRoutes = routes.isEmpty ? [NEIPv4Route.default()] : routes

        var excluded: [NEIPv4Route] = []
        let excludeIterator = options.getInet4RouteExcludeAddress()!
        while excludeIterator.hasNext() {
            let prefix = excludeIterator.next()!
            excluded.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
        result.excludedRoutes = excluded
        return result
    }

    private func ipv6Settings(_ options: LibboxTunOptionsProtocol) throws -> NEIPv6Settings {
        var addresses: [String] = []
        var prefixes: [NSNumber] = []
        let addressIterator = options.getInet6Address()!
        while addressIterator.hasNext() {
            let prefix = addressIterator.next()!
            addresses.append(prefix.address())
            prefixes.append(NSNumber(value: prefix.prefix()))
        }

        let result = NEIPv6Settings(addresses: addresses, networkPrefixLengths: prefixes)
        var routes: [NEIPv6Route] = []
        let routeIterator = options.getInet6RouteAddress()!
        while routeIterator.hasNext() {
            let prefix = routeIterator.next()!
            routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
        }
        result.includedRoutes = routes.isEmpty ? [NEIPv6Route.default()] : routes

        var excluded: [NEIPv6Route] = []
        let excludeIterator = options.getInet6RouteExcludeAddress()!
        while excludeIterator.hasNext() {
            let prefix = excludeIterator.next()!
            excluded.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
        }
        result.excludedRoutes = excluded
        return result
    }

    func clearDNSCache() {
        guard let networkSettings else { return }
        runBlocking {
            self.tunnel.reasserting = true
            defer { self.tunnel.reasserting = false }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(nil) { _ in continuation.resume() }
            }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(networkSettings) { _ in continuation.resume() }
            }
        }
    }

    // MARK: Network changes

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let firstUpdate = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            self.onPathUpdate(listener, path)
            firstUpdate.signal()
            monitor.pathUpdateHandler = { path in
                self.onPathUpdate(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        firstUpdate.wait()
    }

    private func onPathUpdate(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        let description = "\(path.status) \(path.availableInterfaces.map { "\($0.name)#\($0.index)" })"
        listener.updateNetworkPath(description)
        if description == lastNetworkPath { return }
        lastNetworkPath = description

        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index),
                                        isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let pathMonitor else {
            throw TunnelError("path monitor is not started")
        }
        let path = pathMonitor.currentPath
        if path.status == .unsatisfied {
            return InterfaceIterator([])
        }
        return InterfaceIterator(path.availableInterfaces.map { item in
            let interface = LibboxNetworkInterface()
            interface.name = item.name
            interface.index = Int32(item.index)
            switch item.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            return interface
        })
    }

    private final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    // MARK: Service control

    func serviceStop() throws {
        tunnel.stopService()
    }

    func serviceReload() throws {
        try tunnel.reloadService()
    }

    // MARK: Fixed answers on iOS

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func readWIFISSID() -> String? { nil }
    func tailscaleHostname() -> String { "" }
    func writeLog(_: String?) {}
    func writeDebugMessage(_: String?) {}
    func send(_: LibboxNotification?) throws {}
    func cancelNotification(_: String?, typeID _: Int32) throws {}
    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func registerMyInterface(_: String?) {}
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_: Bool) throws {}
    func triggerNativeCrash() throws {}

    // MARK: Not available on iOS

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw TunnelError("not supported on iOS")
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw TunnelError("not supported on iOS")
    }

    func checkPlatformShell() throws {
        throw TunnelError("not supported on iOS")
    }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw TunnelError("not supported on iOS")
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw TunnelError("not supported on iOS")
    }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw TunnelError("not supported on iOS")
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = TunnelError("not supported on iOS") as NSError
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = TunnelError("not supported on iOS") as NSError
        return ""
    }
}

extension LibboxStringIteratorProtocol {
    func toArray() -> [String] {
        var array: [String] = []
        while hasNext() {
            array.append(next())
        }
        return array
    }
}

/// libbox 的回调是同步的，而 NetworkExtension 的接口是异步的
private func runBlocking<T>(_ block: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        box.value = await block()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

private func runBlocking<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<Result<T, Error>>()
    Task.detached(priority: .userInitiated) {
        do {
            box.value = .success(try await block())
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.value.get()
}

private final class ResultBox<T> {
    var value: T!
}
