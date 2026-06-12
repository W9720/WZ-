import Foundation
import UIKit
import SwiftUI

class CertificateManager: ObservableObject {
    static let shared = CertificateManager()
    
    @Published var isInstalled: Bool = false
    @Published var isTrusted: Bool = false
    
    private let certData: Data
    
    private init() {
        self.certData = Data(preGeneratedCert)
        checkCertificateStatus()
    }
    
    func checkCertificateStatus() {
        isInstalled = checkCertificateInstalled()
        isTrusted = false
    }
    
    private func checkCertificateInstalled() -> Bool {
        let host = "apis.map.qq.com"
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        
        let task = URLSession.shared.dataTask(with: URL(string: "https://\(host)")!) { _, response, error in
            if let error = error as NSError? {
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorServerCertificateUntrusted {
                    result = false
                }
            } else if let httpResponse = response as? HTTPURLResponse {
                result = httpResponse.statusCode == 200 || httpResponse.statusCode == 403
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        
        return false
    }
    
    func getCertificateData() -> Data {
        return certData
    }
    
    func saveCertificateToDisk() -> URL? {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.warzone.changer") else {
            print("无法访问 App Group 容器")
            return nil
        }
        
        let certURL = containerURL.appendingPathComponent("WarZoneChanger_CA.cer")
        
        do {
            try certData.write(to: certURL)
            print("证书已保存到: \(certURL.path)")
            return certURL
        } catch {
            print("保存证书失败: \(error)")
            return nil
        }
    }
    
    func getCertificateBase64() -> String {
        return certData.base64EncodedString()
    }
    
    func openCertificateInSafari() {
        saveCertificateToDisk()
        
        let base64Cert = certData.base64EncodedString()
        let dataURL = "data:application/x-x509-ca-cert;base64,\(base64Cert)"
        
        if let url = URL(string: dataURL) {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:]) { success in
                    if success {
                        print("证书已在 Safari 中打开")
                    } else {
                        print("无法打开证书")
                    }
                }
            }
        }
    }
    
    func shareCertificate() {
        if let certURL = saveCertificateToDisk() {
            let activityVC = UIActivityViewController(activityItems: [certURL], applicationActivities: nil)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                activityVC.popoverPresentationController?.sourceView = rootVC.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                activityVC.popoverPresentationController?.permittedArrowDirections = []
                rootVC.present(activityVC, animated: true)
            }
        }
    }
    
    func copyCertificateToPasteboard() {
        let base64Cert = certData.base64EncodedString()
        let pemString = "-----BEGIN CERTIFICATE-----\n\(base64Cert)\n-----END CERTIFICATE-----"
        UIPasteboard.general.string = pemString
    }
    
    func getCertificateInfo() -> String {
        var info = "证书信息:\n"
        info += "格式: DER (.cer)\n"
        info += "大小: \(certData.count) bytes\n"
        info += "Common Name: apis.map.qq.com\n"
        info += "有效期: 10年\n"
        return info
    }
}
