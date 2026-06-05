import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 启动隧道")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        settings.mtu = 1400
        settings.ipv6Settings = nil
        
        let ipv4Settings = NEIPv4Settings(addresses: ["192.168.99.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "192.168.99.0", subnetMask: "255.255.255.0")
        ]
        settings.ipv4Settings = ipv4Settings
        
        let dns = NEDNSSettings(servers: ["223.5.5.5"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            self.startForwarding()
            completionHandler(nil)
        }
    }
    
    private func startForwarding() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            self.packetFlow.writePackets(packets, withProtocols: protocols)
            self.startForwarding()
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
