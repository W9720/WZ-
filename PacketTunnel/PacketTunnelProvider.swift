import NetworkExtension
import Foundation
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var udpSessions: [String: UDPSession] = [:]
    private var tcpConnections: [String: TCPConnection] = [:]
    private var cleanupTimer: DispatchSourceTimer?
    private let maxUDPSessions = 100
    private let maxTCPConnections = 200
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 启动隧道")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        if #available(iOS 16.0, *) {
            settings.mtu = 1500
        } else {
            settings.mtu = 1400
        }
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "10.1.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "10.2.0.0", subnetMask: "255.254.0.0"),
            NEIPv4Route(destinationAddress: "10.4.0.0", subnetMask: "255.252.0.0"),
            NEIPv4Route(destinationAddress: "10.8.0.0", subnetMask: "255.248.0.0"),
            NEIPv4Route(destinationAddress: "10.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "10.32.0.0", subnetMask: "255.224.0.0"),
            NEIPv4Route(destinationAddress: "10.64.0.0", subnetMask: "255.192.0.0"),
            NEIPv4Route(destinationAddress: "10.128.0.0", subnetMask: "255.128.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0")
        ]
        
        settings.ipv4Settings = ipv4Settings
        
        if #available(iOS 16.0, *) {
            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [64])
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6Settings
        } else {
            settings.ipv6Settings = nil
        }
        
        let dnsSettings = NEDNSSettings(servers: ["223.5.5.5", "119.29.29.29", "114.114.114.114"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 设置失败: \(error)")
                completionHandler(error)
                return
            }
            
            if #available(iOS 16.0, *) {
                NSLog("[PacketTunnel] 设置成功，开始处理数据包")
                self.startReadingPackets()
                self.startCleanupTimer()
                completionHandler(nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSLog("[PacketTunnel] 设置成功，开始处理数据包")
                    self.startReadingPackets()
                    self.startCleanupTimer()
                    completionHandler(nil)
                }
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止隧道")
        cleanupTimer?.cancel()
        cleanupTimer = nil
        udpSessions.values.forEach { $0.close() }
        udpSessions.removeAll()
        tcpConnections.values.forEach { $0.close() }
        tcpConnections.removeAll()
        completionHandler()
    }
    
    private func startReadingPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInteractive).async {
                autoreleasepool {
                    do {
                        for index in 0..<packets.count {
                            let packet = packets[index]
                            let proto = protocols[index].int32Value
                            self.processPacket(packet, protocolNumber: proto)
                        }
                    } catch {
                        NSLog("[PacketTunnel] 处理数据包异常: \(error)")
                    }
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
            session.send(payload)
            return
        }
        
        if udpSessions.count >= maxUDPSessions {
            if let oldestKey = udpSessions.keys.first {
                udpSessions[oldestKey]?.close()
                udpSessions.removeValue(forKey: oldestKey)
            }
        }
        
        let session = UDPSession(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, packetFlow: packetFlow)
        udpSessions[key] = session
        session.start()
        session.send(payload)
    }
    
    private func handleTCPPacket(_ packet: Data, ipHeaderLen: Int, srcIP: String, dstIP: String) {
        guard packet.count >= ipHeaderLen + 20 else { return }
        
        let tcpOffset = ipHeaderLen
        let srcPort = UInt16(packet[tcpOffset]) << 8 | UInt16(packet[tcpOffset + 1])
        let dstPort = UInt16(packet[tcpOffset + 2]) << 8 | UInt16(packet[tcpOffset + 3])
        
        let dataOffset = Int((packet[tcpOffset + 12] >> 4) & 0x0F) * 4
        let payloadOffset = tcpOffset + dataOffset
        let payload = payloadOffset < packet.count ? packet.subdata(in: payloadOffset..<packet.count) : Data()
        
        let connKey = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        
        if let conn = tcpConnections[connKey] {
            conn.processPacket(packet)
            return
        }
        
        if tcpConnections.count >= maxTCPConnections {
            if let oldestKey = tcpConnections.keys.first {
                tcpConnections[oldestKey]?.close()
                tcpConnections.removeValue(forKey: oldestKey)
            }
        }
        
        let conn = TCPConnection(packetFlow: packetFlow, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
        tcpConnections[connKey] = conn
        conn.processPacket(packet)
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
    
    private func startCleanupTimer() {
        cleanupTimer = DispatchSource.makeTimerSource(queue: .global())
        cleanupTimer?.schedule(deadline: .now(), repeating: 60.0)
        cleanupTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let udpCount = self.udpSessions.count
            let tcpCount = self.tcpConnections.count
            
            self.udpSessions = self.udpSessions.filter { $0.value.isConnected }
            self.tcpConnections = self.tcpConnections.filter { $0.value.isConnected }
            
            NSLog("[PacketTunnel] 连接清理: UDP=%d->%d, TCP=%d->%d", 
                  udpCount, self.udpSessions.count, tcpCount, self.tcpConnections.count)
        }
        cleanupTimer?.resume()
    }
}

