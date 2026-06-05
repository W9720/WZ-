import NetworkExtension
import Foundation
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var udpSessions: [String: UDPSession] = [:]
    
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
        udpSessions.values.forEach { $0.cancel() }
        udpSessions.removeAll()
        completionHandler()
    }
    
    private func startReading() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            for (index, packet) in packets.enumerated() {
                let proto = (protocols[index] as! NSNumber).int32Value
                self.handlePacket(packet, protocolNumber: proto)
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
        
        if dstPort == 80 || dstPort == 8080 {
            let conn = TCPForwarder(packetFlow: packetFlow, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
            conn.forwardPacket(data)
        } else {
            forwardTCP(data, dstIP: dstIP, dstPort: dstPort)
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
    
    private func forwardTCP(_ data: Data, dstIP: String, dstPort: UInt16) {
        let host = NWEndpoint.Host(rawValue: dstIP)!
        let port = NWEndpoint.Port(rawValue: dstPort)!
        
        let conn = NWConnection(host: host, port: port, using: .tcp)
        
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: data, completion: .contentProcessed { _ in })
                
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, _, error in
                    if let data = data {
                        self.packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
                    }
                    conn.cancel()
                }
                
            case .failed, .cancelled:
                conn.cancel()
                
            default:
                break
            }
        }
        
        conn.start(queue: DispatchQueue.global())
    }
}

class UDPSession {
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    private var connection: NWConnection?
    
    init(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.packetFlow = packetFlow
    }
    
    func start() {
        let host = NWEndpoint.Host(rawValue: dstIP)!
        let port = NWEndpoint.Port(rawValue: dstPort)!
        
        connection = NWConnection(host: host, port: port, using: .udp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.connection?.receiveMessage { [weak self] data, _, _, error in
                    guard let self = self else { return }
                    
                    if let data = data {
                        self.sendResponse(data)
                    }
                    
                    if error == nil {
                        self.connection?.receiveMessage(completion: $0)
                    }
                }
                
            case .failed, .cancelled:
                break
                
            default:
                break
            }
        }
        
        connection?.start(queue: DispatchQueue.global())
    }
    
    func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
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
        
        packetFlow.writePackets([response], withProtocols: [AF_INET as NSNumber])
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
    
    func cancel() {
        connection?.cancel()
        connection = nil
    }
}

class TCPForwarder {
    private let packetFlow: NEPacketTunnelFlow
    private let srcIP: String
    private let srcPort: UInt16
    private let dstIP: String
    private let dstPort: UInt16
    private var connection: NWConnection?
    private var clientBuffer = Data()
    private var isTarget = false
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
    }
    
    func forwardPacket(_ data: Data) {
        let tcpOffset = Int((data[0] & 0x0F)) * 4
        let flags = data[tcpOffset + 13]
        let dataOffset = Int((data[tcpOffset + 12] >> 4) & 0x0F) * 4
        let payloadOffset = tcpOffset + dataOffset
        let payload = payloadOffset < data.count ? data.subdata(in: payloadOffset..<data.count) : Data()
        
        if (flags & 0x02) != 0 {
            sendSYNACK()
            return
        }
        
        if (flags & 0x10) != 0 && connection == nil {
            connectToServer()
        }
        
        if !payload.isEmpty {
            clientBuffer.append(payload)
            
            if !isTarget {
                if let request = HTTPParser.shared.parseRequest(clientBuffer) {
                    isTarget = LocationInjector.shared.isTargetRequest(host: request.host, path: request.path)
                }
            }
            
            if connection != nil && !isTarget {
                connection?.send(content: payload, completion: .contentProcessed({ _ in }))
            }
        }
    }
    
    private func sendSYNACK() {
        let packet = buildTCPPacket(flags: 0x12, payload: Data())
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
    }
    
    private func connectToServer() {
        let host = NWEndpoint.Host(rawValue: dstIP)!
        let port = NWEndpoint.Port(rawValue: dstPort)!
        
        connection = NWConnection(host: host, port: port, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                if self.clientBuffer.count > 0 {
                    if self.isTarget {
                        self.sendFakeResponse()
                    } else {
                        self.connection?.send(content: self.clientBuffer, completion: .contentProcessed({ _ in }))
                        self.startReceiving()
                    }
                }
                
            case .failed(let error):
                NSLog("[TCPForwarder] 连接失败: \(error)")
                
            case .cancelled:
                break
                
            default:
                break
            }
        }
        
        connection?.start(queue: DispatchQueue.global())
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, _, error in
            guard let self = self else { return }
            
            if let data = data {
                self.sendToClient(data)
            }
            
            if error == nil {
                self.startReceiving()
            }
        }
    }
    
    private func sendFakeResponse() {
        guard let location = LocationStore.shared.getSelectedLocation() else {
            startReceiving()
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
        
        connection?.cancel()
        connection = nil
    }
    
    private func sendToClient(_ data: Data) {
        let maxSize = 1400
        var offset = 0
        
        while offset < data.count {
            let size = min(maxSize, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + size)
            
            let flags: UInt8 = offset + size >= data.count ? 0x11 : 0x18
            let packet = buildTCPPacket(flags: flags, payload: chunk)
            packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
            
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
        
        var tcpHeader = Data()
        tcpHeader.append(UInt8(dstPort >> 8))
        tcpHeader.append(UInt8(dstPort & 0xFF))
        tcpHeader.append(UInt8(srcPort >> 8))
        tcpHeader.append(UInt8(srcPort & 0xFF))
        
        let seqNum: UInt32 = arc4random() % 1000000
        tcpHeader.append(UInt8(seqNum >> 24))
        tcpHeader.append(UInt8((seqNum >> 16) & 0xFF))
        tcpHeader.append(UInt8((seqNum >> 8) & 0xFF))
        tcpHeader.append(UInt8(seqNum & 0xFF))
        
        let ackNum: UInt32 = 0
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
        pseudoHeader.append(contentsOf: srcBytes)
        pseudoHeader.append(contentsOf: dstBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x06)
        let tcpLen = UInt16(tcpHeader.count + payload.count)
        pseudoHeader.append(UInt8(tcpLen >> 8))
        pseudoHeader.append(UInt8(tcpLen & 0xFF))
        
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