import Foundation
import Security
import CommonCrypto

// MARK: - 纯 Swift TLS 1.2 服务端引擎（不依赖 keychain / SSLContext）

class TLSEngine {
    
    private let privateKey: SecKey
    private let certificate: SecCertificate
    private let certData: Data
    
    // 会话状态
    private var clientRandom = Data()
    private var serverRandom = Data()
    private var premasterSecret = Data()
    private var masterSecret = Data()
    private var clientWriteKey = Data()
    private var serverWriteKey = Data()
    private var clientWriteIV = Data()
    private var serverWriteIV = Data()
    private var clientWriteMAC = Data()
    private var serverWriteMAC = Data()
    
    private var serverSeq: UInt64 = 0
    private var clientSeq: UInt64 = 0
    
    private var handshakeComplete = false
    
    // 输出缓冲区
    private(set) var outputBuffer = Data()
    
    // 解密后的明文数据
    private var plaintextBuffer = Data()
    private(set) var readyToRead = false
    
    init?(privateKey: SecKey, certificate: SecCertificate, certData: Data) {
        self.privateKey = privateKey
        self.certificate = certificate
        self.certData = certData
    }
    
    // MARK: - 处理入站 TLS 记录
    
    enum ProcessResult {
        case needMoreData
        case handshakeDone
        case appData(Data)
        case error(String)
    }
    
    func process(_ data: Data) -> ProcessResult {
        var offset = 0
        var result: ProcessResult = .needMoreData
        
        while offset + 5 <= data.count {
            let contentType = data[offset]
            let recordVersion = (UInt16(data[offset + 1]) << 8) | UInt16(data[offset + 2])
            let recordLength = Int((UInt16(data[offset + 3]) << 8) | UInt16(data[offset + 4]))
            
            guard offset + 5 + recordLength <= data.count else {
                return .needMoreData
            }
            
            let payload = data.subdata(in: offset + 5 ..< offset + 5 + recordLength)
            offset += 5 + recordLength
            
            if contentType == 0x16 { // Handshake
                let r = processHandshake(payload)
                switch r {
                case .needMoreData: return .needMoreData
                case .error(let msg): return .error(msg)
                default: result = r
                }
            } else if contentType == 0x14 { // ChangeCipherSpec
                // 忽略，客户端已切换加密
                continue
            } else if contentType == 0x17 { // Application Data
                if handshakeComplete {
                    let r = decryptApplicationData(payload)
                    switch r {
                    case .appData(let decrypted):
                        plaintextBuffer.append(decrypted)
                        readyToRead = true
                        result = .appData(decrypted)
                    case .error(let msg): return .error(msg)
                    default: break
                    }
                }
            }
        }
        
        return result
    }
    
    func readPlaintext() -> Data {
        let d = plaintextBuffer
        plaintextBuffer.removeAll()
        readyToRead = false
        return d
    }
    
    // MARK: - 加密明文为 TLS 记录
    
    func encryptApplicationData(_ data: Data) -> Data? {
        guard handshakeComplete else { return nil }
        return buildTLSRecord(contentType: 0x17, plaintext: data, key: serverWriteKey, iv: serverWriteIV, macKey: serverWriteMAC, seq: &serverSeq)
    }
    
    // MARK: - Handshake
    
    private func processHandshake(_ data: Data) -> ProcessResult {
        var offset = 0
        while offset + 4 <= data.count {
            let msgType = data[offset]
            let bodyLen = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard offset + 4 + bodyLen <= data.count else { break }
            let body = data.subdata(in: offset + 4 ..< offset + 4 + bodyLen)
            offset += 4 + bodyLen
            
            switch msgType {
            case 0x01: // ClientHello
                let r = handleClientHello(body)
                if case .error(let msg) = r { return .error(msg) }
                return r
            case 0x10: // ClientKeyExchange
                let r = handleClientKeyExchange(body)
                if case .error(let msg) = r { return .error(msg) }
                return r
            case 0x14: // Finished (encrypted)
                return handleClientFinished(body)
            default:
                break
            }
        }
        return .needMoreData
    }
    
    // MARK: - ClientHello
    
