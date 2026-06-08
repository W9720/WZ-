import NetworkExtension
import Foundation
import Security

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    private var targetIPs: Set<String> = []
    private var tcpConnections: [String: TCPHandler] = [:]
    private let appGroupId = "group.com.warzone.changer"
    private let logQueue = DispatchQueue(label: "vpn.log")
    private var packetCount: Int = 0
    private var tlsIdentity: (SecIdentity, SecCertificate)?
    
    private let fallbackIPs: Set<String> = [
        "119.147.13.124", "119.147.13.222", "119.147.14.89",
        "183.60.15.100", "183.60.60.100", "183.60.82.100",
        "123.151.76.100", "123.151.77.100",
        "61.151.229.100", "61.151.252.100"
    ]
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        clearLogs()
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
                        let addr_in = sockaddr_in_ptr.pointee.sin_addr
                        if let ipCStr = inet_ntoa(addr_in) {
                            ips.insert(String(cString: ipCStr))
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
        
        // 接受 80 (HTTP) 和 443 (HTTPS)
        guard dstPort == 80 || dstPort == 443 else {
            writeLog("[跳过] 非80/443端口: \(dstPort)")
            return
        }
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        if let conn = tcpConnections[key] {
            conn.processPacket(packet)
        } else {
            let isHTTPS = (dstPort == 443)
            let conn = TCPHandler(
                packetFlow: packetFlow,
                srcIP: srcIP, srcPort: srcPort,
                dstIP: dstIP, dstPort: dstPort,
                targetHost: targetHost, targetPath: targetPath,
                isHTTPS: isHTTPS,
                tlsIdentity: isHTTPS ? getOrCreateIdentity() : nil,
                logger: { [weak self] msg in self?.writeLog(msg) }
            )
            tcpConnections[key] = conn
            conn.processPacket(packet)
        }
        
        tcpConnections = tcpConnections.filter { !$0.value.isClosed }
    }
    
    private func getOrCreateIdentity() -> (SecIdentity, SecCertificate)? {
        if let existing = tlsIdentity { return existing }
        writeLog("[TLS] 开始生成自签名证书...")
        let result = createIdentity()
        tlsIdentity = result
        if result != nil {
            writeLog("[TLS] ✅ 自签名证书生成成功")
        } else {
            writeLog("[TLS] ❌ 自签名证书生成失败!")
        }
        return result
    }
    
    // MARK: - 自签名证书
    
    private func createIdentity() -> (SecIdentity, SecCertificate)? {
        // 生成 RSA 密钥对
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: true,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            writeLog("[TLS] 密钥生成失败")
            return nil
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            writeLog("[TLS] 获取公钥失败")
            return nil
        }
        
        // 构建 X.509 证书
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            writeLog("[TLS] 导出公钥失败")
            return nil
        }
        
        guard let certData = buildX509Certificate(publicKeyData: pubKeyData, privateKey: privateKey) else {
            writeLog("[TLS] 构建证书失败")
            return nil
        }
        
        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            writeLog("[TLS] 创建证书对象失败")
            return nil
        }
        
        // 添加到 keychain 获取 identity
        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true,
        ]
        var certRef: CFTypeRef?
        let certStatus = SecItemAdd(certAdd as CFDictionary, &certRef)
        guard certStatus == errSecSuccess, let certPersistentRef = certRef else {
            writeLog("[TLS] 添加证书到keychain失败: \(certStatus)")
            return nil
        }
        
        let keyAdd: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnPersistentRef as String: true,
        ]
        var keyRef: CFTypeRef?
        let keyStatus = SecItemAdd(keyAdd as CFDictionary, &keyRef)
        guard keyStatus == errSecSuccess, let keyPersistentRef = keyRef else {
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValuePersistentRef as String: certPersistentRef] as CFDictionary)
            writeLog("[TLS] 添加密钥到keychain失败: \(keyStatus)")
            return nil
        }
        
        // 获取 identity
        let idQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchItemList as String: [certPersistentRef, keyPersistentRef],
        ]
        var identity: CFTypeRef?
        let idStatus = SecItemCopyMatching(idQuery as CFDictionary, &identity)
        
        guard idStatus == errSecSuccess, let ident = identity else {
            writeLog("[TLS] 获取identity失败: \(idStatus)")
            return nil
        }
        
        writeLog("[TLS] 证书和密钥已保存到keychain")
        return (ident as! SecIdentity, certificate)
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
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            return nil
        }
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
    let tlsIdentity: (SecIdentity, SecCertificate)?
    let logger: (String) -> Void
    
    var seq: UInt32 = arc4random()
    var ack: UInt32 = 0
    var state: State = .closed
    var httpBuffer = Data()
    var isClosed = false
    
    // TLS
    private var sslContext: SSLContext?
    private var tlsInBuffer = Data()
    private var tlsOutBuffer = Data()
    private var tlsHandshakeDone = false
    
    enum State { case closed, synRecv, established, tlsHandshake, tlsEstablished, intercepted }
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, targetHost: String, targetPath: String, isHTTPS: Bool, tlsIdentity: (SecIdentity, SecCertificate)?, logger: @escaping (String) -> Void) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.targetHost = targetHost
        self.targetPath = targetPath
        self.isHTTPS = isHTTPS
        self.tlsIdentity = tlsIdentity
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
                state = isHTTPS ? .tlsHandshake : .established
                logger("[TCP] 握手完成: \(srcIP):\(srcPort) -> \(dstIP):\(dstPort)")
                
                if isHTTPS {
                    startTLSHandshake()
                }
            }
            
        case .tlsHandshake:
            if !payload.isEmpty {
                ack = seqNum + UInt32(payload.count)
                sendACK()
                feedTLSData(payload)
            }
            
        case .established:
            if fin {
                sendFinAck(seqNum: seqNum)
                state = .closed; isClosed = true
            } else if rst {
                state = .closed; isClosed = true
            } else if !payload.isEmpty {
                ack = seqNum + UInt32(payload.count)
                sendACK()
                handleHTTPData(payload)
            }
            
        case .tlsEstablished:
            if fin {
                sendFinAck(seqNum: seqNum)
                state = .closed; isClosed = true
            } else if rst {
                state = .closed; isClosed = true
            } else if !payload.isEmpty {
                ack = seqNum + UInt32(payload.count)
                sendACK()
                tlsInBuffer.append(payload)
                readDecryptedHTTP()
            }
            
        case .intercepted:
            if fin || rst {
                state = .closed; isClosed = true
            }
        }
    }
    
    // MARK: - TLS
    
    private func startTLSHandshake() {
        guard let (identity, _) = tlsIdentity else {
            logger("[TLS] 无证书，关闭连接")
            sendRST()
            state = .closed; isClosed = true
            return
        }
        
        sslContext = SSLCreateContext(nil, .serverSide, .streamType)
        guard let ctx = sslContext else {
            logger("[TLS] 创建SSLContext失败")
            sendRST()
            state = .closed; isClosed = true
            return
        }
        
        SSLSetCertificate(ctx, [identity] as CFArray)
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        SSLSetConnection(ctx, selfPtr)
        SSLSetIOFuncs(ctx, { (conn: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLen: UnsafeMutablePointer<Int>) -> OSStatus in
            let handler = Unmanaged<TCPHandler>.fromOpaque(conn).takeUnretainedValue()
            if handler.tlsInBuffer.isEmpty {
                dataLen.pointee = 0
                return errSSLWouldBlock
            }
            let readLen = min(dataLen.pointee, handler.tlsInBuffer.count)
            handler.tlsInBuffer.copyBytes(to: data.assumingMemoryBound(to: UInt8.self), count: readLen)
            handler.tlsInBuffer.removeFirst(readLen)
            dataLen.pointee = readLen
            return noErr
        }, { (conn: SSLConnectionRef, data: UnsafeRawPointer, dataLen: UnsafeMutablePointer<Int>) -> OSStatus in
            let handler = Unmanaged<TCPHandler>.fromOpaque(conn).takeUnretainedValue()
            handler.tlsOutBuffer.append(data.assumingMemoryBound(to: UInt8.self), count: dataLen.pointee)
            return noErr
        })
        
        let status = SSLHandshake(ctx)
        logger("[TLS] 握手状态: \(status)")
        
        if !tlsOutBuffer.isEmpty {
            let outData = tlsOutBuffer
            tlsOutBuffer.removeAll()
            sendTLSData(outData)
            logger("[TLS] 发送握手数据 \(outData.count) bytes")
        }
        
        if status == noErr {
            logger("[TLS] ✅ 握手成功!")
            tlsHandshakeComplete()
        } else if status == errSSLWouldBlock {
            logger("[TLS] 等待更多客户端数据...")
        } else {
            logger("[TLS] ❌ 握手失败: \(status)")
            sendRST()
            state = .closed; isClosed = true
        }
    }
    
    private func feedTLSData(_ data: Data) {
        guard let ctx = sslContext else { return }
        
        tlsInBuffer.append(data)
        logger("[TLS] 收到客户端数据 \(data.count) bytes, 缓冲 \(tlsInBuffer.count) bytes")
        
        let status = SSLHandshake(ctx)
        logger("[TLS] 继续握手状态: \(status)")
        
        if !tlsOutBuffer.isEmpty {
            let outData = tlsOutBuffer
            tlsOutBuffer.removeAll()
            sendTLSData(outData)
            logger("[TLS] 发送握手数据 \(outData.count) bytes")
        }
        
        if status == noErr {
            logger("[TLS] ✅ 握手成功!")
            tlsHandshakeComplete()
        } else if status == errSSLWouldBlock {
            logger("[TLS] 等待更多数据...")
        } else {
            logger("[TLS] ❌ 握手失败: \(status)")
            sendRST()
            state = .closed; isClosed = true
        }
    }
    
    private func tlsHandshakeComplete() {
        tlsHandshakeDone = true
        state = .tlsEstablished
        logger("[TLS] 握手完成! 等待HTTP请求")
        
        // 尝试读取已缓冲的明文
        if !tlsInBuffer.isEmpty {
            readDecryptedHTTP()
        }
    }
    
    private func readDecryptedHTTP() {
        guard let ctx = sslContext, tlsHandshakeDone else { return }
        
        // 将 tlsInBuffer 喂给 SSL 并读取明文
        var decrypted = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var processed = 0
        
        // 先尝试 SSLRead
        let readStatus = SSLRead(ctx, &buf, 4096, &processed)
        if readStatus == noErr || readStatus == errSSLWouldBlock {
            if processed > 0 {
                decrypted.append(Data(buf[0..<processed]))
            }
        }
        
        if !decrypted.isEmpty {
            logger("[TLS] 解密数据 \(decrypted.count) bytes")
            handleHTTPData(decrypted)
        }
    }
    
    private func sendTLSData(_ data: Data) {
        let pkt = buildTCPPacket(flags: 0x18, payload: data)
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
        seq += UInt32(data.count)
        logger("[TLS] 发送TLS数据 \(data.count) bytes")
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
        
        if isHTTPS, let ctx = sslContext, tlsHandshakeDone {
            // HTTPS: 加密响应
            var written = 0
            responseData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let status = SSLWrite(ctx, ptr.baseAddress!, responseData.count, &written)
                logger("[TLS] SSLWrite 状态: \(status), 写入: \(written)")
            }
            
            if !tlsOutBuffer.isEmpty {
                let outData = tlsOutBuffer
                tlsOutBuffer.removeAll()
                let pkt = buildTCPPacket(flags: 0x18, payload: outData)
                packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
                seq += UInt32(outData.count)
            }
        } else {
            // HTTP: 明文发送
            let pkt = buildTCPPacket(flags: 0x18, payload: responseData)
            packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
            seq += UInt32(responseData.count)
        }
        
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