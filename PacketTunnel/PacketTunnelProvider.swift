import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let queue = DispatchQueue(label: "com.warzone.packettunnel")
    private var isRunning = false
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[WarZoneChanger] Starting tunnel...")
        
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        networkSettings.ipv4Settings = ipv4Settings
        
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        networkSettings.dnsSettings = dnsSettings
        
        networkSettings.mtu = 1400
        
        setTunnelNetworkSettings(networkSettings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[WarZoneChanger] Failed to set tunnel settings: \(error)")
                completionHandler(error)
                return
            }
            
            NSLog("[WarZoneChanger] Tunnel settings applied successfully")
            self.isRunning = true
            self.readPackets()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[WarZoneChanger] Stopping tunnel with reason: \(reason.rawValue)")
        isRunning = false
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        NSLog("[WarZoneChanger] Received app message: \(messageData.count) bytes")
        
        if let handler = completionHandler {
            let response = "OK".data(using: .utf8)
            handler(response)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        NSLog("[WarZoneChanger] Sleep")
        completionHandler()
    }
    
    override func wake() {
        NSLog("[WarZoneChanger] Wake")
    }
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            guard self.isRunning else { return }
            
            self.queue.async {
                for (index, packet) in packets.enumerated() {
                    let processedPacket = PacketHandler.shared.handlePacket(packet)
                    if let processed = processedPacket {
                        self.packetFlow.writePackets([processed], withProtocols: [protocols[index]])
                    }
                }
                
                self.readPackets()
            }
        }
    }
}
