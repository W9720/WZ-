import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let queue = DispatchQueue(label: "com.warzone.packettunnel")
    private var isRunning = false
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
            self.isRunning = true
            self.readPackets()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止隧道，原因: \(reason.rawValue)")
        isRunning = false
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        completionHandler()
    }
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            
            for packet in packets {
                self.handlePacket(packet)
            }
            
            self.readPackets()
        }
    }
    
    private func handlePacket(_ data: Data) {
        guard let ipHeader = parseIPHeader(data) else {
            return
        }
        
        if ipHeader.protocolType == 17 {
            handleUDP(data, ipHeader: ipHeader)
            return
        }
        
        guard ipHeader.protocolType == 6 else {
            return
        }
        
        guard let tcpHeader = parseTCPHeader(data, ipHeaderOffset: ipHeader.headerLength) else {
            return
        }
        
        let connectionKey = "\(ipHeader.sourceAddress):\(tcpHeader.sourcePort)-\(ipHeader.destinationAddress):\(tcpHeader.destinationPort)"
        
        var connection = connections[connectionKey]
        
        if connection == nil {
            connection = TCPConnection(
                sourceIP: ipHeader.sourceAddress,
                sourcePort: tcpHeader.sourcePort,
                destIP: ipHeader.destinationAddress,
                destPort: tcpHeader.destinationPort,
                packetFlow: packetFlow
            )
            connections[connectionKey] = connection
        }
        
        guard let connection = connection else { return }
        
        let payloadOffset = ipHeader.headerLength + tcpHeader.headerLength
        let payload = data.subdata(in: payloadOffset..<data.count)
        
        connection.handlePacket(
            sequenceNumber: tcpHeader.sequenceNumber,
            acknowledgmentNumber: tcpHeader.acknowledgmentNumber,
            flags: tcpHeader.flags,
            payload: payload
        )
        
        if tcpHeader.isFIN || tcpHeader.isRST {
            connection.cancel()
            connections.removeValue(forKey: connectionKey)
        }
    }
    
    private func handleUDP(_ data: Data, ipHeader: IPHeader) {
        guard data.count >= ipHeader.headerLength + 8 else {
            return
        }
        
        let udpOffset = ipHeader.headerLength
        let sourcePort = UInt16(data[udpOffset]) << 8 | UInt16(data[udpOffset + 1])
        let destPort = UInt16(data[udpOffset + 2]) << 8 | UInt16(data[udpOffset + 3])
        let length = Int(UInt16(data[udpOffset + 4]) << 8 | UInt16(data[udpOffset + 5]))
        let payloadOffset = udpOffset + 8
        
        guard data.count >= payloadOffset else { return }
        
        let payload = data.subdata(in: payloadOffset..<min(data.count, payloadOffset + length - 8))
        
        let connection = NWConnection(
            host: NWEndpoint.Host(ipHeader.destinationAddress),
            port: NWEndpoint.Port(rawValue: destPort)!,
            using: .udp
        )
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                connection.send(content: payload, completion: .idempotent)
                connection.receiveMessage { [weak self] data, _, isComplete, error in
                    guard let self = self else { return }
                    if let data = data, !data.isEmpty {
                        var responsePacket = Data()
                        
                        var udpHeader = Data()
                        udpHeader.append(UInt8(destPort >> 8))
                        udpHeader.append(UInt8(destPort & 0xFF))
                        udpHeader.append(UInt8(sourcePort >> 8))
                        udpHeader.append(UInt8(sourcePort & 0xFF))
                        let totalLength = UInt16(8 + data.count)
                        udpHeader.append(UInt8(totalLength >> 8))
                        udpHeader.append(UInt8(totalLength & 0xFF))
                        udpHeader.append(0x00)
                        udpHeader.append(0x00)
                        
                        let srcIPBytes = self.parseIP(ipHeader.destinationAddress)
                        let dstIPBytes = self.parseIP(ipHeader.sourceAddress)
                        
                        var pseudoHeader = Data()
                        pseudoHeader.append(contentsOf: srcIPBytes)
                        pseudoHeader.append(contentsOf: dstIPBytes)
                        pseudoHeader.append(0x00)
                        pseudoHeader.append(0x11)
                        pseudoHeader.append(UInt8(totalLength >> 8))
                        pseudoHeader.append(UInt8(totalLength & 0xFF))
                        
                        var checksumData = pseudoHeader
                        checksumData.append(udpHeader)
                        checksumData.append(data)
                        
                        let checksum = self.calculateChecksum(checksumData)
                        udpHeader.replaceSubrange(6..<8, with: withUnsafeBytes(of: checksum.bigEndian) { Data($0) })
                        
                        var ipHeader = Data()
                        ipHeader.append(0x45)
                        ipHeader.append(0x00)
                        let ipTotalLength = UInt16(20 + 8 + data.count)
                        ipHeader.append(UInt8(ipTotalLength >> 8))
                        ipHeader.append(UInt8(ipTotalLength & 0xFF))
                        ipHeader.append(0x00)
                        ipHeader.append(0x00)
                        ipHeader.append(0x40)
                        ipHeader.append(0x00)
                        ipHeader.append(0x40)
                        ipHeader.append(0x11)
                        ipHeader.append(0x00)
                        ipHeader.append(0x00)
                        ipHeader.append(contentsOf: srcIPBytes)
                        ipHeader.append(contentsOf: dstIPBytes)
                        
                        let ipChecksum = self.calculateChecksum(ipHeader)
                        ipHeader.replaceSubrange(10..<12, with: withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) })
                        
                        responsePacket.append(ipHeader)
                        responsePacket.append(udpHeader)
                        responsePacket.append(data)
                        
                        self.packetFlow.writePackets([responsePacket], withProtocols: [AF_INET as NSNumber])
                    }
                    if isComplete || error != nil {
                        connection.cancel()
                    }
                }
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        
        connection.start(queue: queue)
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
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if let message = String(data: messageData, encoding: .utf8) {
            NSLog("[PacketTunnel] 收到消息: \(message)")
        }
        completionHandler?(nil)
    }
}

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

