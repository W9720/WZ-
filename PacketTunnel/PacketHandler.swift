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
    
    private var connections: [String: TCPConnection] = [:]
    private let queue = DispatchQueue(label: "com.warzone.packet-handler")
    
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
        let reverseKey = "\(ipHeader.destinationAddress):\(tcpHeader.destinationPort)-\(ipHeader.sourceAddress):\(tcpHeader.sourcePort)"
        
        let payloadOffset = ipHeader.headerLength + tcpHeader.headerLength
        let payload = data.subdata(in: payloadOffset..<data.count)
        
        if tcpHeader.isSYN {
            handleSYN(connectionKey: connectionKey, 
                     destinationAddress: ipHeader.destinationAddress, 
                     destinationPort: tcpHeader.destinationPort)
        }
        
        if tcpHeader.isFIN || tcpHeader.isRST {
            handleFIN(connectionKey: connectionKey, reverseKey: reverseKey)
        }
        
        if !payload.isEmpty {
            handlePayload(connectionKey: connectionKey, 
                         reverseKey: reverseKey, 
                         payload: payload,
                         destinationAddress: ipHeader.destinationAddress,
                         destinationPort: tcpHeader.destinationPort)
        }
        
        return data
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
    
    private func handleSYN(connectionKey: String, destinationAddress: String, destinationPort: UInt16) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if self.connections[connectionKey] == nil {
                let connection = TCPConnection(host: destinationAddress, port: destinationPort)
                
                connection.setResponseInjector { [weak self] request in
                    return self?.createFakeResponse(for: request)
                }
                
                self.connections[connectionKey] = connection
                connection.start()
            }
        }
    }
    
    private func handleFIN(connectionKey: String, reverseKey: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.connections[connectionKey]?.cancel()
            self.connections.removeValue(forKey: connectionKey)
            self.connections.removeValue(forKey: reverseKey)
        }
    }
    
    private func handlePayload(connectionKey: String, reverseKey: String, payload: Data, destinationAddress: String, destinationPort: UInt16) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            var connection = self.connections[connectionKey]
            
            if connection == nil {
                connection = TCPConnection(host: destinationAddress, port: destinationPort)
                connection?.setResponseInjector { [weak self] request in
                    return self?.createFakeResponse(for: request)
                }
                self.connections[connectionKey] = connection
                connection?.start()
            }
            
            connection?.send(data: payload)
        }
    }
    
    private func createFakeResponse(for request: HTTPRequest) -> HTTPResponse? {
        guard LocationInjector.shared.isTargetRequest(host: request.host, path: request.path) else {
            return nil
        }
        
        guard let location = LocationStore.shared.getSelectedLocation() else {
            return nil
        }
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(
            adcode: location.adcode,
            regionName: location.name
        )
        
        guard let bodyData = fakeBody.data(using: .utf8) else {
            return nil
        }
        
        let headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Server": "tencent-nginx",
            "Date": DateFormatter.rfc1123.string(from: Date()),
            "Connection": "close",
            "Content-Length": "\(bodyData.count)"
        ]
        
        return HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: headers,
            body: bodyData
        )
    }
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
