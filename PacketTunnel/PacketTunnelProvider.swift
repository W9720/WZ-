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
        settings.mtu = 1400 // iOS 15 强制 1400
        
        let ipv4Settings = NEIPv4Settings(addresses: ["192.168.99.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "192.168.99.0", subnetMask: "255.255.255.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        ]
        
        settings.ipv4Settings = ipv4Settings
        settings.ipv6Settings = nil
        
        let dnsSettings = NEDNSSettings(servers: ["223.5.5.5", "119.29.29.29"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                completionHandler(error)
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startReadingPackets()
                self.startCleanupTimer()
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        cleanupTimer?.cancel()
        udpSessions.values.forEach { $0.close() }
        tcpConnections.values.forEach { $0.close() }
        completionHandler()
    }
    
    private func startReadingPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            DispatchQueue.global().async {
                for i in 0..<packets.count {
                    self.processPacket(packets[i], protocolNumber: protocols[i].int32Value)
                }
                self.startReadingPackets()
            }
        }
    }
    
    private func processPacket(_ packet: Data, protocolNumber: Int32) {
        guard packet.count >= 20 else { return }
        let version = (packet[0] >> 4) & 0x0F
        guard version == 4 else { return }
        
        let ihl = Int(packet[0] & 0x0F) * 4
        let proto = packet[9]
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        
        if proto == 17 {
            handleUDPPacket(packet, ipHeaderLen: ihl, srcIP: srcIP, dstIP: dstIP)
        } else if proto == 6 {
            handleTCPPacket(packet, ipHeaderLen: ihl, srcIP: srcIP, dstIP: dstIP)
        }
    }
    
    private func handleUDPPacket(_ packet: Data, ipHeaderLen: Int, srcIP: String, dstIP: String) {
        guard packet.count >= ipHeaderLen + 8 else { return }
        let srcPort = UInt16(packet[ipHeaderLen]) << 8 | UInt16(packet[ipHeaderLen+1])
        let dstPort = UInt16(packet[ipHeaderLen+2]) << 8 | UInt16(packet[ipHeaderLen+3])
        let payload = packet.subdata(in: ipHeaderLen+8..<packet.count)
        
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        if let s = udpSessions[key] {
            s.send(payload)
            return
        }
        
        let s = UDPSession(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, packetFlow: packetFlow)
        udpSessions[key] = s
        s.start()
        s.send(payload)
    }
    
    private func handleTCPPacket(_ packet: Data, ipHeaderLen: Int, srcIP: String, dstIP: String) {
        let srcPort = UInt16(packet[ipHeaderLen]) << 8 | UInt16(packet[ipHeaderLen+1])
        let dstPort = UInt16(packet[ipHeaderLen+2]) << 8 | UInt16(packet[ipHeaderLen+3])
        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"
        
        if let c = tcpConnections[key] {
            c.processPacket(packet)
            return
        }
        
        let c = TCPConnection(packetFlow: packetFlow, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
        tcpConnections[key] = c
        c.processPacket(packet)
    }
    
    private func startCleanupTimer() {
        cleanupTimer = DispatchSource.makeTimerSource(queue: .global())
        cleanupTimer?.schedule(deadline: .now(), repeating: 30)
        cleanupTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.udpSessions = self.udpSessions.filter { $0.value.isConnected }
            self.tcpConnections = self.tcpConnections.filter { $0.value.isConnected }
        }
        cleanupTimer?.resume()
    }
}

// ==============================================
// 修复版 UDPSession（内部自带 parseIP + checksum）
// ==============================================
class UDPSession {
    let srcIP: String
    let srcPort: UInt16
    let dstIP: String
    let dstPort: UInt16
    let packetFlow: NEPacketTunnelFlow
    var connection: NWConnection?
    let queue = DispatchQueue(label: "udp")
    var lastActivity = Date()
    
    var isConnected: Bool {
        connection?.state == .ready
    }
    
    init(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16, packetFlow: NEPacketTunnelFlow) {
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
        self.packetFlow = packetFlow
    }
    
