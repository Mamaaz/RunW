import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appManager: AppManager
    @EnvironmentObject var proxyManager: ProxyManager
    @State private var isTargeted = false
    @State private var showingSettings = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            headerView
            
            Divider()
            
            // 主内容区
            if appManager.apps.isEmpty {
                emptyStateView
            } else {
                appListView
            }
            
            Divider()
            
            // 底部状态栏
            footerView
        }
        .frame(minWidth: 420, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.accentColor.opacity(0.1))
                    .padding(8)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(proxyManager)
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            Text("RunW")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            // 主开关
            Toggle("", isOn: $proxyManager.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
            
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "plus.app.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text("拖拽应用到这里")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            Text("或点击下方按钮添加")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            Button("从应用程序选择") {
                appManager.showAppPicker()
            }
            .buttonStyle(.bordered)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - App List
    private var appListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(appManager.apps) { app in
                    AppRowView(app: app)
                        .environmentObject(appManager)
                }
            }
            .padding(12)
        }
    }
    
    // MARK: - Footer
    private var footerView: some View {
        HStack {
            Button {
                appManager.showAppPicker()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            
            Spacer()
            
            // Surge 连接状态
            if proxyManager.surgeConnected {
                Button {
                    Task {
                        await proxyManager.syncRulesToSurge(apps: appManager.apps)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("同步规则")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Surge 已连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        await proxyManager.checkSurgeConnection()
                    }
                } label: {
                    Text("连接 Surge")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                Text("未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - Drop Handler
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                
                if url.pathExtension == "app" {
                    DispatchQueue.main.async {
                        appManager.addApp(from: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - App Row View
struct AppRowView: View {
    let app: ProxyApp
    @EnvironmentObject var appManager: AppManager
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // App Icon
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 36, height: 36)
            }
            
            // App Info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Rule Picker
            Menu {
                ForEach(ProxyRule.allCases, id: \.self) { rule in
                    Button {
                        appManager.updateRule(for: app.id, rule: rule)
                    } label: {
                        Label(rule.rawValue, systemImage: rule.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.rule.icon)
                    Text(app.rule.rawValue)
                        .font(.caption)
                }
                .foregroundStyle(app.rule.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(app.rule.color.opacity(0.1))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            // Enable Toggle
            Toggle("", isOn: Binding(
                get: { app.isEnabled },
                set: { appManager.toggleApp(app.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            
            // Delete Button
            if isHovered {
                Button {
                    appManager.removeApp(app.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppManager())
        .environmentObject(ProxyManager())
}
