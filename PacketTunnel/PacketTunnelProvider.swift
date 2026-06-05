import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var udpSessions: [String: UDPSession] = [:]
    private var tcpConnections: [String: TCPConnection] = [:]
    
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
            session.send(payload)
            return
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
            conn.processPacket(packet)
            return
        }
        
        let conn = TCPConnection(packetFlow: packetFlow, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
        tcpConnections[connKey] = conn
        conn.processPacket(packet)
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

class UDPSession {
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    private var socket: Int32 = -1
    
    init(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.packetFlow = packetFlow
    }
    
    func start() {
        socket = Darwin.socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP)
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")
        
        withUnsafePointer(to: &addr) { ptr in
            bind(socket, UnsafePointer(ptr), socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            self.receiveLoop()
        }
    }
    
    func send(_ data: Data) {
        guard socket != -1 else { return }
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = dstPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(dstIP)
        
        data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                sendto(socket, ptr.baseAddress, data.count, 0, UnsafePointer(addrPtr), socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
    }
    
    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
        
        while socket != -1 {
            let bytesRead = withUnsafeMutablePointer(to: &addr) { addrPtr in
                recvfrom(socket, &buffer, buffer.count, 0, UnsafeMutablePointer(addrPtr), &addrLen)
            }
            
            if bytesRead > 0 {
                let response = Data(bytes: buffer, count: bytesRead)
                sendResponse(response)
            } else {
                break
            }
        }
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
        ipHeader[6] = 0x40
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
        if socket != -1 {
            Darwin.close(socket)
            socket = -1
        }
    }
}

class TCPConnection {
    private let packetFlow: NEPacketTunnelFlow
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    private var socket: Int32 = -1
    private var clientBuffer = Data()
    private var isTarget = false
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
    }
    
    func processPacket(_ data: Data) {
        let tcpOffset = Int((data[0] & 0x0F)) * 4
        let flags = data[tcpOffset + 13]
        let dataOffset = Int((data[tcpOffset + 12] >> 4) & 0x0F) * 4
        let payloadOffset = tcpOffset + dataOffset
        let payload = payloadOffset < data.count ? data.subdata(in: payloadOffset..<data.count) : Data()
        
        if (flags & 0x02) != 0 {
            sendSYNACK()
            return
        }
        
        if (flags & 0x10) != 0 && socket == -1 {
            connectToServer()
        }
        
        if !payload.isEmpty {
            clientBuffer.append(payload)
            
            if !isTarget {
                if let request = String(data: clientBuffer, encoding: .utf8),
                   request.contains("apis.map.qq.com") && request.contains("/ws/geocoder/v1") {
                    isTarget = true
                }
            }
            
            if socket != -1 && !isTarget {
                sendToServer(payload)
            }
        }
        
        if (flags & 0x01) != 0 {
            close()
        }
    }
    
    private func sendSYNACK() {
        let packet = buildTCPPacket(flags: 0x12, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }
    
    private func connectToServer() {
        socket = Darwin.socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = dstPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(dstIP)
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            let result = withUnsafePointer(to: &addr) { addrPtr in
                connect(self.socket, UnsafePointer(addrPtr), socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
            
            if result == 0 {
                self.onConnected()
            } else {
                NSLog("[TCPConnection] 连接失败")
                self.close()
            }
        }
    }
    
    private func onConnected() {
        if clientBuffer.count > 0 {
            if isTarget {
                sendFakeResponse()
            } else {
                sendToServer(clientBuffer)
                clientBuffer.removeAll()
                startReceiveLoop()
            }
        }
    }
    
    private func sendToServer(_ data: Data) {
        guard socket != -1 else { return }
        
        data.withUnsafeBytes { ptr in
            _ = send(socket, ptr.baseAddress, data.count, 0)
        }
    }
    
    private func startReceiveLoop() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            var buffer = [UInt8](repeating: 0, count: 4096)
            
            while self.socket != -1 {
                let bytesRead = recv(self.socket, &buffer, buffer.count, 0)
                
                if bytesRead > 0 {
                    let response = Data(bytes: buffer, count: bytesRead)
                    self.sendToClient(response)
                } else {
                    break
                }
            }
            
            self.close()
        }
    }
    
    private func sendFakeResponse() {
        guard let location = LocationStore.shared.getSelectedLocation() else {
            startReceiveLoop()
            return
        }
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: location.adcode, regionName: location.name)
        let fakeResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\nContent-Length: \(fakeBody.count)\r\n\r\n\(fakeBody)"
        
        guard let responseData = fakeResponse.data(using: .utf8) else {
            startReceiveLoop()
            return
        }
        
        sendToClient(responseData)
        close()
    }
    
    private func sendToClient(_ data: Data) {
        let maxSize = 1400
        var offset = 0
        
        while offset < data.count {
            let size = min(maxSize, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + size)
            
            let flags: UInt8 = offset + size >= data.count ? 0x11 : 0x18
            let packet = buildTCPPacket(flags: flags, payload: chunk)
            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
            
            offset += size
        }
    }
    
    private func buildTCPPacket(flags: UInt8, payload: Data) -> Data {
        var packet = Data()
        
        let srcBytes = parseIP(dstIP)
        let dstBytes = parseIP(srcIP)
        
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
        withUnsafeBytes(of: dstPort.bigEndian) { tcpHeader.replaceSubrange(0..<2, with: $0) }
        withUnsafeBytes(of: srcPort.bigEndian) { tcpHeader.replaceSubrange(2..<4, with: $0) }
        
        let seqNum: UInt32 = arc4random() % 1000000
        withUnsafeBytes(of: seqNum.bigEndian) { tcpHeader.replaceSubrange(4..<8, with: $0) }
        
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
    
    func close() {
        if socket != -1 {
            shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
            socket = -1
        }
    }
}