    func start() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true // 🔥 修复 TrollStore 必加
        connection = NWConnection(
            host: .init(dstIP),
            port: .init(rawValue: dstPort)!,
            using: params
        )
        
        connection?.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            if st == .ready { self.recv() }
        }
        
        connection?.start(queue: queue)
    }
    
    func send(_ data: Data) {
        guard isConnected else { return }
        connection?.send(content: data, completion: .idempotent)
    }
    
    func recv() {
        connection?.receiveMessage { [weak self] data, _, _, _ in
            guard let self = self, let d = data, !d.isEmpty else { return }
            self.sendBack(d)
            self.recv()
        }
    }
    
    func sendBack(_ data: Data) {
        let src = parseIP(dstIP)
        let dst = parseIP(srcIP)
        
        var ip = Data(count:20)
        ip[0] = 0x45
        ip[1] = 0x00
        let total = UInt16(20 + 8 + data.count)
        total.bigEndian.withUnsafeBytes { ip.replaceSubrange(2..<4, with: $0) }
        ip[8] = 64
        ip[9] = 0x11
        ip.replaceSubrange(12..<16, with: src)
        ip.replaceSubrange(16..<20, with: dst)
        
        let ipCheck = checksum(ip)
        ipCheck.bigEndian.withUnsafeBytes { ip.replaceSubrange(10..<12, with: $0) }
        
        var udp = Data(count:8)
        dstPort.bigEndian.withUnsafeBytes { udp.replaceSubrange(0..<2, with: $0) }
        srcPort.bigEndian.withUnsafeBytes { udp.replaceSubrange(2..<4, with: $0) }
        let udpLen = UInt16(8 + data.count)
        udpLen.bigEndian.withUnsafeBytes { udp.replaceSubrange(4..<6, with: $0) }
        
        var pkt = Data()
        pkt.append(ip)
        pkt.append(udp)
        pkt.append(data)
        
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
    }
    
    func parseIP(_ s: String) -> [UInt8] {
        let p = s.components(separatedBy: ".")
        guard p.count == 4 else { return [0,0,0,0] }
        return p.compactMap { UInt8($0) }
    }
    
    func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        let c = data.count
        while i < c {
            let v = i+1 < c ? UInt32(data[i])<<8 | UInt32(data[i+1]) : UInt32(data[i])<<8
            sum += v
            i += 2
        }
        while sum>>16 != 0 { sum = (sum&0xffff)+(sum>>16) }
        return ~UInt16(sum)
    }
    
    func close() {
        connection?.cancel()
    }
}

// ==============================================
// 修复版 TCPConnection
// ==============================================
class TCPConnection {
    let packetFlow: NEPacketTunnelFlow
    let srcIP: String
    let srcPort: UInt16
    let dstIP: String
    let dstPort: UInt16
    var connection: NWConnection?
    let queue = DispatchQueue(label: "tcp")
    
    var isConnected: Bool {
        connection?.state == .ready
    }
    
    var seq: UInt32 = arc4random()
    var ack: UInt32 = 0
    
    enum State { case closed, synRecv, established }
    var state: State = .closed
    
    init(packetFlow: NEPacketTunnelFlow, srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) {
        self.packetFlow = packetFlow
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
    }
    
