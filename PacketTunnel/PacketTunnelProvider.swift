import NetworkExtension
import Foundation
import Security

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    private var targetIPv4s: Set<String> = []
    private var targetIPv6s: Set<String> = []
    private var tcpConnections: [String: TCPHandler] = [:]
    private let appGroupId = "group.com.warzone.changer"
    private let logQueue = DispatchQueue(label: "vpn.log")
    private var packetCount: Int = 0
    private var tlsIdentity: (SecIdentity, SecCertificate)?
    private var tlsCertData: Data?         // X.509 DER 证书数据
    private var tlsPrivateKey: SecKey?     // RSA 私钥
    
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
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        clearLogs()
        writeLog("[PacketTunnel] startTunnel 被调用")
        
        resolveTargetHost { [weak self] ipv4s, ipv6s in
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
            dns.matchDomains = ["qq.com", "map.qq.com", "apis.map.qq.com"]
            settings.dnsSettings = dns
            
            self.setTunnelNetworkSettings(settings) { error in
                if let error = error {
                    self.writeLog("[PacketTunnel] 设置失败: \(error)")
                    completionHandler(error)
                    return
                }
                
                self.writeLog("[PacketTunnel] 隧道启动成功，IPv4路由数: \(ipv4Routes.count), IPv6路由数: \(self.targetIPv6s.count)")
                
                DispatchQueue.global().async {
                    self.writeLog("[PacketTunnel] 预生成TLS证书...")
                    _ = self.getOrCreateTLS()
                    self.writeLog("[PacketTunnel] TLS证书准备完成")
                }
                
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
    
    // MARK: - 日志
    
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
    
    // MARK: - DNS
    
    private func resolveTargetHost(completion: @escaping (Set<String>, Set<String>) -> Void) {
        DispatchQueue.global().async {
            var ipv4s = Set<String>()
            var ipv6s = Set<String>()
            
            // 解析 IPv4
            var hints4 = addrinfo()
            hints4.ai_family = AF_INET
            hints4.ai_socktype = SOCK_STREAM
            var result4: UnsafeMutablePointer<addrinfo>?
            let status4 = getaddrinfo(self.targetHost, nil, &hints4, &result4)
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
            
            // 解析 IPv6
            var hints6 = addrinfo()
            hints6.ai_family = AF_INET6
            hints6.ai_socktype = SOCK_STREAM
            var result6: UnsafeMutablePointer<addrinfo>?
            let status6 = getaddrinfo(self.targetHost, nil, &hints6, &result6)
            if status6 == 0 {
                var ptr = result6
                while ptr != nil {
                    if let addr = ptr?.pointee.ai_addr {
                        let sockaddr_in6_ptr = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }
                        var addr_in6 = sockaddr_in6_ptr.pointee.sin6_addr
                        var buf = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if inet_ntop(AF_INET6, &addr_in6, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                            ipv6s.insert(String(cString: buf))
                        }
                    }
                    ptr = ptr?.pointee.ai_next
                }
                freeaddrinfo(result6)
            }
            
            if status4 != 0 && status6 != 0 {
                self.writeLog("[PacketTunnel] DNS解析失败，status4=\(status4), status6=\(status6)")
            }
            
            completion(ipv4s, ipv6s)
        }
    }
    
    // MARK: - 转发
    
    private func startForwarding() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
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
                if packet.count >= ihl + 4 {
                    let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
                    let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
                    
                    if dstPort == 443 {
                        writeLog("[TCP 443] #\(packetCount) \(srcIP):\(srcPort) -> \(dstIP):\(dstPort) (目标列表: \(targetIPv4s.contains(dstIP)))")
                    } else if packetCount <= 500 {
                        writeLog("[Packet IPv4] #\(packetCount) TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                    }
                }
            } else if proto == 17 {
                if packet.count >= 28 {
                    let srcPort = UInt16(packet[20]) << 8 | UInt16(packet[21])
                    let dstPort = UInt16(packet[22]) << 8 | UInt16(packet[23])
                    
                    if dstPort == 53 {
                        writeLog("[DNS] #\(packetCount) UDP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                    } else if packetCount <= 500 {
                        writeLog("[Packet IPv4] #\(packetCount) UDP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                    }
                }
            } else if packetCount <= 500 {
                writeLog("[Packet IPv4] #\(packetCount) proto=\(proto) \(srcIP) -> \(dstIP)")
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
        
        if !targetIPv4s.contains(dstIP) {
            return
        }
        
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl + 20 else { return }
        
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
        let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
        
        writeLog("[命中 IPv4] TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
        
        guard dstPort == 80 || dstPort == 443 else {
            writeLog("[跳过] 非80/443端口: \(dstPort)")
            return
        }
        
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
            if packet.count >= 44 {
                let srcPort = UInt16(packet[40]) << 8 | UInt16(packet[41])
                let dstPort = UInt16(packet[42]) << 8 | UInt16(packet[43])
                
                if dstPort == 443 {
                    writeLog("[TCP 443 IPv6] #\(packetCount) \(srcIP):\(srcPort) -> \(dstIP):\(dstPort) (目标列表: \(targetIPv6s.contains(dstIP)))")
                } else if packetCount <= 500 && !dstIP.hasPrefix("ff02") {
                    writeLog("[Packet IPv6] #\(packetCount) TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                }
            }
        } else if proto == 17 {
            if packet.count >= 48 {
                let srcPort = UInt16(packet[40]) << 8 | UInt16(packet[41])
                let dstPort = UInt16(packet[42]) << 8 | UInt16(packet[43])
                
                if dstPort == 53 {
                    writeLog("[DNS IPv6] #\(packetCount) UDP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                } else if packetCount <= 500 && !dstIP.hasPrefix("ff02") {
                    writeLog("[Packet IPv6] #\(packetCount) UDP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                }
            }
        } else if packetCount <= 500 && !dstIP.hasPrefix("ff02") {
            writeLog("[Packet IPv6] #\(packetCount) proto=\(proto) \(srcIP) -> \(dstIP)")
        }
        
        guard proto == 6 else { return }
        
        guard targetIPv6s.contains(dstIP) else { return }
        
        let srcPort = UInt16(packet[40]) << 8 | UInt16(packet[41])
        let dstPort = UInt16(packet[42]) << 8 | UInt16(packet[43])
        
        writeLog("[命中 IPv6] TCP \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
        
        guard dstPort == 80 || dstPort == 443 else {
            writeLog("[跳过] 非80/443端口: \(dstPort)")
            return
        }
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        handleTCPConnection(key: key, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, isIPv6: true, packet: packet)
    }
    
    private func ipv6ToString(_ data: Data, offset: Int) -> String {
        var addr = in6_addr()
        let subData = data.subdata(in: offset..<offset+16)
        _ = withUnsafeMutableBytes(of: &addr) { bufPtr in
            subData.copyBytes(to: bufPtr)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let cString = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        if let cString = cString {
            return String(cString: cString)
        }
        var parts: [String] = []
        for i in stride(from: offset, to: offset + 16, by: 2) {
            let val = UInt16(data[i]) << 8 | UInt16(data[i + 1])
            parts.append(String(format: "%x", val))
        }
        return parts.joined(separator: ":")
    }
    
    private func normalizeIPv6(_ ip: String) -> String {
        var addr = in6_addr()
        if ip.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let cString = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
            if let cString = cString {
                return String(cString: cString)
            }
        }
        return ip.lowercased()
    }
    
    private func handleTCPConnection(key: String, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, isIPv6: Bool, packet: Data) {
        if let conn = tcpConnections[key] {
            conn.processPacket(packet)
        } else {
            let isHTTPS = (dstPort == 443)
            let tls = isHTTPS ? getOrCreateTLS() : nil
            let conn = TCPHandler(
                packetFlow: packetFlow,
                srcIP: srcIP, srcPort: srcPort,
                dstIP: dstIP, dstPort: dstPort,
                targetHost: targetHost, targetPath: targetPath,
                isHTTPS: isHTTPS,
                isIPv6: isIPv6,
                tlsPrivateKey: tls?.privateKey,
                tlsCertData: tls?.certData,
                logger: { [weak self] msg in self?.writeLog(msg) }
            )
            tcpConnections[key] = conn
            conn.processPacket(packet)
        }
        
        tcpConnections = tcpConnections.filter { !$0.value.isClosed }
    }
    
    private func sendRSTForPacket(_ packet: Data) {
        let ihl = Int(packet[0] & 0x0F) * 4
        guard packet.count >= ihl + 20 else { return }
        
        let srcIP = packet.subdata(in: 12..<16)
        let dstIP = packet.subdata(in: 16..<20)
        let srcPort = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl+1])
        let dstPort = UInt16(packet[ihl+2]) << 8 | UInt16(packet[ihl+3])
        let seqNum = packet.subdata(in: ihl+4..<ihl+8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        var rst = Data()
        // IP头
        rst.append(contentsOf: [0x45, 0x00, 0x00, 0x28])
        let id = UInt16.random(in: 1...65535)
        rst.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF)])
        rst.append(contentsOf: [0x00, 0x00])
        rst.append(0x40) // TTL=64
        rst.append(0x06) // TCP
        rst.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        rst.append(dstIP)
        rst.append(srcIP)
        
        // TCP头
        rst.append(contentsOf: [UInt8(dstPort >> 8), UInt8(dstPort & 0xFF)])
        rst.append(contentsOf: [UInt8(srcPort >> 8), UInt8(srcPort & 0xFF)])
        rst.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // seq=0
        let ackNum = seqNum + 1
        rst.append(contentsOf: [UInt8((ackNum >> 24) & 0xFF), UInt8((ackNum >> 16) & 0xFF), UInt8((ackNum >> 8) & 0xFF), UInt8(ackNum & 0xFF)])
        rst.append(0x50) // data offset=5
        rst.append(0x14) // RST+ACK
        rst.append(contentsOf: [0x00, 0x00]) // window=0
        rst.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        rst.append(contentsOf: [0x00, 0x00]) // urgent=0
        
        // TCP checksum
        var pseudo = Data()
        pseudo.append(dstIP)
        pseudo.append(srcIP)
        pseudo.append(0x00)
        pseudo.append(0x06)
        let tcpLen = UInt16(20)
        pseudo.append(contentsOf: [UInt8(tcpLen >> 8), UInt8(tcpLen & 0xFF)])
        pseudo.append(rst.subdata(in: 20..<40))
        let tcpChecksum = checksum(pseudo)
        rst[36] = UInt8(tcpChecksum >> 8)
        rst[37] = UInt8(tcpChecksum & 0xFF)
        
        // IP checksum
        let ipChecksum = checksum(rst.subdata(in: 0..<20))
        rst[10] = UInt8(ipChecksum >> 8)
        rst[11] = UInt8(ipChecksum & 0xFF)
        
        packetFlow.writePackets([rst], withProtocols: [AF_INET as NSNumber])
    }
    
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
    
    private func getOrCreateTLS() -> (privateKey: SecKey, certData: Data)? {
        if let key = tlsPrivateKey, let cert = tlsCertData { return (key, cert) }
        writeLog("[TLS] 开始生成自签名证书...")
        let result = createTLSCertificate()
        if let (key, certData) = result {
            tlsPrivateKey = key
            tlsCertData = certData
            writeLog("[TLS] ✅ 自签名证书生成成功")
            return (key, certData)
        } else {
            writeLog("[TLS] ❌ 自签名证书生成失败!")
            return nil
        }
    }
    
    private func createTLSCertificate() -> (SecKey, Data)? {
        writeLog("[TLS] 开始从预生成数据加载密钥和证书...")
        
        guard let (privateKey, certData) = loadPreGeneratedTLS() else {
            writeLog("[TLS] 预生成数据加载失败")
            return nil
        }
        writeLog("[TLS] 预生成数据加载成功，密钥: \(preGeneratedPrivateKey.count) bytes, 证书: \(preGeneratedCert.count) bytes")
        return (privateKey, certData)
    }
    
    private func loadPreGeneratedTLS() -> (SecKey, Data)? {
        let keyData = Data(preGeneratedPrivateKey)
        let certData = Data(preGeneratedCert)
        
        let keyDict: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyData as CFData, keyDict as CFDictionary, &error) else {
            writeLog("[TLS] 从数据创建私钥失败: \(error?.takeRetainedValue().localizedDescription ?? "?")")
            return nil
        }
        
        return (privateKey, certData)
    }
    
    private func buildX509Certificate(publicKeyData: Data, privateKey: SecKey) -> Data? {
        // DER 编码辅助
        func derLen(_ len: Int) -> Data {
            if len < 128 { return Data([UInt8(len)]) }
            if len < 256 { return Data([0x81, UInt8(len)]) }
            return Data([0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
        }
        func seq(_ d: Data) -> Data { Data([0x30]) + derLen(d.count) + d }
        func oid(_ bytes: [UInt8]) -> Data {
            var r = Data([bytes[0] * 40 + bytes[1]])
            for i in 2..<bytes.count {
                var val = Int(bytes[i])
                var enc: [UInt8] = [UInt8(val & 0x7F)]
                val >>= 7
                while val > 0 { enc.append(UInt8(val & 0x7F) | 0x80); val >>= 7 }
                r.append(contentsOf: enc.reversed())
            }
            return Data([0x06]) + derLen(r.count) + r
        }
        func utcTime(_ d: Date) -> Data {
            let f = DateFormatter(); f.dateFormat = "yyMMddHHmmss'Z'"
            f.timeZone = TimeZone(secondsFromGMT: 0)
            let s = f.string(from: d).data(using: .ascii)!
            return Data([0x17]) + derLen(s.count) + s
        }
        func printableStr(_ s: String) -> Data {
            let d = s.data(using: .ascii)!
            return Data([0x0C]) + derLen(d.count) + d
        }
        
        // 签名算法: sha256WithRSAEncryption (1.2.840.113549.1.1.11)
        let sigAlgOID = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
        let sigAlg = seq(sigAlgOID + Data([0x05, 0x00]))
        
        // Issuer & Subject
        let cnOID = oid([0x55, 0x04, 0x03]) // commonName
        let cn = printableStr("apis.map.qq.com")
        let rdn = seq(cnOID + cn)
        let name = seq(Data([0x31]) + derLen(rdn.count) + rdn) // SET { SEQUENCE { ... } }
        
        // Validity
        let now = Date()
        let tenYears = Date().addingTimeInterval(10 * 365 * 24 * 3600)
        let validity = seq(utcTime(now) + utcTime(tenYears))
        
        // SubjectPublicKeyInfo
        let rsaOID = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let spkiAlg = seq(rsaOID + Data([0x05, 0x00]))
        let pubKeyBits = Data([0x00]) + publicKeyData
        let pubKeyBS = Data([0x03]) + derLen(pubKeyBits.count) + pubKeyBits
        let spki = seq(spkiAlg + pubKeyBS)
        
        // TBSCertificate
        let version = Data([0xA0, 0x03, 0x02, 0x01, 0x02])
        let serial = Data([0x02, 0x01, 0x01])
        let tbsInner = version + serial + sigAlg + name + validity + name + spki
        let tbs = seq(tbsInner)
        
        // 签名
        writeLog("[TLS] 开始证书签名...")
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            let errMsg = error?.takeRetainedValue().localizedDescription ?? "?"
            writeLog("[TLS] 证书签名失败: \(errMsg)")
            return nil
        }
        writeLog("[TLS] 证书签名成功")
        let sigBS = Data([0x03]) + derLen(sig.count + 1) + Data([0x00]) + sig
        
        // 完整证书
        let certInner = tbsInner + sigAlg + sigBS
        return Data([0x30, 0x82]) + UInt16(certInner.count).bigEndian.data + certInner
    }
}

// MARK: - UInt16 → Data 扩展

extension UInt16 {
    var data: Data {
        var v = self.bigEndian
        return Data(bytes: &v, count: 2)
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
    let isHTTPS: Bool
    let isIPv6: Bool
    let tlsPrivateKey: SecKey?
    let tlsCertData: Data?
    let logger: (String) -> Void
    
    var seq: UInt32 = arc4random()
    var ack: UInt32 = 0
    var state: State = .closed
    var httpBuffer = Data()
    var isClosed = false
    
    // 纯 Swift TLS 引擎（不依赖 keychain）
    private var tlsEngine: TLSEngine?
    private var tlsInBuffer = Data()
    private var tlsHandshakeDone = false
    
    enum State { case closed, synRecv, established, tlsHandshake, tlsEstablished, intercepted }
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, targetHost: String, targetPath: String, isHTTPS: Bool, isIPv6: Bool, tlsPrivateKey: SecKey?, tlsCertData: Data?, logger: @escaping (String) -> Void) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.targetHost = targetHost
        self.targetPath = targetPath
        self.isHTTPS = isHTTPS
        self.isIPv6 = isIPv6
        self.tlsPrivateKey = tlsPrivateKey
        self.tlsCertData = tlsCertData
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
                state = isHTTPS ? .tlsHandshake : .established
                logger("[TCP] 握手完成: \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                
                if isHTTPS {
                    initTLSEngine()
                }
            }
            
        case .tlsHandshake:
            if !payload.isEmpty {
                ack = seqNum! + UInt32(payload.count)
                sendACK()
                feedTLSData(payload)
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
            
        case .tlsEstablished:
            if fin {
                sendFinAck(seqNum: seqNum!)
                state = .closed; isClosed = true
            } else if rst {
                state = .closed; isClosed = true
            } else if !payload.isEmpty {
                ack = seqNum! + UInt32(payload.count)
                sendACK()
                feedTLSPayload(payload)
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
    
    // MARK: - TLS (纯 Swift TLSEngine)
    
    private func initTLSEngine() {
        guard let privateKey = tlsPrivateKey, let certData = tlsCertData else {
            logger("[TLS] 无证书，关闭连接")
            sendRST()
            state = .closed; isClosed = true
            return
        }
        logger("[TLS] 证书数据长度: \(certData.count)")
        
        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            logger("[TLS] 创建证书对象失败")
            sendRST()
            state = .closed; isClosed = true
            return
        }
        
        guard let engine = TLSEngine(privateKey: privateKey, certificate: certificate, certData: certData) else {
            logger("[TLS] 创建TLS引擎失败")
            sendRST()
            state = .closed; isClosed = true
            return
        }
        
        tlsEngine = engine
        logger("[TLS] ✅ TLS引擎已初始化")
    }
    
    private func feedTLSData(_ data: Data) {
        guard let engine = tlsEngine else { return }
        
        tlsInBuffer.append(data)
        logger("[TLS] 收到客户端数据 \(data.count) bytes, 缓冲 \(tlsInBuffer.count) bytes")
        
        let result = engine.process(tlsInBuffer)
        tlsInBuffer.removeAll()
        
        let proto = isIPv6 ? AF_INET6 : AF_INET
        
        // 发送输出
        if !engine.outputBuffer.isEmpty {
            let out = engine.outputBuffer
            engine.outputBuffer.removeAll()
            let pkt = buildTCPPacket(flags: 0x18, payload: out)
            packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
            seq += UInt32(out.count)
            logger("[TLS] 发送握手数据 \(out.count) bytes")
        }
        
        switch result {
        case .handshakeDone:
            if !engine.outputBuffer.isEmpty {
                let out = engine.outputBuffer
                engine.outputBuffer.removeAll()
                let pkt = buildTCPPacket(flags: 0x18, payload: out)
                packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
                seq += UInt32(out.count)
                logger("[TLS] 发送握手数据 \(out.count) bytes")
            }
            if !tlsHandshakeDone {
                tlsHandshakeDone = true
                state = .tlsEstablished
                logger("[TLS] ✅ 握手完成! 等待HTTP请求")
            }
        case .needMoreData:
            logger("[TLS] 等待更多客户端数据...")
        case .appData(let plaintext):
            if !tlsHandshakeDone {
                tlsHandshakeDone = true
                state = .tlsEstablished
                logger("[TLS] ✅ 握手完成! 收到应用数据")
            }
            handleHTTPData(plaintext)
        case .error(let msg):
            logger("[TLS] ❌ 错误: \(msg)")
            sendRST()
            state = .closed; isClosed = true
        }
    }
    
    private func feedTLSPayload(_ data: Data) {
        guard let engine = tlsEngine, tlsHandshakeDone else { return }
        
        tlsInBuffer.append(data)
        let result = engine.process(tlsInBuffer)
        tlsInBuffer.removeAll()
        
        switch result {
        case .appData(let plaintext):
            handleHTTPData(plaintext)
        case .error(let msg):
            logger("[TLS] ❌ 解密错误: \(msg)")
            sendRST()
            state = .closed; isClosed = true
        default:
            break
        }
    }
    
    // MARK: - HTTP
    
    private func handleHTTPData(_ data: Data) {
        httpBuffer.append(data)
        
        guard let httpStr = String(data: httpBuffer, encoding: .utf8) else { 
            logger("[HTTP] 无法解码UTF8")
            return 
        }
        guard httpStr.contains("\r\n\r\n") || httpStr.contains("\n\n") else { 
            logger("[HTTP] 等待更多数据... (已缓冲 \(httpBuffer.count) bytes)")
            return 
        }
        
        logger("[HTTP] 请求:\n\(httpStr.prefix(500))")
        
        if httpStr.contains(targetHost) && httpStr.contains(targetPath) {
            logger("[HTTP] ✅ 命中目标! 返回假响应")
            state = .intercepted
            sendFakeResponse()
        } else {
            logger("[HTTP] ⚠️ 非目标请求，关闭连接")
            sendRST()
            state = .closed; isClosed = true
        }
    }
    
    // MARK: - TCP 发包
    
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
    
    private func sendFakeResponse() {
        let location = LocationStore.shared.getSelectedLocation()
        let adcode = location?.adcode ?? "110101"
        let name = location?.name ?? "东城区"
        
        logger("[拦截] 位置: \(location?.province ?? "?") \(location?.city ?? "?") \(name) (\(adcode))")
        
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
        
        let proto = isIPv6 ? AF_INET6 : AF_INET
        
        if isHTTPS, let engine = tlsEngine, tlsHandshakeDone {
            guard let encrypted = engine.encryptApplicationData(responseData) else {
                logger("[TLS] 加密假响应失败")
                sendRST()
                state = .closed; isClosed = true
                return
            }
            let pkt = buildTCPPacket(flags: 0x18, payload: encrypted)
            packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
            seq += UInt32(encrypted.count)
            logger("[TLS] 已加密发送 \(encrypted.count) bytes")
        } else {
            let pkt = buildTCPPacket(flags: 0x18, payload: responseData)
            packetFlow.writePackets([pkt], withProtocols: [proto as NSNumber])
            seq += UInt32(responseData.count)
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let finPkt = self.buildTCPPacket(flags: 0x19, payload: Data())
            self.packetFlow.writePackets([finPkt], withProtocols: [proto as NSNumber])
            self.seq += 1
            self.state = .closed
            self.isClosed = true
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
    
    private func buildIPv6TCPPacket(flags: UInt8, payload: Data) -> Data {
        let src = parseIPv6(dstIP)
        let dst = parseIPv6(srcIP)
        let tcpLen = 20 + payload.count
        
        var ip = Data(count: 40)
        ip[0] = 0x60 // Version=6, Traffic Class=0, Flow Label=0
        ip[1] = 0x00
        ip[2] = 0x00
        ip[3] = 0x00
        withUnsafeBytes(of: UInt16(tcpLen).bigEndian) { ip.replaceSubrange(4..<6, with: $0) }
        ip[6] = 6 // Protocol = TCP
        ip[7] = 64 // Hop Limit
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
        pseudo.append(contentsOf: src)
        pseudo.append(contentsOf: dst)
        let tcpSegLen = UInt32(tcpLen).bigEndian
        withUnsafeBytes(of: tcpSegLen) { pseudo.append(contentsOf: $0) }
        pseudo.append(0)
        pseudo.append(0)
        pseudo.append(0)
        pseudo.append(6)
        
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
    
    private func parseIPv4(_ s: String) -> [UInt8] {
        let parts = s.components(separatedBy: ".")
        guard parts.count == 4 else { return [0, 0, 0, 0] }
        return parts.compactMap { UInt8($0) }
    }
    
    private func parseIPv6(_ s: String) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16)
        let parts = s.components(separatedBy: ":")
        var index = 0
        var skipIndex = -1
        
        for (i, part) in parts.enumerated() {
            if part.isEmpty {
                skipIndex = i
                continue
            }
            if let val = UInt16(part, radix: 16) {
                result[index] = UInt8(val >> 8)
                result[index + 1] = UInt8(val & 0xFF)
                index += 2
            }
        }
        
        if skipIndex != -1 {
            let remaining = 8 - parts.filter { !$0.isEmpty }.count
            let shiftAmount = remaining * 2
            for i in (0..<index).reversed() {
                result[i + shiftAmount] = result[i]
                result[i] = 0
            }
        }
        
        return result
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