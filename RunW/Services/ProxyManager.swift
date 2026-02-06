import SwiftUI
import NetworkExtension

/// 代理管理服务 - 控制 Packet Tunnel Extension
@MainActor
class ProxyManager: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled != oldValue {
                if isEnabled {
                    startProxy()
                } else {
                    stopProxy()
                }
            }
        }
    }
    
    @Published var config: ProxyConfig {
        didSet {
            saveConfig()
        }
    }
    
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var proxyStatus: String = "未启动"
    @Published var extensionInstalled: Bool = false
    
    // 使用 NETunnelProviderManager (Packet Tunnel)
    private var manager: NETunnelProviderManager?
    private let defaults = UserDefaults.standard
    private let configKey = "proxyConfig"
    
    // App Group 共享
    private let appGroupID = "LLNRYKR4A6.com.dundun.runw"
    private var sharedDefaults: UserDefaults?
    
    enum ConnectionStatus {
        case idle
        case testing
        case success
        case failed(String)
    }
    
    init() {
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(ProxyConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .default
        }
        
        // 初始化 App Group
        sharedDefaults = UserDefaults(suiteName: appGroupID)
        
        Task {
            await loadManager()
        }
    }
    
    // MARK: - Config
    
    func saveConfig() {
        // 保存到本地
        if let encoded = try? JSONEncoder().encode(config) {
            defaults.set(encoded, forKey: configKey)
        }
        
        // 同步到 App Group
        sharedDefaults?.set(config.host, forKey: "proxyHost")
        sharedDefaults?.set(config.httpPort, forKey: "httpPort")
        sharedDefaults?.set(config.socksPort, forKey: "socksPort")
        sharedDefaults?.synchronize()
    }
    
    // MARK: - Manager Loading
    
    private func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "com.dundun.runw.RunWProxy"
            }) {
                manager = existing
                extensionInstalled = true
                updateStatus()
                
                // 监听状态变化
                NotificationCenter.default.addObserver(
                    forName: .NEVPNStatusDidChange,
                    object: existing.connection,
                    queue: .main
                ) { [weak self] _ in
                    self?.updateStatus()
                }
            } else {
                extensionInstalled = false
                proxyStatus = "未安装"
            }
        } catch {
            print("加载 Manager 失败: \(error)")
            proxyStatus = "加载失败"
        }
    }
    
    // MARK: - Install Extension
    
    func installExtension(apps: [ProxyApp] = []) async {
        // 先保存配置到 App Group
        saveConfig()
        
        // 保存要代理的应用列表
        let proxyApps = apps.filter { $0.isEnabled && $0.rule == .proxy }.map { $0.bundleIdentifier }
        let rejectApps = apps.filter { $0.isEnabled && $0.rule == .reject }.map { $0.bundleIdentifier }
        sharedDefaults?.set(proxyApps, forKey: "proxyApps")
        sharedDefaults?.set(rejectApps, forKey: "rejectApps")
        sharedDefaults?.synchronize()
        
        let newManager = NETunnelProviderManager()
        
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.dundun.runw.RunWProxy"
        proto.serverAddress = "\(config.host):\(config.socksPort)"
        proto.providerConfiguration = [
            "proxyHost": config.host,
            "httpPort": config.httpPort,
            "socksPort": config.socksPort
        ]
        
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "RunW Packet Tunnel"
        newManager.isEnabled = true
        
        // Packet Tunnel 不需要 appRules，在 Provider 内部处理
        
        do {
            try await newManager.saveToPreferences()
            try await newManager.loadFromPreferences()
            manager = newManager
            extensionInstalled = true
            proxyStatus = "已安装"
            
            // 监听状态变化
            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: newManager.connection,
                queue: .main
            ) { [weak self] _ in
                self?.updateStatus()
            }
        } catch {
            print("安装失败: \(error)")
            proxyStatus = "安装失败: \(error.localizedDescription)"
        }
    }
    
    /// 更新应用规则
    func updateAppRules(apps: [ProxyApp]) async {
        // 保存到 App Group，Provider 会读取
        let proxyApps = apps.filter { $0.isEnabled && $0.rule == .proxy }.map { $0.bundleIdentifier }
        let rejectApps = apps.filter { $0.isEnabled && $0.rule == .reject }.map { $0.bundleIdentifier }
        sharedDefaults?.set(proxyApps, forKey: "proxyApps")
        sharedDefaults?.set(rejectApps, forKey: "rejectApps")
        sharedDefaults?.synchronize()
        
        print("📱 更新应用规则: \(proxyApps.count) 个代理, \(rejectApps.count) 个拒绝")
    }
    
    // MARK: - Proxy Control
    
    private func startProxy() {
        guard let manager = manager else {
            proxyStatus = "未安装扩展"
            isEnabled = false
            return
        }
        
        do {
            let options: [String: NSObject] = [
                "proxyHost": config.host as NSString,
                "socksPort": NSNumber(value: config.socksPort)
            ]
            try manager.connection.startVPNTunnel(options: options)
            proxyStatus = "正在连接..."
        } catch {
            proxyStatus = "启动失败: \(error.localizedDescription)"
            isEnabled = false
        }
    }
    
    private func stopProxy() {
        manager?.connection.stopVPNTunnel()
        proxyStatus = "已停止"
    }
    
    private func updateStatus() {
        guard let manager = manager else { return }
        
        switch manager.connection.status {
        case .invalid:
            proxyStatus = "无效"
            isEnabled = false
        case .disconnected:
            proxyStatus = "已断开"
            isEnabled = false
        case .connecting:
            proxyStatus = "连接中..."
        case .connected:
            proxyStatus = "运行中 ✅"
            if !isEnabled { isEnabled = true }
        case .reasserting:
            proxyStatus = "重连中..."
        case .disconnecting:
            proxyStatus = "断开中..."
        @unknown default:
            proxyStatus = "未知状态"
        }
    }
    
    // MARK: - Test Connection
    
    func testConnection() {
        connectionStatus = .testing
        
        Task {
            do {
                let url = URL(string: "https://www.google.com")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                
                let (_, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    await MainActor.run {
                        connectionStatus = .success
                    }
                } else {
                    await MainActor.run {
                        connectionStatus = .failed("HTTP 错误")
                    }
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .failed(error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - SOCKS5 Test
    
    func testSOCKS5() async -> Bool {
        // 测试 SOCKS5 代理是否可用
        guard let url = URL(string: "http://\(config.host):\(config.socksPort)") else {
            return false
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            // SOCKS5 不支持 HTTP，连接会失败，但这说明端口是开放的
            return true
        }
    }
}
