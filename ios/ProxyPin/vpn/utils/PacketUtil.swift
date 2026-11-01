//
//  PacketUtil.swift
//  ProxyPin
//
//  Created by wanghongen on 2024/9/17.
//

import Foundation
import os.log

class PacketUtil {
    private static var packetId: Int = 0

    static func getPacketId() -> Int {
        defer { packetId += 1 }
        return packetId
    }
    
    static var currentTime: Int {
        return Int(Date().timeIntervalSince1970)
    }
    
   static func writeIntToBytes(value: UInt32, buffer: inout Data, offset: Int) {
        guard buffer.count >= offset + 4 else { return }
        var intValue = value.bigEndian
        let intData = Data(bytes: &intValue, count: 4)
        buffer.replaceSubrange(offset..<offset+4, with: intData)
    }
    
    static func intToIPAddress(_ ip: UInt32) -> String {
        return String(format: "%d.%d.%d.%d", (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF)
    }
    
    /// TCP checksum of `tcpSegment`, covering the IPv4 pseudo header.
    static func tcpChecksum(tcpSegment: UnsafeRawBufferPointer, sourceIP: UInt32, destinationIP: UInt32) -> UInt16 {
        let pseudoHeader = UInt64(sourceIP) + UInt64(destinationIP) + UInt64(ProtocolType.tcp.rawValue) + UInt64(tcpSegment.count)
        return foldChecksum(pseudoHeader + onesComplementSum(tcpSegment))
    }

    /// RFC 1071 Internet checksum of `bytes`.
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        return foldChecksum(onesComplementSum(bytes))
    }

    static func calculateChecksum(data: Data, offset: Int, length: Int) -> Data {
        let value = data.withUnsafeBytes { checksum(UnsafeRawBufferPointer(rebasing: $0[offset..<offset + length])) }
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Sums big-endian words without folding. Each packet goes through this once,
    /// so it reads 32 bits at a time: 2^16 ≡ 1 (mod 0xFFFF), which makes that
    /// equivalent to adding the 16-bit words of RFC 1071.
    private static func onesComplementSum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var sum: UInt64 = 0
        var offset = 0

        while bytes.count - offset >= 4 {
            sum += UInt64(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            offset += 4
        }
        if bytes.count - offset >= 2 {
            sum += UInt64(UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            offset += 2
        }
        // An odd trailing byte is the high half of a word padded with zero.
        if offset < bytes.count {
            sum += UInt64(bytes[offset]) << 8
        }
        return sum
    }

    private static func foldChecksum(_ sum: UInt64) -> UInt16 {
        var folded = sum
        while (folded >> 16) > 0 {
            folded = (folded & 0xFFFF) + (folded >> 16)
        }
        return ~UInt16(truncatingIfNeeded: folded)
    }


    static func isPacketCorrupted(tcpHeader: TCPHeader) -> Bool {
        guard let options = tcpHeader.options else {
            return false
        }

        var i = 0
        while i < options.count {
            let kind = options[i]
            switch kind {
            case 0, 1:
                break
            case 2:
                i += 3
            case 3, 14:
                i += 2
            case 4:
                i += 1
            case 5, 15:
                i += Int(options[i + 1]) - 2
            case 8:
                i += 9
            case 23:
                return true
            default:
                print("Unknown option: \(kind)")
            }
            i += 1
        }
        return false
    }
}


extension FixedWidthInteger {
    var bytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}
