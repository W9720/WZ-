import NetworkExtension
import Foundation
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var udpSessions: [String: UDPSession] = [:]
    private var tcpConnections: [String: TCPConnection] = [:]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 启动隧道")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
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
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "114.114.114.114"])
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 设置失败: \(error)")
                completionHandler(error)
                return
            }
            
            NSLog("[PacketTunnel] 设置成功，开始处理数据包")
            self.startReading()
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
    
    private func startReading() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            for index in 0..<packets.count {
                let proto = protocols[index].int32Value
                self.handlePacket(packets[index], protocolNumber: proto)
            }
            
            self.startReading()
        }
    }
    
    private func handlePacket(_ data: Data, protocolNumber: Int32) {
        guard data.count >= 20 else { return }
        
        let ihl = Int((data[0] & 0x0F)) * 4
        guard ihl >= 20 && data.count >= ihl else { return }
        
        let protocolType = data[9]
        let srcIP = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let dstIP = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"
        
        if protocolType == 17 {
            handleUDP(data, ipHeaderLen: ihl, srcIP: srcIP, dstIP: dstIP)
            return
        }
        
        guard protocolType == 6 else { return }
        
        guard data.count >= ihl + 20 else { return }
        
        let tcpOffset = ihl
        let srcPort = UInt16(data[tcpOffset]) << 8 | UInt16(data[tcpOffset + 1])
        let dstPort = UInt16(data[tcpOffset + 2]) << 8 | UInt16(data[tcpOffset + 3])
        
        let connKey = "\(srcIP):\(srcPort)"
        
        if dstPort == 80 || dstPort == 8080 {
            if let conn = tcpConnections[connKey] {
                conn.processPacket(data)
            } else {
                let conn = TCPConnection(packetFlow: packetFlow, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
                tcpConnections[connKey] = conn
                conn.processPacket(data)
            }
        } else {
            forwardTCPPacket(data, dstIP: dstIP, dstPort: dstPort)
        }
    }
    
    private func handleUDP(_ data: Data, ipHeaderLen: Int, srcIP: String, dstIP: String) {
        guard data.count >= ipHeaderLen + 8 else { return }
        
        let udpOffset = ipHeaderLen
        let srcPort = UInt16(data[udpOffset]) << 8 | UInt16(data[udpOffset + 1])
        let dstPort = UInt16(data[udpOffset + 2]) << 8 | UInt16(data[udpOffset + 3])
        let length = Int(UInt16(data[udpOffset + 4]) << 8 | UInt16(data[udpOffset + 5]))
        
        let payloadOffset = udpOffset + 8
        guard data.count >= payloadOffset else { return }
        let payload = data.subdata(in: payloadOffset..<min(data.count, payloadOffset + length - 8))
        
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
    
    private func forwardTCPPacket(_ data: Data, dstIP: String, dstPort: UInt16) {
        let connKey = "\(dstIP):\(dstPort)"
        
        if let conn = tcpConnections[connKey] {
            conn.forwardToServer(data)
        } else {
            let conn = TCPConnection(packetFlow: packetFlow, srcIP: "", srcPort: 0, dstIP: dstIP, dstPort: dstPort)
            tcpConnections[connKey] = conn
            conn.startForwarding(data)
        }
    }
}

class UDPSession {
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    private let socket: Int32
    
    init(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.packetFlow = packetFlow
        self.socket = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP)
    }
    
    func start() {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")
        
        bind(socket, &addr, socklen_t(MemoryLayout<sockaddr_in>.stride))
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            self.receiveLoop()
        }
    }
    
    func send(_ data: Data) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = dstPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(dstIP)
        
        data.withUnsafeBytes { ptr in
            sendto(socket, ptr.baseAddress, data.count, 0, &addr, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    
    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
        
        while true {
            let bytesRead = recvfrom(socket, &buffer, buffer.count, 0, &addr, &addrLen)
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
        
        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0x00)
        let ipLen = UInt16(20 + 8 + data.count)
        ipHeader.append(UInt8(ipLen >> 8))
        ipHeader.append(UInt8(ipLen & 0xFF))
        ipHeader.append(0x00)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x11)
        
        let ipChecksum = calculateChecksum(ipHeader)
        ipHeader.append(contentsOf: withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) })
        ipHeader.append(contentsOf: srcBytes)
        ipHeader.append(contentsOf: dstBytes)
        
        var udpHeader = Data()
        udpHeader.append(UInt8(dstPort >> 8))
        udpHeader.append(UInt8(dstPort & 0xFF))
        udpHeader.append(UInt8(srcPort >> 8))
        udpHeader.append(UInt8(srcPort & 0xFF))
        let udpLen = UInt16(8 + data.count)
        udpHeader.append(UInt8(udpLen >> 8))
        udpHeader.append(UInt8(udpLen & 0xFF))
        udpHeader.append(0x00)
        udpHeader.append(0x00)
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: srcBytes)
        pseudoHeader.append(contentsOf: dstBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x11)
        pseudoHeader.append(UInt8(udpLen >> 8))
        pseudoHeader.append(UInt8(udpLen & 0xFF))
        
        var checksumData = pseudoHeader
        checksumData.append(udpHeader)
        checksumData.append(data)
        
        let udpChecksum = calculateChecksum(checksumData)
        udpHeader.replaceSubrange(6..<8, with: withUnsafeBytes(of: udpChecksum.bigEndian) { Data($0) })
        
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
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
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
                if let request = HTTPParser.shared.parseRequest(clientBuffer) {
                    isTarget = LocationInjector.shared.isTargetRequest(host: request.host, path: request.path)
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
    
    func startForwarding(_ data: Data) {
        connectToServer()
        sendToServer(data)
    }
    
    func forwardToServer(_ data: Data) {
        sendToServer(data)
    }
    
    private func sendSYNACK() {
        let packet = buildTCPPacket(flags: 0x12, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }
    
    private func connectToServer() {
        socket = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = dstPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(dstIP)
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            let result = connect(self.socket, &addr, socklen_t(MemoryLayout<sockaddr_in>.stride))
            
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
        if socket != -1 {
            data.withUnsafeBytes { ptr in
                send(socket, ptr.baseAddress, data.count, 0)
            }
        }
    }
    
    private func startReceiveLoop() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            var buffer = [UInt8](repeating: 0, count: 4096)
            
            while true {
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
        
        sendToClient(fakeResponse.toData())
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
        
        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0x00)
        let ipLen = UInt16(20 + 20 + payload.count)
        ipHeader.append(UInt8(ipLen >> 8))
        ipHeader.append(UInt8(ipLen & 0xFF))
        ipHeader.append(0x00)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x06)
        
        let ipChecksum = calculateChecksum(ipHeader)
        ipHeader.append(contentsOf: withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) })
        ipHeader.append(contentsOf: srcBytes)
        ipHeader.append(contentsOf: dstBytes)
        
        let tcpHeader = Data(count: 20)
        var tcpHeaderBytes = [UInt8](tcpHeader)
        
        tcpHeaderBytes[0] = UInt8(dstPort >> 8)
        tcpHeaderBytes[1] = UInt8(dstPort & 0xFF)
        tcpHeaderBytes[2] = UInt8(srcPort >> 8)
        tcpHeaderBytes[3] = UInt8(srcPort & 0xFF)
        
        let seqNum: UInt32 = arc4random() % 1000000
        tcpHeaderBytes[4] = UInt8(seqNum >> 24)
        tcpHeaderBytes[5] = UInt8((seqNum >> 16) & 0xFF)
        tcpHeaderBytes[6] = UInt8((seqNum >> 8) & 0xFF)
        tcpHeaderBytes[7] = UInt8(seqNum & 0xFF)
        
        tcpHeaderBytes[8] = 0x50
        tcpHeaderBytes[9] = flags
        tcpHeaderBytes[10] = 0xFF
        tcpHeaderBytes[11] = 0xFF
        
        let tcpLen = UInt16(20 + payload.count)
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: srcBytes)
        pseudoHeader.append(contentsOf: dstBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x06)
        pseudoHeader.append(UInt8(tcpLen >> 8))
        pseudoHeader.append(UInt8(tcpLen & 0xFF))
        
        var checksumData = pseudoHeader
        checksumData.append(Data(tcpHeaderBytes))
        checksumData.append(payload)
        
        let tcpChecksum = calculateChecksum(checksumData)
        tcpHeaderBytes[16] = UInt8(tcpChecksum >> 8)
        tcpHeaderBytes[17] = UInt8(tcpChecksum & 0xFF)
        
        packet.append(ipHeader)
        packet.append(Data(tcpHeaderBytes))
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