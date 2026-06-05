import Foundation
import NetworkExtension
import Network

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
    var requestBuffer: Data
    var responseBuffer: Data
    var isTargetRequest: Bool
    
    init(sourceIP: String, sourcePort: UInt16, destIP: String, destPort: UInt16) {
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destIP = destIP
        self.destPort = destPort
        self.requestBuffer = Data()
        self.responseBuffer = Data()
        self.isTargetRequest = false
    }
}

class ConnectionManager {
    private let packetFlow: NEPacketTunnelFlow
    private var connections: [String: NWConnection] = [:]
    private var connectionInfo: [String: ConnectionInfo] = [:]
    private let queue = DispatchQueue(label: "com.warzone.connection-manager")
    
    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }
    
    func handlePacket(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.processPacket(data)
        }
    }
    
    private func processPacket(_ data: Data) {
        guard let ipHeader = parseIPHeader(data) else {
            return
        }
        
        guard ipHeader.protocolType == 6 else {
            return
        }
        
        guard let tcpHeader = parseTCPHeader(data, ipHeaderOffset: ipHeader.headerLength) else {
            return
        }
        
        let connectionKey = "\(ipHeader.sourceAddress):\(tcpHeader.sourcePort)-\(ipHeader.destinationAddress):\(tcpHeader.destinationPort)"
        
        let payloadOffset = ipHeader.headerLength + tcpHeader.headerLength
        let payload = data.subdata(in: payloadOffset..<data.count)
        
        if connectionInfo[connectionKey] == nil {
            connectionInfo[connectionKey] = ConnectionInfo(
                sourceIP: ipHeader.sourceAddress,
                sourcePort: tcpHeader.sourcePort,
                destIP: ipHeader.destinationAddress,
                destPort: tcpHeader.destinationPort
            )
        }
        
        if tcpHeader.isFIN || tcpHeader.isRST {
            connections[connectionKey]?.cancel()
            connections.removeValue(forKey: connectionKey)
            connectionInfo.removeValue(forKey: connectionKey)
            return
        }
        
        if !payload.isEmpty {
            processPayload(payload, connectionKey: connectionKey, info: connectionInfo[connectionKey]!)
        }
    }
    
    private func processPayload(_ payload: Data, connectionKey: String, info: ConnectionInfo) {
        info.requestBuffer.append(payload)
        
        if !info.isTargetRequest {
            if let request = HTTPParser.shared.parseRequest(info.requestBuffer) {
                info.isTargetRequest = LocationInjector.shared.isTargetRequest(
                    host: request.host,
                    path: request.path
                )
                
                if info.isTargetRequest {
                    NSLog("[ConnectionManager] 检测到目标请求: \(request.host ?? "")\(request.path ?? "")
                }
            }
        }
        
        var connection = connections[connectionKey]
        
        if connection == nil {
            connection = createConnection(connectionKey: connectionKey, info: info)
            connections[connectionKey] = connection
        }
        
        connection?.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[ConnectionManager] Send error: \(error)
            }
        })
    }
    
    private func createConnection(connectionKey: String, info: ConnectionInfo) -> NWConnection {
        let host = NWEndpoint.Host(info.destIP)
        let port = NWEndpoint.Port(rawValue: info.destPort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receive(from: connection, connectionKey: connectionKey, info: info)
            case .failed(let error):
                NSLog("[ConnectionManager] 连接失败: \(error)
                self.connections.removeValue(forKey: connectionKey)
            case .cancelled:
                self.connections.removeValue(forKey: connectionKey)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        return connection
    }
    
    private func receive(from connection: NWConnection, connectionKey: String, info: ConnectionInfo) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ConnectionManager] Receive error: \(error)
                return
            }
            
            if let data = data, !data.isEmpty {
                var responseData = data
                
                if info.isTargetRequest {
                    info.responseBuffer.append(data)
                    
                    if let response = HTTPParser.shared.parseResponse(info.responseBuffer) {
                        let contentLength = response.headers["Content-Length"] ?? "0"
                        let bodyLength = response.body.count
                        
                        if bodyLength >= Int(contentLength) ?? 0 {
                            if let location = LocationStore.shared.getSelectedLocation() {
                                NSLog("[ConnectionManager] 注入伪造响应: \(location.adcode)
                                
                                let fakeBody = LocationInjector.shared.buildFakeResponse(
                                    adcode: location.adcode,
                                    regionName: location.name
                                )
                                
                                let fakeResponse = HTTPResponse(
                                    statusCode: 200,
                                    statusMessage: "OK",
                                    headers: [
                                        "Content-Type": "application/json; charset=utf-8",
                                        "Server": "tencent-nginx",
                                        "Connection": "close",
                                        "Content-Length": "\(fakeBody.data(using: .utf8)?.count ?? 0)"
                                    ],
                                    body: fakeBody.data(using: .utf8) ?? Data()
                                )
                                
                                responseData = fakeResponse.toData()
                            }
                        }
                    }
                }
                
                let responsePacket = self.buildResponsePacket(
                    sourceIP: info.destIP,
                    sourcePort: info.destPort,
                    destIP: info.sourceIP,
                    destPort: info.sourcePort,
                    payload: responseData
                )
                self.packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
            }
            
            if isComplete {
                connection.cancel()
            } else {
                self.receive(from: connection, connectionKey: connectionKey, info: info)
            }
        }
    }
    
    private func buildResponsePacket(
        sourceIP: String, sourcePort: UInt16,
        destIP: String, destPort: UInt16,
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
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
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
