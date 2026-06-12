import Foundation
import UIKit
import SwiftUI

class CertificateManager: ObservableObject {
    
    static let shared = CertificateManager()
    
    @Published var lastMessage: String = ""
    @Published var showMessage: Bool = false
    
    private let caCertData: Data
    private var httpServer: LocalHTTPServer?
    
    private init() {
        self.caCertData = Data(preGeneratedCACert)
        print("CA 证书数据大小: \(caCertData.count) bytes")
    }
    
    func getCACertificateData() -> Data {
        return caCertData
    }
    
    func getCACertificateBase64() -> String {
        return caCertData.base64EncodedString()
    }
    
    func getMobileConfigString() -> String {
        let base64Cert = caCertData.base64EncodedString()
        return generateMobileConfig(certBase64: base64Cert)
    }
    
    private func generateMobileConfig(certBase64: String) -> String {
        let uuid1 = UUID().uuidString
        let uuid2 = UUID().uuidString
        
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadCertificateFileName</key>
            <string>WarZoneChangerCA.cer</string>
            <key>PayloadContent</key>
            <data>\(certBase64)</data>
            <key>PayloadDescription</key>
            <string>安装 CA 根证书以支持 HTTPS 拦截。此证书用于验证 VPN 拦截的腾讯地图 API 请求。</string>
            <key>PayloadDisplayName</key>
            <string>WarZoneChanger Root CA</string>
            <key>PayloadIdentifier</key>
            <string>com.warzone.changer.ca</string>
            <key>PayloadOrganization</key>
            <string>WarZoneChanger</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>\(uuid1)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>战区精灵证书配置 - 用于 HTTPS 定位拦截</string>
    <key>PayloadDisplayName</key>
    <string>战区精灵证书</string>
    <key>PayloadIdentifier</key>
    <string>com.warzone.changer.config</string>
    <key>PayloadOrganization</key>
    <string>WarZoneChanger</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>\(uuid2)</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
"""
    }
    
    func openCertificateViaHTTPServer() -> Bool {
        print("启动本地 HTTP 服务器...")
        
        let mobileConfig = getMobileConfigString()
        
        httpServer = LocalHTTPServer()
        
        if httpServer?.start(mobileConfig: mobileConfig, port: 8080) == true {
            print("HTTP 服务器启动成功")
            
            if let url = URL(string: "http://localhost:8080/cert.mobileconfig") {
                print("打开 URL: \(url)")
                
                DispatchQueue.main.async {
                    UIApplication.shared.open(url) { success in
                        if success {
                            self.showSuccessMessage("已打开证书安装页面，请在 Safari 中点击\"允许\"，然后前往\"设置\"→\"已下载描述文件\"进行安装")
                        } else {
                            self.showErrorMessage("无法打开 Safari")
                        }
                    }
                }
                return true
            }
        } else {
            print("HTTP 服务器启动失败")
            showErrorMessage("无法启动本地服务器")
            return false
        }
        
        return false
    }
    
    func stopHTTPServer() {
        httpServer?.stop()
        httpServer = nil
    }
    
    func saveCertFileToDocuments() -> URL? {
        print("保存 CA 证书到 Documents 目录...")
        
        let fileManager = FileManager.default
        
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("错误: 无法获取 Documents 目录")
            showErrorMessage("无法访问文件目录")
            return nil
        }
        
        print("Documents 目录: \(documentsDir.path)")
        
        let certURL = documentsDir.appendingPathComponent("WarZoneChangerCA.cer")
        
        do {
            try caCertData.write(to: certURL)
            print("CA 证书已保存到: \(certURL.path)")
            
            let fileExists = fileManager.fileExists(atPath: certURL.path)
            print("文件存在: \(fileExists)")
            
            if fileExists {
                shareFile(url: certURL)
                showSuccessMessage("CA 证书已准备好，请在分享面板中选择操作")
            } else {
                showErrorMessage("文件不存在")
                return nil
            }
            
            return certURL
        } catch {
            print("保存证书失败: \(error.localizedDescription)")
            showErrorMessage("保存失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func shareFile(url: URL) {
        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                activityVC.popoverPresentationController?.sourceView = rootVC.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                activityVC.popoverPresentationController?.permittedArrowDirections = []
                
                rootVC.present(activityVC, animated: true)
            } else {
                print("无法获取 rootViewController")
            }
        }
    }
    
    func copyCertificateToPasteboard() {
        let base64Cert = caCertData.base64EncodedString()
        let pemString = "-----BEGIN CERTIFICATE-----\n\(base64Cert)\n-----END CERTIFICATE-----"
        UIPasteboard.general.string = pemString
        print("CA 证书已复制到剪贴板")
        showSuccessMessage("CA 证书已复制到剪贴板")
    }
    
    func getCertificateInfo() -> String {
        var info = "CA 根证书信息:\n"
        info += "格式: DER (.cer)\n"
        info += "类型: CA 根证书 (CA: TRUE)\n"
        info += "大小: \(caCertData.count) bytes\n"
        info += "数据非空: \(caCertData.count > 0)\n"
        info += "\n使用说明:\n"
        info += "1. 安装证书后，前往 通用 → 关于本机 → 证书信任设置\n"
        info += "2. 找到 WarZoneChanger Root CA 并启用完全信任"
        return info
    }
    
    private func showSuccessMessage(_ message: String) {
        DispatchQueue.main.async {
            self.lastMessage = "✅ \(message)"
            self.showMessage = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.showMessage = false
        }
    }
    
    private func showErrorMessage(_ message: String) {
        DispatchQueue.main.async {
            self.lastMessage = "❌ \(message)"
            self.showMessage = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.showMessage = false
        }
    }
}
