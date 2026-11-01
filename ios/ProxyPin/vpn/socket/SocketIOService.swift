//
//  ProxySocketIOService.swift
//  ProxyPin
//
//  Created by wanghongen on 2024/9/17.
//

import Foundation
import NetworkExtension
import os.log

class SocketIOService {
    // 单次读取上限，读到的数据按 MSS 分段后批量写回隧道
    private static let maxReceiveBufferSize = 65535

    // 所有连接的回调都在这条串行队列上运行
    private let queue: DispatchQueue = DispatchQueue(label: "ProxyPin.SocketIOService", qos: .userInitiated)

    private var clientPacketWriter: ClientPacketWriter

    private var shutdown = false

    init(clientPacketWriter: ClientPacketWriter) {
        self.clientPacketWriter = clientPacketWriter
    }

    public func stop() {
        os_log("Stopping SocketIOService", log: OSLog.default, type: .default)
        queue.async {
            self.shutdown = true
        }
//        queue.suspend()
    }

    //从connection接受数据 写到client
    public func registerSession(connection: Connection) {
        guard let channel = connection.withLock({ connection.channel }) else {
            os_log("Missing channel for %{public}@", log: OSLog.default, type: .error, connection.description)
            connection.closeConnection()
            return
        }

        channel.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
//             os_log("Connection %{public}@ state changed to %{public}@", log: OSLog.default, type: .default, connection.description, String(describing: state))
            switch state {

            case .ready:
                connection.withLock {
                    connection.isConnected = true
                    connection.isAbortingConnection = false
                    connection.lastActiveAt = Date()
                }
                os_log("Connected to %{public}@ on receiveMessage", log: OSLog.default, type: .default, connection.description)

                //接受远程服务器的数据
                connection.sendToDestination()
                self.receiveMessage(connection: connection)
            case .cancelled:
                connection.withLock {
                    connection.isConnected = false
                }
                os_log("Connection cancelled  %{public}@", log: OSLog.default, type: .default, connection.description)
                self.sendFin(connection: connection)
                connection.closeConnection()

            case .waiting(let error):
                connection.withLock {
                    connection.isConnected = false
                    connection.isAbortingConnection = true
                }
                os_log("Connection waiting: %{public}@ %{public}@", log: OSLog.default, type: .error, connection.description, error.localizedDescription)
                connection.closeConnection()
            case .failed(let error):
                connection.withLock {
                    connection.isConnected = false
                    connection.isAbortingConnection = true
                }
                os_log("Failed to connect: %{public}@ %{public}@", log: OSLog.default, type: .error,connection.description, error.localizedDescription)
                connection.closeConnection()
            default:
                os_log("Connection %{public}@ entered unhandled state: %{public}@", log: OSLog.default, type: .default, connection.description, String(describing: state))
                break
            }
        }

