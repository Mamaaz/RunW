import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var proxyManager: ProxyManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("代理设置")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            Form {
                // 快捷配置
                Section {
                    HStack(spacing: 12) {
                        PresetButton(title: "Surge 本地", host: "127.0.0.1", httpPort: 6152, socksPort: 6153, config: $proxyManager.config)
                        PresetButton(title: "Surge 局域网", host: "192.168.1.68", httpPort: 6152, socksPort: 6153, config: $proxyManager.config)
                        PresetButton(title: "Clash", host: "127.0.0.1", httpPort: 7890, socksPort: 7891, config: $proxyManager.config)
                    }
                } header: {
                    Text("快捷配置")
                }
                
                // 服务器地址
                Section {
                    TextField("代理地址", text: $proxyManager.config.host)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("服务器")
                }
                
                // 端口配置
                Section {
                    HStack {
                        Text("HTTP 端口")
                        Spacer()
                        TextField("", value: $proxyManager.config.httpPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Text("SOCKS5 端口")
                        Spacer()
                        TextField("", value: $proxyManager.config.socksPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("端口")
                }
                
                // 协议选择
                Section {
                    Picker("首选协议", selection: $proxyManager.config.preferredProtocol) {
                        ForEach(ProxyProtocol.allCases, id: \.self) { proto in
                            Text(proto.rawValue).tag(proto)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("协议")
                }
                
                // 预览和测试
                Section {
                    HStack {
                        Text(proxyManager.config.proxyURL)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        // 连接状态指示
                        connectionStatusView
                        
                        Button("测试") {
                            proxyManager.testConnection()
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("连接测试")
                }
            }
            .formStyle(.grouped)
            .padding()
            
            Spacer()
            
            Divider()
            
            // Footer
            HStack {
                Text("配置 Surge/Clash 的 HTTP 或 SOCKS5 代理端口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("保存") {
                    proxyManager.saveConfig()
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 420, height: 500)
    }
    
    @ViewBuilder
    private var connectionStatusView: some View {
        switch proxyManager.connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .scaleEffect(0.6)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(msg)
        }
    }
}

// MARK: - Preset Button

struct PresetButton: View {
    let title: String
    let host: String
    let httpPort: Int
    let socksPort: Int
    @Binding var config: ProxyConfig
    
    private var isSelected: Bool {
        config.host == host && config.httpPort == httpPort && config.socksPort == socksPort
    }
    
    var body: some View {
        Button {
            config.host = host
            config.httpPort = httpPort
            config.socksPort = socksPort
        } label: {
            Text(title)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : nil)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ProxyManager())
}
