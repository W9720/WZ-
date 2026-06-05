import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var packetFlowManager: PacketFlowManager?
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 开始启动隧道...")
        
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
                NSLog("[PacketTunnel] 设置网络配置失败: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            NSLog("[PacketTunnel] 网络配置设置成功")
            
            self.packetFlowManager = PacketFlowManager(packetFlow: self.packetFlow)
            self.packetFlowManager?.startProcessing()
            
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止隧道，原因: \(reason.rawValue)")
        packetFlowManager?.stop()
        completionHandler()
    }
}

class PacketFlowManager {
    private let packetFlow: NEPacketTunnelFlow
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    
    private var connections: [String: ProxyConnection] = [:]
    
    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }
    
    func startProcessing() {
        readPackets()
    }
    
    func stop() {
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            for (index, packet) in packets.enumerated() {
                let protocolNumber = (protocols[index] as! NSNumber).int32Value
                self.processPacket(packet, protocolNumber: protocolNumber)
            }
            
            self.readPackets()
        }
    }
    
    private func processPacket(_ data: Data, protocolNumber: Int32) {
        guard data.count >= 20 else { return }
        
        let versionAndIHL = data[0]
        let ihl = Int(versionAndIHL & 0x0F) * 4
        
        guard ihl >= 20 && data.count >= ihl else { return }
        
        let protocolType = data[9]
        
        let sourceIP = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let destIP = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"
        
        if protocolType == 17 {
            handleUDP(data, ipHeaderLength: ihl, sourceIP: sourceIP, destIP: destIP)
            return
        }
        
        guard protocolType == 6 else { return }
        
        guard data.count >= ihl + 20 else { return }
        
        let tcpOffset = ihl
        let sourcePort = UInt16(data[tcpOffset]) << 8 | UInt16(data[tcpOffset + 1])
        let destPort = UInt16(data[tcpOffset + 2]) << 8 | UInt16(data[tcpOffset + 3])
        
        if destPort != 80 && destPort != 8080 {
            forwardPacket(data)
            return
        }
        
        let connectionKey = "\(sourceIP):\(sourcePort)-\(destIP):\(destPort)"
        
        var connection = connections[connectionKey]
        
        if connection == nil {
            connection = ProxyConnection(
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destIP: destIP,
                destPort: destPort,
                packetFlow: packetFlow,
                targetHost: targetHost,
                targetPath: targetPath
            )
            connections[connectionKey] = connection
        }
        
        guard let conn = connection else { return }
        
        let flags = data[tcpOffset + 13]
        let dataOffset = Int((data[tcpOffset + 12] >> 4) & 0x0F) * 4
        let payloadOffset = ihl + dataOffset
        let payload = payloadOffset < data.count ? data.subdata(in: payloadOffset..<data.count) : Data()
        
        conn.processPacket(flags: flags, payload: payload)
        
        if (flags & 0x01) != 0 || (flags & 0x04) != 0 {
            conn.cancel()
            connections.removeValue(forKey: connectionKey)
        }
    }
    
    private func handleUDP(_ data: Data, ipHeaderLength: Int, sourceIP: String, destIP: String) {
        forwardPacket(data)
    }
    
    private func forwardPacket(_ data: Data) {
        packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
    }
}

class ProxyConnection {
    private let sourceIP: String
    private let sourcePort: UInt16
    private let destIP: String
    private let destPort: UInt16
    private let packetFlow: NEPacketTunnelFlow
    private let targetHost: String
    private let targetPath: String
    
    private var serverConnection: NWConnection?
    private var isConnected = false
    private var requestBuffer = Data()
    private var isTargetRequest = false
    private var responseSent = false
    
    init(sourceIP: String, sourcePort: UInt16, destIP: String, destPort: UInt16, packetFlow: NEPacketTunnelFlow, targetHost: String, targetPath: String) {
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destIP = destIP
        self.destPort = destPort
        self.packetFlow = packetFlow
        self.targetHost = targetHost
        self.targetPath = targetPath
    }
    
