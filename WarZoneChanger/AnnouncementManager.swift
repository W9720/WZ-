import Foundation

struct Announcement: Codable, Equatable {
    let id: Int
    let title: String
    let content: String
    let createdAt: String
    
    static func == (lhs: Announcement, rhs: Announcement) -> Bool {
        return lhs.id == rhs.id
    }
}

class AnnouncementManager: ObservableObject {
    static let shared = AnnouncementManager()
    
    @Published var unreadAnnouncements: [Announcement] = []
    @Published var isLoading = false
    
    private let serverURL = "https://your-server-domain.com"
    private let userIDKey = "app_user_id"
    
    private var userID: String {
        if let saved = UserDefaults.standard.string(forKey: userIDKey) {
            return saved
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: userIDKey)
        return newID
    }
    
    private init() {}
    
    func fetchUnreadAnnouncements() {
        isLoading = true
        
        guard let url = URL(string: "\(serverURL)/announcement/unread") else {
            isLoading = false
            return
        }
        
        let parameters: [String: Any] = ["userId": userID]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    print("公告获取失败: \(error.localizedDescription)")
                    return
                }
                
                guard let data = data else {
                    return
                }
                
                do {
                    let result = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    
                    if let success = result?["success"] as? Bool, success {
                        if let annData = result?["data"] as? [[String: Any]] {
                            let announcements: [Announcement] = annData.compactMap { dict in
                                guard let id = dict["id"] as? Int,
                                      let title = dict["title"] as? String,
                                      let content = dict["content"] as? String else {
                                    return nil
                                }
                                return Announcement(
                                    id: id,
                                    title: title,
                                    content: content,
                                    createdAt: dict["createdAt"] as? String ?? ""
                                )
                            }
                            self?.unreadAnnouncements = announcements
                        }
                    }
                } catch {
                    print("公告解析失败")
                }
            }
        }.resume()
    }
    
    func markAsRead(announcementId: Int) {
        guard let url = URL(string: "\(serverURL)/announcement/mark-read") else {
            return
        }
        
        let parameters: [String: Any] = [
            "userId": userID,
            "announcementId": announcementId
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("标记已读失败: \(error.localizedDescription)")
                return
            }
            
            DispatchQueue.main.async {
                self?.unreadAnnouncements.removeAll { $0.id == announcementId }
            }
        }.resume()
    }
    
    func markAllAsRead() {
        unreadAnnouncements.forEach { markAsRead(announcementId: $0.id) }
    }
}