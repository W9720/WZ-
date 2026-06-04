import Foundation

struct CardCodeInfo: Codable {
    let code: String
    let expiresAt: String
    var remainingCount: Int
    let createdAt: String
    
    var expiresDate: Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: expiresAt)
    }
    
    var isExpired: Bool {
        guard let date = expiresDate else { return true }
        return date < Date()
    }
}

class CardCodeManager: ObservableObject {
    static let shared = CardCodeManager()
    
    @Published var isLoggedIn = false
    @Published var cardInfo: CardCodeInfo?
    @Published var errorMessage: String?
    @Published var isLoading = false
    
    private let serverURL = "https://your-server-domain.com"
    
    private init() {
        loadSavedCardCode()
    }
    
    private func loadSavedCardCode() {
        if let savedCode = UserDefaults.standard.string(forKey: "cardCode"),
           !savedCode.isEmpty {
            validateCardCode(code: savedCode)
        }
    }
    
    func validateCardCode(code: String) {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: "\(serverURL)/validate") else {
            errorMessage = "服务器地址无效"
            isLoading = false
            return
        }
        
        let parameters = ["code": code]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    self?.errorMessage = "网络错误: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else {
                    self?.errorMessage = "服务器返回数据为空"
                    return
                }
                
                do {
                    let result = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    
                    if let success = result?["success"] as? Bool, success {
                        if let cardData = result?["data"] as? [String: Any] {
                            let cardInfo = CardCodeInfo(
                                code: cardData["code"] as? String ?? "",
                                expiresAt: cardData["expiresAt"] as? String ?? "",
                                remainingCount: cardData["remainingCount"] as? Int ?? 0,
                                createdAt: cardData["createdAt"] as? String ?? ""
                            )
                            
                            self?.cardInfo = cardInfo
                            self?.isLoggedIn = true
                            UserDefaults.standard.set(code, forKey: "cardCode")
                        }
                    } else {
                        self?.errorMessage = result?["message"] as? String ?? "验证失败"
                        self?.isLoggedIn = false
                        self?.cardInfo = nil
                    }
                } catch {
                    self?.errorMessage = "数据解析失败"
                }
            }
        }.resume()
    }
    
    func deductCount() async throws -> Bool {
        guard let code = cardInfo?.code else {
            throw NSError(domain: "CardCode", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        
        guard let url = URL(string: "\(serverURL)/deduct") else {
            throw NSError(domain: "CardCode", code: -2, userInfo: [NSLocalizedDescriptionKey: "服务器地址无效"])
        }
        
        let parameters = ["code": code]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = data else {
                    continuation.resume(throwing: NSError(domain: "CardCode", code: -3, userInfo: [NSLocalizedDescriptionKey: "服务器返回数据为空"]))
                    return
                }
                
                do {
                    let result = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    
                    if let success = result?["success"] as? Bool, success {
                        if let remaining = result?["remainingCount"] as? Int {
                            self?.cardInfo?.remainingCount = remaining
                        }
                        continuation.resume(returning: true)
                    } else {
                        let message = result?["message"] as? String ?? "扣费失败"
                        continuation.resume(throwing: NSError(domain: "CardCode", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }.resume()
        }
    }
    
    func logout() {
        UserDefaults.standard.removeObject(forKey: "cardCode")
        isLoggedIn = false
        cardInfo = nil
        errorMessage = nil
    }
}