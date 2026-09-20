import Foundation
import Darwin

enum PortalAddress {
    static func normalize(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains("%"), !value.contains("\\") else { return nil }
        let address = value.contains("://") ? value : "https://" + value
        let authority = address.components(separatedBy: "://").last?.split(separator: "/", omittingEmptySubsequences: false).first
        guard authority?.last != ":" else { return nil }
        guard var url = URLComponents(string: address), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let host = url.host, !host.isEmpty,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let validHost: Bool
        if host.hasPrefix("[") && host.hasSuffix("]") {
            var bytes = in6_addr()
            validHost = String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &bytes) == 1 }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            validHost = host.utf8.count <= 253 && labels.allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
            if host.allSatisfy({ $0.isNumber || $0 == "." }) {
                var bytes = in_addr()
                guard host.withCString({ inet_pton(AF_INET, $0, &bytes) }) == 1 else { return nil }
            }
        }
        guard validHost else { return nil }
        url.scheme = "https"
        url.host = host.lowercased()
        if url.port == 443 { url.port = nil }
        url.path = ""
        return url.string
    }
}
