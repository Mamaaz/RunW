import NetworkExtension
import Network
import os.log

/// 透明代理 Provider - 实现按应用代理
class TransparentProxyProvider: NEAppProxyProvider {
    
    private let logger = Logger(subsystem: "com.dundun.runw.proxy", category: "TransparentProxy")
    
    // 代理配置
    private var proxyHost: String = "127.0.0.1"
    private var socksPort: UInt16 = 7891
    
    // 应用规则
    private var proxyApps: Set<String> = []  // 需要代理的应用
    private var rejectApps: Set<String> = [] // 需要拒绝的应用
    
    // App Group 共享数据
    private let appGroupID = "LLNRYKR4A6.com.dundun.runw"
    
    // MARK: - Lifecycle
    
    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("🚀 启动透明代理...")
        
        // 加载配置和规则
        loadConfig()
        loadAppRules()
        
        // 从启动选项读取配置
        if let host = options?["proxyHost"] as? String {
            proxyHost = host
        }
        if let socks = options?["socksPort"] as? NSNumber {
            socksPort = socks.uint16Value
        }
        
        logger.info("✅ 代理配置: SOCKS5 \(self.proxyHost):\(self.socksPort)")
        logger.info("📱 代理应用: \(self.proxyApps.count) 个, 拒绝应用: \(self.rejectApps.count) 个")
        
        completionHandler(nil)
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("🛑 停止透明代理, 原因: \(String(describing: reason))")
        completionHandler()
    }
    
    // MARK: - Config
    
    private func loadConfig() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        
        if let host = defaults.string(forKey: "proxyHost") {
            proxyHost = host
        }
        if defaults.object(forKey: "socksPort") != nil {
            socksPort = UInt16(defaults.integer(forKey: "socksPort"))
        }
    }
    
    private func loadAppRules() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        
        if let proxyList = defaults.stringArray(forKey: "proxyApps") {
            proxyApps = Set(proxyList)
        }
        if let rejectList = defaults.stringArray(forKey: "rejectApps") {
            rejectApps = Set(rejectList)
        }
    }
    
    // MARK: - Flow Handling
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let appID = flow.metaData.sourceAppSigningIdentifier
        
        // 检查是否需要拒绝
        if rejectApps.contains(appID) {
            logger.info("🚫 拒绝流量: \(appID)")
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return true
        }
        
        // 检查是否需要代理
        let shouldProxy = proxyApps.isEmpty || proxyApps.contains(appID)
        
        if !shouldProxy {
            logger.debug("⏭️ 直连: \(appID)")
            return false // 不处理，让系统直连
        }
        
        logger.info("📱 代理流量: \(appID)")
        
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            Task {
                await handleTCPFlow(tcpFlow)
            }
            return true
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            Task {
                await handleUDPFlow(udpFlow)
            }
            return true
        }
        
        return false
    }
    
    // MARK: - TCP Flow
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) async {
        guard let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            logger.error("❌ 无法获取远程端点")
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return
        }
        
        let targetHost = remoteEndpoint.hostname
        let targetPort = UInt16(remoteEndpoint.port) ?? 80
        
        logger.info("🔗 TCP 连接: \(targetHost):\(targetPort)")
        
        // 创建到 SOCKS5 代理的连接
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: socksPort)
        )
        
        let connection = NWConnection(to: proxyEndpoint, using: .tcp)
        
        // 启动连接
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.logger.info("✅ 代理连接就绪")
                    continuation.resume()
                case .failed(let error):
                    self?.logger.error("❌ 代理连接失败: \(error.localizedDescription)")
                    continuation.resume()
                case .cancelled:
                    self?.logger.info("🚫 代理连接取消")
                    continuation.resume()
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        
        guard connection.state == .ready else {
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return
        }
        
        // SOCKS5 握手
        do {
            try await performSOCKS5Handshake(connection: connection, host: targetHost, port: targetPort)
        } catch {
            logger.error("❌ SOCKS5 握手失败: \(error.localizedDescription)")
            connection.cancel()
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
            return
        }
        
        // 打开 flow
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                flow.open(withLocalEndpoint: nil) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            logger.error("❌ 打开 flow 失败: \(error.localizedDescription)")
            connection.cancel()
            return
        }
        
        logger.info("🔄 开始双向转发: \(targetHost):\(targetPort)")
        
        // 双向转发数据
        await withTaskGroup(of: Void.self) { group in
            // Flow -> Proxy
            group.addTask {
                await self.forwardFlowToConnection(flow: flow, connection: connection)
            }
            
            // Proxy -> Flow
            group.addTask {
                await self.forwardConnectionToFlow(connection: connection, flow: flow)
            }
        }
        
        connection.cancel()
        logger.info("✅ 连接结束: \(targetHost):\(targetPort)")
    }
    
    // MARK: - SOCKS5 Handshake
    
    private func performSOCKS5Handshake(connection: NWConnection, host: String, port: UInt16) async throws {
        // 步骤 1: 发送问候消息
        let greeting = Data([0x05, 0x01, 0x00]) // SOCKS5, 1 method, No Auth
        try await send(data: greeting, on: connection)
        
        // 步骤 2: 读取响应
        let response1 = try await receive(on: connection, minLength: 2)
        guard response1.count >= 2, response1[0] == 0x05, response1[1] == 0x00 else {
            throw ProxyError.handshakeFailed
        }
        
        // 步骤 3: 发送连接请求
        var connectRequest = Data([0x05, 0x01, 0x00, 0x03]) // SOCKS5, CONNECT, RSV, DOMAINNAME
        connectRequest.append(UInt8(host.utf8.count))
        connectRequest.append(contentsOf: host.utf8)
        connectRequest.append(UInt8(port >> 8))
        connectRequest.append(UInt8(port & 0xFF))
        
        try await send(data: connectRequest, on: connection)
        
        // 步骤 4: 读取连接响应
        let response2 = try await receive(on: connection, minLength: 4)
        guard response2.count >= 2, response2[0] == 0x05, response2[1] == 0x00 else {
            throw ProxyError.connectionRejected
        }
        
        logger.info("🤝 SOCKS5 握手成功: \(host):\(port)")
    }
    
    // MARK: - Data Forwarding
    
    private func forwardFlowToConnection(flow: NEAppProxyTCPFlow, connection: NWConnection) async {
        while true {
            do {
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    flow.readData { data, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let data = data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
                
                if data.isEmpty { break }
                
                try await send(data: data, on: connection)
            } catch {
                break
            }
        }
        
        flow.closeReadWithError(nil)
    }
    
    private func forwardConnectionToFlow(connection: NWConnection, flow: NEAppProxyTCPFlow) async {
        while true {
            do {
                let data = try await receive(on: connection, minLength: 1)
                if data.isEmpty { break }
                
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    flow.write(data) { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } catch {
                break
            }
        }
        
        flow.closeWriteWithError(nil)
    }
    
    // MARK: - UDP Flow
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) async {
        // UDP 暂时直接放行
        flow.open(withLocalEndpoint: nil) { error in
            if let error = error {
                self.logger.error("❌ UDP 打开失败: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Network Helpers
    
    private func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receive(on connection: NWConnection, minLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: minLength, maximumLength: 65535) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }
}

// MARK: - Errors

enum ProxyError: Error, LocalizedError {
    case handshakeFailed
    case connectionRejected
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .handshakeFailed: return "SOCKS5 握手失败"
        case .connectionRejected: return "代理拒绝连接"
        case .invalidResponse: return "无效的代理响应"
        }
    }
}
