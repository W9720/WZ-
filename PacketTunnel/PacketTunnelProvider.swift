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
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) {
        let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint
        let host = remoteEndpoint?.hostname ?? ""
        let port = remoteEndpoint?.port ?? "80"
        
        NSLog("[AppProxy] TCP 连接: \(host):\(port)")
        
        guard port == "80" else {
            flow.open(withLocalEndpoint: nil) { error in
                if let error = error {
                    NSLog("[AppProxy] 打开连接失败: \(error)")
                } else {
                    self.forwardTCP(flow)
                }
            }
            return
        }
        
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[AppProxy] 打开连接失败: \(error)")
                return
            }
            
            self.interceptAndForward(flow)
        }
    }
    
    private func interceptAndForward(_ flow: NEAppProxyTCPFlow) {
        flow.readData { [weak self] data, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if let error = error {
                    NSLog("[AppProxy] 读取失败: \(error)")
                }
                return
            }
            
            if let httpStr = String(data: data, encoding: .utf8) {
                NSLog("[AppProxy] HTTP 请求:\n\(httpStr.prefix(500))")
                
                if httpStr.contains(self.targetHost) && httpStr.contains(self.targetPath) {
                    NSLog("[AppProxy] 命中目标: \(self.targetHost)\(self.targetPath)")
                    self.sendFakeResponse(flow)
                    return
                }
            }
            
            self.forwardData(flow, data: data)
        }
    }
    
    private func forwardData(_ flow: NEAppProxyTCPFlow, data: Data) {
        flow.write(data) { error in
            if let error = error {
                NSLog("[AppProxy] 写入失败: \(error)")
                return
            }
            
            flow.readData { [weak self] data, error in
                guard let self = self, let data = data, !data.isEmpty else {
                    if let error = error {
                        NSLog("[AppProxy] 读取响应失败: \(error)")
                    }
                    return
                }
                
                flow.write(data) { _ in
                    self.forwardData(flow, data: data)
                }
            }
        }
    }
    
    private func forwardTCP(_ flow: NEAppProxyTCPFlow) {
        flow.readData { [weak self] data, error in
            guard let self = self, let data = data, !data.isEmpty else { return }
            flow.write(data) { _ in
                self.forwardTCP(flow)
            }
        }
    }
    
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
            }
        }
    }
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) {
        flow.open(withLocalEndpoint: nil) { error in
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
            
            flow.writeDatagrams(datagrams, sentBy: remoteEndpoints ?? []) { _ in
                self.forwardUDP(flow)
            }
        }
    }
}
