import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    private var targetIPv4s: Set<String> = []
    private var targetIPv6s: Set<String> = []
    private var tcpConnections: [String: TCPHandler] = [:]
    private let appGroupId = "group.com.warzone.changer"
    private let logQueue = DispatchQueue(label: "vpn.log")
    private var packetCount: Int = 0
    
    private let fallbackIPs: Set<String> = [
        "119.147.13.124", "119.147.13.222", "119.147.14.89",
        "183.60.15.100", "183.60.60.100", "183.60.82.100",
        "123.151.76.100", "123.151.77.100",
        "61.151.229.100", "61.151.252.100",
        "116.130.223.114", "116.130.224.140",
        "123.151.48.124", "123.151.49.230",
    ]
    
    private let fallbackIPv6s: Set<String> = [
        "2408:8711:10:1000::19",
        "2408:8711:10:105::2e",
        "240e:928:1400:1003::2f",
        "240e:928:1400:105::23",
        "240e:928:1400:1000::19",
        "240e:928:1400:105::2e",
    ]
    
    private let additionalDomains: [String] = [
        "apis.map.qq.com",
        "st.map.qq.com",
        "sv.map.qq.com",
        "c.map.qq.com",
        "p.map.qq.com",
        "ditu.qq.com",
        "map.qq.com",
    ]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        clearLogs()
        writeLog("[PacketTunnel] startTunnel 被调用")
        
        resolveAllDomains { [weak self] ipv4s, ipv6s in
            guard let self = self else { return }
            
            self.targetIPv4s = ipv4s.union(self.fallbackIPs)
            self.targetIPv6s = ipv6s.union(self.fallbackIPv6s)
            self.writeLog("[PacketTunnel] DNS解析 IPv4: \(ipv4s), IPv6: \(ipv6s)")
            self.writeLog("[PacketTunnel] 目标IPv4共\(self.targetIPv4s.count)个: \(self.targetIPv4s)")
            self.writeLog("[PacketTunnel] 目标IPv6共\(self.targetIPv6s.count)个: \(self.targetIPv6s)")
            
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "8.8.8.8")
            settings.mtu = 1400
            
            let ipv4 = NEIPv4Settings(addresses: ["192.168.99.2"], subnetMasks: ["255.255.255.0"])
            var ipv4Routes: [NEIPv4Route] = []
            for ip in self.targetIPv4s {
                ipv4Routes.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
            }
            ipv4.includedRoutes = ipv4Routes
            settings.ipv4Settings = ipv4
            
            if !self.targetIPv6s.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: ["fd00:192:168:99::2"], networkPrefixLengths: [64])
                var ipv6Routes: [NEIPv6Route] = []
                for ip in self.targetIPv6s {
                    ipv6Routes.append(NEIPv6Route(destinationAddress: ip, networkPrefixLength: 128))
                }
                ipv6.includedRoutes = ipv6Routes
                settings.ipv6Settings = ipv6
            }
            
            let dns = NEDNSSettings(servers: ["223.5.5.5", "119.29.29.29"])
            dns.matchDomains = additionalDomains + ["qq.com", "map.qq.com", "apis.map.qq.com"]
            settings.dnsSettings = dns
            
            self.setTunnelNetworkSettings(settings) { error in
                if let error = error {
                    self.writeLog("[PacketTunnel] 设置失败: \(error)")
                    completionHandler(error)
                    return
                }
                
                self.writeLog("[PacketTunnel] 隧道启动成功，IPv4路由数: \(ipv4Routes.count), IPv6路由数: \(self.targetIPv6s.count)")
                
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
        flushLogs()
        completionHandler()
    }
    
    private func clearLogs() {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.removeObject(forKey: "vpn_logs")
            defaults.synchronize()
        }
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let fileURL = containerURL.appendingPathComponent("vpn_diag.log")
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
    
    private func flushLogs() {
        logQueue.sync {}
    }
    
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
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return }
        let fileURL = containerURL.appendingPathComponent("vpn_diag.log")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) { handle.write(data) }
            handle.closeFile()
        } else {
            try? (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
    
    private func writeToUserDefaults(_ line: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        var existing = defaults.string(forKey: "vpn_logs") ?? ""
        existing += line + "\n"
        if existing.count > 10000 { existing = String(existing.suffix(10000)) }
        defaults.set(existing, forKey: "vpn_logs")
        defaults.synchronize()
    }
    
    private func resolveAllDomains(completion: @escaping (Set<String>, Set<String>) -> Void) {
        let group = DispatchGroup()
        var allIPv4s = Set<String>()
        var allIPv6s = Set<String>()
        let lock = NSLock()
        
        for domain in additionalDomains {
            group.enter()
            resolveDomain(domain) { ipv4s, ipv6s in
                lock.lock()
                allIPv4s.formUnion(ipv4s)
                allIPv6s.formUnion(ipv6s)
                lock.unlock()
                self.writeLog("[DNS] \(domain) IPv4: \(ipv4s), IPv6: \(ipv6s)")
                group.leave()
            }
        }
        
        group.notify(queue: .global()) {
            completion(allIPv4s, allIPv6s)
        }
    }
    
    private func resolveDomain(_ domain: String, completion: @escaping (Set<String>, Set<String>) -> Void) {
        DispatchQueue.global().async {
            var ipv4s = Set<String>()
            var ipv6s = Set<String>()
            
            var hints4 = addrinfo()
            hints4.ai_family = AF_INET
            hints4.ai_socktype = SOCK_STREAM
            var result4: UnsafeMutablePointer<addrinfo>?
            let status4 = getaddrinfo(domain, nil, &hints4, &result4)
            if status4 == 0 {
                var ptr = result4
                while ptr != nil {
                    if let addr = ptr?.pointee.ai_addr {
                        let sockaddr_in_ptr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
                        let addr_in = sockaddr_in_ptr.pointee.sin_addr
                        if let ipCStr = inet_ntoa(addr_in) {
                            ipv4s.insert(String(cString: ipCStr))
                        }
                    }
                    ptr = ptr?.pointee.ai_next
                }
                freeaddrinfo(result4)
            }
            
            var hints6 = addrinfo()
            hints6.ai_family = AF_INET6
            hints6.ai_socktype = SOCK_STREAM
            var result6: UnsafeMutablePointer<addrinfo>?
            let status6 = getaddrinfo(domain, nil, &hints6, &result6)
            if status6 == 0 {
                var ptr = result6
                while ptr != nil {
                    if let addr = ptr?.pointee.ai_addr {
                        let sockaddr_in6_ptr = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }
                        var addr_in6 = sockaddr_in6_ptr.pointee.sin6_addr
                        let ipStr = self.in6AddrToString(&addr_in6)
                        if ipStr.contains(".") {
                            ipv4s.insert(ipStr)
                        } else {
                            ipv6s.insert(ipStr)
                        }
                    }
                    ptr = ptr?.pointee.ai_next
                }
                freeaddrinfo(result6)
            }
            
            completion(ipv4s, ipv6s)
        }
    }
    
    private func startForwarding() {
        writeLog("[PacketTunnel] startForwarding 被调用")
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            if packets.count > 0 {
                writeLog("[PacketTunnel] 收到 \(packets.count) 个数据包")
            }
            for packet in packets { self.processPacket(packet) }
            self.startForwarding()
        }
    }
    
    private func processPacket(_ packet: Data) {
        guard packet.count >= 20 else { return }
        let version = (packet[0] >> 4) & 0x0F
        
        if version == 4 {
            let proto = packet[9]
            let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
            let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
            
            packetCount += 1
            
            if proto == 6 {
                let ihl = Int(packet[0] & 0x0F) * 4
                if packet.count >= ihl + 14 {
                    let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
                    let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
                    let flags = packet[ihl + 13]
                    let syn = (flags & 0x02) != 0
                    let ack = (flags & 0x10) != 0
                    let fin = (flags & 0x01) != 0
                    let rst = (flags & 0x04) != 0
                    
                    if dstPort == 80 || packetCount <= 50 {
                        let flagStr = [syn ? "SYN" : "", ack ? "ACK" : "", fin ? "FIN" : "", rst ? "RST" : ""].filter { !$0.isEmpty }.joined(separator: ",")
                        writeLog("[TCP IPv4] #\(packetCount) \(srcIP):\(srcPort) -> \(dstIP):\(dstPort) flags=\(flagStr)")
                    }
                }
            } else if proto == 17 {
                if packet.count >= 28 {
                    let dstPort = UInt16(packet[22]) << 8 | UInt16(packet[23])
                    if dstPort == 53 {
                        writeLog("[DNS IPv4] #\(packetCount) UDP \(srcIP):\(packet[20]) -> \(dstIP):53")
                    }
                }
            }
            
            processIPv4Packet(packet)
        } else if version == 6 {
            processIPv6Packet(packet)
        }
    }
    
    private func processIPv4Packet(_ packet: Data) {
        guard packet.count >= 20 else { return }
        
        let proto = packet[9]
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        
        guard proto == 6 else { return }
        guard targetIPv4s.contains(dstIP) else { return }
        
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl + 20 else { return }
        
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
        let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
        
        guard dstPort == 80 else {
            writeLog("[跳过] 非80端口: \(dstPort)")
            return
        }
        
        writeLog("[命中 IPv4] TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        handleTCPConnection(key: key, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, isIPv6: false, packet: packet)
    }
    
    private func processIPv6Packet(_ packet: Data) {
        guard packet.count >= 40 else { return }
        
        let proto = packet[6]
        let dstIP = ipv6ToString(packet, offset: 24)
        let srcIP = ipv6ToString(packet, offset: 8)
        
        packetCount += 1
        
        if proto == 6 {
            if packet.count >= 54 {
                let srcPort = UInt16(packet[40]) << 8 | UInt16(packet[41])
                let dstPort = UInt16(packet[42]) << 8 | UInt16(packet[43])
                
                if (dstPort == 80 || packetCount <= 50) && !dstIP.hasPrefix("ff02") {
                    writeLog("[TCP IPv6] #\(packetCount) \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                }
            }
        }
        
        guard proto == 6 else { return }
        
        let isMappedIPv4 = dstIP.contains(".")
        let targetList = isMappedIPv4 ? targetIPv4s : targetIPv6s
        guard targetList.contains(dstIP) else { return }
        
        let srcPort = UInt16(packet[40]) << 8 | UInt16(packet[41])
        let dstPort = UInt16(packet[42]) << 8 | UInt16(packet[43])
        
        guard dstPort == 80 else {
            writeLog("[跳过] 非80端口: \(dstPort)")
            return
        }
        
        writeLog("[命中 IPv6] TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        handleTCPConnection(key: key, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, isIPv6: !isMappedIPv4, packet: packet)
    }
    
    private func ipv6ToString(_ data: Data, offset: Int) -> String {
        var addr = in6_addr()
        let subData = data.subdata(in: offset..<offset+16)
        _ = withUnsafeMutableBytes(of: &addr) { bufPtr in
            subData.copyBytes(to: bufPtr)
        }
        return in6AddrToString(&addr)
    }
    
    private func in6AddrToString(_ addr: UnsafePointer<in6_addr>) -> String {
        let bytes = UnsafeRawPointer(addr).assumingMemoryBound(to: UInt8.self)
        if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0 &&
           bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 0 &&
           bytes[8] == 0 && bytes[9] == 0 && bytes[10] == 0xff && bytes[11] == 0xff {
            return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let cString = inet_ntop(AF_INET6, addr, &buffer, socklen_t(buffer.count))
        if let cString = cString {
            return String(cString: cString)
        }
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let val = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            parts.append(String(format: "%x", val))
        }
        return parts.joined(separator: ":")
    }
    
    private func handleTCPConnection(key: String, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, isIPv6: Bool, packet: Data) {
        if let conn = tcpConnections[key] {
            conn.processPacket(packet)
        } else {
            let conn = TCPHandler(
                packetFlow: packetFlow,
                srcIP: srcIP, srcPort: srcPort,
                dstIP: dstIP, dstPort: dstPort,
                targetHost: targetHost, targetPath: targetPath,
                isIPv6: isIPv6,
                logger: { [weak self] msg in self?.writeLog(msg) }
            )
            tcpConnections[key] = conn
            conn.processPacket(packet)
        }
        
        tcpConnections = tcpConnections.filter { !$0.value.isClosed }
    }
}

class TCPHandler {
    let packetFlow: NEPacketTunnelFlow
    let srcIP: String
    let srcPort: UInt16
    let dstIP: String
    let dstPort: UInt16
    let targetHost: String
    let targetPath: String
    let isIPv6: Bool
    let logger: (String) -> Void
    
    var seq: UInt32 = arc4random()
    var ack: UInt32 = 0
    var state: State = .closed
    var httpBuffer = Data()
    var isClosed = false
    
    private func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += UInt32(UInt16(data[i]) << 8 | UInt16(data[i+1]))
            i += 2
        }
        if i < data.count {
            sum += UInt32(data[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }
    
    enum State { case closed, synRecv, established, intercepted }
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, targetHost: String, targetPath: String, isIPv6: Bool, logger: @escaping (String) -> Void) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.targetHost = targetHost
        self.targetPath = targetPath
        self.isIPv6 = isIPv6
        self.logger = logger
    }
    
    func processPacket(_ pkt: Data) {
        let (seqNum, flags, _, payload) = parsePacket(pkt)
        guard seqNum != nil else { return }
        
        let syn = (flags & 0x02) != 0
        let ackF = (flags & 0x10) != 0
        let fin = (flags & 0x01) != 0
        let rst = (flags & 0x04) != 0
        
        switch state {
        case .closed:
            if syn {
                ack = seqNum! + 1
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
                sendFinAck(seqNum: seqNum!)
                state = .closed; isClosed = true
            } else if rst {
                state = .closed; isClosed = true
            } else if !payload.isEmpty {
                ack = seqNum! + UInt32(payload.count)
                sendACK()
                handleHTTPData(payload)
            }
            
        case .intercepted:
            if fin || rst {
                state = .closed; isClosed = true
            }
        }
    }
    
    private func parsePacket(_ pkt: Data) -> (seqNum: UInt32?, flags: UInt8, tcpHdrLen: Int, payload: Data) {
        if isIPv6 {
            guard pkt.count >= 40 else { return (nil, 0, 0, Data()) }
            let seqNum = pkt.subdata(in: 40+4..<40+8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let flags = pkt[40 + 13]
            let tcpHdrLen = Int((pkt[40 + 12] >> 4) & 0x0F) * 4
            let payloadOffset = 40 + tcpHdrLen
            let payload = pkt.count > payloadOffset ? pkt.subdata(in: payloadOffset..<pkt.count) : Data()
            return (seqNum, flags, tcpHdrLen, payload)
        } else {
            guard pkt.count >= 20 else { return (nil, 0, 0, Data()) }
            let ipHdrLen = Int(pkt[0] & 0x0F) * 4
            guard pkt.count >= ipHdrLen + 20 else { return (nil, 0, 0, Data()) }
            let seqNum = pkt.subdata(in: ipHdrLen+4..<ipHdrLen+8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let flags = pkt[ipHdrLen + 13]
            let tcpHdrLen = Int((pkt[ipHdrLen + 12] >> 4) & 0x0F) * 4
            let payloadOffset = ipHdrLen + tcpHdrLen
            let payload = pkt.count > payloadOffset ? pkt.subdata(in: payloadOffset..<pkt.count) : Data()
            return (seqNum, flags, tcpHdrLen, payload)
        }
    }
    
    private func handleHTTPData(_ data: Data) {
        httpBuffer.append(data)
        
        guard let httpStr = String(data: httpBuffer, encoding: .utf8) else {
            logger("[HTTP] 无法解码UTF8，长度: \(httpBuffer.count)")
            return
        }
        
        guard httpStr.contains("\r\n\r\n") || httpStr.contains("\n\n") else {
            logger("[HTTP] 等待更多数据... (已缓冲 \(httpBuffer.count) bytes)")
            return
        }
        
        let requestPreview = String(httpStr.prefix(500))
        logger("[HTTP] 收到请求: \(requestPreview.replacingOccurrences(of: "\r\n", with: " | "))")
        
        let lowercased = httpStr.lowercased()
        let isMapRequest = lowercased.contains("map.qq.com") || lowercased.contains("ditu.qq.com") || lowercased.contains("apis.map.qq.com")
        
        if isMapRequest {
            logger("[HTTP] ✅ 检测到腾讯地图域名请求")
        }
        
        var apiType = LocationInjector.shared.detectAPIType(httpStr)
        logger("[HTTP] API类型: \(apiType)")
        
        if apiType == .unknown && isMapRequest {
            if lowercased.contains("/ws/") || lowercased.contains("geocoder") || lowercased.contains("location") {
                apiType = .reverseGeocoder
                logger("[HTTP] ✅ 泛化匹配成功")
            }
        }
        
        if apiType != .unknown {
            logger("[HTTP] ✅ 命中目标API! 返回假响应")
            state = .intercepted
            sendFakeResponse(apiType: apiType)
        } else if isMapRequest {
            logger("[HTTP] ✅ 地图域名请求，返回假响应")
            state = .intercepted
            sendFakeResponse(apiType: .reverseGeocoder)
        } else {
            logger("[HTTP] ⚠️ 非目标请求，关闭连接")
            sendRST()
            state = .closed; isClosed = true
        }
    }
    
    private func sendSynAck() {
        let pkt = buildTCPPacket(flags: 0x12, payload: Data())
        let proto = isIPv6 ? AF_INET6 : AF_INET
        packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
        seq += 1
    }
    
    private func sendACK() {
        let pkt = buildTCPPacket(flags: 0x10, payload: Data())
        let proto = isIPv6 ? AF_INET6 : AF_INET
        packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
    }
    
    private func sendFinAck(seqNum: UInt32) {
        ack = seqNum + 1
        let pkt = buildTCPPacket(flags: 0x11, payload: Data())
        let proto = isIPv6 ? AF_INET6 : AF_INET
        packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
        seq += 1
    }
    
    private func sendRST() {
        let pkt = buildTCPPacket(flags: 0x04, payload: Data())
        let proto = isIPv6 ? AF_INET6 : AF_INET
        packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
    }
    
    func close() {
        if state != .closed {
            sendRST()
            state = .closed
            isClosed = true
        }
    }
    
    private func sendFakeResponse(apiType: LocationInjector.APIType = .reverseGeocoder) {
        let location = LocationStore.shared.getSelectedLocation()
        
        let adcode = location?.adcode ?? "460100"
        let name = location?.name ?? "海口市"
        
        logger("[拦截] ✅ 位置: \(name) (adcode: \(adcode))")
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(for: apiType, adcode: adcode, regionName: name)
        let bodyData = fakeBody.data(using: .utf8) ?? Data()
        
        logger("[拦截] 假响应体长度: \(bodyData.count) bytes")
        
        let response = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        
        logger("[HTTP] ✅ 发送假响应 (\(responseData.count) bytes)")
        
        let proto = isIPv6 ? AF_INET6 : AF_INET
        let pkt = buildTCPPacket(flags: 0x18, payload: responseData)
        packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
        seq += UInt32(responseData.count)
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let finPkt = self.buildTCPPacket(flags: 0x11, payload: Data())
            self.packetFlow.writePackets([finPkt], withProtocols: [proto as NSNumber])
            self.seq += 1
            self.state = .closed
            self.isClosed = true
            logger("[TCP] 连接关闭")
        }
    }
    
    private func buildTCPPacket(flags: UInt8, payload: Data) -> Data {
        if isIPv6 {
            return buildIPv6TCPPacket(flags: flags, payload: payload)
        } else {
            return buildIPv4TCPPacket(flags: flags, payload: payload)
        }
    }
    
    private func buildIPv4TCPPacket(flags: UInt8, payload: Data) -> Data {
        let src = parseIPv4(dstIP)
        let dst = parseIPv4(srcIP)
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
        pseudo.append(src)
        pseudo.append(dst)
        pseudo.append(0x00)
        pseudo.append(0x06)
        let tcpLen = UInt16(20 + payload.count)
        withUnsafeBytes(of: tcpLen.bigEndian) { pseudo.append(contentsOf: $0) }
        pseudo.append(tcp)
        pseudo.append(payload)
        
        let tcpCheck = checksum(pseudo)
        withUnsafeBytes(of: tcpCheck.bigEndian) { tcp.replaceSubrange(16..<18, with: $0) }
        
        var result = ip
        result.append(tcp)
        result.append(payload)
        return result
    }
    
    private func buildIPv6TCPPacket(flags: UInt8, payload: Data) -> Data {
        let totalLen = 40 + 20 + payload.count
        
        var ip = Data(count: 40)
        ip[0] = 0x60
        ip[6] = 6
        withUnsafeBytes(of: UInt16(totalLen - 40).bigEndian) { ip.replaceSubrange(4..<6, with: $0) }
        ip[7] = 64
        
        let src = parseIPv6(dstIP)
        let dst = parseIPv6(srcIP)
        ip.replaceSubrange(8..<24, with: src)
        ip.replaceSubrange(24..<40, with: dst)
        
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
        pseudo.append(src)
        pseudo.append(dst)
        let tcpLen = UInt32(20 + payload.count)
        withUnsafeBytes(of: tcpLen.bigEndian) { pseudo.append(contentsOf: $0) }
        pseudo.append(0x00)
        pseudo.append(0x06)
        withUnsafeBytes(of: UInt16(20 + payload.count).bigEndian) { pseudo.append(contentsOf: $0) }
        pseudo.append(tcp)
        pseudo.append(payload)
        
        let tcpCheck = checksum(pseudo)
        withUnsafeBytes(of: tcpCheck.bigEndian) { tcp.replaceSubrange(16..<18, with: $0) }
        
        var result = ip
        result.append(tcp)
        result.append(payload)
        return result
    }
    
    private func parseIPv4(_ ip: String) -> Data {
        let parts = ip.components(separatedBy: ".").compactMap { UInt8($0) }
        return Data(parts)
    }
    
    private func parseIPv6(_ ip: String) -> Data {
        var addr = in6_addr()
        _ = ip.withCString { inet_pton(AF_INET6, $0, &addr) }
        return withUnsafeBytes(of: addr) { Data($0) }
    }
}