    func processPacket(_ pkt: Data) {
        guard pkt.count >= 40 else { return }
        let tcpOff = Int(pkt[0] & 0x0F)*4
        let seqNum: UInt32 = pkt.subdata(in: tcpOff+4..<tcpOff+8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let flags = pkt[tcpOff+13]
        
        let syn = (flags & 0x02) != 0
        let ackF = (flags & 0x10) != 0
        
        if state == .closed, syn {
            ack = seqNum + 1
            state = .synRecv
            sendSynAck()
        } else if state == .synRecv, ackF {
            state = .established
            connect()
        }
    }
    
    func sendSynAck() {
        let ip = buildIP(src: parseIP(dstIP), dst: parseIP(srcIP), proto: 6, len: 40)
        var tcp = Data(count:20)
        dstPort.bigEndian.withUnsafeBytes { tcp.replaceSubrange(0..<2, with: $0) }
        srcPort.bigEndian.withUnsafeBytes { tcp.replaceSubrange(2..<4, with: $0) }
        seq.bigEndian.withUnsafeBytes { tcp.replaceSubrange(4..<8, with: $0) }
        ack.bigEndian.withUnsafeBytes { tcp.replaceSubrange(8..<12, with: $0) }
        tcp[12] = 0x50
        tcp[13] = 0x12
        let window: UInt16 = 65535
        window.bigEndian.withUnsafeBytes { tcp.replaceSubrange(14..<16, with: $0) }
        
        var full = Data()
        full.append(ip)
        full.append(tcp)
        packetFlow.writePackets([full], withProtocols: [AF_INET as NSNumber])
        seq += 1
    }
    
    func connect() {
        let opt = NWProtocolTCP.Options()
        opt.noDelay = true
        let params = NWParameters(tls: nil, tcp: opt)
        params.allowLocalEndpointReuse = true // 🔥 TrollStore 必加
        
        connection = NWConnection(
            host: .init(dstIP),
            port: .init(rawValue: dstPort)!,
            using: params
        )
        
        connection?.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            if st == .ready { self.recv() }
        }
        
        connection?.start(queue: queue)
    }
    
    func recv() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1400) { [weak self] data, _, _, _ in
            guard let self = self, let d = data else { return }
            self.sendBack(d)
            self.recv()
        }
    }
    
    func sendBack(_ data: Data) {
        let ip = buildIP(src: parseIP(dstIP), dst: parseIP(srcIP), proto: 6, len: 20+20+data.count)
        var tcp = Data(count:20)
        dstPort.bigEndian.withUnsafeBytes { tcp.replaceSubrange(0..<2, with: $0) }
        srcPort.bigEndian.withUnsafeBytes { tcp.replaceSubrange(2..<4, with: $0) }
        seq.bigEndian.withUnsafeBytes { tcp.replaceSubrange(4..<8, with: $0) }
        ack.bigEndian.withUnsafeBytes { tcp.replaceSubrange(8..<12, with: $0) }
        tcp[12] = 0x50
        tcp[13] = 0x18
        let window: UInt16 = 65535
        window.bigEndian.withUnsafeBytes { tcp.replaceSubrange(14..<16, with: $0) }
        
        var pkt = Data()
        pkt.append(ip)
        pkt.append(tcp)
        pkt.append(data)
        packetFlow.writePackets([pkt], withProtocols: [AF_INET as NSNumber])
        seq += UInt32(data.count)
    }
    
    func buildIP(src: [UInt8], dst: [UInt8], proto: UInt8, len: Int) -> Data {
        var ip = Data(count:20)
        ip[0] = 0x45
        ip[1] = 0x00
        UInt16(len).bigEndian.withUnsafeBytes { ip.replaceSubrange(2..<4, with: $0) }
        ip[8] = 64
        ip[9] = proto
        ip.replaceSubrange(12..<16, with: src)
        ip.replaceSubrange(16..<20, with: dst)
        
        var sum: UInt32 = 0
        var i = 0
        while i<20 {
            let v = i+1<20 ? UInt32(ip[i])<<8 | UInt32(ip[i+1]) : UInt32(ip[i])<<8
            sum += v
            i += 2
        }
        while sum>>16 != 0 { sum = (sum&0xffff)+(sum>>16) }
        let cs = ~UInt16(sum)
        cs.bigEndian.withUnsafeBytes { ip.replaceSubrange(10..<12, with: $0) }
        return ip
    }
    
    func parseIP(_ s: String) -> [UInt8] {
        let p = s.components(separatedBy: ".")
        guard p.count == 4 else { return [0,0,0,0] }
        return p.compactMap { UInt8($0) }
    }
    
    func close() {
        connection?.cancel()
    }
}
