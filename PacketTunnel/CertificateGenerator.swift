import Foundation
import Security
import CommonCrypto

// MARK: - 证书生成和管理

class CertificateGenerator {
    
    static let shared = CertificateGenerator()
    
    init() {}
    
    // 生成 RSA 密钥对
    func generateRSAKeyPair(keySize: Int = 2048) -> (privateKey: SecKey, publicKey: SecKey)? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: keySize,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: false,
                kSecAttrApplicationTag: "com.warzone.changer.ca.private"
            ] as [CFString: Any],
            kSecPublicKeyAttrs: [
                kSecAttrIsPermanent: false,
                kSecAttrApplicationTag: "com.warzone.changer.ca.public"
            ] as [CFString: Any]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let errDesc = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            print("生成密钥对失败: \(errDesc)")
            return nil
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            print("获取公钥失败")
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    // 生成 CA 根证书
    func generateCACertificate(privateKey: SecKey, publicKey: SecKey) -> Data? {
        let serialNumber = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        
        let now = Date()
        let notBefore = now
        let notAfter = Calendar.current.date(byAdding: .year, value: 10, to: now) ?? now
        
        var builder = [UInt8]()
        
        let subject: [String: String] = [
            "CN": "WarZoneChanger Root CA",
            "O": "WarZoneChanger",
            "OU": "VPN",
            "C": "CN"
        ]
        
        builder.append(contentsOf: [0x30, 0x82, 0x03, 0x00])
        
        builder.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        
        let issuerName = encodeName(subject)
        builder.append(contentsOf: issuerName)
        
        builder.append(contentsOf: [0x30, 0x1E])
        builder.append(contentsOf: encodeDate(notBefore))
        builder.append(contentsOf: encodeDate(notAfter))
        
        builder.append(contentsOf: issuerName)
        
        guard let publicKeyData = exportPublicKey(publicKey) else {
            print("导出公钥失败")
            return nil
        }
        builder.append(contentsOf: publicKeyData)
        
        builder.append(contentsOf: [0xA3, 0x18, 0x30, 0x16])
        builder.append(contentsOf: [0x30, 0x0E, 0x06, 0x03, 0x55, 0x1D, 0x13, 0x01, 0x01, 0xFF, 0x04, 0x04, 0x30, 0x02, 0x01, 0x01])
        builder.append(contentsOf: [0x30, 0x0E, 0x06, 0x03, 0x55, 0x1D, 0x0F, 0x01, 0x01, 0xFF, 0x04, 0x04, 0x03, 0x02, 0x01, 0x06])
        
        let tbsCert = Data(builder)
        
        guard let signature = signData(tbsCert, with: privateKey) else {
            print("签名失败")
            return nil
        }
        
        var finalCert = [UInt8]()
        finalCert.append(0x30)
        finalCert.append(contentsOf: encodeLength(tbsCert.count + signature.count + 5))
        finalCert.append(contentsOf: tbsCert)
        finalCert.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        finalCert.append(0x03)
        finalCert.append(contentsOf: encodeLength(signature.count + 1))
        finalCert.append(0x00)
        finalCert.append(contentsOf: signature)
        
        return Data(finalCert)
    }
    
    func encodeName(_ name: [String: String]) -> [UInt8] {
        var result = [UInt8]()
        
        if let cn = name["CN"] {
            result.append(contentsOf: encodeNameEntry("2.5.4.3", value: cn))
        }
        if let ou = name["OU"] {
            result.append(contentsOf: encodeNameEntry("2.5.4.11", value: ou))
        }
        if let o = name["O"] {
            result.append(contentsOf: encodeNameEntry("2.5.4.10", value: o))
        }
        if let c = name["C"] {
            result.append(contentsOf: encodeNameEntry("2.5.4.6", value: c))
        }
        
        var setData = [UInt8]()
        for entry in result {
            setData.append(entry)
        }
        
        var wrapped = [UInt8]()
        wrapped.append(0x31)
        wrapped.append(contentsOf: encodeLength(setData.count))
        wrapped.append(contentsOf: setData)
        
        var final = [UInt8]()
        final.append(0x30)
        final.append(contentsOf: encodeLength(wrapped.count))
        final.append(contentsOf: wrapped)
        
        return final
    }
    
    func encodeNameEntry(_ oid: String, value: String) -> [UInt8] {
        var result = [UInt8]()
        
        result.append(0x30)
        let oidBytes = encodeOID(oid)
        let valueData = value.data(using: .utf8) ?? Data()
        
        var seqContent = [UInt8]()
        seqContent.append(contentsOf: oidBytes)
        seqContent.append(0x0C)
        seqContent.append(contentsOf: encodeLength(valueData.count))
        seqContent.append(contentsOf: valueData)
        
        result.append(contentsOf: encodeLength(seqContent.count))
        result.append(contentsOf: seqContent)
        
        return result
    }
    
    func encodeOID(_ oid: String) -> [UInt8] {
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
        result.append(contentsOf: encodeLength(bytes.count))
        result.append(contentsOf: bytes)
        
        return result
    }
    
    func encodeLength(_ length: Int) -> [UInt8] {
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
    
    func encodeDate(_ date: Date) -> [UInt8] {
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
    
    func exportPublicKey(_ publicKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            let errDesc = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            print("导出公钥失败: \(errDesc)")
            return nil
        }
        
        let data = keyData as Data
        
        var wrapped = [UInt8]()
        wrapped.append(0x30)
        wrapped.append(contentsOf: encodeLength(data.count))
        wrapped.append(contentsOf: data)
        
        return Data(wrapped)
    }
    
    func signData(_ data: Data, with privateKey: SecKey) -> Data? {
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
            let errDesc = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            print("签名失败: \(errDesc)")
            return nil
        }
        
        return signature as Data
    }
    
    func sha256(_ data: Data) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }
}

