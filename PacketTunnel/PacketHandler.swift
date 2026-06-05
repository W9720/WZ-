import Foundation
import NetworkExtension

struct IPHeader {
    let version: UInt8
    let ihl: UInt8
    let totalLength: UInt16
    let protocolType: UInt8
    let sourceAddress: String
    let destinationAddress: String
    let headerLength: Int
}

struct TCPHeader {
    let sourcePort: UInt16
    let destinationPort: UInt16
    let sequenceNumber: UInt32
    let acknowledgmentNumber: UInt32
    let dataOffset: UInt8
    let flags: UInt8
    let windowSize: UInt16
    let headerLength: Int
    
    var isSYN: Bool { return (flags & 0x02) != 0 }
    var isACK: Bool { return (flags & 0x10) != 0 }
    var isFIN: Bool { return (flags & 0x01) != 0 }
    var isPSH: Bool { return (flags & 0x08) != 0 }
    var isRST: Bool { return (flags & 0x04) != 0 }
}

struct ConnectionInfo {
    let sourceIP: String
    let sourcePort: UInt16
    let destIP: String
    let destPort: UInt16
    let ipHeader: IPHeader
    let tcpHeader: TCPHeader
}

class PacketHandler {
    static let shared = PacketHandler()
    
    private var connections: [String: TCPConnection] = [:]
    private var connectionInfoMap: [String: ConnectionInfo] = [:]
    private var pendingResponses: [Data] = []
    private let queue = DispatchQueue(label: "com.warzone.packet-handler")
    
    var packetFlow: NEPacketTunnelFlow?
    
    private init() {}
    
    func handlePacket(_ data: Data) -> Data? {
        guard let ipHeader = parseIPHeader(data) else {
            return data
        }
        
        guard ipHeader.protocolType == 6 else {
            return data
        }
        
        guard let tcpHeader = parseTCPHeader(data, ipHeaderOffset: ipHeader.headerLength) else {
            return data
        }
        
        let connectionKey = "\(ipHeader.sourceAddress):\(tcpHeader.sourcePort)-\(ipHeader.destinationAddress):\(tcpHeader.destinationPort)"
        let reverseKey = "\(ipHeader.destinationAddress):\(tcpHeader.destinationPort)-\(ipHeader.sourceAddress):\(tcpHeader.sourcePort)"
        
        let payloadOffset = ipHeader.headerLength + tcpHeader.headerLength
        let payload = data.subdata(in: payloadOffset..<data.count)
        
        if connectionInfoMap[connectionKey] == nil {
            connectionInfoMap[connectionKey] = ConnectionInfo(
                sourceIP: ipHeader.sourceAddress,
                sourcePort: tcpHeader.sourcePort,
                destIP: ipHeader.destinationAddress,
                destPort: tcpHeader.destinationPort,
                ipHeader: ipHeader,
                tcpHeader: tcpHeader
            )
        }
        
        if tcpHeader.isSYN {
            handleSYN(connectionKey: connectionKey, 
                     destinationAddress: ipHeader.destinationAddress, 
                     destinationPort: tcpHeader.destinationPort,
                     info: connectionInfoMap[connectionKey]!)
        }
        
        if tcpHeader.isFIN || tcpHeader.isRST {
            handleFIN(connectionKey: connectionKey, reverseKey: reverseKey)
        }
        
        if !payload.isEmpty {
            handlePayload(connectionKey: connectionKey, 
                         reverseKey: reverseKey, 
                         payload: payload,
                         destinationAddress: ipHeader.destinationAddress,
                         destinationPort: tcpHeader.destinationPort,
                         info: connectionInfoMap[connectionKey]!)
        }
        
        return data
    }
    
