import Foundation

struct CompanionLink: Codable, Equatable {
    let version: Int
    let endpoint: String
    let token: String
    let certificateSHA256: String
    var valid: Bool {
        guard version == 1, endpoint.count <= 300, token.count == 64, certificateSHA256.count == 64,
              token.allSatisfy(\.isHexDigit), certificateSHA256.allSatisfy(\.isHexDigit),
              let url = URL(string: endpoint), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", (1...65535).contains(url.port ?? 443) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = labels.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
              zip(labels, parts).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}