    func processPacket(flags: UInt8, payload: Data) {
        if (flags & 0x02) != 0 {
            sendSYNACK()
            return
        }
        
        if (flags & 0x10) != 0 && !isConnected {
            connectToServer()
            return
        }
        
        if !payload.isEmpty {
            requestBuffer.append(payload)
            
            if !isTargetRequest {
                if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                    isTargetRequest = LocationInjector.shared.isTargetRequest(host: request.host, path: request.path)
                    if isTargetRequest {
                        NSLog("[ProxyConnection] 检测到目标请求")
                    }
                }
            }
            
            if isConnected && serverConnection != nil && !isTargetRequest {
                serverConnection?.send(content: payload, completion: .contentProcessed({ _ in }))
            }
        }
    }
    
    private func sendSYNACK() {
        let synAckPacket = buildTCPPacket(flags: 0x12, payload: Data())
        packetFlow.writePackets([synAckPacket], withProtocols: [AF_INET as NSNumber])
    }
    
    private func connectToServer() {
        let host = NWEndpoint.Host(rawValue: destIP)!
        let port = NWEndpoint.Port(rawValue: destPort)!
        
        serverConnection = NWConnection(host: host, port: port, using: .tcp)
        
        serverConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.isConnected = true
                NSLog("[ProxyConnection] 服务器连接就绪")
                
                if self.requestBuffer.count > 0 {
                    if self.isTargetRequest {
                        self.sendFakeResponse()
                    } else {
                        self.serverConnection?.send(content: self.requestBuffer, completion: .contentProcessed({ _ in }))
                        self.startReceiving()
                    }
                }
                
            case .failed(let error):
                NSLog("[ProxyConnection] 服务器连接失败: \(error)")
                self.sendRST()
                
            case .cancelled:
                break
                
            default:
                break
            }
        }
        
        serverConnection?.start(queue: DispatchQueue.global())
    }
    
    private func startReceiving() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, _, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ProxyConnection] 接收失败: \(error)")
                return
            }
            
            if let data = data {
                self.sendToClient(data)
            }
            
            self.startReceiving()
        }
    }
    
    private func sendFakeResponse() {
        guard let location = LocationStore.shared.getSelectedLocation() else {
            NSLog("[ProxyConnection] 未选择位置")
            startReceiving()
            return
        }
        
        NSLog("[ProxyConnection] 发送伪造响应")
        
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
        
        let responseData = fakeResponse.toData()
        sendToClient(responseData)
        
        responseSent = true
        
        if serverConnection != nil {
            serverConnection?.cancel()
            serverConnection = nil
        }
    }
    
    private func sendToClient(_ data: Data) {
        let maxSize = 1400
        var offset = 0
        
        while offset < data.count {
            let size = min(maxSize, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + size)
            
            let flags: UInt8 = 0x18
            let packet = buildTCPPacket(flags: flags, payload: chunk)
            packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
            
            offset += size
        }
    }
    
    private func sendRST() {
        let rstPacket = buildTCPPacket(flags: 0x04, payload: Data())
        packetFlow.writePackets([rstPacket], withProtocols: [AF_INET as NSNumber])
    }
    
    private func buildTCPPacket(flags: UInt8, payload: Data) -> Data {
        var packet = Data()
        
        let srcIPBytes = parseIP(destIP)
        let dstIPBytes = parseIP(sourceIP)
        
        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0x00)
        let ipTotalLength = UInt16(20 + 20 + payload.count)
        ipHeader.append(UInt8(ipTotalLength >> 8))
        ipHeader.append(UInt8(ipTotalLength & 0xFF))
        ipHeader.append(0x00)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x06)
        
        let ipChecksum = calculateChecksum(ipHeader)
        ipHeader.append(contentsOf: withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) })
        ipHeader.append(contentsOf: srcIPBytes)
        ipHeader.append(contentsOf: dstIPBytes)
        
        var tcpHeader = Data()
        tcpHeader.append(UInt8(destPort >> 8))
        tcpHeader.append(UInt8(destPort & 0xFF))
        tcpHeader.append(UInt8(sourcePort >> 8))
        tcpHeader.append(UInt8(sourcePort & 0xFF))
        
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
        serverConnection?.cancel()
        serverConnection = nil
    }
}