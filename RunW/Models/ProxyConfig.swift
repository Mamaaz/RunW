import Foundation

/// 代理服务器配置
struct ProxyConfig: Codable, Equatable {
    var host: String
    var httpPort: Int
    var socksPort: Int
    var preferredProtocol: ProxyProtocol
    
    static let `default` = ProxyConfig(
        host: "192.168.1.68",
        httpPort: 6152,
        socksPort: 6153,
        preferredProtocol: .socks5
    )
    
    /// 获取代理 URL
    var proxyURL: String {
        switch preferredProtocol {
        case .http:
            return "http://\(host):\(httpPort)"
        case .socks5:
            return "socks5://\(host):\(socksPort)"
        }
    }
}

/// 代理协议类型
enum ProxyProtocol: String, Codable, CaseIterable {
    case http = "HTTP"
    case socks5 = "SOCKS5"
}
