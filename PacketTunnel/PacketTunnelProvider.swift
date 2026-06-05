import NetworkExtension
import Foundation

class PacketTunnelProvider: NEAppProxyProvider {
    
    override func startProxy(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[PacketTunnel] 开始启动代理...")
        
        let settings = NEAppProxySettings()
        settings.includedDomains = ["apis.map.qq.com"]
        settings.excludedDomains = ["127.0.0.1", "localhost", "*.local"]
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 设置网络配置失败: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            NSLog("[PacketTunnel] 网络配置设置成功")
            completionHandler(nil)
        }
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[PacketTunnel] 停止代理，原因: \(reason.rawValue)")
        completionHandler()
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            NSLog("[PacketTunnel] 不支持的流类型")
            return false
        }
        
        let remoteHost = tcpFlow.remoteHost as String
        let remotePort = tcpFlow.remotePort as NSNumber
        
        NSLog("[PacketTunnel] 新的TCP流: \(remoteHost):\(remotePort)")
        
        if remoteHost.contains("apis.map.qq.com") {
            handleTargetFlow(tcpFlow)
        } else {
            handleNormalFlow(tcpFlow)
        }
        
        return true
    }
    
    private func handleTargetFlow(_ flow: NEAppProxyTCPFlow) {
        NSLog("[PacketTunnel] 处理目标请求")
        
        let host = flow.remoteHost as String
        let port = flow.remotePort as NSNumber
        
        flow.readData { [weak self] data, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 读取数据失败: \(error)")
                flow.closeRead()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                flow.closeRead()
                return
            }
            
            if let request = HTTPParser.shared.parseRequest(data) {
                let isTarget = LocationInjector.shared.isTargetRequest(host: request.host, path: request.path)
                
                if isTarget {
                    NSLog("[PacketTunnel] 检测到目标请求，发送伪造响应")
                    
                    if let location = LocationStore.shared.getSelectedLocation() {
                        let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: location.adcode, regionName: location.name)
                        let fakeResponse = HTTPResponse(
                            version: "HTTP/1.1",
                            statusCode: 200,
                            statusMessage: "OK",
                            headers: [
                                "Content-Type": "application/json; charset=utf-8",
                                "Connection": "close",
                                "Content-Length": "\(fakeBody.data(using: .utf8)?.count ?? 0)"
                            ],
                            body: fakeBody.data(using: .utf8) ?? Data()
                        )
                        
                        let responseData = fakeResponse.toData()
                        
                        flow.writeData(responseData) { error in
                            if let error = error {
                                NSLog("[PacketTunnel] 写入伪造响应失败: \(error)")
                            }
                            flow.closeWrite()
                            flow.closeRead()
                        }
                        
                        return
                    }
                }
            }
            
            self.forwardToRealServer(flow, host: host, port: port, initialData: data)
        }
    }
    
    private func handleNormalFlow(_ flow: NEAppProxyTCPFlow) {
        let host = flow.remoteHost as String
        let port = flow.remotePort as NSNumber
        
        NSLog("[PacketTunnel] 转发正常请求到 \(host):\(port)")
        
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(truncating: port))!, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self, flow] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.startProxying(flow: flow, connection: connection)
                
            case .failed(let error):
                NSLog("[PacketTunnel] 连接失败: \(error)")
                flow.closeRead()
                flow.closeWrite()
                connection.cancel()
                
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func forwardToRealServer(_ flow: NEAppProxyTCPFlow, host: String, port: NSNumber, initialData: Data) {
        NSLog("[PacketTunnel] 转发到真实服务器 \(host):\(port)")
        
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(truncating: port))!, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self, flow, initialData] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                connection.send(content: initialData, completion: .contentProcessed { _ in })
                self.startProxying(flow: flow, connection: connection)
                
            case .failed(let error):
                NSLog("[PacketTunnel] 连接服务器失败: \(error)")
                flow.closeRead()
                flow.closeWrite()
                connection.cancel()
                
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func startProxying(flow: NEAppProxyTCPFlow, connection: NWConnection) {
        flow.readData { [weak self, connection] data, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 读取客户端数据失败: \(error)")
                connection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in })
                self.startProxying(flow: flow, connection: connection)
            } else {
                flow.closeRead()
                connection.cancel()
            }
        }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self, flow] data, _, _, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[PacketTunnel] 读取服务器数据失败: \(error)")
                flow.closeWrite()
                return
            }
            
            if let data = data, !data.isEmpty {
                flow.writeData(data) { [weak self, flow, connection] error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        NSLog("[PacketTunnel] 写入客户端数据失败: \(error)")
                        connection.cancel()
                        return
                    }
                    
                    self.startProxying(flow: flow, connection: connection)
                }
            } else {
                flow.closeWrite()
            }
        }
    }
}