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
    private var proxyApps: Set<String> = []
    private var rejectApps: Set<String> = []
    
    // App Group
    private let appGroupID = "LLNRYKR4A6.com.dundun.runw"
    
    // MARK: - Lifecycle
    
    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("🚀 启动透明代理...")
        
        loadConfig()
        loadAppRules()
        
        if let host = options?["proxyHost"] as? String {
            proxyHost = host
        }
        if let socks = options?["socksPort"] as? NSNumber {
            socksPort = socks.uint16Value
        }
        
        logger.info("✅ 代理: \(self.proxyHost):\(self.socksPort), 应用: \(self.proxyApps.count) 个")
        
        completionHandler(nil)
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("🛑 停止透明代理")
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
        
        // 拒绝规则
        if rejectApps.contains(appID) {
            logger.info("🚫 拒绝: \(appID)")
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return true
        }
        
        // 代理规则：如果设置了代理应用列表，只代理列表中的应用
        let shouldProxy = proxyApps.isEmpty || proxyApps.contains(appID)
        
        if !shouldProxy {
            logger.debug("⏭️ 直连: \(appID)")
            return false
        }
        
        logger.info("📱 代理: \(appID)")
        
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            Task { await handleTCPFlow(tcpFlow) }
            return true
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            // UDP 直接放行
            udpFlow.open(withLocalEndpoint: nil) { _ in }
            return true
        }
        
        return false
    }
    
    // MARK: - TCP Flow
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) async {
        guard let remoteEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            logger.error("❌ 无法获取远程端点")
            closeFlow(flow)
            return
        }
        
        let targetHost = remoteEndpoint.hostname
        let targetPort = UInt16(remoteEndpoint.port) ?? 80
        
        logger.info("🔗 连接: \(targetHost):\(targetPort)")
        
        // 1. 创建代理连接
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: socksPort)
        )
        
        let connection = NWConnection(to: proxyEndpoint, using: .tcp)
        
        // 2. 等待连接就绪
        let connectResult = await waitForConnection(connection)
        guard connectResult else {
            logger.error("❌ 代理连接失败")
            closeFlow(flow)
            return
        }
        
        // 3. SOCKS5 握手
        do {
            try await performSOCKS5Handshake(connection: connection, host: targetHost, port: targetPort)
        } catch {
            logger.error("❌ SOCKS5 失败: \(error.localizedDescription)")
            connection.cancel()
            closeFlow(flow)
            return
        }
        
        // 4. 打开 flow
        let flowOpened = await openFlow(flow)
        guard flowOpened else {
            logger.error("❌ 打开 flow 失败")
            connection.cancel()
            return
        }
        
        logger.info("🔄 转发: \(targetHost):\(targetPort)")
        
        // 5. 双向转发
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.forwardFlowToProxy(flow: flow, connection: connection) }
            group.addTask { await self.forwardProxyToFlow(connection: connection, flow: flow) }
        }
        
        connection.cancel()
        logger.info("✅ 结束: \(targetHost):\(targetPort)")
    }
    
    // MARK: - Connection Helpers
    
    private func waitForConnection(_ connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
    
    private func openFlow(_ flow: NEAppProxyTCPFlow) async -> Bool {
        await withCheckedContinuation { continuation in
            flow.open(withLocalEndpoint: nil) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }
    
    private func closeFlow(_ flow: NEAppProxyFlow) {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
    
    // MARK: - SOCKS5 Handshake
    
    private func performSOCKS5Handshake(connection: NWConnection, host: String, port: UInt16) async throws {
        // 1. 问候
        try await send(Data([0x05, 0x01, 0x00]), on: connection)
        
        // 2. 响应
        let r1 = try await receive(on: connection)
        guard r1.count >= 2, r1[0] == 0x05, r1[1] == 0x00 else {
            throw ProxyError.handshakeFailed
        }
        
        // 3. 连接请求
        var req = Data([0x05, 0x01, 0x00, 0x03])
        req.append(UInt8(host.utf8.count))
        req.append(contentsOf: host.utf8)
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xFF))
        try await send(req, on: connection)
        
        // 4. 响应
        let r2 = try await receive(on: connection)
        guard r2.count >= 2, r2[0] == 0x05, r2[1] == 0x00 else {
            throw ProxyError.connectionRejected
        }
        
        logger.info("🤝 握手成功: \(host):\(port)")
    }
    
    // MARK: - Data Forwarding
    
    private func forwardFlowToProxy(flow: NEAppProxyTCPFlow, connection: NWConnection) async {
        while connection.state == .ready {
            do {
                let data = try await readFromFlow(flow)
                guard !data.isEmpty else { break }
                try await send(data, on: connection)
            } catch {
                break
            }
        }
        flow.closeReadWithError(nil)
    }
    
    private func forwardProxyToFlow(connection: NWConnection, flow: NEAppProxyTCPFlow) async {
        while connection.state == .ready {
            do {
                let data = try await receive(on: connection)
                guard !data.isEmpty else { break }
                try await writeToFlow(flow, data: data)
            } catch {
                break
            }
        }
        flow.closeWriteWithError(nil)
    }
    
    // MARK: - Network I/O
    
    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }
    
    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }
    
    private func readFromFlow(_ flow: NEAppProxyTCPFlow) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            flow.readData { data, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }
    
    private func writeToFlow(_ flow: NEAppProxyTCPFlow, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            flow.write(data) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
}

// MARK: - Errors

enum ProxyError: Error, LocalizedError {
    case handshakeFailed
    case connectionRejected
    
    var errorDescription: String? {
        switch self {
        case .handshakeFailed: return "SOCKS5 握手失败"
        case .connectionRejected: return "代理拒绝连接"
        }
    }
}
