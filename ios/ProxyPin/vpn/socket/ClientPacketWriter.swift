//
//  ClientPacketWriter.swift
//  ProxyPin
//
//  Created by wanghongen on 2024/9/

import Foundation
import NetworkExtension

/// Writes packets back to the tunnel. Packets queued while a write is pending
/// go out together, so a burst costs one writePackets call rather than one each.
class ClientPacketWriter: NSObject {
    private static let ipv4 = NSNumber(value: AF_INET)

    private let packetFlow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "ProxyPin.ClientPacketWriter", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Data] = []
    private var isFlushScheduled = false

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func write(data: Data) {
        write(packets: [data])
    }

    func write(packets: [Data]) {
        lock.lock()
        pending.append(contentsOf: packets)
        let shouldSchedule = !isFlushScheduled
        isFlushScheduled = true
        lock.unlock()

        if shouldSchedule {
            queue.async { self.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let packets = pending
        pending = []
        isFlushScheduled = false
        lock.unlock()

        let protocols = [NSNumber](repeating: Self.ipv4, count: packets.count)
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
}

