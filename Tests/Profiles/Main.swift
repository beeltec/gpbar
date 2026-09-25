import Foundation

@main @MainActor enum ProfileTests {
    enum Failure: Error { case check(String) }
    static var checks = 0

    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.check(name) }
        checks += 1
    }

    static func main() throws {
        let domain = "com.beeltec.GPBar.ProfileTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure.check("isolated defaults") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let portal = "https://portal.example"
        let until = UInt64(Date().timeIntervalSince1970) + 300
        let legacy: [String: Any] = [
            "portal": portal, "displayName": "Work", "authenticationMethod": "certificate",
            "browser": "specific", "browserID": "fixture.browser", "reconnect": false,
            "rememberAuthentication": true, "certificateReference": Data([1, 2, 3]), "certificateName": "Fixture certificate",
            "certificateID": "fixture-id", "certificateTokenID": "fixture-token", "certificateOnly": true,
            "certificateUsername": "fixture-user", "pendingAuthenticationRemovals": ["https://previous.example"],
            "kerberosPolicyPortal": portal, "kerberosFallbackUntil": Double(until)
        ]
        for (key, value) in legacy { defaults.set(value, forKey: "connection." + key) }
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set("untouched", forKey: "general.fixture")
        let store = ConnectionProfiles(defaults: defaults)
        let original = store.selected
        let originalID = original.id
        try expect(store.profiles.count == 1 && store.storageError == nil, "one migrated profile")
        try expect(original.portal == portal && original.displayName == "Work", "legacy address and name")
        try expect(original.authenticationMethod == .certificate && original.browser == .specific && original.browserID == "fixture.browser", "legacy auth and browser")
        try expect(!original.reconnect && original.rememberAuthentication, "legacy behavior")
        try expect(original.certificateReference == Data([1, 2, 3]) && original.certificateTokenID == "fixture-token", "legacy certificate and token")
        try expect(original.certificateName == "Fixture certificate" && original.certificateID == "fixture-id"
            && original.certificateOnly && original.certificateUsername == "fixture-user", "legacy certificate options")
        try expect(original.pendingAuthenticationRemovals == ["https://previous.example"] && original.kerberosFallbackUntil == until, "legacy pending removals and policy")
        try expect(original.authenticationNamespace == nil, "migrated cookie namespace preserved")
        let reloaded = ConnectionProfiles(defaults: defaults)
        try expect(reloaded.selected.id == originalID && reloaded.selected.portal == portal, "idempotent migration")
        guard let second = store.add() else { throw Failure.check("add profile") }
        try expect(second.id != original.id && second.authenticationNamespace == second.id, "independent identity and cookie namespace")
        try expect(second.portal.isEmpty && second.browser == .inApp && second.authenticationMethod == .automatic
            && second.reconnect && !second.rememberAuthentication && second.certificateReference == nil, "new profile defaults")
        second.addressDraft = "portal.example"
        try expect(second.saveAddress() && second.portal == original.portal, "same portal is allowed")
        second.displayName = original.displayName
        try expect(store.label(for: second) != store.label(for: original), "identical names and portals have distinct labels")
        second.browser = .systemDefault
        second.reconnect = true
        try expect(original.browser == .specific && !original.reconnect && original.rememberAuthentication, "profile setting isolation")
        try expect(second.certificateReference == nil && second.kerberosFallbackUntil == 0, "certificate and policy not copied")
        second.addressDraft = "http://invalid.example/path"
        try expect(!second.saveAddress() && second.portal == portal && second.addressError != nil, "invalid address does not replace saved address")
        try expect(store.select(originalID) && store.select(second.id), "select by identity")
        try expect(second.addressDraft == "http://invalid.example/path", "invalid draft survives switching in memory")
        let restored = ConnectionProfiles(defaults: defaults)
        try expect(restored.selected.id == second.id && restored.selected.addressDraft == portal, "only valid address persists after restart")
        try expect(restored.profiles.first?.certificateID == "fixture-id" && restored.selected.browser == .systemDefault, "all profile settings survive restart")
        store.saveKerberosPolicy(KerberosPolicyUpdate(portal: portal, revision: UUID(), fallbackUntil: until))
        try expect(original.kerberosFallbackUntil == until && second.kerberosFallbackUntil == until, "portal grant reaches every profile")
        store.saveKerberosPolicy(KerberosPolicyUpdate(portal: portal, revision: UUID(), fallbackUntil: 0))
        try expect(original.kerberosFallbackUntil == 0 && second.kerberosFallbackUntil == 0, "portal revocation reaches every profile")
        second.addressDraft = "new.example"
        second.certificateReference = Data([4])
        second.certificateTokenID = "other-token"
        try expect(second.saveAddress() && second.certificateReference == nil && second.certificateTokenID == nil, "address changes clear certificate binding")
        try expect(second.pendingAuthenticationRemovals.contains(portal) && original.portal == portal, "old cookie removal marked without changing another profile")
        second.canChangeAddress = { false }
        second.addressDraft = "forbidden.example"
        try expect(!second.saveAddress() && second.portal == "https://new.example", "model address gate honored")
        let removed = store.removeSelected()
        try expect(removed?.id == second.id && store.selected.id == originalID && store.retired.count == 1, "remove chooses remaining profile")
        store.finishRemoval(second)
        try expect(store.retired.count == 1, "pending cleanup prevents tombstone removal")
        let interrupted = ConnectionProfiles(defaults: defaults)
        try expect(interrupted.retired.first?.pendingAuthenticationRemovals.contains(portal) == true, "cleanup survives restart")
        second.pendingAuthenticationRemovals = []
        store.finishRemoval(second)
        try expect(store.retired.isEmpty && defaults.object(forKey: "profile.\(second.id.uuidString).portal") == nil, "completed cleanup removes namespace")
        _ = store.removeSelected()
        try expect(store.profiles.count == 1 && store.selected.portal.isEmpty && store.selected.id != originalID, "last deletion provides fresh setup")
        try expect(defaults.bool(forKey: "SUEnableAutomaticChecks") == false && defaults.string(forKey: "general.fixture") == "untouched", "global preferences unchanged")
        let manifest = defaults.data(forKey: "profiles.manifest")
        defaults.set(Data("unsupported profiles".utf8), forKey: "profiles.manifest")
        let broken = ConnectionProfiles(defaults: defaults)
        try expect(broken.storageError != nil && broken.add() == nil && !broken.select(broken.selected.id), "corrupt manifest blocks edits")
        broken.selected.displayName = "Do not persist"
        try expect(defaults.string(forKey: "connection.displayName") == "Work", "corrupt storage does not overwrite legacy settings")
        try expect(defaults.data(forKey: "profiles.manifest") == Data("unsupported profiles".utf8), "corrupt manifest preserved")
        if let manifest,
           var invalidManifest = try JSONSerialization.jsonObject(with: manifest) as? [String: Any] {
            invalidManifest["version"] = 99
            defaults.set(try JSONSerialization.data(withJSONObject: invalidManifest), forKey: "profiles.manifest")
            try expect(ConnectionProfiles(defaults: defaults).storageError != nil, "future manifest version rejected without migration")
            invalidManifest["version"] = 1
            invalidManifest["ids"] = [store.selected.id.uuidString, store.selected.id.uuidString]
            defaults.set(try JSONSerialization.data(withJSONObject: invalidManifest), forKey: "profiles.manifest")
            try expect(ConnectionProfiles(defaults: defaults).storageError != nil, "duplicate manifest identities rejected")
        }
        defaults.set(manifest, forKey: "profiles.manifest")
        let emptyDomain = domain + ".empty"
        guard let empty = UserDefaults(suiteName: emptyDomain) else { throw Failure.check("empty defaults") }
        defer { empty.removePersistentDomain(forName: emptyDomain) }
        let fresh = ConnectionProfiles(defaults: empty)
        try expect(fresh.selected.portal.isEmpty && fresh.selected.reconnect && fresh.selected.browser == .inApp, "first-launch defaults")
        fresh.session = ConnectionProfiles.Session(id: UUID().uuidString, profileID: fresh.selected.id)
        try expect(ConnectionProfiles(defaults: empty).session?.profileID == fresh.selected.id, "session ownership persists")
        print("PASS: \(checks) profile migration, persistence, isolation, policy, draft, and deletion checks")
    }
}
