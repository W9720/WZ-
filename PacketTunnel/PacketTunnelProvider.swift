import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let queue = DispatchQueue(label: "com.warzone.packettunnel")
    private var isRunning = false
    private var connectionManager: ConnectionManager!
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 开始启动隧道...")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings
        
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "114.114.114.114"])
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 设置网络配置失败: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            NSLog("[PacketTunnel] 网络配置设置成功，开始读取数据包...")
            self.connectionManager = ConnectionManager(packetFlow: self.packetFlow)
            self.isRunning = true
            self.readPackets()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止隧道，原因: \(reason.rawValue)")
        isRunning = false
        completionHandler()
    }
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            
            for packet in packets {
                self.connectionManager.handlePacket(packet)
            }
            
            self.readPackets()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if let message = String(data: messageData, encoding: .utf8) {
            NSLog("[PacketTunnel] 收到消息: \(message)")
        }
        completionHandler?(nil)
    }
}
