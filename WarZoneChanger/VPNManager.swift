import Foundation
import NetworkExtension

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var isConnecting = false
    
    private var vpnManager: NEAppProxyProviderManager?
    
    private init() {}
    
    func checkStatus() {
        errorMessage = nil
        NEAppProxyProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Failed to load VPN managers: \(error)")
                return
            }
            
            self.vpnManager = managers?.first
            DispatchQueue.main.async {
                self.isConnected = self.vpnManager?.connection.status == .connected
                self.isConnecting = self.vpnManager?.connection.status == .connecting || 
                                    self.vpnManager?.connection.status == .reasserting
            }
        }
    }
    
    func startVPN() {
        errorMessage = nil
        isConnecting = true
        
        NEAppProxyProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Failed to load VPN managers: \(error)")
                DispatchQueue.main.async {
                    self.errorMessage = "无法加载VPN配置: \(error.localizedDescription)"
                    self.isConnecting = false
                }
                return
            }
            
            let vpnManager: NEAppProxyProviderManager
            if let existing = managers?.first {
                vpnManager = existing
            } else {
                vpnManager = NEAppProxyProviderManager()
                vpnManager.localizedDescription = "战区精灵"
                
                let protocolConfig = NEAppProxyProviderProtocol()
                protocolConfig.providerBundleIdentifier = "com.warzone.changer.PacketTunnel"
                protocolConfig.serverAddress = "127.0.0.1"
                vpnManager.protocolConfiguration = protocolConfig
            }
            
            vpnManager.isEnabled = true
            
            vpnManager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                
                if let error = error {
                    print("Failed to save VPN config: \(error)")
                    DispatchQueue.main.async {
                        self.errorMessage = "无法保存VPN配置: \(error.localizedDescription)"
                        self.isConnecting = false
                    }
                    return
                }
                
                vpnManager.loadFromPreferences { [weak self] error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        print("Failed to load VPN config: \(error)")
                        DispatchQueue.main.async {
                            self.errorMessage = "无法加载VPN配置: \(error.localizedDescription)"
                            self.isConnecting = false
                        }
                        return
                    }
                    
                    do {
                        try vpnManager.connection.startVPNTunnel()
                        DispatchQueue.main.async {
                            self.isConnected = true
                            self.isConnecting = false
                            self.vpnManager = vpnManager
                        }
                    } catch {
                        print("Failed to start VPN: \(error)")
                        DispatchQueue.main.async {
                            self.errorMessage = "VPN启动失败，请检查系统设置是否允许VPN"
                            self.isConnecting = false
                        }
                    }
                }
            }
        }
    }
    
    func stopVPN() {
        vpnManager?.connection.stopVPNTunnel()
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.errorMessage = nil
        }
    }
}
