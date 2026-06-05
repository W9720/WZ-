import Foundation
import NetworkExtension

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var isConnecting = false
    
    private var vpnManager: NEVPNManager?
    private let appGroupIdentifier = "group.com.warzone.changer"
    private let tunnelBundleIdentifier = "com.warzonechanger.PacketTunnel"
    
    private init() {
        loadVPNConfiguration()
    }
    
    private func loadVPNConfiguration() {
        NEVPNManager.shared().loadFromPreferences { [weak self] error in
            if let error = error {
                print("加载VPN配置失败: \(error.localizedDescription)")
                self?.createVPNConfiguration()
                return
            }
            
            self?.vpnManager = NEVPNManager.shared()
            
            if self?.vpnManager?.protocolConfiguration == nil {
                self?.createVPNConfiguration()
            } else {
                self?.checkStatus()
            }
        }
    }
    
    private func createVPNConfiguration() {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = tunnelBundleIdentifier
        tunnelProtocol.serverAddress = "WarZoneChanger"
        
        vpnManager = NEVPNManager.shared()
        vpnManager?.protocolConfiguration = tunnelProtocol
        vpnManager?.localizedDescription = "战区精灵"
        vpnManager?.isEnabled = true
        
        vpnManager?.saveToPreferences { [weak self] error in
            if let error = error {
                print("保存VPN配置失败: \(error.localizedDescription)")
                self?.errorMessage = "VPN配置保存失败: \(error.localizedDescription)"
            } else {
                print("VPN配置创建成功")
                self?.checkStatus()
            }
        }
    }
    
    func checkStatus() {
        guard let manager = vpnManager else { return }
        
        switch manager.connection.status {
        case .connected:
            isConnected = true
            isConnecting = false
        case .connecting, .reasserting:
            isConnecting = true
            isConnected = false
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
            
            if let neError = error as NSError?, neError.domain == NEVPNErrorDomain {
                if neError.code == 1 {
                    errorMessage = "VPN配置无效，请重新安装应用"
                    createVPNConfiguration()
                }
            }
        }
    }
    
    func stopVPN() {
        vpnManager?.connection.stopVPNTunnel()
        isConnected = false
        isConnecting = false
    }
}
