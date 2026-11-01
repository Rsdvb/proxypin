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
                    let dns = NEDNSSettings(servers: servers)
                    // 没有默认路由时，系统不会把 DNS 交给隧道，要显式声明
                    if !useDefaultRoute {
                        dns.matchDomains = [""]
                        dns.matchDomainsNoSearch = true
                    }
                    settings.dnsSettings = dns
                }
            }
        }

        if options.isHTTPProxyEnabled() {
            settings.proxySettings = proxySettings(options)
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

    /// 关闭“默认路由”时用这组子网路由代替，覆盖范围相同，但系统不把它当作默认路由
    private var useDefaultRoute: Bool {
        let configuration = (tunnel.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return configuration?["defaultRoute"] as? Bool ?? true
    }

    private func proxySettings(_ options: LibboxTunOptionsProtocol) -> NEProxySettings {
        let settings = NEProxySettings()
        let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
        settings.httpServer = server
        settings.httpsServer = server
        settings.httpEnabled = true
        settings.httpsEnabled = true

        let bypass = options.getHTTPProxyBypassDomain()!.toArray()
        if !bypass.isEmpty {
            settings.exceptionList = bypass
        }
        let match = options.getHTTPProxyMatchDomain()!.toArray()
        if !match.isEmpty {
            settings.matchDomains = match
        }
        return settings
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
        if routes.isEmpty {
            routes = useDefaultRoute
                ? [NEIPv4Route.default()]
                : [
                    NEIPv4Route(destinationAddress: "1.0.0.0", subnetMask: "255.0.0.0"),
                    NEIPv4Route(destinationAddress: "2.0.0.0", subnetMask: "254.0.0.0"),
                    NEIPv4Route(destinationAddress: "4.0.0.0", subnetMask: "252.0.0.0"),
                    NEIPv4Route(destinationAddress: "8.0.0.0", subnetMask: "248.0.0.0"),
                    NEIPv4Route(destinationAddress: "16.0.0.0", subnetMask: "240.0.0.0"),
                    NEIPv4Route(destinationAddress: "32.0.0.0", subnetMask: "224.0.0.0"),
                    NEIPv4Route(destinationAddress: "64.0.0.0", subnetMask: "192.0.0.0"),
                    NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"),
                ]
        }
        result.includedRoutes = routes

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
        if routes.isEmpty {
            routes = useDefaultRoute
                ? [NEIPv6Route.default()]
                : [
                    NEIPv6Route(destinationAddress: "100::", networkPrefixLength: 8),
                    NEIPv6Route(destinationAddress: "200::", networkPrefixLength: 7),
                    NEIPv6Route(destinationAddress: "400::", networkPrefixLength: 6),
                    NEIPv6Route(destinationAddress: "800::", networkPrefixLength: 5),
                    NEIPv6Route(destinationAddress: "1000::", networkPrefixLength: 4),
                    NEIPv6Route(destinationAddress: "2000::", networkPrefixLength: 3),
                    NEIPv6Route(destinationAddress: "4000::", networkPrefixLength: 2),
                    NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1),
                ]
        }
        result.includedRoutes = routes

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
    func includeAllNetworks() -> Bool { tunnel.protocolConfiguration.includeAllNetworks }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
    /// 分流规则用到 Wi-Fi 条件时内核才会来问。隧道开着时系统允许读，不需要定位权限
    func readWIFIState() -> LibboxWIFIState? {
        let network = runBlocking {
            await NEHotspotNetwork.fetchCurrent()
        }
        guard let network else {
            return nil
        }
        return LibboxWIFIState(network.ssid, wifiBSSID: network.bssid)
    }
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
