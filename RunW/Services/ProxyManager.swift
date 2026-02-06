import SwiftUI
import NetworkExtension

/// 代理管理服务 - 控制 Network Extension
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
    
    private var manager: NEAppProxyProviderManager?
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
            let managers = try await NEAppProxyProviderManager.loadAllFromPreferences()
            if let existing = managers.first {
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
        
        let newManager = NEAppProxyProviderManager()
        
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.dundun.runw.RunWProxy"
        proto.serverAddress = "\(config.host):\(config.socksPort)"
        proto.providerConfiguration = [
            "proxyHost": config.host,
            "httpPort": config.httpPort,
            "socksPort": config.socksPort
        ]
        
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "RunW 透明代理"
        newManager.isEnabled = true
        
        // 为每个要代理的应用创建规则
        if !apps.isEmpty {
            var rules: [NEAppRule] = []
            for app in apps where app.isEnabled && app.rule == .proxy {
                // 使用 bundle identifier 和通用证书要求
                let rule = NEAppRule(signingIdentifier: app.bundleIdentifier, designatedRequirement: "anchor apple generic")
                rules.append(rule)
                print("📱 添加规则: \(app.bundleIdentifier)")
            }
            if !rules.isEmpty {
                newManager.appRules = rules
            }
        }
        
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
        guard let manager = manager else { return }
        
        // 为每个要代理的应用创建规则
        var rules: [NEAppRule] = []
        for app in apps where app.isEnabled && app.rule == .proxy {
            let rule = NEAppRule(signingIdentifier: app.bundleIdentifier, designatedRequirement: "anchor apple generic")
            rules.append(rule)
        }
        
        if rules.isEmpty {
            print("⚠️ 没有要代理的应用")
            return
        }
        
        manager.appRules = rules
        print("📱 更新 appRules: \(rules.count) 个应用")
        
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            print("更新规则失败: \(error)")
        }
    }
    
    // MARK: - Proxy Control
    
    private func startProxy() {
        guard let manager = manager else {
            proxyStatus = "请先安装扩展"
            isEnabled = false
            return
        }
        
        // 先保存配置
        saveConfig()
        
        // 确保扩展已启用
        if !manager.isEnabled {
            manager.isEnabled = true
            Task {
                do {
                    try await manager.saveToPreferences()
                } catch {
                    print("保存配置失败: \(error)")
                }
            }
        }
        
        do {
            try manager.connection.startVPNTunnel(options: [
                "proxyHost": config.host as NSString,
                "httpPort": NSNumber(value: config.httpPort),
                "socksPort": NSNumber(value: config.socksPort)
            ])
            proxyStatus = "启动中..."
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
        guard let status = manager?.connection.status else { return }
        
        switch status {
        case .invalid:
            proxyStatus = "无效"
            isEnabled = false
        case .disconnected:
            proxyStatus = "已断开"
            isEnabled = false
        case .connecting:
            proxyStatus = "连接中..."
        case .connected:
            proxyStatus = "运行中"
            isEnabled = true
        case .reasserting:
            proxyStatus = "重新连接..."
        case .disconnecting:
            proxyStatus = "断开中..."
        @unknown default:
            proxyStatus = "未知状态"
        }
    }
    
    // MARK: - Connection Test
    
    func testConnection() {
        connectionStatus = .testing
        
        Task {
            do {
                let testURL = URL(string: "https://www.google.com")!
                var request = URLRequest(url: testURL)
                request.timeoutInterval = 5
                
                let proxyDict: [String: Any] = [
                    kCFNetworkProxiesSOCKSEnable as String: true,
                    kCFNetworkProxiesSOCKSProxy as String: config.host,
                    kCFNetworkProxiesSOCKSPort as String: config.socksPort
                ]
                
                let sessionConfig = URLSessionConfiguration.ephemeral
                sessionConfig.connectionProxyDictionary = proxyDict
                let session = URLSession(configuration: sessionConfig)
                
                let (_, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    connectionStatus = .success
                } else {
                    connectionStatus = .failed("响应异常")
                }
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
            
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .success = connectionStatus {
                connectionStatus = .idle
            }
        }
    }
}
