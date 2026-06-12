import Foundation
import Network

class LocalHTTPServer {
    
    private var listener: NWListener?
    private var mobileConfig: String = ""
    private var connections: [NWConnection] = []
    
    init() {}
    
    func start(mobileConfig: String, port: UInt16 = 8080) -> Bool {
        self.mobileConfig = mobileConfig
        
        do {
            let endpointPort = NWEndpoint.Port(integerLiteral: port)
            listener = try NWListener(using: .tcp, on: endpointPort)
            
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("本地 HTTP 服务器启动成功，端口: \(port)")
                case .failed(let error):
                    print("本地 HTTP 服务器启动失败: \(error)")
                case .cancelled:
                    print("本地 HTTP 服务器已停止")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.connections.append(connection)
                self.handleConnection(connection)
            }
            
            listener?.start(queue: .main)
            return true
            
        } catch {
            print("创建 HTTP 服务器失败: \(error)")
            return false
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("连接错误: \(error)")
                connection.cancel()
                return
            }
            
            if isComplete {
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                print("未收到数据")
                connection.cancel()
                return
            }
            
            let request = String(data: data, encoding: .utf8) ?? ""
            print("收到 HTTP 请求: \(request.prefix(200))")
            
            let response = self.buildResponse()
            
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                print("响应已发送")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    connection.cancel()
                }
            })
        }
    }
    
    private func buildResponse() -> String {
        let configData = mobileConfig.data(using: .utf8) ?? Data()
        
        var response = ""
        response += "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: application/x-apple-aspen-config\r\n"
        response += "Content-Length: \(configData.count)\r\n"
        response += "Content-Disposition: attachment; filename=\"WarZoneChanger.mobileconfig\"\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += mobileConfig
        
        return response
    }
    
    func stop() {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        print("本地 HTTP 服务器已停止")
    }
    
    func isRunning() -> Bool {
        return listener != nil
    }
}