class UDPSession {
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.warzone.udp.session")
    private var lastActivity: Date = Date()
    private var timeoutTimer: DispatchSourceTimer?
    
    var isConnected: Bool {
        return connection != nil
    }
    
    init(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.packetFlow = packetFlow
    }
    
    func start() {
        lastActivity = Date()
        
        let host = NWEndpoint.Host(dstIP)
        let port = NWEndpoint.Port(rawValue: dstPort)!
        
        connection = NWConnection(host: host, port: port, using: .udp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.lastActivity = Date()
            
            switch state {
            case .ready:
                NSLog("[UDPSession] 连接就绪: \(self.dstIP):\(self.dstPort)")
                self.receiveData()
            case .failed(let error):
                NSLog("[UDPSession] 连接失败: \(error)")
                self.close()
            case .cancelled:
                NSLog("[UDPSession] 连接已取消")
            default:
                break
            }
        }
        
        connection?.start(queue: queue)
        startTimeoutTimer()
    }
    
    func send(_ data: Data) {
        lastActivity = Date()
        guard let connection = connection else { return }
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[UDPSession] 发送失败: \(error)")
            }
        })
    }
    
    private func receiveData() {
        guard let connection = connection else { return }
        
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            self.lastActivity = Date()
            
            if let error = error {
                NSLog("[UDPSession] 接收失败: \(error)")
                self.close()
                return
            }
            
            if let data = data, !data.isEmpty {
                self.sendResponse(data)
            }
            
            if !isComplete {
                self.receiveData()
            }
        }
    }
    
    private func startTimeoutTimer() {
        timeoutTimer = DispatchSource.makeTimerSource(queue: queue)
        timeoutTimer?.schedule(deadline: .now(), repeating: 5.0)
        timeoutTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            if Date().timeIntervalSince(self.lastActivity) > 30 {
                NSLog("[UDPSession] 超时自动关闭: \(self.dstIP):\(self.dstPort)")
                self.close()
            }
        }
        timeoutTimer?.resume()
    }
    
    private func sendResponse(_ data: Data) {
        var response = Data()
        
        let srcBytes = parseIP(dstIP)
        let dstBytes = parseIP(srcIP)
        
        var ipHeader = Data(count: 20)
        ipHeader[0] = 0x45
        ipHeader[1] = 0x00
        let ipLen = UInt16(20 + 8 + data.count)
        withUnsafeBytes(of: ipLen.bigEndian) { ipHeader.replaceSubrange(2..<4, with: $0) }
        
        let identification = UInt16.random(in: 1...65535)
        withUnsafeBytes(of: identification.bigEndian) { ipHeader.replaceSubrange(4..<6, with: $0) }
        
        ipHeader[6] = 0x40
        ipHeader[8] = 64
        ipHeader[9] = 0x11
        
        ipHeader.replaceSubrange(12..<16, with: srcBytes)
        ipHeader.replaceSubrange(16..<20, with: dstBytes)
        
        let ipChecksum = calculateChecksum(ipHeader)
        withUnsafeBytes(of: ipChecksum.bigEndian) { ipHeader.replaceSubrange(10..<12, with: $0) }
        
        var udpHeader = Data(count: 8)
        withUnsafeBytes(of: dstPort.bigEndian) { udpHeader.replaceSubrange(0..<2, with: $0) }
        withUnsafeBytes(of: srcPort.bigEndian) { udpHeader.replaceSubrange(2..<4, with: $0) }
        let udpLen = UInt16(8 + data.count)
        withUnsafeBytes(of: udpLen.bigEndian) { udpHeader.replaceSubrange(4..<6, with: $0) }
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: srcBytes)
        pseudoHeader.append(contentsOf: dstBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x11)
        let udpLenBytes = withUnsafeBytes(of: udpLen.bigEndian) { Array($0) }
        pseudoHeader.append(contentsOf: udpLenBytes)
        
        var checksumData = pseudoHeader
        checksumData.append(udpHeader)
        checksumData.append(data)
        
        let udpChecksum = calculateChecksum(checksumData)
        withUnsafeBytes(of: udpChecksum.bigEndian) { udpHeader.replaceSubrange(6..<8, with: $0) }
        
        response.append(ipHeader)
        response.append(udpHeader)
        response.append(data)
        
        packetFlow.writePackets([response], withProtocols: [NSNumber(value: AF_INET)])
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
    
    func close() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        connection?.cancel()
        connection = nil
    }
}

