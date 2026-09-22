import Foundation

struct LoginCredentialCache {
    private struct Entry {
        let username: String
        let password: String
        let userID: UInt32
        let auditSessionID: UInt32
        let portal: String
        let deadline: ContinuousClock.Instant
    }
    private var entry: Entry?
    private var attempt: (userID: UInt32, auditSessionID: UInt32, portal: String)?

    mutating func begin(userID: UInt32, auditSessionID: UInt32, portal: String, enabled: Bool) {
        attempt = enabled ? (userID, auditSessionID, portal) : nil
        if !enabled { entry = nil }
    }

    mutating func respond(to event: EngineEvent, activeUser: UInt32?, enrolledPortal: String?, validSession: Bool)
        -> (username: String, password: String)? {
        guard [.authenticationRequired, .credentialsRequired, .otpRequired].contains(event.type), let attempt else { return nil }
        self.attempt = nil
        guard event.type == .credentialsRequired, event.loginSSOAllowed == true,
              event.challengeID != nil, activeUser == attempt.userID, validSession,
              enrolledPortal == attempt.portal, PortalAddress.normalize(event.server ?? "") == attempt.portal else {
            entry = nil
            return nil
        }
        return take(userID: attempt.userID, auditSessionID: attempt.auditSessionID, portal: attempt.portal)
    }

    mutating func capture(username: String, password: String, userID: UInt32, auditSessionID: UInt32,
                          portal: String, now: ContinuousClock.Instant = .now) {
        entry = nil
        guard userID >= 501, auditSessionID != 0, auditSessionID != UInt32.max,
              !username.isEmpty, username.utf8.count <= 1024,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !password.isEmpty, password.utf8.count <= 4096,
              PortalAddress.normalize(portal) == portal else { return }
        entry = Entry(username: username, password: password, userID: userID,
                      auditSessionID: auditSessionID, portal: portal, deadline: now + .seconds(300))
    }

    mutating func take(userID: UInt32, auditSessionID: UInt32, portal: String,
                       now: ContinuousClock.Instant = .now) -> (username: String, password: String)? {
        guard let entry else { return nil }
        self.entry = nil
        guard now < entry.deadline, entry.userID == userID, entry.auditSessionID == auditSessionID,
              entry.portal == portal else { return nil }
        return (entry.username, entry.password)
    }

    mutating func clear() { entry = nil; attempt = nil }
}
