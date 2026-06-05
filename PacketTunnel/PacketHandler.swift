import Foundation
import NetworkExtension

struct IPHeader {
    let version: UInt8
    let ihl: UInt8
    let totalLength: UInt16
    let protocolType: UInt8
    let sourceAddress: String
    let destinationAddress: String
    let headerLength: Int
}

struct TCPHeader {
    let sourcePort: UInt16
    let destinationPort: UInt16
    let sequenceNumber: UInt32
    let acknowledgmentNumber: UInt32
    let dataOffset: UInt8
    let flags: UInt8
    let windowSize: UInt16
    let headerLength: Int
    
    var isSYN: Bool { return (flags & 0x02) != 0 }
    var isACK: Bool { return (flags & 0x10) != 0 }
    var isFIN: Bool { return (flags & 0x01) != 0 }
    var isPSH: Bool { return (flags & 0x08) != 0 }
    var isRST: Bool { return (flags & 0x04) != 0 }
}

class PacketHandler {
    static let shared = PacketHandler()
    
    private let queue = DispatchQueue(label: "com.warzone.packet-handler")
    private var connections: [String: StaticTCPConnection] = [:]
    private let targetHost = "apis.map.qq.com"
    private let targetPort: UInt16 = 80
    
    private init() {}
    
    func handlePacket(_ data: Data) -> Data? {
        guard let ipHeader = parseIPHeader(data) else {
            return data
        }
        
        guard ipHeader.protocolType == 6 else {
            return data
        }
        
        guard let tcpHeader = parseTCPHeader(data, ipHeaderOffset: ipHeader.headerLength) else {
            return data
        }
        
        let connectionKey = "\(ipHeader.sourceAddress):\(tcpHeader.sourcePort)-\(ipHeader.destinationAddress):\(tcpHeader.destinationPort)"
        
        let payloadOffset = ipHeader.headerLength + tcpHeader.headerLength
        let payload = data.subdata(in: payloadOffset..<data.count)
        
        let isTargetPort = tcpHeader.destinationPort == targetPort || tcpHeader.sourcePort == targetPort
        
        if !isTargetPort {
            return data
        }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.handleTargetPacket(
                connectionKey: connectionKey,
                ipHeader: ipHeader,
                tcpHeader: tcpHeader,
                payload: payload
            )
        }
        
        return data
    }
    
    private func handleTargetPacket(connectionKey: String, ipHeader: IPHeader, tcpHeader: TCPHeader, payload: Data) {
        var connection = connections[connectionKey]
        
        if connection == nil {
            connection = StaticTCPConnection(
                packetFlow: PacketTunnelProvider.shared?.packetFlow,
                sourceIP: ipHeader.sourceAddress,
                sourcePort: tcpHeader.sourcePort,
                destIP: ipHeader.destinationAddress,
                destPort: tcpHeader.destinationPort
            )
            connections[connectionKey] = connection
        }
        
        connection?.handlePacket(tcpHeader: tcpHeader, payload: payload)
    }
    
    private func parseIPHeader(_ data: Data) -> IPHeader? {
        guard data.count >= 20 else { return nil }
        
        let versionAndIHL = data[0]
        let version = (versionAndIHL >> 4) & 0x0F
        let ihl = versionAndIHL & 0x0F
        let headerLength = Int(ihl) * 4
        
        guard headerLength >= 20 && data.count >= headerLength else { return nil }
        
        let totalLength = UInt16(data[2]) << 8 | UInt16(data[3])
        let protocolType = data[9]
        
        let sourceAddress = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let destinationAddress = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"
        
        return IPHeader(
            version: version,
            ihl: ihl,
            totalLength: totalLength,
            protocolType: protocolType,
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            headerLength: headerLength
        )
    }
    
    private func parseTCPHeader(_ data: Data, ipHeaderOffset: Int) -> TCPHeader? {
        guard data.count >= ipHeaderOffset + 20 else { return nil }
        
        let sourcePort = UInt16(data[ipHeaderOffset]) << 8 | UInt16(data[ipHeaderOffset + 1])
        let destinationPort = UInt16(data[ipHeaderOffset + 2]) << 8 | UInt16(data[ipHeaderOffset + 3])
        
        let sequenceNumber = UInt32(data[ipHeaderOffset + 4]) << 24 |
                            UInt32(data[ipHeaderOffset + 5]) << 16 |
                            UInt32(data[ipHeaderOffset + 6]) << 8 |
                            UInt32(data[ipHeaderOffset + 7])
        
        let acknowledgmentNumber = UInt32(data[ipHeaderOffset + 8]) << 24 |
                                  UInt32(data[ipHeaderOffset + 9]) << 16 |
                                  UInt32(data[ipHeaderOffset + 10]) << 8 |
                                  UInt32(data[ipHeaderOffset + 11])
        
        let dataOffset = (data[ipHeaderOffset + 12] >> 4) & 0x0F
        let headerLength = Int(dataOffset) * 4
        
        let flags = data[ipHeaderOffset + 13]
        let windowSize = UInt16(data[ipHeaderOffset + 14]) << 8 | UInt16(data[ipHeaderOffset + 15])
        
        return TCPHeader(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: acknowledgmentNumber,
            dataOffset: dataOffset,
            flags: flags,
            windowSize: windowSize,
            headerLength: headerLength
        )
    }
}

