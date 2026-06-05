import Foundation
import Network

class TCPConnection {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private var requestBuffer = Data()
    private var responseBuffer = Data()
    private var isTargetRequest = false
    private var didReceiveCompleteRequest = false
    private var responseInjector: ((HTTPRequest) -> HTTPResponse?)?
    
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
                self.receive()
            case .failed(let error):
                print("TCP Connection failed: \(error)")
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
            isTargetRequest = LocationInjector.shared.isTargetRequest(
                host: request.host,
                path: request.path
            )
            
            if isTargetRequest {
                print("[LocationInjector] 识别到腾讯地图API请求: \(request.host ?? "")\(request.path)")
                
                if let location = LocationStore.shared.getSelectedLocation(),
                   let fakeResponse = responseInjector?(request) {
                    print("[LocationInjector] 替换响应: adcode=\(location.adcode), 区域=\(location.name)")
                    let fakeData = fakeResponse.toData()
                    onDataReceived?(fakeData)
                    cancel()
                    return
                }
            }
        }
        
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("Send error: \(error)")
            }
        })
    }
    
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Receive error: \(error)")
                self.onComplete?()
                return
            }
            
            if let data = data, !data.isEmpty {
                if self.isTargetRequest {
                    print("[LocationInjector] 拦截到真实响应，已忽略")
                } else {
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
    
    func cancel() {
        connection?.cancel()
    }
    
    func setResponseInjector(_ injector: @escaping (HTTPRequest) -> HTTPResponse?) {
        self.responseInjector = injector
    }
}