        channel.start(queue: self.queue)
    }

    private func receiveMessage(connection: Connection) {
        if (shutdown) {
            os_log("SocketIOService is shutting down", log: OSLog.default, type: .default)
            return
        }

        if (connection.nwProtocol == .UDP) {
            readUDP(connection: connection)
        } else {
            readTCP(connection: connection)
        }

        if connection.withLock({ connection.isAbortingConnection }) {
            os_log("Connection is aborting", log: OSLog.default, type: .default)
            connection.closeConnection()
            return
        }
    }

    func readTCP(connection: Connection) {
//         os_log("Reading from TCP socket")
        if connection.withLock({ connection.isAbortingConnection }) {
            os_log("Connection is aborting", log: OSLog.default, type: .default)
            return
        }

        guard let channel = connection.withLock({ connection.channel }) else {
            os_log("Invalid channel type", log: OSLog.default, type: .error)
            return
        }
        
        // 这里没有重传：超出客户端窗口的数据被丢弃后连接就卡死了。窗口满时先不读，等 ACK 恢复
        let window = connection.withLock { () -> Int in
            let window = connection.availableSendWindow
            connection.isReadPaused = window <= 0
            return window
        }
        guard window > 0 else {
            return
        }

        channel.receive(minimumIncompleteLength: 1, maximumLength: min(window, Self.maxReceiveBufferSize)) { (data, context, isComplete, error) in
//             os_log("[SocketIOService] Received TCP data packet %{public}@ length %d", log: OSLog.default, type: .default, connection.description, data?.count ?? -1)
            if let error = error {
                os_log("Failed to read from TCP socket: %@", log: OSLog.default, type: .error, error as CVarArg)
                connection.withLock {
                    connection.isAbortingConnection = true
                }
                connection.closeConnection()
                return
            }

            if let data = data, !data.isEmpty {
                self.pushDataToClient(buffer: data, connection: connection)
            }

            if (isComplete) {
                self.sendFin(connection: connection)
                connection.closeConnection()
                return
            }

            // Recursively call readTCP to continue reading messages
            self.receiveMessage(connection: connection)
        }
    }

    ///客户端窗口腾出空间后继续读取
    func resumeRead(connection: Connection) {
        queue.async {
            self.receiveMessage(connection: connection)
        }
    }

    func synchronized(_ lock: AnyObject, closure: () -> Void) {
//        objc_sync_enter(lock)
        closure()
//        objc_sync_exit(lock)
    }

    ///create packet data and send it to VPN client
    private func pushDataToClient(buffer: Data, connection: Connection) {
        // The last segment of a read is the natural place to set PSH on the
        // resulting TCP packets that go to the VPN.

        guard let packets = connection.withLock({ () -> [Data]? in
            connection.hasReceivedLastSegment = false

            guard let ipHeader = connection.lastIpHeader, let tcpHeader = connection.lastTcpHeader else {
                return nil
            }

            connection.lastActiveAt = Date()

            let segmentSize = Int(TCPPacketFactory.MAX_SEGMENT_SIZE)
            var packets = [Data]()
            packets.reserveCapacity(buffer.count / segmentSize + 1)

            var offset = buffer.startIndex
            while offset < buffer.endIndex {
                let end = min(offset + segmentSize, buffer.endIndex)
                let unAck = connection.sendNext
                //序列号按 2^32 回绕
                connection.sendNext = unAck &+ UInt32(end - offset)

                packets.append(TCPPacketFactory.createResponsePacketData(
                    ipHeader: ipHeader,
                    tcpHeader: tcpHeader,
                    packetData: buffer[offset..<end],
                    isPsh: end == buffer.endIndex,
                    ackNumber: connection.recSequence,
                    seqNumber: unAck,
                    timeSender: connection.timestampSender,
                    timeReplyTo: connection.timestampReplyTo
                ))
                offset = end
            }
            return packets
        }) else {
            os_log("Invalid ipHeader or tcpHeader", log: OSLog.default, type: .error)
            return
        }

        self.clientPacketWriter.write(packets: packets)
//              os_log("[SocketIOService] Sent TCP data packet to client %{public}@ length:%d", log: OSLog.default, type: .default, connection.description, buffer.count)
    }

    private func sendFin(connection: Connection) {
        if (connection.nwProtocol != .TCP) {
            return
        }
        
        guard let data = connection.withLock({ () -> Data? in
            guard let ipHeader = connection.lastIpHeader, let tcpHeader = connection.lastTcpHeader else {
                return nil
            }

            return TCPPacketFactory.createFinData(
                ipHeader: ipHeader,
                tcpHeader: tcpHeader,
                ackNumber: connection.recSequence,
                seqNumber: connection.sendNext,
                timeSender: connection.timestampSender,
                timeReplyTo: connection.timestampReplyTo
            )
        }) else {
            os_log("Invalid ipHeader or tcpHeader", log: OSLog.default, type: .error)
            return
        }

        self.clientPacketWriter.write(data: data)
    }

    func readUDP(connection: Connection) {
 
        guard let channel = connection.withLock({ connection.channel }) else {
            os_log("Invalid channel type", log: OSLog.default, type: .error)
            return
        }

        channel.receive(minimumIncompleteLength: 1, maximumLength: 65507) { (data, context, isComplete, error) in
            if let error = error {
                os_log("Failed to read from UDP socket: %@", log: OSLog.default, type: .error, error as CVarArg)
                connection.isAbortingConnection = true
                return
            }

//            os_log("Received UDP data packet length %d", log: OSLog.default, type: .debug, data?.count ?? 0)

            guard let data = data, !data.isEmpty else {
                return
            }

            guard let ipHeader = connection.lastIpHeader, let udpHeader = connection.lastUdpHeader else {
                os_log("Missing IP or UDP header for connection %{public}@", log: OSLog.default, type: .error, connection.description)
                return
            }

            let packetData = UDPPacketFactory.createResponsePacket(
                ip: ipHeader,
                udp: udpHeader,
                packetData: data
            )

            self.clientPacketWriter.write(data: packetData)

            // Recursively call receiveMessage to continue receiving messages
            self.receiveMessage(connection: connection)
        }
    }
}
