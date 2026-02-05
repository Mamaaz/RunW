import Foundation
import NetworkExtension

/// 透明代理提供者 - 实现按应用代理
class TransparentProxyProvider: NETransparentProxyProvider {
    
    // 配置的代理地址
    private var proxyHost: String = "127.0.0.1"
    private var proxyPort: Int = 6153
    private var useSOCKS5: Bool = true
    
    // 需要代理的 Bundle ID 列表
    private var proxiedBundleIDs: Set<String> = []
    
    // 需要拒绝的 Bundle ID 列表
    private var rejectedBundleIDs: Set<String> = []
    
    override func startProxy(options: [String : Any]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[RunWProxy] 启动透明代理...")
        
        // 从 options 读取配置
        if let host = options?["proxyHost"] as? String {
            proxyHost = host
        }
        if let port = options?["proxyPort"] as? Int {
            proxyPort = port
        }
        if let useSocks = options?["useSOCKS5"] as? Bool {
            useSOCKS5 = useSocks
        }
        if let proxied = options?["proxiedBundleIDs"] as? [String] {
            proxiedBundleIDs = Set(proxied)
        }
        if let rejected = options?["rejectedBundleIDs"] as? [String] {
            rejectedBundleIDs = Set(rejected)
        }
        
        NSLog("[RunWProxy] 配置: \(proxyHost):\(proxyPort), SOCKS5: \(useSOCKS5)")
        NSLog("[RunWProxy] 代理应用: \(proxiedBundleIDs)")
        NSLog("[RunWProxy] 拒绝应用: \(rejectedBundleIDs)")
        
        completionHandler(nil)
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[RunWProxy] 停止透明代理, 原因: \(reason)")
        completionHandler()
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // 获取发起连接的应用信息
        guard let appDescription = flow.metaData.sourceAppSigningIdentifier.components(separatedBy: ".").last else {
            // 无法识别应用，直接放行
            return false
        }
        
        let bundleID = flow.metaData.sourceAppSigningIdentifier
        
        // 检查是否需要拒绝
        if rejectedBundleIDs.contains(bundleID) {
            NSLog("[RunWProxy] 拒绝连接: \(bundleID)")
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return true
        }
        
        // 检查是否需要代理
        if proxiedBundleIDs.contains(bundleID) {
            NSLog("[RunWProxy] 代理连接: \(bundleID)")
            handleProxiedFlow(flow)
            return true
        }
        
        // 其他应用直连
        return false
    }
    
