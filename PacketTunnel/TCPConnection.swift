import Foundation
import Network

class TCPConnection {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private var requestBuffer = Data()
    private var responseBuffer = Data()
    private var isTargetRequest = false
    private var didInjectResponse = false
    private var responseInjector: ((HTTPRequest) -> HTTPResponse?)?
    private var pendingRequest: HTTPRequest?
    
    var onDataReceived: ((Data) -> Void)?
    var onComplete: (() -> Void)?
    
    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    
    func start() {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                NSLog("[TCPConnection] 连接就绪: \(self.host):\(self.port)")
                self.receive()
            case .failed(let error):
                NSLog("[TCPConnection] 连接失败: \(error)")
                self.onComplete?()
            case .cancelled:
                self.onComplete?()
            default:
                break
            }
        }
        
        connection?.start(queue: .global())
    }
    
    func send(data: Data) {
        requestBuffer.append(data)
        
        if let request = HTTPParser.shared.parseRequest(requestBuffer) {
            pendingRequest = request
            isTargetRequest = LocationInjector.shared.isTargetRequest(
                host: request.host,
                path: request.path
            )
            
            if isTargetRequest {
                NSLog("[TCPConnection] 识别到目标请求: \(request.host ?? "")\(request.path ?? "")")
            }
        }
        
        NSLog("[TCPConnection] 发送 \(data.count) 字节到 \(host):\(port)")
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[TCPConnection] 发送错误: \(error)")
            } else {
                NSLog("[TCPConnection] 发送成功")
            }
        })
    }
    
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[TCPConnection] 接收错误: \(error)")
                self.onComplete?()
                return
            }
            
            if let data = data, !data.isEmpty {
                NSLog("[TCPConnection] 收到 \(data.count) 字节")
                
                if self.isTargetRequest && !self.didInjectResponse {
                    self.responseBuffer.append(data)
                    
                    var shouldInject = false
                    
                    if let request = self.pendingRequest {
                        if let response = self.parseResponse(self.responseBuffer) {
                            if response.isComplete {
                                shouldInject = true
                            }
                        }
                    }
                    
                    if shouldInject, let request = self.pendingRequest {
                        if let location = LocationStore.shared.getSelectedLocation(),
                           let fakeResponse = self.responseInjector?(request) {
                            NSLog("[TCPConnection] 注入伪造响应")
                            self.didInjectResponse = true
                            let fakeData = fakeResponse.toData()
                            self.onDataReceived?(fakeData)
                            self.cancel()
                            return
                        }
                    }
                } else if !self.isTargetRequest {
                    self.onDataReceived?(data)
                }
            }
            
            if isComplete {
                self.onComplete?()
            } else {
                self.receive()
            }
        }
    }
    
    private func parseResponse(_ data: Data) -> (isComplete: Bool, headers: [String: String], body: Data)? {
        guard let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let lines = str.components(separatedBy: "\r\n")
        
        guard let firstLine = lines.first, firstLine.hasPrefix("HTTP/") else {
            return nil
        }
        
        var headers: [String: String] = [:]
        var headerEndIndex = 0
        
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty {
                headerEndIndex = i
                break
            }
            
            let parts = line.components(separatedBy: ": ")
            if parts.count >= 2 {
                let key = parts[0].lowercased()
                let value = parts.dropFirst().joined(separator: ": ")
                headers[key] = value
            }
        }
        
        var isComplete = false
        var body = Data()
        
        if let contentLengthStr = headers["content-length"], let contentLength = Int(contentLengthStr) {
            let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8))?.upperBound ?? data.startIndex
            body = data.subdata(in: headerEnd..<data.count)
            
            if body.count >= contentLength {
                isComplete = true
            }
        } else if str.contains("\r\n0\r\n\r\n") {
            isComplete = true
        }
        
        return (isComplete, headers, body)
    }
    
    func cancel() {
        connection?.cancel()
    }
    
    func setResponseInjector(_ injector: @escaping (HTTPRequest) -> HTTPResponse?) {
        self.responseInjector = injector
    }
}
