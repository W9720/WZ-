import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let host: String?
    let port: Int
    let body: Data?
    
    var fullURL: String {
        return "http://\(host ?? ""):\(port)\(path)"
    }
}

struct HTTPResponse {
    let version: String
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let body: Data
    
    init(statusCode: Int, statusMessage: String, headers: [String: String] = [:], body: Data = Data()) {
        self.version = "HTTP/1.1"
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.headers = headers
        self.body = body
    }
    
    func toData() -> Data {
        var headerLines = ["\(version) \(statusCode) \(statusMessage)"]
        
        var allHeaders = headers
        if allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = "close"
        }
        
        for (key, value) in allHeaders {
            headerLines.append("\(key): \(value)")
        }
        
        headerLines.append("")
        
        var data = headerLines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        data.append("\r\n".data(using: .utf8)!)
        data.append(body)
        
        return data
    }
}

class HTTPParser {
    static let shared = HTTPParser()
    
    private init() {}
    
    func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard lines.count > 0 else {
            return nil
        }
        
        let requestLine = lines[0]
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            return nil
        }
        
        let method = parts[0]
        let path = parts[1]
        let version = parts[2]
        
        var headers: [String: String] = [:]
        var host: String?
        var port = 80
        
        var bodyStartIndex = -1
        
        for (index, line) in lines.enumerated() where index > 0 {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                let key = headerParts[0]
                let value = headerParts[1...].joined(separator: ": ")
                headers[key] = value
                
                if key.lowercased() == "host" {
                    let hostParts = value.components(separatedBy: ":")
                    host = hostParts[0]
                    if hostParts.count > 1, let p = Int(hostParts[1]) {
                        port = p
                    }
                }
            }
        }
        
        var body: Data?
        if bodyStartIndex > 0 && bodyStartIndex < lines.count {
            let bodyLines = lines[bodyStartIndex...].joined(separator: "\r\n")
            body = bodyLines.data(using: .utf8)
        }
        
        return HTTPRequest(
            method: method,
            path: path,
            version: version,
            headers: headers,
            host: host,
            port: port,
            body: body
        )
    }
    
    func parseResponse(_ data: Data) -> HTTPResponse? {
        guard let responseString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let lines = responseString.components(separatedBy: "\r\n")
        guard lines.count > 0 else {
            return nil
        }
        
        let statusLine = lines[0]
        let parts = statusLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            return nil
        }
        
        let version = parts[0]
        guard let statusCode = Int(parts[1]) else {
            return nil
        }
        let statusMessage = parts[2...].joined(separator: " ")
        
        var headers: [String: String] = [:]
        var bodyStartIndex = -1
        
        for (index, line) in lines.enumerated() where index > 0 {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                let key = headerParts[0]
                let value = headerParts[1...].joined(separator: ": ")
                headers[key] = value
            }
        }
        
        var body = Data()
        if bodyStartIndex > 0 && bodyStartIndex < lines.count {
            let bodyLines = lines[bodyStartIndex...].joined(separator: "\r\n")
            body = bodyLines.data(using: .utf8) ?? Data()
        }
        
        return HTTPResponse(
            version: version,
            statusCode: statusCode,
            statusMessage: statusMessage,
            headers: headers,
            body: body
        )
    }
}