    private func handleProxiedFlow(_ flow: NEAppProxyFlow) {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handleTCPFlow(tcpFlow)
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            handleUDPFlow(udpFlow)
        }
    }
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) {
        // 获取目标地址
        guard let endpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return
        }
        
        let destHost = endpoint.hostname
        let destPort = endpoint.port
        
        NSLog("[RunWProxy] TCP 连接: \(destHost):\(destPort)")
        
        // 创建到代理服务器的连接
        let proxyEndpoint = NWHostEndpoint(hostname: proxyHost, port: String(proxyPort))
        
        // 打开到代理的连接
        flow.open(withLocalEndpoint: nil) { error in
            if let error = error {
                NSLog("[RunWProxy] 打开流失败: \(error)")
                return
            }
            
            // 如果使用 SOCKS5，发送握手
            if self.useSOCKS5 {
                self.performSOCKS5Handshake(flow: flow, destHost: destHost, destPort: destPort)
            } else {
                // HTTP CONNECT
                self.performHTTPConnect(flow: flow, destHost: destHost, destPort: destPort)
            }
        }
    }
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) {
        // UDP 代理支持（简化版，直接放行）
        NSLog("[RunWProxy] UDP 流量，暂不支持代理")
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
    
    // MARK: - SOCKS5 Protocol
    
    private func performSOCKS5Handshake(flow: NEAppProxyTCPFlow, destHost: String, destPort: String) {
        // SOCKS5 握手第一步：发送版本和认证方法
        // 0x05 = SOCKS5, 0x01 = 1个方法, 0x00 = 无认证
        let greeting = Data([0x05, 0x01, 0x00])
        
        flow.write(greeting) { error in
            if let error = error {
                NSLog("[RunWProxy] SOCKS5 握手失败: \(error)")
                return
            }
            
            // 读取服务器响应
            flow.readData(ofMinLength: 2, maxLength: 2) { responseData, error in
                if let error = error {
                    NSLog("[RunWProxy] SOCKS5 握手响应失败: \(error)")
                    return
                }
                
                guard let data = responseData, data.count == 2,
                      data[0] == 0x05, data[1] == 0x00 else {
                    NSLog("[RunWProxy] SOCKS5 握手响应无效")
                    return
                }
                
                // 发送连接请求
                self.sendSOCKS5ConnectRequest(flow: flow, destHost: destHost, destPort: destPort)
            }
        }
    }
    
    private func sendSOCKS5ConnectRequest(flow: NEAppProxyTCPFlow, destHost: String, destPort: String) {
        // SOCKS5 连接请求
        // 0x05 = SOCKS5, 0x01 = CONNECT, 0x00 = 保留, 0x03 = 域名类型
        var request = Data([0x05, 0x01, 0x00, 0x03])
        
        // 域名长度 + 域名
        let hostData = destHost.data(using: .utf8)!
        request.append(UInt8(hostData.count))
        request.append(hostData)
        
        // 端口（大端序）
        let port = UInt16(destPort) ?? 443
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        
        flow.write(request) { error in
            if let error = error {
                NSLog("[RunWProxy] SOCKS5 连接请求失败: \(error)")
                return
            }
            
            // 读取连接响应（至少10字节）
            flow.readData(ofMinLength: 10, maxLength: 32) { responseData, error in
                if let error = error {
                    NSLog("[RunWProxy] SOCKS5 连接响应失败: \(error)")
                    return
                }
                
                guard let data = responseData, data.count >= 10,
                      data[0] == 0x05, data[1] == 0x00 else {
                    NSLog("[RunWProxy] SOCKS5 连接失败")
                    return
                }
                
                NSLog("[RunWProxy] SOCKS5 连接成功: \(destHost):\(destPort)")
                // 连接建立成功，现在可以转发数据
                self.startForwarding(flow: flow)
            }
        }
    }
    
    // MARK: - HTTP CONNECT
    
    private func performHTTPConnect(flow: NEAppProxyTCPFlow, destHost: String, destPort: String) {
        let connectRequest = "CONNECT \(destHost):\(destPort) HTTP/1.1\r\nHost: \(destHost):\(destPort)\r\n\r\n"
        let requestData = connectRequest.data(using: .utf8)!
        
        flow.write(requestData) { error in
            if let error = error {
                NSLog("[RunWProxy] HTTP CONNECT 失败: \(error)")
                return
            }
            
            // 读取响应
            flow.readData(ofMinLength: 12, maxLength: 1024) { responseData, error in
                if let error = error {
                    NSLog("[RunWProxy] HTTP CONNECT 响应失败: \(error)")
                    return
                }
                
                guard let data = responseData,
                      let response = String(data: data, encoding: .utf8),
                      response.contains("200") else {
                    NSLog("[RunWProxy] HTTP CONNECT 失败")
                    return
                }
                
                NSLog("[RunWProxy] HTTP CONNECT 成功: \(destHost):\(destPort)")
                self.startForwarding(flow: flow)
            }
        }
    }
    
    // MARK: - Data Forwarding
    
    private func startForwarding(flow: NEAppProxyTCPFlow) {
        // 持续读取和转发数据
        readAndForward(flow: flow)
    }
    
    private func readAndForward(flow: NEAppProxyTCPFlow) {
        flow.readData(ofMinLength: 1, maxLength: 65536) { data, error in
            if let error = error {
                NSLog("[RunWProxy] 读取数据错误: \(error)")
                return
            }
            
            guard let data = data, !data.isEmpty else {
                // 连接关闭
                return
            }
            
            // 写入数据
            flow.write(data) { writeError in
                if let writeError = writeError {
                    NSLog("[RunWProxy] 写入数据错误: \(writeError)")
                    return
                }
                
                // 继续读取
                self.readAndForward(flow: flow)
            }
        }
    }
}
