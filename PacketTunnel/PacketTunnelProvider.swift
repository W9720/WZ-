import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var udpSessions: [String: NWUDPSession] = [:]
    private var tcpConnections: [String: NWConnection] = [:]
    private var pendingTCPRequests: [String: Data] = [:]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 启动隧道")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0")
        ]
        
        settings.ipv4Settings = ipv4Settings
        
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "114.114.114.114", "223.5.5.5"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 设置失败: \(error)")
                completionHandler(error)
                return
            }
            
            NSLog("[PacketTunnel] 设置成功，开始处理数据包")
            self.startReadingPackets()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止隧道")
        udpSessions.values.forEach { $0.cancel() }
        udpSessions.removeAll()
        tcpConnections.values.forEach { $0.cancel() }
        tcpConnections.removeAll()
        completionHandler()
    }
    
    private func startReadingPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInteractive).async {
                for index in 0..<packets.count {
                    let packet = packets[index]
                    let proto = protocols[index].int32Value
                    self.processPacket(packet, protocolNumber: proto)
                }
                
                self.startReadingPackets()
            }
        }
    }
    
    private func processPacket(_ packet: Data, protocolNumber: Int32) {
        guard packet.count >= 20 else { return }
        
        let version = (packet[0] >> 4) & 0x0F
        guard version == 4 else { return }
        
        let ihl = Int((packet[0] & 0x0F)) * 4
        guard ihl >= 20 && packet.count >= ihl else { return }
        
        let protocolType = packet[9]
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        
        if protocolType == 17 {
            handleUDPPacket(packet, ipHeaderLen: ihl, srcIP: srcIP, dstIP: dstIP)
            return
        }
        
        guard protocolType == 6 else { return }
        
        handleTCPPacket(packet, ipHeaderLen: ihl, srcIP: srcIP, dstIP: dstIP)
    }
    
    private func handleUDPPacket(_ packet: Data, ipHeaderLen: Int, srcIP: String, dstIP: String) {
        guard packet.count >= ipHeaderLen + 8 else { return }
        
        let udpOffset = ipHeaderLen
        let srcPort = UInt16(packet[udpOffset]) << 8 | UInt16(packet[udpOffset + 1])
        let dstPort = UInt16(packet[udpOffset + 2]) << 8 | UInt16(packet[udpOffset + 3])
        let udpLen = Int(UInt16(packet[udpOffset + 4]) << 8 | UInt16(packet[udpOffset + 5]))
        
        let payloadOffset = udpOffset + 8
        guard packet.count >= payloadOffset else { return }
        let payload = packet.subdata(in: payloadOffset..<min(packet.count, payloadOffset + udpLen - 8))
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        
        if let session = udpSessions[key] {
            session.send(payload, completionHandler: { _ in })
            return
        }
        
        let endpoint = NWHostEndpoint(hostname: dstIP, port: "\(dstPort)")
        let session = self.createUDPSession(to: endpoint, from: nil)
        udpSessions[key] = session
        
        session.setReadHandler({ [weak self] (datagrams: [Data]?, error: Error?) in
            if let datagrams = datagrams, !datagrams.isEmpty {
                let responses = datagrams.map { self?.buildUDPResponse($0, srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort) ?? Data() }
                self?.packetFlow.writePackets(responses, withProtocols: [NSNumber(value: AF_INET)])
            }
        }, maxDatagrams: 32)
        
        session.send(payload, completionHandler: { _ in })
    }
    
    private func handleTCPPacket(_ packet: Data, ipHeaderLen: Int, srcIP: String, dstIP: String) {
        guard packet.count >= ipHeaderLen + 20 else { return }
        
        let tcpOffset = ipHeaderLen
        let srcPort = UInt16(packet[tcpOffset]) << 8 | UInt16(packet[tcpOffset + 1])
        let dstPort = UInt16(packet[tcpOffset + 2]) << 8 | UInt16(packet[tcpOffset + 3])
        
        let dataOffset = Int((packet[tcpOffset + 12] >> 4) & 0x0F) * 4
        let payloadOffset = tcpOffset + dataOffset
        let payload = payloadOffset < packet.count ? packet.subdata(in: payloadOffset..<packet.count) : Data()
        
        let connKey = "\(srcIP):\(srcPort)"
        
        if (dstPort == 80 || dstPort == 8080) && !payload.isEmpty {
            if let request = String(data: payload, encoding: .utf8),
               request.contains("apis.map.qq.com") && request.contains("/ws/geocoder/v1") {
                
                NSLog("[PacketTunnel] 拦截目标请求: \(dstIP):\(dstPort)")
                sendFakeResponse(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
                return
            }
        }
        
        if let conn = tcpConnections[connKey] {
            if !payload.isEmpty {
                conn.send(content: payload, completion: .contentProcessed({ _ in }))
            }
            return
        }
        
        let tcpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(dstIP), port: NWEndpoint.Port(rawValue: dstPort)!)
        let conn = NWConnection(to: tcpEndpoint, using: .tcp)
        tcpConnections[connKey] = conn
        
        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                if let pendingData = self.pendingTCPRequests[connKey] {
                    conn.send(content: pendingData, completion: .contentProcessed({ _ in }))
                    self.pendingTCPRequests[connKey] = nil
                }
            case .failed(let error):
                NSLog("[PacketTunnel] TCP连接失败: \(error)")
                fallthrough
            case .cancelled:
                self.tcpConnections[connKey] = nil
                self.pendingTCPRequests[connKey] = nil
            default:
                break
            }
        }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] (data: Data?, context: NWConnection.ContentContext?, isComplete: Bool, error: Error?) in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                let response = self.buildTCPResponse(data, srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort)
                self.packetFlow.writePackets([response], withProtocols: [NSNumber(value: AF_INET)])
            }
            
            if !isComplete {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096, completion: $0)
            } else {
                self.tcpConnections[connKey] = nil
            }
        }
        
        conn.start(queue: DispatchQueue.global())
        
        if !payload.isEmpty {
            pendingTCPRequests[connKey] = payload
        }
    }
    
    private func buildUDPResponse(_ payload: Data, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) -> Data {
        var response = Data()
        
        let srcBytes = parseIP(srcIP)
        let dstBytes = parseIP(dstIP)
        
        var ipHeader = Data(count: 20)
        ipHeader[0] = 0x45
        ipHeader[1] = 0x00
        let ipLen = UInt16(20 + 8 + payload.count)
        withUnsafeBytes(of: ipLen.bigEndian) { ipHeader.replaceSubrange(2..<4, with: $0) }
        ipHeader[6] = 0x40
        ipHeader[9] = 0x11
        
        ipHeader.replaceSubrange(12..<16, with: srcBytes)
        ipHeader.replaceSubrange(16..<20, with: dstBytes)
        
        let ipChecksum = calculateChecksum(ipHeader)
        withUnsafeBytes(of: ipChecksum.bigEndian) { ipHeader.replaceSubrange(10..<12, with: $0) }
        
        var udpHeader = Data(count: 8)
        withUnsafeBytes(of: srcPort.bigEndian) { udpHeader.replaceSubrange(0..<2, with: $0) }
        withUnsafeBytes(of: dstPort.bigEndian) { udpHeader.replaceSubrange(2..<4, with: $0) }
        let udpLen = UInt16(8 + payload.count)
        withUnsafeBytes(of: udpLen.bigEndian) { udpHeader.replaceSubrange(4..<6, with: $0) }
        
        response.append(ipHeader)
        response.append(udpHeader)
        response.append(payload)
        
        return response
    }
    
    private func buildTCPResponse(_ payload: Data, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) -> Data {
        var response = Data()
        
        let srcBytes = parseIP(srcIP)
        let dstBytes = parseIP(dstIP)
        
        var ipHeader = Data(count: 20)
        ipHeader[0] = 0x45
        ipHeader[1] = 0x00
        let ipLen = UInt16(20 + 20 + payload.count)
        withUnsafeBytes(of: ipLen.bigEndian) { ipHeader.replaceSubrange(2..<4, with: $0) }
        ipHeader[6] = 0x40
        ipHeader[9] = 0x06
        
        ipHeader.replaceSubrange(12..<16, with: srcBytes)
        ipHeader.replaceSubrange(16..<20, with: dstBytes)
        
        let ipChecksum = calculateChecksum(ipHeader)
        withUnsafeBytes(of: ipChecksum.bigEndian) { ipHeader.replaceSubrange(10..<12, with: $0) }
        
        var tcpHeader = Data(count: 20)
        withUnsafeBytes(of: srcPort.bigEndian) { tcpHeader.replaceSubrange(0..<2, with: $0) }
        withUnsafeBytes(of: dstPort.bigEndian) { tcpHeader.replaceSubrange(2..<4, with: $0) }
        
        let seqNum: UInt32 = arc4random() % 1000000
        withUnsafeBytes(of: seqNum.bigEndian) { tcpHeader.replaceSubrange(4..<8, with: $0) }
        
        tcpHeader[12] = 0x50
        tcpHeader[13] = 0x18
        
        let windowSize: UInt16 = 65535
        withUnsafeBytes(of: windowSize.bigEndian) { tcpHeader.replaceSubrange(14..<16, with: $0) }
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: srcBytes)
        pseudoHeader.append(contentsOf: dstBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x06)
        let tcpLen = UInt16(20 + payload.count)
        let tcpLenBytes = withUnsafeBytes(of: tcpLen.bigEndian) { Array($0) }
        pseudoHeader.append(contentsOf: tcpLenBytes)
        
        var checksumData = pseudoHeader
        checksumData.append(tcpHeader)
        checksumData.append(payload)
        
        let tcpChecksum = calculateChecksum(checksumData)
        withUnsafeBytes(of: tcpChecksum.bigEndian) { tcpHeader.replaceSubrange(16..<18, with: $0) }
        
        response.append(ipHeader)
        response.append(tcpHeader)
        response.append(payload)
        
        return response
    }
    
    private func sendFakeResponse(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) {
        guard let location = LocationStore.shared.getSelectedLocation() else {
            NSLog("[PacketTunnel] 未选择位置")
            return
        }
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: location.adcode, regionName: location.name)
        let fakeResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\nContent-Length: \(fakeBody.count)\r\n\r\n\(fakeBody)"
        
        guard let responseData = fakeResponse.data(using: .utf8) else { return }
        
        let responsePacket = buildTCPResponse(responseData, srcIP: dstIP, srcPort: dstPort, dstIP: srcIP, dstPort: srcPort)
        packetFlow.writePackets([responsePacket], withProtocols: [NSNumber(value: AF_INET)])
        
        NSLog("[PacketTunnel] 发送伪造响应: \(location.name) - \(location.adcode)")
    }
    
    private func parseIP(_ addr: String) -> [UInt8] {
        return addr.split(separator: ".").compactMap { UInt8($0) }
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