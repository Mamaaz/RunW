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
    
    // UDP 会话管理
    private var udpAssociations: [String: UDPAssociation] = [:]
    
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
        
        // 清理 UDP 会话
        for (_, association) in udpAssociations {
            association.close()
        }
        udpAssociations.removeAll()
        
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
        
        // 处理 TCP
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            logger.info("📱 TCP代理: \(appID)")
            Task { await handleTCPFlow(tcpFlow) }
            return true
        }
        
        // UDP: Surge SOCKS5 不支持 UDP ASSOCIATE，返回 false 让系统处理
        // 如果启用了 Surge Tun 模式，UDP 流量会被 Surge 代理
        if flow is NEAppProxyUDPFlow {
            logger.info("⏭️ UDP直连(SOCKS5不支持UDP): \(appID)")
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
        
        logger.info("🔗 TCP连接: \(targetHost):\(targetPort) via \(self.proxyHost):\(self.socksPort)")
        
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
        
        logger.info("🔄 TCP转发: \(targetHost):\(targetPort)")
        
        // 5. 双向转发
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.forwardFlowToProxy(flow: flow, connection: connection) }
            group.addTask { await self.forwardProxyToFlow(connection: connection, flow: flow) }
        }
        
        connection.cancel()
        logger.info("✅ TCP结束: \(targetHost):\(targetPort)")
    }
    
    // MARK: - UDP Flow
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) async {
        logger.info("🔗 UDP会话开始")
        
        // 1. 建立 SOCKS5 UDP ASSOCIATE
        let association = UDPAssociation(proxyHost: proxyHost, proxyPort: socksPort, logger: logger)
        
        do {
            try await association.setup()
        } catch {
            logger.error("❌ UDP ASSOCIATE 失败: \(error.localizedDescription)")
            closeFlow(flow)
            return
        }
        
        // 2. 打开 flow
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            if let error = error {
                self?.logger.error("❌ 打开 UDP flow 失败: \(error.localizedDescription)")
                association.close()
                return
            }
            
            // 3. 开始数据转发
            Task {
                await self?.forwardUDPFlow(flow: flow, association: association)
            }
        }
    }
    
    private func forwardUDPFlow(flow: NEAppProxyUDPFlow, association: UDPAssociation) async {
        // 从 flow 读取数据并发送到代理
        await withTaskGroup(of: Void.self) { group in
            // Flow -> Proxy
            group.addTask {
                while true {
                    do {
                        let datagrams = try await self.readDatagrams(from: flow)
                        guard !datagrams.isEmpty else { break }
                        
                        for (data, endpoint) in datagrams {
                            if let hostEndpoint = endpoint as? NWHostEndpoint {
                                try await association.sendDatagram(
                                    data: data,
                                    host: hostEndpoint.hostname,
                                    port: UInt16(hostEndpoint.port) ?? 0
                                )
                            }
                        }
                    } catch {
                        self.logger.error("❌ UDP读取失败: \(error.localizedDescription)")
                        break
                    }
                }
            }
            
            // Proxy -> Flow
            group.addTask {
                while true {
                    do {
                        let (data, host, port) = try await association.receiveDatagram()
                        let endpoint = NWHostEndpoint(hostname: host, port: String(port))
                        try await self.writeDatagrams(to: flow, datagrams: [(data, endpoint)])
                    } catch {
                        self.logger.error("❌ UDP写入失败: \(error.localizedDescription)")
                        break
                    }
                }
            }
        }
        
        association.close()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        logger.info("✅ UDP会话结束")
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
    
    // MARK: - SOCKS5 Handshake (TCP CONNECT)
    
    private func performSOCKS5Handshake(connection: NWConnection, host: String, port: UInt16) async throws {
        // 1. 问候
        try await send(Data([0x05, 0x01, 0x00]), on: connection)
        
        // 2. 响应
        let r1 = try await receive(on: connection)
        guard r1.count >= 2, r1[0] == 0x05, r1[1] == 0x00 else {
            throw ProxyError.handshakeFailed
        }
        
        // 3. 连接请求 (CMD = 0x01 CONNECT)
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
        
        logger.info("🤝 TCP握手成功: \(host):\(port)")
    }
    
    // MARK: - Data Forwarding (TCP)
    
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
    
    private func readDatagrams(from flow: NEAppProxyUDPFlow) async throws -> [(Data, NWHostEndpoint)] {
        try await withCheckedThrowingContinuation { cont in
            flow.readDatagrams { datagrams, endpoints, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let datagrams = datagrams, let endpoints = endpoints {
                    let hostEndpoints = endpoints.compactMap { $0 as? NWHostEndpoint }
                    cont.resume(returning: Array(zip(datagrams, hostEndpoints)))
                } else {
                    cont.resume(returning: [])
                }
            }
        }
    }
    
    private func writeDatagrams(to flow: NEAppProxyUDPFlow, datagrams: [(Data, NWHostEndpoint)]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            flow.writeDatagrams(datagrams.map { $0.0 }, sentBy: datagrams.map { $0.1 }) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
}

// MARK: - UDP Association

/// 管理 SOCKS5 UDP ASSOCIATE 会话
class UDPAssociation {
    private let proxyHost: String
    private let proxyPort: UInt16
    private let logger: Logger
    
    private var controlConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var relayHost: String = ""
    private var relayPort: UInt16 = 0
    
    init(proxyHost: String, proxyPort: UInt16, logger: Logger) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.logger = logger
    }
    
    func setup() async throws {
        // 1. 建立 TCP 控制连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: proxyPort)
        )
        
        controlConnection = NWConnection(to: endpoint, using: .tcp)
        
        logger.info("📡 连接到 \(self.proxyHost):\(self.proxyPort)...")
        guard await waitForConnection(controlConnection!) else {
            logger.error("❌ 无法连接到 SOCKS5 代理")
            throw ProxyError.connectionFailed
        }
        logger.info("✅ TCP 连接成功")
        
        // 2. SOCKS5 问候
        try await send(Data([0x05, 0x01, 0x00]), on: controlConnection!)
        
        let r1 = try await receive(on: controlConnection!)
        logger.info("📨 问候响应: \(r1.map { String(format: "%02X", $0) }.joined(separator: " "))")
        guard r1.count >= 2, r1[0] == 0x05, r1[1] == 0x00 else {
            logger.error("❌ 问候失败: \(r1.map { String(format: "%02X", $0) }.joined(separator: " "))")
            throw ProxyError.handshakeFailed
        }
        logger.info("✅ 问候成功")
        
        // 3. UDP ASSOCIATE 请求 (CMD = 0x03)
        // 告诉代理我们要发 UDP，源地址设为 0.0.0.0:0
        var req = Data([0x05, 0x03, 0x00, 0x01])  // VER, CMD=UDP_ASSOCIATE, RSV, ATYP=IPv4
        req.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // 0.0.0.0
        req.append(contentsOf: [0x00, 0x00])  // port 0
        logger.info("📤 发送 UDP ASSOCIATE 请求...")
        try await send(req, on: controlConnection!)
        
        // 4. 解析响应，获取 relay 地址
        let r2 = try await receive(on: controlConnection!)
        logger.info("📨 UDP ASSOCIATE 响应: \(r2.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        guard r2.count >= 10 else {
            logger.error("❌ 响应太短: \(r2.count) 字节")
            throw ProxyError.udpAssociateFailed
        }
        
        guard r2[0] == 0x05 else {
            logger.error("❌ 版本错误: \(r2[0])")
            throw ProxyError.udpAssociateFailed
        }
        
        guard r2[1] == 0x00 else {
            let errorCode = r2[1]
            let errorMsg: String
            switch errorCode {
            case 0x01: errorMsg = "一般 SOCKS 服务器故障"
            case 0x02: errorMsg = "规则不允许连接"
            case 0x03: errorMsg = "网络不可达"
            case 0x04: errorMsg = "主机不可达"
            case 0x05: errorMsg = "连接被拒绝"
            case 0x06: errorMsg = "TTL 过期"
            case 0x07: errorMsg = "不支持的命令"
            case 0x08: errorMsg = "不支持的地址类型"
            default: errorMsg = "未知错误 \(errorCode)"
            }
            logger.error("❌ UDP ASSOCIATE 被拒绝: \(errorMsg)")
            throw ProxyError.udpAssociateFailed
        }
        
        // 解析 BND.ADDR 和 BND.PORT
        let addrType = r2[3]
        var offset = 4
        
        switch addrType {
        case 0x01:  // IPv4
            let ip = r2[offset..<offset+4].map { String($0) }.joined(separator: ".")
            relayHost = ip
            offset += 4
        case 0x03:  // Domain
            let len = Int(r2[offset])
            offset += 1
            relayHost = String(data: r2[offset..<offset+len], encoding: .utf8) ?? ""
            offset += len
        case 0x04:  // IPv6
            // 简化处理，转换为字符串
            relayHost = proxyHost  // 回退使用代理地址
            offset += 16
        default:
            throw ProxyError.invalidResponse
        }
        
        relayPort = UInt16(r2[offset]) << 8 | UInt16(r2[offset + 1])
        
        // 如果返回 0.0.0.0，使用代理服务器地址
        if relayHost == "0.0.0.0" {
            relayHost = proxyHost
        }
        
        logger.info("🎯 UDP Relay: \(self.relayHost):\(self.relayPort)")
        
        // 5. 建立 UDP 连接到 relay 地址
        let udpEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(relayHost),
            port: NWEndpoint.Port(integerLiteral: relayPort)
        )
        
        let udpParams = NWParameters.udp
        udpConnection = NWConnection(to: udpEndpoint, using: udpParams)
        
        guard await waitForConnection(udpConnection!) else {
            throw ProxyError.connectionFailed
        }
        
        logger.info("✅ UDP ASSOCIATE 成功")
    }
    
    func sendDatagram(data: Data, host: String, port: UInt16) async throws {
        guard let udpConnection = udpConnection else {
            throw ProxyError.notConnected
        }
        
        // 构建 SOCKS5 UDP 请求头
        var packet = Data([0x00, 0x00, 0x00])  // RSV, FRAG
        
        // ATYP + DST.ADDR
        packet.append(0x03)  // Domain name
        packet.append(UInt8(host.utf8.count))
        packet.append(contentsOf: host.utf8)
        
        // DST.PORT
        packet.append(UInt8(port >> 8))
        packet.append(UInt8(port & 0xFF))
        
        // DATA
        packet.append(data)
        
        try await send(packet, on: udpConnection)
    }
    
    func receiveDatagram() async throws -> (Data, String, UInt16) {
        guard let udpConnection = udpConnection else {
            throw ProxyError.notConnected
        }
        
        let packet = try await receive(on: udpConnection)
        
        // 解析 SOCKS5 UDP 响应头
        guard packet.count >= 10 else {
            throw ProxyError.invalidResponse
        }
        
        // 跳过 RSV(2) + FRAG(1)
        var offset = 3
        
        // 解析 ATYP
        let addrType = packet[offset]
        offset += 1
        
        var host = ""
        switch addrType {
        case 0x01:  // IPv4
            host = packet[offset..<offset+4].map { String($0) }.joined(separator: ".")
            offset += 4
        case 0x03:  // Domain
            let len = Int(packet[offset])
            offset += 1
            host = String(data: packet[offset..<offset+len], encoding: .utf8) ?? ""
            offset += len
        case 0x04:  // IPv6
            offset += 16
            host = "::1"  // 简化处理
        default:
            throw ProxyError.invalidResponse
        }
        
        // 解析端口
        let port = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
        offset += 2
        
        // 获取数据
        let data = packet[offset...]
        
        return (Data(data), host, port)
    }
    
    func close() {
        controlConnection?.cancel()
        udpConnection?.cancel()
        controlConnection = nil
        udpConnection = nil
    }
    
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
}

// MARK: - Errors

enum ProxyError: Error, LocalizedError {
    case handshakeFailed
    case connectionRejected
    case connectionFailed
    case udpAssociateFailed
    case invalidResponse
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .handshakeFailed: return "SOCKS5 握手失败"
        case .connectionRejected: return "代理拒绝连接"
        case .connectionFailed: return "连接失败"
        case .udpAssociateFailed: return "UDP ASSOCIATE 失败"
        case .invalidResponse: return "无效响应"
        case .notConnected: return "未连接"
        }
    }
}