class TCPConnection {
    private let sourceIP: String
    private let sourcePort: UInt16
    private let destIP: String
    private let destPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    
    private var connection: NWConnection?
    private var clientSeq: UInt32 = 0
    private var clientAck: UInt32 = 0
    private var serverSeq: UInt32 = 0
    private var serverAck: UInt32 = 0
    private var isEstablished = false
    
    private var requestBuffer: Data = Data()
    private var responseBuffer: Data = Data()
    private var isTargetRequest = false
    private let queue = DispatchQueue(label: "com.warzone.tcp-connection")
    
    init(sourceIP: String, sourcePort: UInt16, destIP: String, destPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destIP = destIP
        self.destPort = destPort
        self.packetFlow = packetFlow
    }
    
    func handlePacket(sequenceNumber: UInt32, acknowledgmentNumber: UInt32, flags: UInt8, payload: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.clientSeq = sequenceNumber
            self.clientAck = acknowledgmentNumber
            
            if (flags & 0x02) != 0 {
                NSLog("[TCPConnection] 收到 SYN")
                self.sendSYNACK(clientSeq: sequenceNumber)
                self.serverSeq = 1000
                return
            }
            
            if (flags & 0x10) != 0 && !self.isEstablished {
                NSLog("[TCPConnection] 收到 ACK，建立连接")
                self.isEstablished = true
                self.connectToServer()
                return
            }
            
            if !payload.isEmpty {
                self.handlePayload(payload)
            }
            
            if (flags & 0x10) != 0 && !payload.isEmpty {
                let ackPacket = self.buildPacket(
                    sourceIP: self.destIP,
                    sourcePort: self.destPort,
                    destIP: self.sourceIP,
                    destPort: self.sourcePort,
                    seqNum: self.serverSeq,
                    ackNum: self.clientSeq + UInt32(payload.count),
                    flags: 0x10,
                    payload: Data()
                )
                self.packetFlow.writePackets([ackPacket], withProtocols: [AF_INET as NSNumber])
            }
        }
    }
    
    private func handlePayload(_ payload: Data) {
        requestBuffer.append(payload)
        
        if !isTargetRequest {
            if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                isTargetRequest = LocationInjector.shared.isTargetRequest(
                    host: request.host,
                    path: request.path
                )
                
                if isTargetRequest {
                    NSLog("[TCPConnection] 检测到目标请求: \(request.host ?? "")\(request.path ?? "")")
                }
            }
        }
        
        connection?.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[TCPConnection] Send error: \(error)")
            }
        })
    }
    
    private func connectToServer() {
        let host = NWEndpoint.Host(destIP)
        let port = NWEndpoint.Port(rawValue: destPort)!
        
        connection = NWConnection(to: .hostPort(host: host, port: port), using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                NSLog("[TCPConnection] 服务器连接成功")
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
        
        connection?.start(queue: queue)
    }
    
    private func receiveFromServer() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[TCPConnection] Receive error: \(error)")
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
                                NSLog("[TCPConnection] 注入伪造响应: \(location.adcode)")
                                
                                let fakeBody = LocationInjector.shared.buildFakeResponse(
                                    adcode: location.adcode,
                                    regionName: location.name
                                )
                                
                                let fakeResponse = HTTPResponse(
                                    version: "HTTP/1.1",
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
                
                self.sendDataToClient(responseData)
            }
            
            if isComplete {
                self.sendFIN()
            } else if error == nil {
                self.receiveFromServer()
            }
        }
    }
    
    private func sendDataToClient(_ data: Data) {
        let maxSegmentSize = 1400
        var offset = 0
        
        while offset < data.count {
            let chunkSize = min(maxSegmentSize, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + chunkSize)
            
            let packet = buildPacket(
                sourceIP: destIP,
                sourcePort: destPort,
                destIP: sourceIP,
                destPort: sourcePort,
                seqNum: serverSeq,
                ackNum: clientSeq + 1,
                flags: 0x18,
                payload: chunk
            )
            
            packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
            serverSeq += UInt32(chunkSize)
            offset += chunkSize
        }
    }
    
    private func sendSYNACK(clientSeq: UInt32) {
        let packet = buildPacket(
            sourceIP: destIP,
            sourcePort: destPort,
            destIP: sourceIP,
            destPort: sourcePort,
            seqNum: serverSeq,
            ackNum: clientSeq + 1,
            flags: 0x12,
            payload: Data()
        )
        
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
        serverSeq += 1
    }
    
    private func sendFIN() {
        let packet = buildPacket(
            sourceIP: destIP,
            sourcePort: destPort,
            destIP: sourceIP,
            destPort: sourcePort,
            seqNum: serverSeq,
            ackNum: clientSeq + 1,
            flags: 0x11,
            payload: Data()
        )
        
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
        serverSeq += 1
    }
    
    private func sendRST() {
        let packet = buildPacket(
            sourceIP: destIP,
            sourcePort: destPort,
            destIP: sourceIP,
            destPort: sourcePort,
            seqNum: serverSeq,
            ackNum: clientSeq + 1,
            flags: 0x04,
            payload: Data()
        )
        
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
    }
    
    private func buildPacket(
        sourceIP: String, sourcePort: UInt16,
        destIP: String, destPort: UInt16,
        seqNum: UInt32, ackNum: UInt32,
        flags: UInt8, payload: Data
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
        
        let ipChecksum: UInt16 = 0
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
        
        let tcpChecksum: UInt16 = 0
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
    
    func cancel() {
        connection?.cancel()
        connection = nil
    }
}