// MARK: - 动态签发服务器证书

class ServerCertificateGenerator {
    
    static let shared = ServerCertificateGenerator()
    
    init() {}
    
    func generateServerCertificate(
        for host: String,
        caPrivateKey: SecKey,
        caCertificate: SecCertificate
    ) -> (certificate: Data, privateKey: SecKey)? {
        
        let certGen = CertificateGenerator()
        guard let (serverPrivateKey, serverPublicKey) = certGen.generateRSAKeyPair() else {
            print("生成服务器密钥对失败")
            return nil
        }
        
        guard let serverCert = createServerCertificate(
            for: host,
            serverPublicKey: serverPublicKey,
            caPrivateKey: caPrivateKey,
            caCertificate: caCertificate
        ) else {
            print("生成服务器证书失败")
            return nil
        }
        
        return (serverCert, serverPrivateKey)
    }
    
    func createServerCertificate(
        for host: String,
        serverPublicKey: SecKey,
        caPrivateKey: SecKey,
        caCertificate: SecCertificate
    ) -> Data? {
        
        var builder = [UInt8]()
        
        let serialNumber = Data([0x02, 0x03, 0x04, 0x05, 0x06])
        let now = Date()
        let notBefore = now
        let notAfter = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
        
        builder.append(contentsOf: [0x30, 0x82, 0x02, 0x50])
        
        builder.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        
        let certGen = CertificateGenerator()
        
        let caSubject: [String: String] = [
            "CN": "WarZoneChanger Root CA",
            "O": "WarZoneChanger",
            "OU": "VPN",
            "C": "CN"
        ]
        let issuerName = certGen.encodeName(caSubject)
        builder.append(contentsOf: issuerName)
        
        builder.append(contentsOf: [0x30, 0x1E])
        builder.append(contentsOf: certGen.encodeDate(notBefore))
        builder.append(contentsOf: certGen.encodeDate(notAfter))
        
        let serverSubject: [String: String] = [
            "CN": host,
            "O": "WarZoneChanger",
            "OU": "VPN",
            "C": "CN"
        ]
        let subjectName = certGen.encodeName(serverSubject)
        builder.append(contentsOf: subjectName)
        
        guard let publicKeyData = certGen.exportPublicKey(serverPublicKey) else {
            return nil
        }
        builder.append(contentsOf: publicKeyData)
        
        let tbsCert = Data(builder)
        
        guard let signature = certGen.signData(tbsCert, with: caPrivateKey) else {
            return nil
        }
        
        var finalCert = [UInt8]()
        finalCert.append(0x30)
        finalCert.append(contentsOf: certGen.encodeLength(tbsCert.count + signature.count + 5))
        finalCert.append(contentsOf: tbsCert)
        finalCert.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        finalCert.append(0x03)
        finalCert.append(contentsOf: certGen.encodeLength(signature.count + 1))
        finalCert.append(0x00)
        finalCert.append(contentsOf: signature)
        
        return Data(finalCert)
    }
}
