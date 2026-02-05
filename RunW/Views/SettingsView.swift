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
                Section {
                    TextField("代理地址", text: $proxyManager.config.host)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("服务器")
                }
                
                Section {
                    HStack {
                        Text("HTTP 端口")
                        Spacer()
                        TextField("", value: $proxyManager.config.httpPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    
                    HStack {
                        Text("SOCKS5 端口")
                        Spacer()
                        TextField("", value: $proxyManager.config.socksPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                } header: {
                    Text("端口")
                }
                
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
                
                Section {
                    HStack {
                        Text(proxyManager.config.proxyURL)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Button("测试连接") {
                            proxyManager.testConnection()
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("预览")
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
        .frame(width: 380, height: 420)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ProxyManager())
}
