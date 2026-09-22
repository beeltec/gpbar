import Foundation
import Security

@main @MainActor enum LoginSSOTests {
    enum Failure: Error { case check(String) }
    static var checks = 0

    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.check(name) }
        checks += 1
    }

    static func main() throws {
        let portal = "https://portal.example"
        let now = ContinuousClock.now
        func captured() -> LoginCredentialCache {
            var cache = LoginCredentialCache()
            cache.capture(username: "fixture-user", password: "fixture-password", userID: 501,
                          auditSessionID: 100, portal: portal, now: now)
            cache.begin(userID: 501, auditSessionID: 100, portal: portal, enabled: true)
            return cache
        }
        var event = EngineEvent(type: .credentialsRequired, challengeID: "fixture-challenge", server: portal)
        event.loginSSOAllowed = true
        var cache = captured()
        let credential = cache.respond(to: event, activeUser: 501, enrolledPortal: portal, validSession: true)
        try expect(credential?.username == "fixture-user" && credential?.password == "fixture-password", "portal receives captured credentials")
        try expect(cache.respond(to: event, activeUser: 501, enrolledPortal: portal, validSession: true) == nil, "one use only")
        cache = captured()
        try expect(cache.take(userID: 501, auditSessionID: 100, portal: portal, now: now + .seconds(300)) == nil, "monotonic expiry")
        for (uid, session, origin) in [(502, 100, portal), (501, 101, portal), (501, 100, "https://other.example")] {
            cache = captured()
            try expect(cache.take(userID: UInt32(uid), auditSessionID: UInt32(session), portal: origin) == nil, "identity and origin binding")
            try expect(cache.take(userID: 501, auditSessionID: 100, portal: portal) == nil, "mismatch destroys credential")
        }
        for (active, enrolled, valid) in [(UInt32(502), portal, true), (501, "https://other.example", true), (501, portal, false)] {
            cache = captured()
            try expect(cache.respond(to: event, activeUser: active, enrolledPortal: enrolled, validSession: valid) == nil, "current session and consent required")
            try expect(cache.respond(to: event, activeUser: 501, enrolledPortal: portal, validSession: true) == nil, "no late reuse")
        }
        for kind in [EngineEvent.Kind.authenticationRequired, .otpRequired, .credentialsRequired] {
            cache = captured()
            let other = EngineEvent(type: kind, challengeID: "other", server: portal)
            try expect(cache.respond(to: other, activeUser: 501, enrolledPortal: portal, validSession: true) == nil, "SAML, MFA, and same-origin gateway cannot consume")
            try expect(cache.respond(to: event, activeUser: 501, enrolledPortal: portal, validSession: true) == nil, "first prompt only")
        }
        cache = captured()
        cache.begin(userID: 501, auditSessionID: 100, portal: portal, enabled: false)
        try expect(cache.respond(to: event, activeUser: 501, enrolledPortal: portal, validSession: true) == nil, "disabled by default")
        cache = captured()
        cache.clear()
        try expect(cache.respond(to: event, activeUser: 501, enrolledPortal: portal, validSession: true) == nil, "cancel and logout clear memory")
        for (username, password) in [("", "fixture"), ("fixture\nuser", "fixture"), ("fixture", ""), ("fixture", String(repeating: "x", count: 4097))] {
            cache.capture(username: username, password: password, userID: 501, auditSessionID: 100, portal: portal)
            try expect(cache.take(userID: 501, auditSessionID: 100, portal: portal) == nil, "malformed context rejected")
        }
        let original = ["builtin:prelogin", "third-party:before", "builtin:authenticate,privileged",
                        "builtin:login-success", "third-party:after", "loginwindow:done"]
        let installed = try LoginSSORule.mechanisms(original, installing: true)
        try expect(installed[4] == loginSSOMechanism, "capture follows successful authentication")
        try expect(try LoginSSORule.mechanisms(installed, installing: true) == installed, "idempotent install")
        try expect(try LoginSSORule.mechanisms(installed, installing: false) == original, "removal preserves other mechanisms")
        let changed = installed + ["another-vendor:later"]
        try expect(try LoginSSORule.mechanisms(changed, installing: false) == original + ["another-vendor:later"], "removal preserves later edits")
        for invalid in [[], ["allow"], ["builtin:login-success", "builtin:authenticate,privileged", "loginwindow:done"], original + ["unknown:tail"]] {
            do { _ = try LoginSSORule.mechanisms(invalid, installing: true); throw Failure.check("unsupported login rule accepted") }
            catch LoginSSORule.Failure.unsupportedRule { checks += 1 }
        }
        var requirement: SecRequirement?
        try expect(SecRequirementCreateWithString(loginSSOHostRequirement as CFString, [], &requirement) == errSecSuccess, "host requirement is valid")
        var ownCode: SecCode?
        _ = SecCodeCopySelf([], &ownCode)
        if let ownCode, let requirement {
            try expect(SecCodeCheckValidity(ownCode, [], requirement) != errSecSuccess, "fixture cannot impersonate the Apple host")
        }
        let encoded = try JSONEncoder().encode(event)
        try expect(try JSONDecoder().decode(EngineEvent.self, from: encoded).loginSSOAllowed == true, "engine eligibility survives IPC")
        print("PASS: \(checks) login SSO ownership, consent, expiry, rule preservation, signature, and IPC checks")
    }
}
