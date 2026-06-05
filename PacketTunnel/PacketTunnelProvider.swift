import NetworkExtension
import Network
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var connections: [String: TCPConnection] = [:]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 开始启动隧道...")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings
        
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "114.114.114.114"])
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 设置网络配置失败: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            NSLog("[PacketTunnel] 网络配置设置成功，开始读取数据包...")
            self.readPackets()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止隧道，原因: \(reason.rawValue)")
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        completionHandler()
    }
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            for (index, packet) in packets.enumerated() {
                let protocolNum = (protocols[index] as! NSNumber).int32Value
                self.handlePacket(packet, protocolNumber: protocolNum)
            }
            
            self.readPackets()
        }
    }
    
    private func handlePacket(_ data: Data, protocolNumber: Int32) {
        guard data.count >= 20 else { return }
        
        let versionAndIHL = data[0]
        let ihl = versionAndIHL & 0x0F
        let headerLength = Int(ihl) * 4
        
        guard headerLength >= 20 && data.count >= headerLength else { return }
        
        let protocolType = data[9]
        
        let sourceAddress = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let destinationAddress = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"
        
        if protocolType == 17 {
            handleUDP(data, ipHeaderLength: headerLength, sourceIP: sourceAddress, destIP: destinationAddress)
            return
        }
        
        guard protocolType == 6 else { return }
        
        guard data.count >= headerLength + 20 else { return }
        
        let tcpOffset = headerLength
        let sourcePort = UInt16(data[tcpOffset]) << 8 | UInt16(data[tcpOffset + 1])
        let destPort = UInt16(data[tcpOffset + 2]) << 8 | UInt16(data[tcpOffset + 3])
        
        let seqNum = UInt32(data[tcpOffset + 4]) << 24 | UInt32(data[tcpOffset + 5]) << 16 |
                     UInt32(data[tcpOffset + 6]) << 8 | UInt32(data[tcpOffset + 7])
        
        let ackNum = UInt32(data[tcpOffset + 8]) << 24 | UInt32(data[tcpOffset + 9]) << 16 |
                     UInt32(data[tcpOffset + 10]) << 8 | UInt32(data[tcpOffset + 11])
        
        let dataOffset = (data[tcpOffset + 12] >> 4) & 0x0F
        let tcpHeaderLength = Int(dataOffset) * 4
        
        let flags = data[tcpOffset + 13]
        
        let connectionKey = "\(sourceAddress):\(sourcePort)-\(destinationAddress):\(destPort)"
        
        var connection = connections[connectionKey]
        
        if connection == nil {
            connection = TCPConnection(
                sourceIP: sourceAddress,
                sourcePort: sourcePort,
                destIP: destinationAddress,
                destPort: destPort,
                packetFlow: packetFlow
            )
            connections[connectionKey] = connection
        }
        
        guard let conn = connection else { return }
        
        let payloadOffset = headerLength + tcpHeaderLength
        let payload = payloadOffset < data.count ? data.subdata(in: payloadOffset..<data.count) : Data()
        
        conn.handlePacket(seqNum: seqNum, ackNum: ackNum, flags: flags, payload: payload)
        
        if (flags & 0x01) != 0 || (flags & 0x04) != 0 {
            conn.cancel()
            connections.removeValue(forKey: connectionKey)
        }
    }
    
    private func handleUDP(_ data: Data, ipHeaderLength: Int, sourceIP: String, destIP: String) {
        guard data.count >= ipHeaderLength + 8 else { return }
        
        let udpOffset = ipHeaderLength
        let sourcePort = UInt16(data[udpOffset]) << 8 | UInt16(data[udpOffset + 1])
        let destPort = UInt16(data[udpOffset + 2]) << 8 | UInt16(data[udpOffset + 3])
        let length = Int(UInt16(data[udpOffset + 4]) << 8 | UInt16(data[udpOffset + 5]))
        let payloadOffset = udpOffset + 8
        
        guard data.count >= payloadOffset else { return }
        
        let payload = data.subdata(in: payloadOffset..<min(data.count, payloadOffset + length - 8))
        
        let host = NWEndpoint.Host(destIP)
        let port = NWEndpoint.Port(rawValue: destPort)!
        
        let connection = NWConnection(host: host, port: port, using: .udp)
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                connection.send(content: payload, completion: .idempotent)
                connection.receiveMessage { [weak self] data, _, _, error in
                    guard let self = self else { return }
                    if let data = data, !data.isEmpty {
                        self.sendUDPResponse(
                            sourceIP: destIP,
                            sourcePort: destPort,
                            destIP: sourceIP,
                            destPort: sourcePort,
                            payload: data
                        )
                    }
                    connection.cancel()
                }
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func sendUDPResponse(sourceIP: String, sourcePort: UInt16, destIP: String, destPort: UInt16, payload: Data) {
        var responsePacket = Data()
        
        let srcIPBytes = parseIP(sourceIP)
        let dstIPBytes = parseIP(destIP)
        
        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0x00)
        let ipTotalLength = UInt16(20 + 8 + payload.count)
        ipHeader.append(UInt8(ipTotalLength >> 8))
        ipHeader.append(UInt8(ipTotalLength & 0xFF))
        ipHeader.append(0x00)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x11)
        
        var ipChecksum: UInt16 = 0
        ipHeader.append(contentsOf: withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) })
        ipHeader.append(contentsOf: srcIPBytes)
        ipHeader.append(contentsOf: dstIPBytes)
        
        let calculatedIPChecksum = calculateChecksum(ipHeader)
        ipHeader.replaceSubrange(10..<12, with: withUnsafeBytes(of: calculatedIPChecksum.bigEndian) { Data($0) })
        
        var udpHeader = Data()
        udpHeader.append(UInt8(sourcePort >> 8))
        udpHeader.append(UInt8(sourcePort & 0xFF))
        udpHeader.append(UInt8(destPort >> 8))
        udpHeader.append(UInt8(destPort & 0xFF))
        let udpLength = UInt16(8 + payload.count)
        udpHeader.append(UInt8(udpLength >> 8))
        udpHeader.append(UInt8(udpLength & 0xFF))
        udpHeader.append(0x00)
        udpHeader.append(0x00)
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: srcIPBytes)
        pseudoHeader.append(contentsOf: dstIPBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x11)
        pseudoHeader.append(UInt8(udpLength >> 8))
        pseudoHeader.append(UInt8(udpLength & 0xFF))
        
        var checksumData = pseudoHeader
        checksumData.append(udpHeader)
        checksumData.append(payload)
        
        let udpChecksum = calculateChecksum(checksumData)
        udpHeader.replaceSubrange(6..<8, with: withUnsafeBytes(of: udpChecksum.bigEndian) { Data($0) })
        
        responsePacket.append(ipHeader)
        responsePacket.append(udpHeader)
        responsePacket.append(payload)
        
        packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
    }
    
    private func parseIP(_ address: String) -> [UInt8] {
        return address.split(separator: ".").compactMap { UInt8($0) }
    }
    
    private func calculateChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let words = data.count / 2
        
        for i in 0..<words {
            sum += UInt32(data[i * 2]) << 8 | UInt32(data[i * 2 + 1])
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

class TCPConnection {
    private let sourceIP: String
    private let sourcePort: UInt16
    private let destIP: String
    private let destPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    
    private var connection: NWConnection?
    private var clientSeq: UInt32 = 0
    private var serverSeq: UInt32 = 0
    private var isEstablished = false
    
    private var requestBuffer = Data()
    private var responseBuffer = Data()
    private var isTargetRequest = false
    
    init(sourceIP: String, sourcePort: UInt16, destIP: String, destPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destIP = destIP
        self.destPort = destPort
        self.packetFlow = packetFlow
        self.serverSeq = arc4random() % 1000000
    }
    
    func handlePacket(seqNum: UInt32, ackNum: UInt32, flags: UInt8, payload: Data) {
        clientSeq = seqNum
        
        if (flags & 0x02) != 0 {
            sendSYNACK(clientSeq: seqNum)
            return
        }
        
        if (flags & 0x10) != 0 && !isEstablished {
            isEstablished = true
            connectToServer()
            return
        }
        
        if !payload.isEmpty {
            requestBuffer.append(payload)
            
            if !isTargetRequest {
                if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                    isTargetRequest = LocationInjector.shared.isTargetRequest(host: request.host, path: request.path)
                    if isTargetRequest {
                        NSLog("[TCPConnection] 检测到目标请求: \(request.host ?? "")\(request.path ?? "")")
                    }
                }
            }
            
            connection?.send(content: payload, completion: .contentProcessed { _ in })
            
            let ackPacket = buildPacket(seqNum: serverSeq, ackNum: clientSeq + UInt32(payload.count), flags: 0x10, payload: Data())
            packetFlow.writePackets([ackPacket], withProtocols: [AF_INET as NSNumber])
        }
        
        if (flags & 0x10) != 0 && payload.isEmpty {
            let ackPacket = buildPacket(seqNum: serverSeq, ackNum: clientSeq + 1, flags: 0x10, payload: Data())
            packetFlow.writePackets([ackPacket], withProtocols: [AF_INET as NSNumber])
        }
    }
    
    private func connectToServer() {
        let host = NWEndpoint.Host(destIP)
        let port = NWEndpoint.Port(rawValue: destPort)!
        
        connection = NWConnection(host: host, port: port, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receiveFromServer()
            case .failed(let error):
                NSLog("[TCPConnection] 服务器连接失败: \(error)")
                self.sendRST()
            case .cancelled:
                break
            default:
                break
            }
        }
        
        connection?.start(queue: .global())
    }
    
    private func receiveFromServer() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[TCPConnection] 接收失败: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                var responseData = data
                
                if self.isTargetRequest {
                    self.responseBuffer.append(data)
                    
                    if let response = HTTPParser.shared.parseResponse(self.responseBuffer) {
                        let contentLength = response.headers["Content-Length"] ?? "0"
                        let bodyLength = response.body.count
                        
                        if bodyLength >= Int(contentLength) ?? 0 {
                            if let location = LocationStore.shared.getSelectedLocation() {
                                NSLog("[TCPConnection] 注入伪造响应")
                                
                                let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: location.adcode, regionName: location.name)
                                let fakeResponse = HTTPResponse(
                                    version: "HTTP/1.1",
                                    statusCode: 200,
                                    statusMessage: "OK",
                                    headers: [
                                        "Content-Type": "application/json; charset=utf-8",
                                        "Connection": "close",
                                        "Content-Length": "\(fakeBody.data(using: .utf8)?.count ?? 0)"
                                    ],
                                    body: fakeBody.data(using: .utf8) ?? Data()
                                )
                                
                                responseData = fakeResponse.toData()
                            }
                            self.responseBuffer.removeAll()
                        }
                    }
                }
                
                self.sendToClient(responseData)
            }
            
            if isComplete {
                self.sendFIN()
            } else if error == nil {
                self.receiveFromServer()
            }
        }
    }
    
    private func sendToClient(_ data: Data) {
        let maxSize = 1400
        var offset = 0
        
        while offset < data.count {
            let size = min(maxSize, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + size)
            
            let flags: UInt8 = 0x18
            let packet = buildPacket(seqNum: serverSeq, ackNum: clientSeq + 1, flags: flags, payload: chunk)
            packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
            
            serverSeq += UInt32(size)
            offset += size
        }
    }
    
    private func sendSYNACK(clientSeq: UInt32) {
        let packet = buildPacket(seqNum: serverSeq, ackNum: clientSeq + 1, flags: 0x12, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
        serverSeq += 1
    }
    
    private func sendFIN() {
        let packet = buildPacket(seqNum: serverSeq, ackNum: clientSeq + 1, flags: 0x11, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
    }
    
    private func sendRST() {
        let packet = buildPacket(seqNum: serverSeq, ackNum: clientSeq + 1, flags: 0x04, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
    }
    
    private func buildPacket(seqNum: UInt32, ackNum: UInt32, flags: UInt8, payload: Data) -> Data {
        var packet = Data()
        
        let srcIPBytes = parseIP(destIP)
        let dstIPBytes = parseIP(sourceIP)
        
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
        tcpHeader.append(UInt8(destPort >> 8))
        tcpHeader.append(UInt8(destPort & 0xFF))
        tcpHeader.append(UInt8(sourcePort >> 8))
        tcpHeader.append(UInt8(sourcePort & 0xFF))
        
        tcpHeader.append(UInt8(seqNum >> 24))
        tcpHeader.append(UInt8((seqNum >> 16) & 0xFF))
        tcpHeader.append(UInt8((seqNum >> 8) & 0xFF))
        tcpHeader.append(UInt8(seqNum & 0xFF))
        
        tcpHeader.append(UInt8(ackNum >> 24))
        tcpHeader.append(UInt8((ackNum >> 16) & 0xFF))
        tcpHeader.append(UInt8((ackNum >> 8) & 0xFF))
        tcpHeader.append(UInt8(ackNum & 0xFF))
        
        tcpHeader.append(0x50)
        tcpHeader.append(flags)
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
        
        var checksumData = pseudoHeader
        checksumData.append(tcpHeader)
        checksumData.append(payload)
        
        let calculatedTCPChecksum = calculateChecksum(checksumData)
        tcpHeader.replaceSubrange(16..<18, with: withUnsafeBytes(of: calculatedTCPChecksum.bigEndian) { Data($0) })
        
        packet.append(ipHeader)
        packet.append(tcpHeader)
        packet.append(payload)
        
        return packet
    }
    
    private func parseIP(_ address: String) -> [UInt8] {
        return address.split(separator: ".").compactMap { UInt8($0) }
    }
    
    private func calculateChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let words = data.count / 2
        
        for i in 0..<words {
            sum += UInt32(data[i * 2]) << 8 | UInt32(data[i * 2 + 1])
        }
        
        if data.count % 2 == 1 {
            sum += UInt32(data[data.count - 1]) << 8
        }
        
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        
        return UInt16(~sum & 0xFFFF)
    }
    
    func cancel() {
        connection?.cancel()
        connection = nil
    }
}
