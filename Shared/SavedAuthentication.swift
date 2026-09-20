import Foundation

struct SavedAuthentication: Codable, Sendable {
    let portal: String
    let username: String
    let computer: String
    var portalCookie: RetainedCookie?
    var gatewayCookie: RetainedCookie?

    enum CodingKeys: String, CodingKey {
        case portal, username, computer
        case portalCookie = "portal_cookie", gatewayCookie = "gateway_cookie"
    }

    var isValid: Bool {
        PortalAddress.normalize(portal) == portal
            && !username.isEmpty && username.utf8.count <= 1024
            && !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !computer.isEmpty && computer.utf8.count <= 256
            && !computer.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (portalCookie != nil || gatewayCookie != nil)
            && portalCookie.map({ $0.isValid && $0.server == portal && $0.username == username }) != false
            && gatewayCookie?.isValid != false
    }

    func unexpired() -> SavedAuthentication? {
        guard isValid else { return nil }
        var result = self
        if result.portalCookie?.isCurrent != true { result.portalCookie = nil }
        if result.gatewayCookie?.isCurrent != true { result.gatewayCookie = nil }
        return result.portalCookie == nil && result.gatewayCookie == nil ? nil : result
    }
}

struct RetainedCookie: Codable, Sendable {
    let server: String
    let username: String
    let value: String
    let issuedAt: UInt64
    let expiresAt: UInt64

    enum CodingKeys: String, CodingKey {
        case server, username, value, issuedAt = "issued_at", expiresAt = "expires_at"
    }

    var isValid: Bool {
        PortalAddress.normalize(server) == server
            && !username.isEmpty && username.utf8.count <= 1024
            && !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.isEmpty && value != "empty" && value != "(null)" && value.utf8.count <= 16384
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && expiresAt > issuedAt && expiresAt - issuedAt <= 365 * 86400
    }

    var isCurrent: Bool {
        let now = Date().timeIntervalSince1970
        return isValid && Double(issuedAt) <= now && now < Double(expiresAt)
    }
}
