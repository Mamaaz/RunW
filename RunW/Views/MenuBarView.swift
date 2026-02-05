import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appManager: AppManager
    @EnvironmentObject var proxyManager: ProxyManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 状态
            HStack {
                Circle()
                    .fill(proxyManager.isEnabled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(proxyManager.isEnabled ? "代理已启用" : "代理已停止")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            Divider()
            
            // 快速开关
            Toggle(proxyManager.isEnabled ? "停止代理" : "启动代理", isOn: $proxyManager.isEnabled)
                .toggleStyle(.button)
            
            Divider()
            
            // App 列表
            if !appManager.apps.isEmpty {
                Text("代理应用")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                
                ForEach(appManager.apps.filter { $0.isEnabled }) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        Text(app.name)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: app.rule.icon)
                            .foregroundStyle(app.rule.color)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                
                Divider()
            }
            
            // 打开主窗口
            Button("打开 RunW") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("RunW") || $0.isKeyWindow }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // 创建新窗口
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                        styleMask: [.titled, .closable, .miniaturizable],
                        backing: .buffered,
                        defer: false
                    )
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                }
            }
            
            Divider()
            
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppManager())
        .environmentObject(ProxyManager())
        .frame(width: 200)
}
