import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    private var targetIPs: Set<String> = []
    private var tcpConnections: [String: TCPHandler] = [:]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 启动隧道")
        
        resolveTargetHost { [weak self] ips in
            guard let self = self else { return }
            self.targetIPs = ips
            NSLog("[PacketTunnel] 目标IP列表: \(ips)")
            
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "8.8.8.8")
            settings.mtu = 1400
            settings.ipv6Settings = nil
            
            let ipv4 = NEIPv4Settings(addresses: ["192.168.99.2"], subnetMasks: ["255.255.255.0"])
            
            // 只路由目标IP的流量，其他流量走默认网络
            var routes: [NEIPv4Route] = []
            for ip in ips {
                routes.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
            }
            if routes.isEmpty {
                // 解析失败时用假IP，避免全局路由
                routes.append(NEIPv4Route(destinationAddress: "1.2.3.4", subnetMask: "255.255.255.255"))
            }
            ipv4.includedRoutes = routes
            
            settings.ipv4Settings = ipv4
            
            let dns = NEDNSSettings(servers: ["223.5.5.5", "119.29.29.29"])
            dns.matchDomains = [""]
            settings.dnsSettings = dns
            
            self.setTunnelNetworkSettings(settings) { error in
                if let error = error {
                    NSLog("[PacketTunnel] 设置网络失败: \(error)")
                    completionHandler(error)
                    return
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startForwarding()
                    NSLog("[PacketTunnel] 隧道启动成功")
                    completionHandler(nil)
                }
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tcpConnections.values.forEach { $0.close() }
        tcpConnections.removeAll()
        completionHandler()
    }
    
    // MARK: - DNS 解析
    
    private func resolveTargetHost(completion: @escaping (Set<String>) -> Void) {
        DispatchQueue.global().async {
            var ips = Set<String>()
            
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(self.targetHost, nil, &hints, &result)
            
            if status == 0 {
                var ptr = result
                while ptr != nil {
                    if let addr = ptr?.pointee.ai_addr {
                        let sockaddr_in_ptr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
                        var addr_in = sockaddr_in_ptr.pointee.sin_addr
                        if let ipCStr = inet_ntoa(addr_in) {
                            let ip = String(cString: ipCStr)
                            ips.insert(ip)
                        }
                    }
                    ptr = ptr?.pointee.ai_next
                }
                freeaddrinfo(result)
            }
            
            NSLog("[PacketTunnel] DNS解析 \(self.targetHost) → \(ips)")
            completion(ips)
        }
    }
    
    // MARK: - 数据包转发
    
    private func startForwarding() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            
            for packet in packets {
                self.processPacket(packet)
            }
            
            self.startForwarding()
        }
    }
    
    private func processPacket(_ packet: Data) {
        guard packet.count >= 20 else { return }
        let version = (packet[0] >> 4) & 0x0F
        guard version == 4 else { return }
        
        let proto = packet[9]
        guard proto == 6 else { return } // 只处理 TCP
        
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        guard targetIPs.contains(dstIP) else { return }
        
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl + 20 else { return }
        
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
        let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
        
        guard dstPort == 80 else { return }
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        if let conn = tcpConnections[key] {
            conn.processPacket(packet)
        } else {
            let conn = TCPHandler(
                packetFlow: packetFlow,
                srcIP: srcIP, srcPort: srcPort,
                dstIP: dstIP, dstPort: dstPort,
                targetHost: targetHost, targetPath: targetPath
            )
            tcpConnections[key] = conn
            conn.processPacket(packet)
        }
        
        // 清理已关闭的连接
        tcpConnections = tcpConnections.filter { !$0.value.isClosed }
    }
}

// MARK: - TCP 连接处理器

class TCPHandler {
    let packetFlow: NEPacketTunnelFlow
    let srcIP: String
    let srcPort: UInt16
    let dstIP: String
    let dstPort: UInt16
    let targetHost: String
    let targetPath: String
    
    var seq: UInt32 = arc4random()
    var ack: UInt32 = 0
    var state: State = .closed
    var httpBuffer = Data()
    var isClosed = false
    
