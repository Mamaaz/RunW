import NetworkExtension
import Network
import os.log

/// Packet Tunnel Provider - 在 IP 层拦截流量，支持 TCP 和 UDP
class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let logger = Logger(subsystem: "com.dundun.runw.proxy", category: "PacketTunnel")
    
    // 代理配置
    private var proxyHost: String = "192.168.1.68"
    private var socksPort: UInt16 = 6153
    
    // 虚拟网络配置
    private let tunnelAddress = "10.8.0.2"
    private let tunnelNetmask = "255.255.255.0"
    private let tunnelDNS = "8.8.8.8"
    
    // 连接管理
    private var tcpConnections: [String: NWConnection] = [:]
    private var udpConnections: [String: NWConnection] = [:]
    private let connectionQueue = DispatchQueue(label: "com.dundun.runw.connections", attributes: .concurrent)
    
    // 运行状态
    private var isRunning = false
    
    // MARK: - Lifecycle
    
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("🚀 启动 Packet Tunnel...")
        
        // 读取配置
        loadConfiguration(from: options)
        
        // 配置虚拟网络接口
        let settings = createTunnelSettings()
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.logger.error("❌ 设置隧道失败: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            self?.logger.info("✅ 隧道设置成功")
            self?.isRunning = true
            self?.startPacketHandling()
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("🛑 停止 Packet Tunnel, 原因: \(reason.rawValue)")
        
        isRunning = false
        
        // 关闭所有连接
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.tcpConnections.values.forEach { $0.cancel() }
            self?.udpConnections.values.forEach { $0.cancel() }
            self?.tcpConnections.removeAll()
            self?.udpConnections.removeAll()
        }
        
        completionHandler()
    }
    
    // MARK: - Configuration
    
    private func loadConfiguration(from options: [String: NSObject]?) {
        // 从 protocolConfiguration 读取
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let config = proto.providerConfiguration {
            if let host = config["proxyHost"] as? String {
                proxyHost = host
                logger.info("📍 代理服务器: \(host)")
            }
            if let port = config["socksPort"] as? Int {
                socksPort = UInt16(port)
                logger.info("📍 SOCKS5 端口: \(port)")
            }
        }
        
        // 从 App Group 读取
        let appGroupID = "LLNRYKR4A6.com.dundun.runw"
        if let defaults = UserDefaults(suiteName: appGroupID) {
            if let host = defaults.string(forKey: "proxyHost"), !host.isEmpty {
                proxyHost = host
            }
            let port = defaults.integer(forKey: "socksPort")
            if port > 0 {
                socksPort = UInt16(port)
            }
        }
        
        logger.info("✅ 配置: \(self.proxyHost):\(self.socksPort)")
    }
    
    private func createTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: proxyHost)
        
        // IPv4 设置
        let ipv4Settings = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [tunnelNetmask])
        
        // 路由所有流量到隧道
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        
        // 排除代理服务器本身的流量（避免循环）
        let proxyRoute = NEIPv4Route(destinationAddress: proxyHost, subnetMask: "255.255.255.255")
        ipv4Settings.excludedRoutes = [proxyRoute]
        
        settings.ipv4Settings = ipv4Settings
        
        // DNS 设置
        settings.dnsSettings = NEDNSSettings(servers: [tunnelDNS])
        
        // MTU
        settings.mtu = 1500
        
        return settings
    }
    
    // MARK: - Packet Handling
    
    private func startPacketHandling() {
        logger.info("📦 开始处理数据包...")
        
        // 持续读取 IP 数据包
        readPackets()
    }
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            
            for (index, packet) in packets.enumerated() {
                let proto = protocols[index]
                self.handlePacket(packet, protocol: proto)
            }
            
            // 继续读取
            self.readPackets()
        }
    }
    
    private func handlePacket(_ packet: Data, protocol proto: NSNumber) {
        // AF_INET = 2, AF_INET6 = 30
        guard proto.intValue == 2 else {
            // 暂时只处理 IPv4
            return
        }
        
        guard packet.count >= 20 else { return }  // 最小 IP 头长度
        
        // 解析 IP 头
        let version = (packet[0] >> 4) & 0x0F
        guard version == 4 else { return }  // IPv4
        
        let headerLength = Int(packet[0] & 0x0F) * 4
        let protocol_ = packet[9]
        
        guard packet.count >= headerLength else { return }
        
        // 目标 IP
        let destIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        
        // 根据协议处理
        switch protocol_ {
        case 6:  // TCP
            handleTCPPacket(packet, headerLength: headerLength, destIP: destIP)
        case 17: // UDP
            handleUDPPacket(packet, headerLength: headerLength, destIP: destIP)
        default:
            break
        }
    }
    
    // MARK: - TCP Handling
    
    private func handleTCPPacket(_ packet: Data, headerLength: Int, destIP: String) {
        guard packet.count >= headerLength + 4 else { return }
        
        // 解析 TCP 头
        let tcpHeader = packet.dropFirst(headerLength)
        let srcPort = UInt16(tcpHeader[0]) << 8 | UInt16(tcpHeader[1])
        let destPort = UInt16(tcpHeader[2]) << 8 | UInt16(tcpHeader[3])
        
        let connectionKey = "\(destIP):\(destPort)-\(srcPort)"
        
        // 检查是否已有连接
        var existingConnection: NWConnection?
        connectionQueue.sync {
            existingConnection = tcpConnections[connectionKey]
        }
        
        if existingConnection == nil {
            // 创建新的代理连接
            createTCPProxyConnection(for: connectionKey, destHost: destIP, destPort: destPort)
        }
        
        // 转发数据（简化处理）
        // 注意：完整实现需要维护 TCP 状态机
    }
    
    private func createTCPProxyConnection(for key: String, destHost: String, destPort: UInt16) {
        logger.info("🔗 TCP: \(destHost):\(destPort)")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: socksPort)
        )
        
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        connectionQueue.async(flags: .barrier) {
            self.tcpConnections[key] = connection
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.debug("✅ TCP 连接就绪: \(key)")
                // 执行 SOCKS5 握手
                Task {
                    await self?.performSOCKS5Handshake(connection: connection, host: destHost, port: destPort)
                }
            case .failed(let error):
                self?.logger.error("❌ TCP 连接失败: \(error.localizedDescription)")
                self?.removeTCPConnection(key: key)
            case .cancelled:
                self?.removeTCPConnection(key: key)
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    private func removeTCPConnection(key: String) {
        connectionQueue.async(flags: .barrier) {
            self.tcpConnections.removeValue(forKey: key)
        }
    }
    
    // MARK: - UDP Handling
    
    private func handleUDPPacket(_ packet: Data, headerLength: Int, destIP: String) {
        guard packet.count >= headerLength + 8 else { return }
        
        // 解析 UDP 头
        let udpHeader = packet.dropFirst(headerLength)
        let srcPort = UInt16(udpHeader[0]) << 8 | UInt16(udpHeader[1])
        let destPort = UInt16(udpHeader[2]) << 8 | UInt16(udpHeader[3])
        let udpLength = Int(UInt16(udpHeader[4]) << 8 | UInt16(udpHeader[5]))
        
        guard packet.count >= headerLength + udpLength else { return }
        
        // 提取 UDP 数据
        let udpDataStart = headerLength + 8
        let udpData = packet.dropFirst(udpDataStart)
        
        let connectionKey = "udp-\(destIP):\(destPort)-\(srcPort)"
        
        logger.info("📦 UDP: \(destIP):\(destPort), 数据: \(udpData.count) 字节")
        
        // 对于 UDP，直接通过 SOCKS5 UDP ASSOCIATE 转发
        // 或者如果代理不支持 UDP，可以考虑直接发送
        Task {
            await forwardUDPPacket(data: Data(udpData), destIP: destIP, destPort: destPort, srcPort: srcPort)
        }
    }
    
    private func forwardUDPPacket(data: Data, destIP: String, destPort: UInt16, srcPort: UInt16) async {
        // 由于 Surge SOCKS5 不支持 UDP ASSOCIATE，我们直接发送 UDP
        // 这要求代理服务器本身能处理目标地址
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(destIP),
            port: NWEndpoint.Port(integerLiteral: destPort)
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        self?.logger.error("❌ UDP 发送失败: \(error.localizedDescription)")
                    }
                    connection.cancel()
                })
            case .failed(let error):
                self?.logger.error("❌ UDP 连接失败: \(error.localizedDescription)")
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    // MARK: - SOCKS5 Handshake
    
    private func performSOCKS5Handshake(connection: NWConnection, host: String, port: UInt16) async {
        do {
            // 1. 问候
            try await send(Data([0x05, 0x01, 0x00]), on: connection)
            
            let r1 = try await receive(on: connection)
            guard r1.count >= 2, r1[0] == 0x05, r1[1] == 0x00 else {
                logger.error("❌ SOCKS5 问候失败")
                connection.cancel()
                return
            }
            
            // 2. 连接请求
            var req = Data([0x05, 0x01, 0x00, 0x03])
            req.append(UInt8(host.utf8.count))
            req.append(contentsOf: host.utf8)
            req.append(UInt8(port >> 8))
            req.append(UInt8(port & 0xFF))
            try await send(req, on: connection)
            
            let r2 = try await receive(on: connection)
            guard r2.count >= 2, r2[0] == 0x05, r2[1] == 0x00 else {
                logger.error("❌ SOCKS5 连接被拒绝")
                connection.cancel()
                return
            }
            
            logger.info("🤝 SOCKS5 握手成功: \(host):\(port)")
            
            // 开始转发数据
            startDataRelay(connection: connection, host: host, port: port)
            
        } catch {
            logger.error("❌ SOCKS5 错误: \(error.localizedDescription)")
            connection.cancel()
        }
    }
    
    private func startDataRelay(connection: NWConnection, host: String, port: UInt16) {
        // 从代理接收数据并写回 packetFlow
        receiveFromProxy(connection: connection, host: host, port: port)
    }
    
    private func receiveFromProxy(connection: NWConnection, host: String, port: UInt16) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isRunning else { return }
            
            if let data = data, !data.isEmpty {
                // 将数据封装成 IP 包写回
                self.writeResponsePacket(data: data, destIP: host, destPort: port)
            }
            
            if !isComplete && error == nil {
                self.receiveFromProxy(connection: connection, host: host, port: port)
            }
        }
    }
    
    private func writeResponsePacket(data: Data, destIP: String, destPort: UInt16) {
        // 构建响应 IP 包（简化）
        // 注意：完整实现需要正确构建 IP + TCP/UDP 头
        
        // 这里我们直接返回数据，实际上需要完整的包构建
        // 由于复杂度较高，这里仅作为占位符
        logger.debug("📤 响应: \(data.count) 字节 -> \(destIP):\(destPort)")
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
}