    private func handleSYN(connectionKey: String, destinationAddress: String, destinationPort: UInt16, info: ConnectionInfo) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if self.connections[connectionKey] == nil {
                let connection = TCPConnection(host: destinationAddress, port: destinationPort)
                
                connection.setResponseInjector { [weak self] request in
                    return self?.createFakeResponse(for: request)
                }
                
                connection.onDataReceived = { [weak self] fakeData in
                    self?.injectResponse(fakeData, for: connectionKey, info: info)
                }
                
                self.connections[connectionKey] = connection
                connection.start()
            }
        }
    }
    
    private func handleFIN(connectionKey: String, reverseKey: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.connections[connectionKey]?.cancel()
            self.connections.removeValue(forKey: connectionKey)
            self.connections.removeValue(forKey: reverseKey)
            self.connectionInfoMap.removeValue(forKey: connectionKey)
            self.connectionInfoMap.removeValue(forKey: reverseKey)
        }
    }
    
    private func handlePayload(connectionKey: String, reverseKey: String, payload: Data, destinationAddress: String, destinationPort: UInt16, info: ConnectionInfo) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            var connection = self.connections[connectionKey]
            
            if connection == nil {
                connection = TCPConnection(host: destinationAddress, port: destinationPort)
                connection?.setResponseInjector { [weak self] request in
                    return self?.createFakeResponse(for: request)
                }
                connection?.onDataReceived = { [weak self] fakeData in
                    self?.injectResponse(fakeData, for: connectionKey, info: info)
                }
                self.connections[connectionKey] = connection
                connection?.start()
            }
            
            connection?.send(data: payload)
        }
    }
    
    private func injectResponse(_ data: Data, for connectionKey: String, info: ConnectionInfo) {
        NSLog("[PacketHandler] 注入伪造响应，大小: \(data.count)")
        
        let fakePacket = buildFakeResponsePacket(
            sourceIP: info.destIP,
            sourcePort: info.destPort,
            destIP: info.sourceIP,
            destPort: info.sourcePort,
            seq: info.tcpHeader.acknowledgmentNumber,
            ack: info.tcpHeader.sequenceNumber + 1,
            payload: data
        )
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.pendingResponses.append(fakePacket)
            
            if let flow = self.packetFlow {
                flow.writePackets([fakePacket], withProtocols: [AF_INET as NSNumber])
                NSLog("[PacketHandler] 伪造响应已写入 VPN 隧道")
            } else {
                NSLog("[PacketHandler] Error: packetFlow 为 nil")
            }
        }
    }
    
    private func buildFakeResponsePacket(
        sourceIP: String, sourcePort: UInt16,
        destIP: String, destPort: UInt16,
        seq: UInt32, ack: UInt32,
        payload: Data
    ) -> Data {
        var packet = Data()
        
        let srcIPBytes = parseIP(sourceIP)
        let dstIPBytes = parseIP(destIP)
        
        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0x00)
        let totalLength = UInt16(20 + 20 + payload.count)
        ipHeader.append(UInt8(totalLength >> 8))
        ipHeader.append(UInt8(totalLength & 0xFF))
        ipHeader.append(0x00)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x06)
        
        var ipChecksum: UInt16 = 0
        ipHeader.append(contentsOf: withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) })
        ipHeader.append(contentsOf: srcIPBytes)
        ipHeader.append(contentsOf: dstIPBytes)
        
        let calculatedIPChecksum = calculateChecksum(ipHeader)
        ipHeader.replaceSubrange(10..<12, with: withUnsafeBytes(of: calculatedIPChecksum.bigEndian) { Data($0) })
        
        var tcpHeader = Data()
        tcpHeader.append(UInt8(sourcePort >> 8))
        tcpHeader.append(UInt8(sourcePort & 0xFF))
        tcpHeader.append(UInt8(destPort >> 8))
        tcpHeader.append(UInt8(destPort & 0xFF))
        tcpHeader.append(UInt8(seq >> 24))
        tcpHeader.append(UInt8((seq >> 16) & 0xFF))
        tcpHeader.append(UInt8((seq >> 8) & 0xFF))
        tcpHeader.append(UInt8(seq & 0xFF))
        tcpHeader.append(UInt8(ack >> 24))
        tcpHeader.append(UInt8((ack >> 16) & 0xFF))
        tcpHeader.append(UInt8((ack >> 8) & 0xFF))
        tcpHeader.append(UInt8(ack & 0xFF))
        tcpHeader.append(0x50)
        tcpHeader.append(0x18)
        tcpHeader.append(0xFF)
        tcpHeader.append(0xFF)
        
        var tcpChecksum: UInt16 = 0
        tcpHeader.append(contentsOf: withUnsafeBytes(of: tcpChecksum.bigEndian) { Data($0) })
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: srcIPBytes)
        pseudoHeader.append(contentsOf: dstIPBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x06)
        let tcpLength = UInt16(tcpHeader.count + payload.count)
        pseudoHeader.append(UInt8(tcpLength >> 8))
        pseudoHeader.append(UInt8(tcpLength & 0xFF))
        
        var tcpChecksumData = pseudoHeader
        tcpChecksumData.append(tcpHeader)
        tcpChecksumData.append(payload)
        
        let calculatedTCPChecksum = calculateChecksum(tcpChecksumData)
        tcpHeader.replaceSubrange(16..<18, with: withUnsafeBytes(of: calculatedTCPChecksum.bigEndian) { Data($0) })
        
        packet.append(ipHeader)
        packet.append(tcpHeader)
        packet.append(payload)
        
        return packet
    }
    
    private func createFakeResponse(for request: HTTPRequest) -> HTTPResponse? {
        guard LocationInjector.shared.isTargetRequest(host: request.host, path: request.path) else {
            return nil
        }
        
        guard let location = LocationStore.shared.getSelectedLocation() else {
            return nil
        }
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(
            adcode: location.adcode,
            regionName: location.name
        )
        
        guard let bodyData = fakeBody.data(using: .utf8) else {
            return nil
        }
        
        let headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Server": "tencent-nginx",
            "Date": DateFormatter.rfc1123.string(from: Date()),
            "Connection": "close",
            "Content-Length": "\(bodyData.count)"
        ]
        
        return HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: headers,
            body: bodyData
        )
    }
    
    private func parseIPHeader(_ data: Data) -> IPHeader? {
        guard data.count >= 20 else { return nil }
        
        let versionAndIHL = data[0]
        let version = (versionAndIHL >> 4) & 0x0F
        let ihl = versionAndIHL & 0x0F
        let headerLength = Int(ihl) * 4
        
        guard headerLength >= 20 && data.count >= headerLength else { return nil }
        
        let totalLength = UInt16(data[2]) << 8 | UInt16(data[3])
        let protocolType = data[9]
        
        let sourceAddress = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let destinationAddress = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"
        
        return IPHeader(
            version: version,
            ihl: ihl,
            totalLength: totalLength,
            protocolType: protocolType,
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            headerLength: headerLength
        )
    }
    
    private func parseTCPHeader(_ data: Data, ipHeaderOffset: Int) -> TCPHeader? {
        guard data.count >= ipHeaderOffset + 20 else { return nil }
        
        let sourcePort = UInt16(data[ipHeaderOffset]) << 8 | UInt16(data[ipHeaderOffset + 1])
        let destinationPort = UInt16(data[ipHeaderOffset + 2]) << 8 | UInt16(data[ipHeaderOffset + 3])
        
        let sequenceNumber = UInt32(data[ipHeaderOffset + 4]) << 24 |
                            UInt32(data[ipHeaderOffset + 5]) << 16 |
                            UInt32(data[ipHeaderOffset + 6]) << 8 |
                            UInt32(data[ipHeaderOffset + 7])
        
        let acknowledgmentNumber = UInt32(data[ipHeaderOffset + 8]) << 24 |
                                  UInt32(data[ipHeaderOffset + 9]) << 16 |
                                  UInt32(data[ipHeaderOffset + 10]) << 8 |
                                  UInt32(data[ipHeaderOffset + 11])
        
        let dataOffset = (data[ipHeaderOffset + 12] >> 4) & 0x0F
        let headerLength = Int(dataOffset) * 4
        
        let flags = data[ipHeaderOffset + 13]
        let windowSize = UInt16(data[ipHeaderOffset + 14]) << 8 | UInt16(data[ipHeaderOffset + 15])
        
        return TCPHeader(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: acknowledgmentNumber,
            dataOffset: dataOffset,
            flags: flags,
            windowSize: windowSize,
            headerLength: headerLength
        )
    }
    
    private func parseIP(_ address: String) -> [UInt8] {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : [0, 0, 0, 0]
    }
    
    private func calculateChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let words = data.count / 2
        
        for i in 0..<words {
            let word = UInt32(data[i * 2]) << 8 | UInt32(data[i * 2 + 1])
            sum += word
        }
        
        if data.count % 2 == 1 {
            sum += UInt32(data[data.count - 1]) << 8
        }
        
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        
        return UInt16(~sum & 0xFFFF)
    }
}

extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()
}