    enum State { case closed, synRecv, established, intercepted }
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, targetHost: String, targetPath: String) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.targetHost = targetHost
        self.targetPath = targetPath
    }
    
    func processPacket(_ pkt: Data) {
        guard pkt.count >= 40 else { return }
        let ipHdrLen = Int(pkt[0] & 0x0F) * 4
        guard pkt.count >= ipHdrLen + 20 else { return }
        
        let seqNum = pkt.subdata(in: ipHdrLen+4..<ipHdrLen+8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let flags = pkt[ipHdrLen + 13]
        let tcpHdrLen = Int((pkt[ipHdrLen + 12] >> 4) & 0x0F) * 4
        let payloadOffset = ipHdrLen + tcpHdrLen
        let payload = pkt.count > payloadOffset ? pkt.subdata(in: payloadOffset..<pkt.count) : Data()
        
        let syn = (flags & 0x02) != 0
        let ackF = (flags & 0x10) != 0
        let fin = (flags & 0x01) != 0
        let rst = (flags & 0x04) != 0
        
        switch state {
        case .closed:
            if syn {
                ack = seqNum + 1
                state = .synRecv
                sendSynAck()
            }
            
        case .synRecv:
            if ackF {
                state = .established
                NSLog("[TCP] 三次握手完成: \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
            }
            
        case .established:
            if fin {
                sendFinAck(seqNum: seqNum)
                state = .closed
                isClosed = true
            } else if rst {
                state = .closed
                isClosed = true
            } else if !payload.isEmpty {
                ack = seqNum + UInt32(payload.count)
                sendACK()
                handleHTTPData(payload)
            }
            
        case .intercepted:
            if fin || rst {
                state = .closed
                isClosed = true
            }
        }
    }
    
    private func handleHTTPData(_ data: Data) {
        httpBuffer.append(data)
        
        guard let httpStr = String(data: httpBuffer, encoding: .utf8) else { return }
        
        // 等待 HTTP 请求头完整
        guard httpStr.contains("\r\n\r\n") || httpStr.contains("\n\n") else { return }
        
        NSLog("[TCP] HTTP请求:\n\(httpStr.prefix(500))")
        
        if httpStr.contains(targetHost) && httpStr.contains(targetPath) {
            NSLog("[TCP] ✅ 命中目标! 返回假响应")
            state = .intercepted
            sendFakeResponse()
        } else {
            // 不应该出现：我们只路由了目标IP
            NSLog("[TCP] ⚠️ 非目标请求，关闭连接")
            sendRST()
            state = .closed
            isClosed = true
        }
    }
    
    // MARK: - TCP 发包
    
    private func sendSynAck() {
        let pkt = buildTCPPacket(flags: 0x12, payload: Data())
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
        seq += 1
    }
    
    private func sendACK() {
        let pkt = buildTCPPacket(flags: 0x10, payload: Data())
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
    }
    
    private func sendFinAck(seqNum: UInt32) {
        ack = seqNum + 1
        let pkt = buildTCPPacket(flags: 0x11, payload: Data())
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
        seq += 1
    }
    
    private func sendRST() {
        let pkt = buildTCPPacket(flags: 0x04, payload: Data())
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
    }
    
    private func sendFakeResponse() {
        let location = LocationStore.shared.getSelectedLocation()
        let adcode = location?.adcode ?? "110101"
        let name = location?.name ?? "东城区"
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: adcode, regionName: name)
        let bodyData = fakeBody.data(using: .utf8) ?? Data()
        
        let response = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        
        NSLog("[TCP] 发送假响应 (\(responseData.count) bytes)")
        
        let pkt = buildTCPPacket(flags: 0x18, payload: responseData)
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
        seq += UInt32(responseData.count)
        
        // 延迟发送 FIN
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let finPkt = self.buildTCPPacket(flags: 0x19, payload: Data())
            self.packetFlow.writePackets([finPkt], withProtocols: [AF_INET as NSNumber])
            self.seq += 1
            self.state = .closed
            self.isClosed = true
        }
    }
    
    private func buildTCPPacket(flags: UInt8, payload: Data) -> Data {
        let src = parseIP(dstIP)
        let dst = parseIP(srcIP)
        let totalLen = 20 + 20 + payload.count
        
        var ip = Data(count: 20)
        ip[0] = 0x45
        ip[1] = 0x00
        withUnsafeBytes(of: UInt16(totalLen).bigEndian) { ip.replaceSubrange(2..<4, with: $0) }
        let ident = UInt16.random(in: 1...65535)
        withUnsafeBytes(of: ident.bigEndian) { ip.replaceSubrange(4..<6, with: $0) }
        ip[8] = 64
        ip[9] = 6
        ip.replaceSubrange(12..<16, with: src)
        ip.replaceSubrange(16..<20, with: dst)
        
        // IP checksum
        let ipCheck = checksum(ip)
        withUnsafeBytes(of: ipCheck.bigEndian) { ip.replaceSubrange(10..<12, with: $0) }
        
        var tcp = Data(count: 20)
        withUnsafeBytes(of: dstPort.bigEndian) { tcp.replaceSubrange(0..<2, with: $0) }
        withUnsafeBytes(of: srcPort.bigEndian) { tcp.replaceSubrange(2..<4, with: $0) }
        withUnsafeBytes(of: seq.bigEndian) { tcp.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: ack.bigEndian) { tcp.replaceSubrange(8..<12, with: $0) }
        tcp[12] = 0x50
        tcp[13] = flags
        let window: UInt16 = 65535
        withUnsafeBytes(of: window.bigEndian) { tcp.replaceSubrange(14..<16, with: $0) }
        
        // TCP checksum (pseudo header + tcp header + payload)
        var pseudo = Data()
        pseudo.append(contentsOf: src)
        pseudo.append(contentsOf: dst)
        pseudo.append(0)
        pseudo.append(6)
        let tcpSegLen = UInt16(20 + payload.count)
        withUnsafeBytes(of: tcpSegLen.bigEndian) { pseudo.replaceSubrange(12..<14, with: $0) }
        
        var tcpWithPayload = Data()
        tcpWithPayload.append(tcp)
        tcpWithPayload.append(payload)
        
        var checkData = Data()
        checkData.append(pseudo)
        checkData.append(tcpWithPayload)
        
        let tcpCheck = checksum(checkData)
        withUnsafeBytes(of: tcpCheck.bigEndian) { tcp.replaceSubrange(16..<18, with: $0) }
        
        var full = Data()
        full.append(ip)
        full.append(tcp)
        full.append(payload)
        
        return full
    }
    
    private func parseIP(_ s: String) -> [UInt8] {
        let parts = s.components(separatedBy: ".")
        guard parts.count == 4 else { return [0, 0, 0, 0] }
        return parts.compactMap { UInt8($0) }
    }
    
    private func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        let count = data.count
        while i < count {
            let v = i + 1 < count ? UInt32(data[i]) << 8 | UInt32(data[i + 1]) : UInt32(data[i]) << 8
            sum += v
            i += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
    
    func close() {
        isClosed = true
    }
}