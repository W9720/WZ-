import Foundation
import Security
import CommonCrypto

struct CACertificateData {
    let caCertData: Data
    let caPrivateKeyData: Data
    let serverCertData: Data
    let serverPrivateKeyData: Data
}

class CertificateChainGenerator {
    
    static let shared = CertificateChainGenerator()
    
    private init() {}
    
    func generateCertificateChain() -> CACertificateData? {
        let certGen = CertificateGenerator()
        
        guard let (caPrivateKey, caPublicKey) = certGen.generateRSAKeyPair() else {
            print("生成 CA 密钥对失败")
            return nil
        }
        
        guard let caCertData = generateCACertificate(privateKey: caPrivateKey, publicKey: caPublicKey) else {
            print("生成 CA 证书失败")
            return nil
        }
        
        guard let (serverPrivateKey, serverPublicKey) = certGen.generateRSAKeyPair() else {
            print("生成服务器密钥对失败")
            return nil
        }
        
        guard let serverCertData = generateServerCertificate(
            host: "apis.map.qq.com",
            serverPublicKey: serverPublicKey,
            caPrivateKey: caPrivateKey,
            caCertData: caCertData
        ) else {
            print("生成服务器证书失败")
            return nil
        }
        
        guard let caPrivKeyData = exportPrivateKey(caPrivateKey) else {
            print("导出 CA 私钥失败")
            return nil
        }
        
        guard let serverPrivKeyData = exportPrivateKey(serverPrivateKey) else {
            print("导出服务器私钥失败")
            return nil
        }
        
        return CACertificateData(
            caCertData: caCertData,
            caPrivateKeyData: caPrivKeyData,
            serverCertData: serverCertData,
            serverPrivateKeyData: serverPrivKeyData
        )
    }
    
    private func generateCACertificate(privateKey: SecKey, publicKey: SecKey) -> Data? {
        let serialNumber = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let now = Date()
        let notBefore = now
        let notAfter = Calendar.current.date(byAdding: .year, value: 10, to: now) ?? now
        
        let certGen = CertificateGenerator()
        
        var tbsCert = [UInt8]()
        tbsCert.append(0x30)
        tbsCert.append(0x82)
        tbsCert.append(0x03)
        tbsCert.append(0x00)
        
        tbsCert.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        
        let caSubject: [String: String] = [
            "CN": "WarZoneChanger Root CA",
            "O": "WarZoneChanger",
            "OU": "VPN",
            "C": "CN"
        ]
        
        let issuerName = buildName(caSubject)
        tbsCert.append(contentsOf: issuerName)
        
        tbsCert.append(contentsOf: [0x30, 0x1E])
        tbsCert.append(contentsOf: buildDate(notBefore))
        tbsCert.append(contentsOf: buildDate(notAfter))
        
        tbsCert.append(contentsOf: issuerName)
        
        guard let publicKeyData = certGen.exportPublicKey(publicKey) else {
            return nil
        }
        tbsCert.append(contentsOf: publicKeyData)
        
        tbsCert.append(contentsOf: [0xA3, 0x18, 0x30, 0x16])
        tbsCert.append(contentsOf: [0x30, 0x0E, 0x06, 0x03, 0x55, 0x1D, 0x13, 0x01, 0x01, 0xFF, 0x04, 0x04, 0x30, 0x02, 0x01, 0x01])
        tbsCert.append(contentsOf: [0x30, 0x0E, 0x06, 0x03, 0x55, 0x1D, 0x0F, 0x01, 0x01, 0xFF, 0x04, 0x04, 0x03, 0x02, 0x01, 0x06])
        
        let tbsData = Data(tbsCert)
        
        guard let signature = signData(tbsData, with: privateKey) else {
            return nil
        }
        
        var finalCert = [UInt8]()
        finalCert.append(0x30)
        finalCert.append(contentsOf: buildLength(tbsData.count + signature.count + 5))
        finalCert.append(contentsOf: tbsData)
        finalCert.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        finalCert.append(0x03)
        finalCert.append(contentsOf: buildLength(signature.count + 1))
        finalCert.append(0x00)
        finalCert.append(contentsOf: signature)
        
        return Data(finalCert)
    }
    
