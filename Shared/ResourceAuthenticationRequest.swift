import Foundation

struct ResourceAuthenticationRequest: Sendable {
    let sessionID: String
    let challengeID: String
    let url: URL
    let message: String
    let expiresAt: Date

    init?(sessionID: String, event: EngineEvent, now: Date = .now) {
        guard UUID(uuidString: sessionID) != nil, event.type == .resourceAuthenticationRequired,
              let id = event.challengeID, id.count == 48, id.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let expiry = event.expiresAtUnix,
              Double(expiry) > now.timeIntervalSince1970, Double(expiry) <= now.timeIntervalSince1970 + 125,
              let raw = event.launchURL, let url = Self.authenticationURL(raw),
              let message = event.message, message.utf8.count <= 2048 else { return nil }
        self.sessionID = sessionID
        challengeID = id
        self.url = url
        self.message = String(String.UnicodeScalarView(message.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }))
        expiresAt = Date(timeIntervalSince1970: Double(expiry))
    }

    static func authenticationURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 2048, raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 92 }),
              let parts = URLComponents(string: raw), parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.port != 0,
              ["/php/uid.php", "/php/browser_challenge.php"].contains(parts.percentEncodedPath),
              let query = parts.queryItems, query.count == 2,
              Set(query.map(\.name)) == Set(["vsys", "rule"]),
              query.allSatisfy({ item in
                  guard let value = item.value else { return false }
                  return !value.isEmpty && value.utf8.count <= 10 && value.utf8.allSatisfy({ (48...57).contains($0) })
              }) else { return nil }
        return parts.url
    }
}