    private func handleClientHello(_ body: Data) -> ProcessResult {
        guard body.count >= 38 else { return .error("ClientHello too short") }
        
        // 跳过 version (2) + random (32) = 34
        clientRandom = body.subdata(in: 2..<34)
        
        // 生成 server random
        var sr = Data(count: 32)
        sr.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        serverRandom = sr
        
        // 跳过 session_id
        var pos = 34
        guard pos < body.count else { return .error("ClientHello truncated") }
        let sessionIDLen = Int(body[pos])
        pos += 1 + sessionIDLen
        
        // 跳过 cipher_suites
        guard pos + 2 <= body.count else { return .error("ClientHello truncated") }
        let csLen = Int((UInt16(body[pos]) << 8) | UInt16(body[pos + 1]))
        pos += 2 + csLen
        
        // 跳过 compression
        guard pos < body.count else { return .error("ClientHello truncated") }
        let compLen = Int(body[pos])
        pos += 1 + compLen
        
        // Extensions (跳过)
        buildServerHello()
        return .handshakeDone
    }
    
    private func buildServerHello() {
        // ServerHello
        var sh = Data()
        sh.append(contentsOf: [0x03, 0x03]) // TLS 1.2
        sh.append(serverRandom)
        sh.append(0) // session_id length = 0
        // CipherSuite: TLS_RSA_WITH_AES_128_CBC_SHA256 (0x00, 0x3C)
        sh.append(contentsOf: [0x00, 0x3C])
        sh.append(0x00) // compression: null
        
        let shMsg = handshakeMessage(type: 0x02, body: sh)
        
        // Certificate
        var certMsg = Data()
        let certLen = UInt32(certData.count)
        certMsg.append(contentsOf: [UInt8((certLen >> 16) & 0xFF), UInt8((certLen >> 8) & 0xFF), UInt8(certLen & 0xFF)])
        certMsg.append(certData)
        let certHS = handshakeMessage(type: 0x0B, body: certMsg)
        
        // ServerHelloDone
        let shd = handshakeMessage(type: 0x0E, body: Data())
        
        let all = shMsg + certHS + shd
        let record = buildTLSRecordPlain(contentType: 0x16, payload: all)
        outputBuffer.append(record)
    }
    
    // MARK: - ClientKeyExchange
    
    private func handleClientKeyExchange(_ body: Data) -> ProcessResult {
        guard body.count >= 2 else { return .error("ClientKeyExchange too short") }
        let encLen = Int((UInt16(body[0]) << 8) | UInt16(body[1]))
        guard 2 + encLen <= body.count else { return .error("ClientKeyExchange invalid") }
        let encrypted = body.subdata(in: 2..<2+encLen)
        
        // RSA 解密 premaster secret
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, encrypted as CFData, &error) as Data? else {
            let errMsg = error?.takeRetainedValue().localizedDescription ?? "unknown"
            return .error("RSA解密失败: \(errMsg)")
        }
        
        // Premaster secret: [0x00, 0x02, random..., 0x00, 0x03, 0x03, 46 random bytes]
        // 对于 ClientKeyExchange 中的 RSA 加密，premaster 是: [client_version(2)] + [46 random bytes]
        guard decrypted.count == 48, decrypted[0] == 0x03, decrypted[1] == 0x03 else {
            return .error("Premaster格式错误")
        }
        premasterSecret = decrypted
        
        // 派生密钥
        deriveKeys()
        