    private func generateServerCertificate(
        host: String,
        serverPublicKey: SecKey,
        caPrivateKey: SecKey,
        caCertData: Data
    ) -> Data? {
        let serialNumber = Data([0x02, 0x03, 0x04, 0x05, 0x06])
        let now = Date()
        let notBefore = now
        let notAfter = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
        
        let certGen = CertificateGenerator()
        
        var tbsCert = [UInt8]()
        tbsCert.append(0x30)
        tbsCert.append(0x82)
        tbsCert.append(0x02)
        tbsCert.append(0x50)
        
        tbsCert.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        
        let caSubject: [String: String] = [
            "CN": "WarZoneChanger Root CA",
            "O": "WarZoneChanger",
            "OU": "VPN",
            "C": "CN"
        ]
        let issuerName = buildName(caSubject)
        tbsCert.append(contentsOf: issuerName)
        
        tbsCert.append(contentsOf: [0x30, 0x1E])
        tbsCert.append(contentsOf: buildDate(notBefore))
        tbsCert.append(contentsOf: buildDate(notAfter))
        
        let serverSubject: [String: String] = [
            "CN": host,
            "O": "WarZoneChanger",
            "OU": "VPN",
            "C": "CN"
        ]
        let subjectName = buildName(serverSubject)
        tbsCert.append(contentsOf: subjectName)
        
        guard let publicKeyData = certGen.exportPublicKey(serverPublicKey) else {
            return nil
        }
        tbsCert.append(contentsOf: publicKeyData)
        
        let tbsData = Data(tbsCert)
        
        guard let signature = signData(tbsData, with: caPrivateKey) else {
            return nil
        }
        
        var finalCert = [UInt8]()
        finalCert.append(0x30)
        finalCert.append(contentsOf: buildLength(tbsData.count + signature.count + 5))
        finalCert.append(contentsOf: tbsData)
        finalCert.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        finalCert.append(0x03)
        finalCert.append(contentsOf: buildLength(signature.count + 1))
        finalCert.append(0x00)
        finalCert.append(contentsOf: signature)
        
        return Data(finalCert)
    }
    
    private func buildName(_ name: [String: String]) -> [UInt8] {
        var result = [UInt8]()
        
        let oidMap: [String: String] = [
            "CN": "2.5.4.3",
            "OU": "2.5.4.11",
            "O": "2.5.4.10",
            "C": "2.5.4.6"
        ]
        
        for (key, value) in name {
            if let oid = oidMap[key] {
                let entry = buildNameEntry(oid, value: value)
                result.append(contentsOf: entry)
            }
        }
        
        var setData = [UInt8]()
        for entry in result {
            setData.append(entry)
        }
        
        var wrapped = [UInt8]()
        wrapped.append(0x31)
        wrapped.append(contentsOf: buildLength(setData.count))
        wrapped.append(contentsOf: setData)
        
        var final = [UInt8]()
        final.append(0x30)
        final.append(contentsOf: buildLength(wrapped.count))
        final.append(contentsOf: wrapped)
        
        return final
    }
    
    private func buildNameEntry(_ oid: String, value: String) -> [UInt8] {
        var result = [UInt8]()
        
        result.append(0x30)
        let oidBytes = buildOID(oid)
        let valueData = value.data(using: .utf8) ?? Data()
        
        var seqContent = [UInt8]()
        seqContent.append(contentsOf: oidBytes)
        seqContent.append(0x0C)
        seqContent.append(contentsOf: buildLength(valueData.count))
        seqContent.append(contentsOf: valueData)
        
        result.append(contentsOf: buildLength(seqContent.count))
        result.append(contentsOf: seqContent)
        
        return result
    }
    
    private func buildOID(_ oid: String) -> [UInt8] {
        var bytes = [UInt8]()
        
        let parts = oid.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return [] }
        
        let firstByte = UInt8(parts[0] * 40 + parts[1])
        bytes.append(firstByte)
        
        for i in 2..<parts.count {
            var value = parts[i]
            var encoded = [UInt8]()
            
            if value == 0 {
                encoded.append(0)
            } else {
                while value > 0 {
                    var byte = UInt8(value & 0x7F)
                    value >>= 7
                    if encoded.count > 0 {
                        byte |= 0x80
                    }
                    encoded.insert(byte, at: 0)
                }
            }
            
            if encoded.count > 0 {
                for j in 0..<encoded.count-1 {
                    encoded[j] |= 0x80
                }
            }
            
            bytes.append(contentsOf: encoded)
        }
        
        var result = [UInt8]()
        result.append(0x06)
        result.append(contentsOf: buildLength(bytes.count))
        result.append(contentsOf: bytes)
        
        return result
    }
    
    private func buildLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        } else if length < 0x100 {
            return [0x81, UInt8(length)]
        } else if length < 0x10000 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }
    
    private func buildDate(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateStr = formatter.string(from: date)
        
        var result = [UInt8]()
        result.append(0x17)
        result.append(0x0D)
        result.append(contentsOf: dateStr.data(using: .ascii) ?? Data())
        
        return result
    }
    
    private func signData(_ data: Data, with privateKey: SecKey) -> Data? {
        let digest = sha256(data)
        
        var digestInfo = [UInt8]()
        digestInfo.append(0x30)
        digestInfo.append(0x31)
        digestInfo.append(0x30)
        digestInfo.append(0x0D)
        digestInfo.append(contentsOf: [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00])
        digestInfo.append(0x04)
        digestInfo.append(0x20)
        digestInfo.append(contentsOf: digest)
        
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(digestInfo) as CFData,
            &error
        ) else {
            if let err = error {
                print("签名失败: \(err.takeRetainedValue())")
            }
            return nil
        }
        
        return signature as Data
    }
    
    private func sha256(_ data: Data) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }
    
    private func exportPrivateKey(_ privateKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, &error) else {
            if let err = error {
                print("导出私钥失败: \(err.takeRetainedValue())")
            }
            return nil
        }
        
        return keyData as Data
    }
}