class StaticTCPConnection {
    private let packetFlow: NEPacketTunnelFlow?
    private let sourceIP: String
    private let sourcePort: UInt16
    private let destIP: String
    private let destPort: UInt16
    
    private var clientSeq: UInt32 = 0
    private var serverSeq: UInt32 = 0
    private var state: TCPState = .listen
    private var requestBuffer = Data()
    
    init(packetFlow: NEPacketTunnelFlow?, sourceIP: String, sourcePort: UInt16, destIP: String, destPort: UInt16) {
        self.packetFlow = packetFlow
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destIP = destIP
        self.destPort = destPort
        self.serverSeq = UInt32.random(in: 0..<UInt32.max)
    }
    
    func handlePacket(tcpHeader: TCPHeader, payload: Data) {
        switch state {
        case .listen:
            if tcpHeader.isSYN {
                handleSYN(clientSeq: tcpHeader.sequenceNumber)
            }
        case .synReceived:
            if tcpHeader.isACK {
                state = .established
            }
        case .established:
            if tcpHeader.isFIN {
                handleFIN()
            } else if !payload.isEmpty {
                requestBuffer.append(payload)
                if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                    handleHTTPRequest(request)
                }
            }
        case .closeWait:
            if tcpHeader.isACK {
                state = .closed
            }
        default:
            break
        }
    }
    
    private func handleSYN(clientSeq: UInt32) {
        self.clientSeq = clientSeq + 1
        state = .synReceived
        sendSYNACK()
    }
    
    private func handleFIN() {
        state = .closeWait
        sendFINACK()
    }
    
    private func handleHTTPRequest(_ request: HTTPRequest) {
        NSLog("[StaticTCP] 收到请求: \(request.host ?? "")\(request.path)")
        
        let isTarget = LocationInjector.shared.isTargetRequest(host: request.host, path: request.path)
        
        if isTarget {
            NSLog("[StaticTCP] 识别到目标请求，返回伪造响应")
            
            if let location = LocationStore.shared.getSelectedLocation() {
                let fakeBody = LocationInjector.shared.buildFakeResponse(
                    adcode: location.adcode,
                    regionName: location.name
                )
                
                let response = HTTPResponse(
                    statusCode: 200,
                    statusMessage: "OK",
                    headers: [
                        "Content-Type": "application/json; charset=utf-8",
                        "Server": "tencent-nginx",
                        "Date": DateFormatter.rfc1123.string(from: Date()),
                        "Connection": "close",
                        "Content-Length": "\(fakeBody.data(using: .utf8)?.count ?? 0)"
                    ],
                    body: fakeBody.data(using: .utf8) ?? Data()
                )
                
                sendHTTPResponse(response)
            }
        }
        
        sendFIN()
    }
    
    private func sendSYNACK() {
        let synAckFlags: UInt8 = 0x12
        var response = buildTCPResponse(
            seq: serverSeq,
            ack: clientSeq,
            flags: synAckFlags,
            window: 65535,
            payload: Data()
        )
        
        if let flow = packetFlow {
            flow.writePackets([response], withProtocols: [AF_INET as NSNumber])
        }
        serverSeq += 1
    }
    
    private func sendFINACK() {
        let finAckFlags: UInt8 = 0x11
        let response = buildTCPResponse(
            seq: serverSeq,
            ack: clientSeq + 1,
            flags: finAckFlags,
            window: 65535,
            payload: Data()
        )
        
        if let flow = packetFlow {
            flow.writePackets([response], withProtocols: [AF_INET as NSNumber])
        }
    }
    
    private func sendFIN() {
        let finFlags: UInt8 = 0x01
        let response = buildTCPResponse(
            seq: serverSeq,
            ack: clientSeq,
            flags: finFlags,
            window: 65535,
            payload: Data()
        )
        
        if let flow = packetFlow {
            flow.writePackets([response], withProtocols: [AF_INET as NSNumber])
        }
        state = .closeWait
    }
    
    private func sendHTTPResponse(_ response: HTTPResponse) {
        let responseData = response.toData()
        
        let pshAckFlags: UInt8 = 0x18
        let packet = buildTCPResponse(
            seq: serverSeq,
            ack: clientSeq,
            flags: pshAckFlags,
            window: 65535,
            payload: responseData
        )
        
        if let flow = packetFlow {
            flow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
        }
        
        serverSeq += UInt32(responseData.count)
    }
    
    private func buildTCPResponse(seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16, payload: Data) -> Data {
        var packet = Data()
        
        let srcIPBytes = parseIP(sourceIP)
        let dstIPBytes = parseIP(destIP)
        
        var ipHeader = Data()
        ipHeader.append(0x45)
        ipHeader.append(0x00)
        let totalLength = UInt16(20 + 20 + payload.count)
        ipHeader.append(UInt8(totalLength >> 8))
        ipHeader.append(UInt8(totalLength & 0xFF))
        ipHeader.append(0x00)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x00)
        ipHeader.append(0x40)
        ipHeader.append(0x06)
        
        var ipChecksum: UInt16 = 0
        let ipChecksumBytes = withUnsafeBytes(of: ipChecksum.bigEndian) { Data($0) }
        ipHeader.append(ipChecksumBytes)
        
        ipHeader.append(contentsOf: dstIPBytes)
        ipHeader.append(contentsOf: srcIPBytes)
        
        let calculatedIPChecksum = calculateChecksum(ipHeader)
        ipHeader.replaceSubrange(10..<12, with: withUnsafeBytes(of: calculatedIPChecksum.bigEndian) { Data($0) })
        
        var tcpHeader = Data()
        tcpHeader.append(UInt8(destPort >> 8))
        tcpHeader.append(UInt8(destPort & 0xFF))
        tcpHeader.append(UInt8(sourcePort >> 8))
        tcpHeader.append(UInt8(sourcePort & 0xFF))
        tcpHeader.append(UInt8(seq >> 24))
        tcpHeader.append(UInt8((seq >> 16) & 0xFF))
        tcpHeader.append(UInt8((seq >> 8) & 0xFF))
        tcpHeader.append(UInt8(seq & 0xFF))
        tcpHeader.append(UInt8(ack >> 24))
        tcpHeader.append(UInt8((ack >> 16) & 0xFF))
        tcpHeader.append(UInt8((ack >> 8) & 0xFF))
        tcpHeader.append(UInt8(ack & 0xFF))
        tcpHeader.append(0x50)
        tcpHeader.append(flags)
        tcpHeader.append(UInt8(window >> 8))
        tcpHeader.append(UInt8(window & 0xFF))
        
        var tcpChecksum: UInt16 = 0
        tcpHeader.append(contentsOf: withUnsafeBytes(of: tcpChecksum.bigEndian) { Data($0) })
        tcpHeader.append(0x00)
        tcpHeader.append(0x00)
        
        var pseudoHeader = Data()
        pseudoHeader.append(contentsOf: dstIPBytes)
        pseudoHeader.append(contentsOf: srcIPBytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x06)
        let tcpLength = UInt16(tcpHeader.count + payload.count)
        pseudoHeader.append(UInt8(tcpLength >> 8))
        pseudoHeader.append(UInt8(tcpLength & 0xFF))
        
        var tcpChecksumData = pseudoHeader
        tcpChecksumData.append(tcpHeader)
        tcpChecksumData.append(payload)
        
        let calculatedTCPChecksum = calculateChecksum(tcpChecksumData)
        tcpHeader.replaceSubrange(16..<18, with: withUnsafeBytes(of: calculatedTCPChecksum.bigEndian) { Data($0) })
        
        packet.append(ipHeader)
        packet.append(tcpHeader)
        packet.append(payload)
        
        return packet
    }
    
    private func parseIP(_ address: String) -> [UInt8] {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : [0, 0, 0, 0]
    }
    
    private func calculateChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let words = data.count / 2
        
        for i in 0..<words {
            let word = UInt32(data[i * 2]) << 8 | UInt32(data[i * 2 + 1])
            sum += word
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

enum TCPState {
    case listen
    case synReceived
    case established
    case closeWait
    case closed
}

extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()
}
