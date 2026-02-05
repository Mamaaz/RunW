import SwiftUI
import Foundation

/// 代理管理服务 - 整合 Surge API
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
    @Published var proxyStatus: String = "未连接"
    @Published var surgeConnected: Bool = false
    
    let surgeService = SurgeService()
    
    private let defaults = UserDefaults.standard
    private let configKey = "proxyConfig"
    
    enum ConnectionStatus {
        case idle
        case testing
        case success
        case failed(String)
    }
    
    init() {
        // 加载配置
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(ProxyConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .default
        }
        
        // 检查 Surge 连接
        Task {
            await checkSurgeConnection()
        }
    }
    
    // MARK: - Config Persistence
    
    func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            defaults.set(encoded, forKey: configKey)
        }
    }
    
    // MARK: - Surge Connection
    
    func checkSurgeConnection() async {
        surgeConnected = await surgeService.testConnection()
        if surgeConnected {
            proxyStatus = "Surge 已连接"
        } else {
            proxyStatus = "Surge 未连接"
        }
    }
    
    // MARK: - Proxy Control
    
    private func startProxy() {
        guard surgeConnected else {
            proxyStatus = "请先连接 Surge"
            isEnabled = false
            return
        }
        proxyStatus = "规则已启用"
    }
    
    private func stopProxy() {
        proxyStatus = "规则已停止"
    }
    
    // MARK: - Sync Rules to Surge
    
    func syncRulesToSurge(apps: [ProxyApp]) async {
        guard surgeConnected else {
            proxyStatus = "请先连接 Surge"
            return
        }
        
        do {
            try await surgeService.syncRules(apps: apps)
            proxyStatus = "规则已同步"
        } catch {
            proxyStatus = "同步失败: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Add Single Rule
    
    func addRule(for app: ProxyApp) async {
        guard surgeConnected else { return }
        
        do {
            let processName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
            let policy = policyName(for: app.rule)
            try await surgeService.addProcessRule(processName: processName, policy: policy)
        } catch {
            print("添加规则失败: \(error)")
        }
    }
    
    // MARK: - Remove Single Rule
    
    func removeRule(for app: ProxyApp) async {
        guard surgeConnected else { return }
        
        do {
            let processName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
            try await surgeService.removeProcessRule(processName: processName)
        } catch {
            print("删除规则失败: \(error)")
        }
    }
    
    private func policyName(for rule: ProxyRule) -> String {
        switch rule {
        case .proxy: return "Proxy"
        case .direct: return "DIRECT"
        case .reject: return "REJECT"
        }
    }
    
    // MARK: - Connection Test
    
    func testConnection() {
        connectionStatus = .testing
        
        Task {
            do {
                // 测试代理连接
                let testURL = URL(string: "https://www.google.com")!
                var request = URLRequest(url: testURL)
                request.timeoutInterval = 5
                
                // 配置代理
                let proxyDict: [String: Any]
                switch config.preferredProtocol {
                case .http:
                    proxyDict = [
                        kCFNetworkProxiesHTTPEnable as String: true,
                        kCFNetworkProxiesHTTPProxy as String: config.host,
                        kCFNetworkProxiesHTTPPort as String: config.httpPort
                    ]
                case .socks5:
                    proxyDict = [
                        kCFNetworkProxiesSOCKSEnable as String: true,
                        kCFNetworkProxiesSOCKSProxy as String: config.host,
                        kCFNetworkProxiesSOCKSPort as String: config.socksPort
                    ]
                }
                
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
            
            // 3秒后重置状态
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .success = connectionStatus {
                connectionStatus = .idle
            }
        }
    }
}