class TCPConnection {
    private let packetFlow: NEPacketTunnelFlow
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    
    private var clientSeq: UInt32 = 0
    private var clientAck: UInt32 = 0
    private var serverSeq: UInt32 = 0
    
    private var clientBuffer = Data()
    private var isTarget = false
    private var state: TCPState = .closed
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.warzone.tcp.connection")
    private var lastActivity: Date = Date()
    private var timeoutTimer: DispatchSourceTimer?
    
    var isConnected: Bool {
        return connection != nil
    }
    
    enum TCPState {
        case closed
        case listen
        case synReceived
        case established
        case closeWait
        case lastAck
        case finWait1
        case finWait2
        case timeWait
    }
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.serverSeq = arc4random()
    }
    
    func processPacket(_ packet: Data) {
        lastActivity = Date()
        guard packet.count >= 20 else { return }
        
        let ihl = Int((packet[0] & 0x0F)) * 4
        guard packet.count >= ihl + 20 else { return }
        
        let tcpOffset = ihl
        let dataOffset = Int((packet[tcpOffset + 12] >> 4) & 0x0F) * 4
        let payloadOffset = tcpOffset + dataOffset
        let payload = payloadOffset < packet.count ? packet.subdata(in: payloadOffset..<packet.count) : Data()
        
        let seqNum: UInt32 = packet.withUnsafeBytes { $0.load(fromByteOffset: tcpOffset + 4, as: UInt32.self) }.bigEndian
        let flags = packet[tcpOffset + 13]
        
        let syn = (flags & 0x02) != 0
        let ack = (flags & 0x10) != 0
        let fin = (flags & 0x01) != 0
        let rst = (flags & 0x04) != 0
        
        if rst {
            close()
            return
        }
        
        switch state {
        case .closed, .listen:
            if syn && !ack {
                clientSeq = seqNum
                state = .synReceived
                sendSYNACK()
            }
            
        case .synReceived:
            if ack {
                state = .established
                if !payload.isEmpty {
                    handleData(payload)
                }
            }
            
        case .established:
            let payloadLength = UInt32(payload.count)
            clientSeq = seqNum + payloadLength
            
            if !payload.isEmpty {
                handleData(payload)
                sendACK(ackNum: clientSeq)
            }
            
            if fin {
                state = .closeWait
                sendACK(ackNum: clientSeq + 1)
                closeServer()
                sendFIN(ackNum: clientSeq + 1)
            }
            
        case .closeWait:
            if ack {
                state = .lastAck
            }
            
        case .lastAck:
            if ack {
                state = .closed
            }
            
        case .finWait1:
            if ack {
                state = .finWait2
            }
            
        case .finWait2:
            if fin {
                state = .timeWait
                sendACK(ackNum: clientSeq + 1)
            }
            
        default:
            break
        }
    }
    
    private func handleData(_ data: Data) {
        clientBuffer.append(data)
        
        if !isTarget {
            if let request = String(data: clientBuffer, encoding: .utf8),
               request.contains("apis.map.qq.com") && request.contains("/ws/geocoder/v1") {
                isTarget = true
                NSLog("[TCPConnection] 检测到目标请求")
            }
        }
        
        if isTarget {
            sendFakeResponse()
        } else {
            if connection == nil {
                connectToServer()
            } else if let connection = connection, connection.state == .ready {
                sendToServer(data)
            }
        }
    }
    
    private func sendSYNACK() {
        let flags: UInt8 = 0x12
        let packet = buildTCPPacket(flags: flags, seqNum: serverSeq, ackNum: clientSeq + 1, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        serverSeq += 1
    }
    
    private func sendACK(ackNum: UInt32) {
        let flags: UInt8 = 0x10
        let packet = buildTCPPacket(flags: flags, seqNum: serverSeq, ackNum: ackNum, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }
    
    private func sendFIN(ackNum: UInt32) {
        let flags: UInt8 = 0x11
        let packet = buildTCPPacket(flags: flags, seqNum: serverSeq, ackNum: ackNum, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        serverSeq += 1
    }
    
    private func connectToServer() {
        lastActivity = Date()
        
        let host = NWEndpoint.Host(dstIP)
        let port = NWEndpoint.Port(rawValue: dstPort)!
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveInterval = 30
        
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        connection = NWConnection(host: host, port: port, using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.lastActivity = Date()
            
            switch state {
            case .ready:
                NSLog("[TCPConnection] 服务器连接就绪: \(self.dstIP):\(self.dstPort)")
                self.onServerConnected()
            case .failed(let error):
                NSLog("[TCPConnection] 服务器连接失败: \(error)")
                self.close()
            case .cancelled:
                NSLog("[TCPConnection] 连接已取消")
            default:
                break
            }
        }
        
        connection?.start(queue: queue)
        startTimeoutTimer()
    }
    
    private func onServerConnected() {
        if clientBuffer.count > 0 {
            sendToServer(clientBuffer)
            clientBuffer.removeAll()
        }
        receiveData()
    }
    
    private func sendToServer(_ data: Data) {
        lastActivity = Date()
        guard let connection = connection else { return }
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[TCPConnection] 发送失败: \(error)")
            }
        })
    }
    
    private func receiveData() {
        guard let connection = connection else { return }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            self.lastActivity = Date()
            
            if let error = error {
                NSLog("[TCPConnection] 接收失败: \(error)")
                self.close()
                return
            }
            
            if let data = data, !data.isEmpty {
                self.sendToClient(data)
            }
            
            if !isComplete {
                self.receiveData()
            } else {
                self.closeServer()
            }
        }
    }
    
    private func sendFakeResponse() {
        guard let location = LocationStore.shared.getSelectedLocation() else {
            sendRST()
            return
        }
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: location.adcode, regionName: location.name)
        let fakeResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\nContent-Length: \(fakeBody.count)\r\n\r\n\(fakeBody)"
        
        guard let responseData = fakeResponse.data(using: .utf8) else {
            sendRST()
            return
        }
        
        NSLog("[TCPConnection] 发送伪造响应: \(location.name)")
        sendToClient(responseData)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.sendFIN(ackNum: self.clientSeq)
        }
    }
    
    private func sendRST() {
        let flags: UInt8 = 0x04
        let packet = buildTCPPacket(flags: flags, seqNum: serverSeq, ackNum: clientSeq + 1, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        close()
    }
    
    private func sendToClient(_ data: Data) {
        let maxSize = 1400
        var offset = 0
        
        while offset < data.count {
            let size = min(maxSize, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + size)
            
            let flags: UInt8 = 0x18
            
            let packet = buildTCPPacket(flags: flags, seqNum: serverSeq, ackNum: clientSeq, payload: chunk)
            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
            
            serverSeq += UInt32(chunk.count)
            offset += size
        }
    }
    
    private func buildTCPPacket(flags: UInt8, seqNum: UInt32, ackNum: UInt32, payload: Data) -> Data {
        var packet = Data()
        
        let srcBytes = parseIP(dstIP)
        let dstBytes = parseIP(srcIP)
        
        var ipHeader = Data(count: 20)
        ipHeader[0] = 0x45
        ipHeader[1] = 0x00
        let ipLen = UInt16(20 + 20 + payload.count)
        withUnsafeBytes(of: ipLen.bigEndian) { ipHeader.replaceSubrange(2..<4, with: $0) }
        
        let identification = UInt16.random(in: 1...65535)
        withUnsafeBytes(of: identification.bigEndian) { ipHeader.replaceSubrange(4..<6, with: $0) }
        
        ipHeader[6] = 0x40
        ipHeader[8] = 64
        ipHeader[9] = 0x06
        
        ipHeader.replaceSubrange(12..<16, with: srcBytes)
        ipHeader.replaceSubrange(16..<20, with: dstBytes)
        
        let ipChecksum = calculateChecksum(ipHeader)
        withUnsafeBytes(of: ipChecksum.bigEndian) { ipHeader.replaceSubrange(10..<12, with: $0) }
        
        var tcpHeader = Data(count: 20)
        withUnsafeBytes(of: dstPort.bigEndian) { tcpHeader.replaceSubrange(0..<2, with: $0) }
        withUnsafeBytes(of: srcPort.bigEndian) { tcpHeader.replaceSubrange(2..<4, with: $0) }
        
        withUnsafeBytes(of: seqNum.bigEndian) { tcpHeader.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: ackNum.bigEndian) { tcpHeader.replaceSubrange(8..<12, with: $0) }
        
        tcpHeader[12] = 0x50
        tcpHeader[13] = flags
        
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
        
        packet.append(ipHeader)
        packet.append(tcpHeader)
        packet.append(payload)
        
        return packet
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
    
    private func closeServer() {
        connection?.cancel()
        connection = nil
    }
    
    private func startTimeoutTimer() {
        timeoutTimer = DispatchSource.makeTimerSource(queue: queue)
        timeoutTimer?.schedule(deadline: .now(), repeating: 30.0)
        timeoutTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            if Date().timeIntervalSince(self.lastActivity) > 300 {
                NSLog("[TCPConnection] 超时自动关闭: \(self.dstIP):\(self.dstPort)")
                self.close()
            }
        }
        timeoutTimer?.resume()
    }
    
    func close() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        closeServer()
        state = .closed
    }
}