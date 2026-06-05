import NetworkExtension
import Foundation

class PacketTunnelProvider: NEAppProxyProvider {
    
    override func startProxy(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 启动代理...")
        
        let settings = NEAppProxySettings(tunnelRemoteAddress: "10.0.0.1")
        settings.httpProxySettings = NEProxySettings()
        settings.httpsProxySettings = NEProxySettings()
        
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("[PacketTunnel] 设置失败: \(error)")
                completionHandler(error)
                return
            }
            NSLog("[PacketTunnel] 设置成功")
            completionHandler(nil)
        }
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            return false
        }
        
        let remoteHost = tcpFlow.remoteHost ?? ""
        let remotePort = tcpFlow.remotePort?.rawValue ?? 0
        
        NSLog("[PacketTunnel] 新连接: \(remoteHost):\(remotePort)")
        
        let connection = NWConnection(
            host: NWEndpoint.Host(remoteHost),
            port: NWEndpoint.Port(rawValue: UInt16(remotePort))!,
            using: .tcp
        )
        
        connection.stateUpdateHandler = { [weak self, weak tcpFlow] state in
            guard let self = self, let tcpFlow = tcpFlow else { return }
            
            switch state {
            case .ready:
                NSLog("[PacketTunnel] 连接成功: \(remoteHost):\(remotePort)")
                self.forwardData(tcpFlow: tcpFlow, connection: connection)
            case .failed(let error):
                NSLog("[PacketTunnel] 连接失败: \(error)")
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        
        connection.start(queue: .global())
        
        return true
    }
    
    private func forwardData(tcpFlow: NEAppProxyTCPFlow, connection: NWConnection) {
        var requestBuffer = Data()
        var isTargetRequest = false
        
        tcpFlow.readData(completionHandler: { [weak self, weak tcpFlow] data, error in
            guard let self = self, let tcpFlow = tcpFlow, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            requestBuffer.append(data)
            
            if !isTargetRequest {
                if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                    isTargetRequest = LocationInjector.shared.isTargetRequest(
                        host: request.host,
                        path: request.path
                    )
                    
                    if isTargetRequest {
                        NSLog("[PacketTunnel] 检测到目标请求: \(request.host ?? "")\(request.path ?? "")")
                    }
                }
            }
            
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    NSLog("[PacketTunnel] 发送失败: \(error)")
                }
            })
            
            tcpFlow.readData(completionHandler: { [weak self, weak tcpFlow] data, error in
                guard let self = self, let tcpFlow = tcpFlow else {
                    connection.cancel()
                    return
                }
                
                if let error = error {
                    NSLog("[PacketTunnel] 读取失败: \(error)")
                    connection.cancel()
                    return
                }
                
                if let data = data, !data.isEmpty {
                    requestBuffer.append(data)
                    
                    if !isTargetRequest {
                        if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                            isTargetRequest = LocationInjector.shared.isTargetRequest(
                                host: request.host,
                                path: request.path
                            )
                        }
                    }
                    
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
                
                tcpFlow.readData(completionHandler: self.readHandler(requestBuffer: &requestBuffer, isTargetRequest: &isTargetRequest, tcpFlow: tcpFlow, connection: connection))
            })
        })
        
        self.receiveFromServer(tcpFlow: tcpFlow, connection: connection, isTargetRequest: &isTargetRequest)
    }
    
    private func readHandler(requestBuffer: inout Data, isTargetRequest: inout Bool, tcpFlow: NEAppProxyTCPFlow, connection: NWConnection) -> (Data?, Error?) -> Void {
        return { [weak self, weak tcpFlow, weak connection] data, error in
            guard let self = self, let tcpFlow = tcpFlow else {
                connection?.cancel()
                return
            }
            
            if let error = error {
                NSLog("[PacketTunnel] 读取失败: \(error)")
                connection?.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                requestBuffer.append(data)
                
                if !isTargetRequest {
                    if let request = HTTPParser.shared.parseRequest(requestBuffer) {
                        isTargetRequest = LocationInjector.shared.isTargetRequest(
                            host: request.host,
                            path: request.path
                        )
                    }
                }
                
                connection?.send(content: data, completion: .contentProcessed { _ in })
            }
            
            tcpFlow.readData(completionHandler: self.readHandler(requestBuffer: &requestBuffer, isTargetRequest: &isTargetRequest, tcpFlow: tcpFlow, connection: connection!))
        }
    }
    
    private func receiveFromServer(tcpFlow: NEAppProxyTCPFlow, connection: NWConnection, isTargetRequest: inout Bool) {
        var responseBuffer = Data()
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self, weak tcpFlow, weak connection] data, context, isComplete, error in
            guard let self = self, let tcpFlow = tcpFlow else {
                connection?.cancel()
                return
            }
            
            if let error = error {
                NSLog("[PacketTunnel] 接收失败: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                if isTargetRequest {
                    responseBuffer.append(data)
                    
                    if let response = HTTPParser.shared.parseResponse(responseBuffer) {
                        let contentLength = response.headers["Content-Length"] ?? "0"
                        let bodyLength = response.body.count
                        
                        if bodyLength >= Int(contentLength) ?? 0 {
                            if let location = LocationStore.shared.getSelectedLocation() {
                                NSLog("[PacketTunnel] 注入伪造响应: \(location.adcode)")
                                
                                let fakeBody = LocationInjector.shared.buildFakeResponse(
                                    adcode: location.adcode,
                                    regionName: location.name
                                )
                                
                                let fakeResponse = HTTPResponse(
                                    version: "HTTP/1.1",
                                    statusCode: 200,
                                    statusMessage: "OK",
                                    headers: [
                                        "Content-Type": "application/json; charset=utf-8",
                                        "Server": "tencent-nginx",
                                        "Connection": "close",
                                        "Content-Length": "\(fakeBody.data(using: .utf8)?.count ?? 0)"
                                    ],
                                    body: fakeBody.data(using: .utf8) ?? Data()
                                )
                                
                                tcpFlow.writeData(fakeResponse.toData()) { error in
                                    if let error = error {
                                        NSLog("[PacketTunnel] 写入失败: \(error)")
                                    }
                                }
                                
                                responseBuffer.removeAll()
                                isTargetRequest = false
                                connection?.cancel()
                                return
                            }
                        }
                    }
                } else {
                    tcpFlow.writeData(data) { error in
                        if let error = error {
                            NSLog("[PacketTunnel] 写入失败: \(error)")
                        }
                    }
                }
            }
            
            if isComplete {
                connection?.cancel()
            } else {
                self.receiveFromServer(tcpFlow: tcpFlow, connection: connection!, isTargetRequest: &isTargetRequest)
            }
        }
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止代理")
        completionHandler()
    }
}
