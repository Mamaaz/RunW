import Foundation

/// Surge HTTP API 服务
/// 文档: https://manual.nssurge.com/others/http-api.html
@MainActor
class SurgeService: ObservableObject {
    
    // MARK: - Configuration
    
    @Published var apiHost: String = "127.0.0.1"
    @Published var apiPort: Int = 6171
    @Published var apiKey: String = "0000"
    
    @Published var isConnected: Bool = false
    @Published var surgeVersion: String = ""
    @Published var enhancedModeEnabled: Bool = false
    
    private let defaults = UserDefaults.standard
    private let configKey = "surgeAPIConfig"
    
    init() {
        loadConfig()
    }
    
    // MARK: - Config Persistence
    
    private func loadConfig() {
        if let data = defaults.data(forKey: configKey),
           let config = try? JSONDecoder().decode(SurgeAPIConfig.self, from: data) {
            apiHost = config.host
            apiPort = config.port
            apiKey = config.key
        }
    }
    
    func saveConfig() {
        let config = SurgeAPIConfig(host: apiHost, port: apiPort, key: apiKey)
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }
    
    // MARK: - API Base
    
    private var baseURL: URL {
        URL(string: "http://\(apiHost):\(apiPort)")!
    }
    
    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        
        // API Key 认证
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Key")
        }
        
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SurgeError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw SurgeError.httpError(httpResponse.statusCode)
        }
        
        return data
    }
    
    // MARK: - Connection Test
    
    func testConnection() async -> Bool {
        do {
            let data = try await request(path: "/v1/outbound")
            isConnected = true
            return true
        } catch {
            print("Surge 连接失败: \(error)")
            isConnected = false
            return false
        }
    }
    
    // MARK: - Get System Status
    
    func getStatus() async throws -> SurgeStatus {
        let data = try await request(path: "/v1/traffic")
        // Surge 返回流量信息表示正在运行
        isConnected = true
        return SurgeStatus(isRunning: true, enhancedMode: enhancedModeEnabled)
    }
    
    // MARK: - Get Current Rules
    
    func getRules() async throws -> [SurgeRule] {
        let data = try await request(path: "/v1/rules")
        let response = try JSONDecoder().decode(SurgeRulesResponse.self, from: data)
        return response.rules
    }
    
    // MARK: - Add PROCESS-NAME Rule
    
    func addProcessRule(processName: String, policy: String = "Proxy") async throws {
        // Surge API: POST /v1/rules/insert
        // 在规则列表开头插入新规则
        let rule = "PROCESS-NAME,\(processName),\(policy)"
        
        let body: [String: Any] = [
            "rule": rule,
            "index": 0  // 插入到第一条
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(path: "/v1/rules/insert", method: "POST", body: jsonData)
    }
    
    // MARK: - Remove Rule by Process Name
    
    func removeProcessRule(processName: String) async throws {
        // 先获取所有规则，找到对应索引，再删除
        let rules = try await getRules()
        
        for (index, rule) in rules.enumerated() {
            if rule.rule.contains("PROCESS-NAME,\(processName)") {
                _ = try await request(path: "/v1/rules/\(index)", method: "DELETE")
                return
            }
        }
    }
    
    // MARK: - Get Policies (Proxy Groups)
    
    func getPolicies() async throws -> [String] {
        let data = try await request(path: "/v1/policies")
        let response = try JSONDecoder().decode(SurgePoliciesResponse.self, from: data)
        return response.policies
    }
    
    // MARK: - Sync All App Rules
    
    func syncRules(apps: [ProxyApp]) async throws {
        // 1. 获取当前规则
        let currentRules = try await getRules()
        
        // 2. 找出需要删除的规则（不在 apps 列表中的 PROCESS-NAME 规则）
        let appProcessNames = Set(apps.filter { $0.isEnabled }.map { extractProcessName(from: $0) })
        
        var indicesToDelete: [Int] = []
        for (index, rule) in currentRules.enumerated() {
            if rule.rule.hasPrefix("PROCESS-NAME,") {
                let parts = rule.rule.split(separator: ",")
                if parts.count >= 2 {
                    let processName = String(parts[1])
                    if !appProcessNames.contains(processName) {
                        indicesToDelete.append(index)
                    }
                }
            }
        }
        
        // 从后往前删除，避免索引变化
        for index in indicesToDelete.reversed() {
            _ = try? await request(path: "/v1/rules/\(index)", method: "DELETE")
        }
        
        // 3. 添加新规则
        for app in apps where app.isEnabled {
            let processName = extractProcessName(from: app)
            let policy = policyName(for: app.rule)
            
            // 检查规则是否已存在
            let existingRules = try await getRules()
            let ruleExists = existingRules.contains { $0.rule.contains("PROCESS-NAME,\(processName)") }
            
            if !ruleExists {
                try await addProcessRule(processName: processName, policy: policy)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func extractProcessName(from app: ProxyApp) -> String {
        // 从路径提取应用名称
        // /Applications/Claude.app -> Claude
        let url = URL(fileURLWithPath: app.path)
        return url.deletingPathExtension().lastPathComponent
    }
    
    private func policyName(for rule: ProxyRule) -> String {
        switch rule {
        case .proxy:
            return "Proxy"  // 或者使用用户配置的策略组名称
        case .direct:
            return "DIRECT"
        case .reject:
            return "REJECT"
        }
    }
}

// MARK: - Data Models

struct SurgeAPIConfig: Codable {
    var host: String
    var port: Int
    var key: String
}

struct SurgeStatus {
    var isRunning: Bool
    var enhancedMode: Bool
}

struct SurgeRule: Codable {
    var rule: String
    var policy: String?
}

struct SurgeRulesResponse: Codable {
    var rules: [SurgeRule]
}

struct SurgePoliciesResponse: Codable {
    var policies: [String]
}

enum SurgeError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case notRunning
    case enhancedModeRequired
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无效的响应"
        case .httpError(let code):
            return "HTTP 错误: \(code)"
        case .notRunning:
            return "Surge 未运行"
        case .enhancedModeRequired:
            return "需要开启增强模式"
        }
    }
}
