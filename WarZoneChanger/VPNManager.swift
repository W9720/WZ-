import Foundation
import NetworkExtension

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var isConnecting = false
    
    private var vpnManager: NEVPNManager?
    private let appGroupIdentifier = "group.com.warzone.changer"
    private let tunnelBundleIdentifier = "com.warzone.changer.PacketTunnel"
    
    private init() {
        loadVPNConfiguration()
    }
    
    private func loadVPNConfiguration() {
        NEVPNManager.shared().loadFromPreferences { [weak self] error in
            if let error = error {
                print("[VPN] 加载VPN配置失败: \(error.localizedDescription)")
                self?.createVPNConfiguration()
                return
            }
            
            self?.vpnManager = NEVPNManager.shared()
            print("[VPN] 加载VPN配置成功, protocol: \(String(describing: self?.vpnManager?.protocolConfiguration))")
            
            if self?.vpnManager?.protocolConfiguration == nil {
                print("[VPN] 协议配置为空，创建新配置")
                self?.createVPNConfiguration()
            } else {
                self?.checkStatus()
            }
        }
    }
    
    private func createVPNConfiguration() {
        print("[VPN] 创建VPN配置, tunnelBundleIdentifier: \(tunnelBundleIdentifier)")
        
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = tunnelBundleIdentifier
        tunnelProtocol.serverAddress = "WarZoneChanger"
        tunnelProtocol.providerConfiguration = ["appGroup": appGroupIdentifier]
        
        vpnManager = NEVPNManager.shared()
        vpnManager?.protocolConfiguration = tunnelProtocol
        vpnManager?.localizedDescription = "战区精灵"
        vpnManager?.isEnabled = true
        
        vpnManager?.saveToPreferences { [weak self] error in
            if let error = error {
                print("[VPN] 保存VPN配置失败: \(error.localizedDescription)")
                print("[VPN] 错误代码: \(error._code), 错误域: \(error._domain)")
                self?.errorMessage = "VPN配置保存失败: \(error.localizedDescription)"
                
                if let neError = error as NSError? {
                    print("[VPN] NSError 详细信息: \(neError)")
                    print("[VPN] NSError userInfo: \(neError.userInfo)")
                }
            } else {
                print("[VPN] VPN配置创建成功")
                self?.loadVPNConfiguration()
            }
        }
    }
    
    func checkStatus() {
        guard let manager = vpnManager else { return }
        
        switch manager.connection.status {
        case .connected:
            isConnected = true
            isConnecting = false
            print("[VPN] 状态: 已连接")
        case .connecting, .reasserting:
            isConnecting = true
            isConnected = false
            print("[VPN] 状态: 连接中")
        case .disconnected:
            isConnected = false
            isConnecting = false
            print("[VPN] 状态: 已断开")
        case .invalid:
            isConnected = false
            isConnecting = false
            print("[VPN] 状态: 无效配置")
            createVPNConfiguration()
        @unknown default:
            isConnected = false
            isConnecting = false
            print("[VPN] 状态: 未知")
        }
    }
    
    func startVPN() {
        guard let manager = vpnManager else {
            errorMessage = "VPN配置未加载"
            return
        }
        
        print("[VPN] 开始启动VPN...")
        
        do {
            try manager.connection.startVPNTunnel()
            isConnecting = true
            print("[VPN] VPN启动命令已发送")
        } catch {
            errorMessage = "启动VPN失败: \(error.localizedDescription)"
            isConnecting = false
            print("[VPN] 启动VPN失败: \(error.localizedDescription)")
            
            if let neError = error as NSError?, neError.domain == NEVPNErrorDomain {
                print("[VPN] NEVPNErrorDomain 错误代码: \(neError.code)")
                switch neError.code {
                case 1:
                    errorMessage = "VPN配置无效，请重新安装应用"
                    createVPNConfiguration()
                case 2:
                    errorMessage = "用户拒绝了VPN配置请求"
                case 3:
                    errorMessage = "VPN配置已存在"
                default:
                    errorMessage = "VPN错误 (\(neError.code)): \(error.localizedDescription)"
                }
            }
        }
    }
    
    func stopVPN() {
        vpnManager?.connection.stopVPNTunnel()
        isConnected = false
        isConnecting = false
        print("[VPN] VPN已停止")
    }
}
