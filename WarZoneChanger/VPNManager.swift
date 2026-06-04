import Foundation
import NetworkExtension

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var isConnecting = false
    
    private var vpnManager: NEVPNManager?
    private let appGroupIdentifier = "group.com.warzonechanger"
    
    private init() {
        loadVPNConfiguration()
    }
    
    private func loadVPNConfiguration() {
        NEVPNManager.shared().loadFromPreferences { [weak self] error in
            if let error = error {
                print("加载VPN配置失败: \(error.localizedDescription)")
                return
            }
            
            self?.vpnManager = NEVPNManager.shared()
            self?.checkStatus()
        }
    }
    
    func checkStatus() {
        guard let manager = vpnManager else { return }
        
        switch manager.connection.status {
        case .connected:
            isConnected = true
        case .connecting, .reasserting:
            isConnecting = true
        default:
            isConnected = false
            isConnecting = false
        }
    }
    
    func startVPN() {
        guard let manager = vpnManager else {
            errorMessage = "VPN配置未加载"
            return
        }
        
        do {
            try manager.connection.startVPNTunnel()
            isConnecting = true
        } catch {
            errorMessage = "启动VPN失败: \(error.localizedDescription)"
            isConnecting = false
        }
    }
    
    func stopVPN() {
        vpnManager?.connection.stopVPNTunnel()
        isConnected = false
        isConnecting = false
    }
}