import NetworkExtension
import Network
import os.log

/// 透明代理 Provider - 实现按应用代理
class TransparentProxyProvider: NEAppProxyProvider {
    
    private let logger = Logger(subsystem: "com.dundun.runw.proxy", category: "TransparentProxy")
    
    // 代理配置 - 默认值
    private var proxyHost: String = "192.168.1.68"
    private var socksPort: UInt16 = 6153
    
    // 应用规则
    private var proxyApps: Set<String> = []
    private var rejectApps: Set<String> = []
    
    // MARK: - Lifecycle
    
    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("🚀 启动透明代理...")
        
        // 优先从 protocolConfiguration 读取配置
        if let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
           let config = proto.providerConfiguration {
            
            if let host = config["proxyHost"] as? String {
                proxyHost = host
                logger.info("📍 从配置读取 Host: \(host)")
            }
            if let socks = config["socksPort"] as? Int {
                socksPort = UInt16(socks)
                logger.info("📍 从配置读取 SOCKS5 端口: \(socks)")
            }
        }
        
        // 其次从启动选项读取
        if let host = options?["proxyHost"] as? String {
            proxyHost = host
            logger.info("📍 从选项读取 Host: \(host)")
        }
        if let socks = options?["socksPort"] as? NSNumber {
            socksPort = socks.uint16Value
            logger.info("📍 从选项读取 SOCKS5 端口: \(socks)")
        }
        
        // 加载应用规则
        loadAppRules()
        
        logger.info("✅ 代理: \(self.proxyHost):\(self.socksPort), 应用: \(self.proxyApps.count) 个")
        
        completionHandler(nil)
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("🛑 停止透明代理")
        completionHandler()
    }
    
    // MARK: - App Rules
    
    private func loadAppRules() {
        // 尝试从 App Group 读取应用规则
        let appGroupID = "LLNRYKR4A6.com.dundun.runw"
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            logger.warning("⚠️ 无法访问 App Group")
            return
        }
        
        if let proxyList = defaults.stringArray(forKey: "proxyApps") {
            proxyApps = Set(proxyList)
            logger.info("📱 代理应用: \(proxyList)")
        }
        if let rejectList = defaults.stringArray(forKey: "rejectApps") {
            rejectApps = Set(rejectList)
            logger.info("🚫 拒绝应用: \(rejectList)")
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
        
        // 代理规则
        let shouldProxy = proxyApps.isEmpty || proxyApps.contains(appID)
        
        if !shouldProxy {
            logger.debug("⏭️ 直连: \(appID)")
            return false
        }
        
        // 只处理 TCP，UDP 让系统直接处理
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            logger.info("📱 TCP代理: \(appID)")
            Task { await handleTCPFlow(tcpFlow) }
            return true
        } else if flow is NEAppProxyUDPFlow {
            // UDP 不处理，让系统直接发送（包括 DNS 和 QUIC）
            logger.debug("⏭️ UDP直连: \(appID)")
            return false
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
        
        logger.info("🔗 连接: \(targetHost):\(targetPort) via \(self.proxyHost):\(self.socksPort)")
        
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
                case .failed(let error):
                    self.logger.error("❌ 连接失败: \(error.localizedDescription)")
                    resumed = true
                    continuation.resume(returning: false)
                case .cancelled:
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
