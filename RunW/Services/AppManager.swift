import SwiftUI
import AppKit

/// 管理已添加的应用列表
@MainActor
class AppManager: ObservableObject {
    @Published var apps: [ProxyApp] = []
    
    private let defaults = UserDefaults.standard
    private let appsKey = "savedApps"
    
    // App Group 共享
    private let appGroupID = "LLNRYKR4A6.com.dundun.runw"
    private var sharedDefaults: UserDefaults?
    
    init() {
        sharedDefaults = UserDefaults(suiteName: appGroupID)
        loadApps()
    }
    
    // MARK: - Persistence
    
    private func loadApps() {
        if let data = defaults.data(forKey: appsKey),
           let decoded = try? JSONDecoder().decode([ProxyApp].self, from: data) {
            apps = decoded
        }
    }
    
    private func saveApps() {
        // 保存到本地
        if let encoded = try? JSONEncoder().encode(apps) {
            defaults.set(encoded, forKey: appsKey)
        }
        
        // 同步到 App Group（供 Extension 读取）
        syncToAppGroup()
    }
    
    /// 同步应用列表到 App Group
    private func syncToAppGroup() {
        // 只保存启用的代理应用的 Bundle ID
        let proxyBundleIDs = enabledProxyApps.map { $0.bundleIdentifier }
        let rejectBundleIDs = enabledRejectApps.map { $0.bundleIdentifier }
        
        sharedDefaults?.set(proxyBundleIDs, forKey: "proxyApps")
        sharedDefaults?.set(rejectBundleIDs, forKey: "rejectApps")
        sharedDefaults?.synchronize()
        
        print("📱 同步到 App Group: \(proxyBundleIDs.count) 个代理, \(rejectBundleIDs.count) 个拒绝")
    }
    
    // MARK: - App Management
    
    /// 从 URL 添加应用
    func addApp(from url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier,
              let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent as String?
        else {
            print("无法读取 App 信息: \(url)")
            return
        }
        
        // 检查是否已存在
        if apps.contains(where: { $0.bundleIdentifier == bundleId }) {
            print("App 已存在: \(bundleId)")
            return
        }
        
        let app = ProxyApp(
            bundleIdentifier: bundleId,
            name: name,
            path: url.path
        )
        
        apps.append(app)
        saveApps()
    }
    
    /// 移除应用
    func removeApp(_ id: UUID) {
        apps.removeAll { $0.id == id }
        saveApps()
    }
    
    /// 更新规则
    func updateRule(for id: UUID, rule: ProxyRule) {
        if let index = apps.firstIndex(where: { $0.id == id }) {
            apps[index].rule = rule
            saveApps()
        }
    }
    
    /// 切换启用状态
    func toggleApp(_ id: UUID, enabled: Bool) {
        if let index = apps.firstIndex(where: { $0.id == id }) {
            apps[index].isEnabled = enabled
            saveApps()
        }
    }
    
    /// 显示应用选择器
    func showAppPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择要添加代理的应用"
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                addApp(from: url)
            }
        }
    }
    
    /// 获取启用的代理应用
    var enabledProxyApps: [ProxyApp] {
        apps.filter { $0.isEnabled && $0.rule == .proxy }
    }
    
    /// 获取启用的拒绝应用
    var enabledRejectApps: [ProxyApp] {
        apps.filter { $0.isEnabled && $0.rule == .reject }
    }
}
