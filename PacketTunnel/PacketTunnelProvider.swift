import NetworkExtension
import Foundation

class PacketTunnelProvider: NEAppProxyProvider {
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    
    override func startProxy(options: [String : Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[AppProxy] 启动代理")
        completionHandler(nil)
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handleTCPFlow(tcpFlow)
            return true
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            handleUDPFlow(udpFlow)
            return true
        }
        return false
    }
    
    // MARK: - TCP Flow Handling
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) {
        let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint
        let host = remoteEndpoint?.hostname ?? ""
        let port = remoteEndpoint?.port ?? ""
        
        NSLog("[AppProxy] TCP 连接: \(host):\(port)")
        
        // 打开连接到远程服务器
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[AppProxy] 打开连接失败: \(error)")
                return
            }
            
            // 只有端口 80 的流量才需要拦截检查
            if port == "80" {
                self.interceptHTTPFlow(flow)
            } else {
                // 其他端口直接双向转发
                self.bidirectionalForward(flow)
            }
        }
    }
    
    // 拦截 HTTP 流量
    private func interceptHTTPFlow(_ flow: NEAppProxyTCPFlow) {
        flow.readData { [weak self] data, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if let error = error {
                    NSLog("[AppProxy] 读取失败: \(error)")
                }
                return
            }
            
            // 尝试解析 HTTP 请求
            if let httpStr = String(data: data, encoding: .utf8) {
                NSLog("[AppProxy] HTTP 请求:\n\(httpStr.prefix(500))")
                
                if httpStr.contains(self.targetHost) && httpStr.contains(self.targetPath) {
                    NSLog("[AppProxy] 命中目标: \(self.targetHost)\(self.targetPath)")
                    self.sendFakeResponse(flow)
                    return
                }
            }
            
            // 不是目标请求，直接转发到服务器
            self.forwardToServer(flow, clientData: data)
        }
    }
    
    // 转发客户端数据到服务器，并读取服务器响应回写客户端
    private func forwardToServer(_ flow: NEAppProxyTCPFlow, clientData: Data) {
        flow.write(clientData) { error in
            if let error = error {
                NSLog("[AppProxy] 写入服务器失败: \(error)")
                return
            }
            
            // 写入成功后，读取服务器响应
            self.readFromServer(flow)
        }
    }
    
    // 读取服务器响应并回写客户端
    private func readFromServer(_ flow: NEAppProxyTCPFlow) {
        flow.readData { [weak self] serverData, error in
            guard let self = self, let serverData = serverData, !serverData.isEmpty else {
                if let error = error {
                    NSLog("[AppProxy] 读取服务器响应失败: \(error)")
                }
                return
            }
            
            // 回写给客户端
            flow.write(serverData) { error in
                if let error = error {
                    NSLog("[AppProxy] 回写客户端失败: \(error)")
                    return
                }
                // 继续读取更多数据（HTTP 响应可能分多次返回）
                self.readFromServer(flow)
            }
        }
    }
    
    // 双向转发（用于非 HTTP 端口）
    private func bidirectionalForward(_ flow: NEAppProxyTCPFlow) {
        flow.readData { [weak self] data, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if let error = error {
                    NSLog("[AppProxy] 双向转发读取失败: \(error)")
                }
                return
            }
            
            // 写入数据（系统自动转发到服务器）
            flow.write(data) { error in
                if let error = error {
                    NSLog("[AppProxy] 双向转发写入失败: \(error)")
                    return
                }
                // 继续读取
                self.bidirectionalForward(flow)
            }
        }
    }
    
    // 发送假响应
    private func sendFakeResponse(_ flow: NEAppProxyTCPFlow) {
        let location = LocationStore.shared.getSelectedLocation()
        let adcode = location?.adcode ?? "110101"
        let name = location?.name ?? "东城区"
        
        let fakeBody = LocationInjector.shared.buildFakeResponse(adcode: adcode, regionName: name)
        let bodyData = fakeBody.data(using: .utf8) ?? Data()
        
        let response = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        
        NSLog("[AppProxy] 发送假响应，长度: \(responseData.count)")
        
        flow.write(responseData) { error in
            if let error = error {
                NSLog("[AppProxy] 发送假响应失败: \(error)")
            } else {
                NSLog("[AppProxy] 假响应发送成功")
            }
        }
    }
    
    // MARK: - UDP Flow Handling
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[AppProxy] UDP 打开失败: \(error)")
                return
            }
            self.forwardUDP(flow)
        }
    }
    
    private func forwardUDP(_ flow: NEAppProxyUDPFlow) {
        flow.readDatagrams { [weak self] datagrams, remoteEndpoints, error in
            guard let self = self, let datagrams = datagrams, !datagrams.isEmpty else {
                if let error = error {
                    NSLog("[AppProxy] UDP 读取失败: \(error)")
                }
                return
            }
            
            flow.writeDatagrams(datagrams, sentBy: remoteEndpoints ?? []) { error in
                if let error = error {
                    NSLog("[AppProxy] UDP 写入失败: \(error)")
                    return
                }
                self.forwardUDP(flow)
            }
        }
    }
}
