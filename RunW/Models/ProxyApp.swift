import SwiftUI

/// 代理的应用
struct ProxyApp: Identifiable, Codable, Hashable {
    let id: UUID
    let bundleIdentifier: String
    let name: String
    let path: String
    var rule: ProxyRule
    var isEnabled: Bool
    
    // 图标不持久化，运行时加载
    var icon: NSImage? {
        NSWorkspace.shared.icon(forFile: path)
    }
    
    init(id: UUID = UUID(), bundleIdentifier: String, name: String, path: String, rule: ProxyRule = .proxy, isEnabled: Bool = true) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.rule = rule
        self.isEnabled = isEnabled
    }
}

/// 规则类型
enum ProxyRule: String, Codable, CaseIterable {
    case proxy = "代理"
    case direct = "直连"
    case reject = "拒绝"
    
    var icon: String {
        switch self {
        case .proxy: return "arrow.triangle.branch"
        case .direct: return "arrow.right"
        case .reject: return "xmark.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .proxy: return .blue
        case .direct: return .green
        case .reject: return .red
        }
    }
}
