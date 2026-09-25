import Darwin
import Foundation

enum SplitDNS {
    static let maximumInputBytes = 32768
    static let validationMessage = "Enter 1–128 domains, separated by commas or spaces. Use DNS names without wildcards, URLs, or IP addresses."

    static func domains(from text: String) -> [String]? {
        guard text.utf8.count <= maximumInputBytes else { return nil }
        let entries = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard !entries.isEmpty, entries.count <= 128 else { return nil }
        var domains: [String] = []
        for entry in entries {
            var domain = entry.lowercased()
            if domain.hasSuffix(".") { domain.removeLast() }
            guard validDomain(domain) else { return nil }
            if !domains.contains(domain) { domains.append(domain) }
        }
        return domains
    }

    static func validPolicy(_ domains: [String]) -> Bool {
        domains.count <= 128 && domains.joined(separator: " ").utf8.count <= maximumInputBytes
            && Set(domains).count == domains.count
            && domains.allSatisfy { $0 == $0.lowercased() && validDomain($0) }
    }

    private static func validDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { return false }
        var address = in_addr()
        return inet_aton(value, &address) == 0
    }
}