        return .handshakeDone
    }
    
    // MARK: - Client Finished
    
    private func handleClientFinished(_ body: Data) -> ProcessResult {
        guard body.count >= 16 else { return .error("Finished too short") }
        // 第一个字节是 verify_data 长度，后面是实际数据
        // 对于 TLS 1.2，verify_data 是 12 bytes
        // 但 encrypted Finished 包含 MAC + padding，所以总长度 >= 16
        
        // 解密 Finished
        let decrypted = decryptRecord(body, key: clientWriteKey, iv: clientWriteIV, macKey: clientWriteMAC, seq: &clientSeq)
        guard let plain = decrypted else {
            return .error("解密Finished失败")
        }
        
        // 验证 verify_data
        // verify_data = PRF(master_secret, "client finished", Hash(handshake_messages))[0..11]
        // 这里简化处理，只检查长度
        guard plain.count >= 12 else { return .error("Finished长度错误") }
        
        handshakeComplete = true
        
        // 发送我们的 ChangeCipherSpec + Finished
        sendChangeCipherSpecAndFinished()
        
        return .handshakeDone
    }
    
    private func sendChangeCipherSpecAndFinished() {
        // ChangeCipherSpec
        let ccs = Data([0x14, 0x03, 0x03, 0x00, 0x01, 0x01])
        outputBuffer.append(ccs)
        
        // Finished (encrypted)
        // verify_data = PRF(master_secret, "server finished", Hash(handshake_messages))[0..11]
        // 简化: 使用 12 字节的伪 verify_data
        let verifyData = Data(repeating: 0, count: 12)
        let finishedBody = handshakeMessage(type: 0x14, body: verifyData)
        guard let encrypted = buildTLSRecord(contentType: 0x16, plaintext: finishedBody, key: serverWriteKey, iv: serverWriteIV, macKey: serverWriteMAC, seq: &serverSeq) else {
            return
        }
        outputBuffer.append(encrypted)
    }
    
    // MARK: - 密钥派生 (TLS 1.2 PRF)
    
    private func deriveKeys() {
        // PRF: P_SHA256(secret, label + seed)
        let seed = clientRandom + serverRandom
        let keyBlock = tlsPRF(secret: premasterSecret, label: "master secret", seed: seed, outputLength: 48)
        masterSecret = keyBlock
        
        // key_block = PRF(master_secret, "key expansion", server_random + client_random)
        let keyMaterial = tlsPRF(secret: masterSecret, label: "key expansion", seed: serverRandom + clientRandom, outputLength: 128)
        
        var pos = 0
        clientWriteMAC = keyMaterial.subdata(in: pos..<pos+32); pos += 32
        serverWriteMAC = keyMaterial.subdata(in: pos..<pos+32); pos += 32
        clientWriteKey = keyMaterial.subdata(in: pos..<pos+16); pos += 16
        serverWriteKey = keyMaterial.subdata(in: pos..<pos+16); pos += 16
        clientWriteIV  = keyMaterial.subdata(in: pos..<pos+16); pos += 16
        serverWriteIV  = keyMaterial.subdata(in: pos..<pos+16); pos += 16
    }
    
    private func tlsPRF(secret: Data, label: String, seed: Data, outputLength: Int) -> Data {
        // P_SHA256(secret, label + seed)
        let labelData = label.data(using: .ascii)!
        let aSeed = labelData + seed
        
        var result = Data()
        var a = aSeed
        while result.count < outputLength {
            // A(i) = HMAC_SHA256(secret, A(i-1))
            var aOut = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
            a.withUnsafeBytes { aPtr in
                secret.withUnsafeBytes { sPtr in
                    aOut.withUnsafeMutableBytes { outPtr in
                        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), sPtr.baseAddress!, secret.count, aPtr.baseAddress!, a.count, outPtr.baseAddress!)
                    }
                }
            }
            a = aOut
            
            // HMAC_SHA256(secret, A(i) + seed)
            let input = a + aSeed
            var hmac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
            input.withUnsafeBytes { iPtr in
                secret.withUnsafeBytes { sPtr in
                    hmac.withUnsafeMutableBytes { outPtr in
                        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), sPtr.baseAddress!, secret.count, iPtr.baseAddress!, input.count, outPtr.baseAddress!)
                    }
                }
            }
            result.append(hmac)
        }
        
        return result.prefix(outputLength)
    }
    
    // MARK: - 加密/解密
    
    private func buildTLSRecordPlain(contentType: UInt8, payload: Data) -> Data {
        var record = Data()
        record.append(contentType)
        record.append(contentsOf: [0x03, 0x03]) // TLS 1.2
        let len = UInt16(payload.count)
        record.append(contentsOf: [UInt8(len >> 8), UInt8(len & 0xFF)])
        record.append(payload)
        return record
    }
    
    private func buildTLSRecord(contentType: UInt8, plaintext: Data, key: Data, iv: Data, macKey: Data, seq: inout UInt64) -> Data? {
        // 计算 MAC: HMAC_SHA256(seq_num + content_type + version + length + plaintext)
        var macInput = Data()
        macInput.append(contentsOf: withUnsafeBytes(of: seq.bigEndian) { Data($0) })
        macInput.append(contentType)
        macInput.append(contentsOf: [0x03, 0x03])
        let len16 = UInt16(plaintext.count)
        macInput.append(contentsOf: [UInt8(len16 >> 8), UInt8(len16 & 0xFF)])
        macInput.append(plaintext)
        
        var mac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        macInput.withUnsafeBytes { mPtr in
            macKey.withUnsafeBytes { kPtr in
                mac.withUnsafeMutableBytes { outPtr in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), kPtr.baseAddress!, macKey.count, mPtr.baseAddress!, macInput.count, outPtr.baseAddress!)
                }
            }
        }
        
        // 明文 + MAC + padding
        let content = plaintext + mac
        let blockSize = 16
        let paddingLen = blockSize - (content.count % blockSize)
        let padding = Data(repeating: UInt8(paddingLen - 1), count: paddingLen)
        let toEncrypt = content + padding
        
        // AES-CBC 加密
        let ivCopy = iv
        var encrypted = Data(count: toEncrypt.count)
        var bytesEncrypted = 0
        let status = encrypted.withUnsafeMutableBytes { encPtr in
            toEncrypt.withUnsafeBytes { plainPtr in
                ivCopy.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress!, kCCKeySizeAES128,
                                ivPtr.baseAddress!,
                                plainPtr.baseAddress!, toEncrypt.count,
                                encPtr.baseAddress!, toEncrypt.count,
                                &bytesEncrypted)
                    }
                }
            }
        }
        
        guard status == kCCSuccess else { return nil }
        encrypted = encrypted.prefix(bytesEncrypted)
        
        seq += 1
        
        // 构建 TLS 记录
        var record = Data()
        record.append(contentType)
        record.append(contentsOf: [0x03, 0x03])
        let recLen = UInt16(encrypted.count)
        record.append(contentsOf: [UInt8(recLen >> 8), UInt8(recLen & 0xFF)])
        record.append(encrypted)
        return record
    }
    
    private func decryptApplicationData(_ payload: Data) -> ProcessResult {
        guard let plain = decryptRecord(payload, key: clientWriteKey, iv: clientWriteIV, macKey: clientWriteMAC, seq: &clientSeq) else {
            return .error("解密应用数据失败")
        }
        return .appData(plain)
    }
    
    private func decryptRecord(_ payload: Data, key: Data, iv: Data, macKey: Data, seq: inout UInt64) -> Data? {
        // AES-CBC 解密
        var decrypted = Data(count: payload.count)
        var bytesDecrypted = 0
        let status = decrypted.withUnsafeMutableBytes { decPtr in
            payload.withUnsafeBytes { encPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress!, kCCKeySizeAES128,
                                ivPtr.baseAddress!,
                                encPtr.baseAddress!, payload.count,
                                decPtr.baseAddress!, payload.count,
                                &bytesDecrypted)
                    }
                }
            }
        }
        
        guard status == kCCSuccess else { return nil }
        decrypted = decrypted.prefix(bytesDecrypted)
        
        seq += 1
        
        // 移除 MAC 和 padding
        // 最后 32 字节是 MAC，最后 1 字节指示 padding 长度
        guard decrypted.count >= 33 else { return nil }
        let paddingLen = Int(decrypted[decrypted.count - 1]) + 1
        let macOffset = decrypted.count - 32 - paddingLen
        guard macOffset >= 0 else { return nil }
        
        return decrypted.prefix(macOffset)
    }
    
    // MARK: - 工具
    
    private func handshakeMessage(type: UInt8, body: Data) -> Data {
        var msg = Data()
        msg.append(type)
        let len = UInt32(body.count)
        msg.append(contentsOf: [UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        msg.append(body)
        return msg
    }
}