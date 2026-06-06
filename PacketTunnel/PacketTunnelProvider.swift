import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    private var targetIPs: Set<String> = []
    private var tcpConnections: [String: TCPHandler] = [:]
    private let appGroupId = "group.com.warzone.changer"
    private let logQueue = DispatchQueue(label: "vpn.log")
    private var packetCount: Int = 0
    
    // 硬编码的 apis.map.qq.com 常见 IP
    private let fallbackIPs: Set<String> = [
        "119.147.13.124", "119.147.13.222", "119.147.14.89",
        "183.60.15.100", "183.60.60.100", "183.60.82.100",
        "123.151.76.100", "123.151.77.100",
        "61.151.229.100", "61.151.252.100"
    ]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 第一时间写入日志，不管App Group是否可用
        writeLog("[PacketTunnel] startTunnel 被调用")
        
        resolveTargetHost { [weak self] ips in
            guard let self = self else { return }
            
            self.targetIPs = ips.union(self.fallbackIPs)
            self.writeLog("[PacketTunnel] DNS解析: \(ips)")
            self.writeLog("[PacketTunnel] 最终目标IP共\(self.targetIPs.count)个: \(self.targetIPs)")
            
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "8.8.8.8")
            settings.mtu = 1400
            settings.ipv6Settings = nil
            
            let ipv4 = NEIPv4Settings(addresses: ["192.168.99.2"], subnetMasks: ["255.255.255.0"])
            
            var routes: [NEIPv4Route] = []
            for ip in self.targetIPs {
                routes.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
            }
            ipv4.includedRoutes = routes
            
            settings.ipv4Settings = ipv4
            
            let dns = NEDNSSettings(servers: ["223.5.5.5", "119.29.29.29"])
            dns.matchDomains = [""]
            settings.dnsSettings = dns
            
            self.setTunnelNetworkSettings(settings) { error in
                if let error = error {
                    self.writeLog("[PacketTunnel] 设置失败: \(error)")
                    completionHandler(error)
                    return
                }
                
                self.writeLog("[PacketTunnel] 隧道启动成功，路由数: \(routes.count)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startForwarding()
                    completionHandler(nil)
                }
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        writeLog("[PacketTunnel] 停止，共处理\(packetCount)个包")
        tcpConnections.values.forEach { $0.close() }
        tcpConnections.removeAll()
        completionHandler()
    }
    
    // MARK: - 日志（线程安全，双重写入）
    
    private func writeLog(_ msg: String) {
        let line = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)"
        NSLog(msg)
        
        logQueue.async { [weak self] in
            guard let self = self else { return }
            self.appendToLogFile(line)
            self.writeToUserDefaults(line)
        }
    }
    
    private func appendToLogFile(_ line: String) {
        // 写入 App Group 共享文件
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            NSLog("[Log] App Group 不可访问!")
            return
        }
        let fileURL = containerURL.appendingPathComponent("vpn_diag.log")
        
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            // 文件不存在，创建
            try? (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
    
    private func writeToUserDefaults(_ line: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            NSLog("[Log] UserDefaults 不可访问!")
            return
        }
        var existing = defaults.string(forKey: "vpn_logs") ?? ""
        existing += line + "\n"
        // 限制长度，保留最近 10000 字符
        if existing.count > 10000 {
            existing = String(existing.suffix(10000))
        }
        defaults.set(existing, forKey: "vpn_logs")
        defaults.synchronize()
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
            } else {
                self.writeLog("[PacketTunnel] DNS解析失败，status=\(status)")
            }
            
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
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        
        packetCount += 1
        
        if packetCount <= 20 {
            let protoName = proto == 6 ? "TCP" : (proto == 17 ? "UDP" : "\(proto)")
            writeLog("[Packet] #\(packetCount) \(protoName) -> \(dstIP)")
        }
        
        guard proto == 6 else { return }
        guard targetIPs.contains(dstIP) else { return }
        
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl + 20 else { return }
        
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
        let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
        
        writeLog("[命中] TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
        
        guard dstPort == 80 else {
            writeLog("[跳过] 非80端口: \(dstPort)")
            return
        }
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        if let conn = tcpConnections[key] {
            conn.processPacket(packet)
        } else {
            let conn = TCPHandler(
                packetFlow: packetFlow,
                srcIP: srcIP, srcPort: srcPort,
                dstIP: dstIP, dstPort: dstPort,
                targetHost: targetHost, targetPath: targetPath,
                logger: { [weak self] msg in self?.writeLog(msg) }
            )
            tcpConnections[key] = conn
            conn.processPacket(packet)
        }
        
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
    let logger: (String) -> Void
    
    var seq: UInt32 = arc4random()
    var ack: UInt32 = 0
    var state: State = .closed
    var httpBuffer = Data()
    var isClosed = false
    
    enum State { case closed, synRecv, established, intercepted }
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, targetHost: String, targetPath: String, logger: @escaping (String) -> Void) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.targetHost = targetHost
        self.targetPath = targetPath
        self.logger = logger
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
                logger("[TCP] SYN: \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
            }
            
        case .synRecv:
            if ackF {
                state = .established
                logger("[TCP] 握手完成: \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
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
        
        guard httpStr.contains("\r\n\r\n") || httpStr.contains("\n\n") else { return }
        
        logger("[HTTP] 请求:\n\(httpStr.prefix(500))")
        
        if httpStr.contains(targetHost) && httpStr.contains(targetPath) {
            logger("[HTTP] ✅ 命中目标! 返回假响应")
            state = .intercepted
            sendFakeResponse()
        } else {
            logger("[HTTP] ⚠️ 非目标请求，关闭连接")
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
        
        logger("[HTTP] 发送假响应 (\(responseData.count) bytes) 位置: \(name) (\(adcode))")
        
        let pkt = buildTCPPacket(flags: 0x18, payload: responseData)
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
        seq += UInt32(responseData.count)
        
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