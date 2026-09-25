import AppKit

@main @MainActor enum ProfileLifecycleTests {
    enum Failure: Error { case check(String) }
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.check(name) }
        checks += 1
    }
    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    static func main() async throws {
        _ = NSApplication.shared
        let domain = "com.beeltec.GPBar.ProfileLifecycle.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure.check("defaults") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = ConnectionModel(defaults: defaults)
        guard let helper = HelperClient.latest else { throw Failure.check("helper fixture") }
        let first = model.preferences
        model.addProfile()
        try expect(model.profiles.profiles.count == 1, "startup unknown state blocks add")
        model.refresh()
        try expect(model.profileControlsLocked, "helper inspection locks selection")
        helper.reply()
        first.addressDraft = "portal.example"
        try expect(first.saveAddress(), "idle address edit")
        model.addProfile()
        let second = model.preferences
        second.addressDraft = "portal.example"
        try expect(second.saveAddress(), "second profile on same portal")
        model.selectProfile(first.id)
        try expect(model.preferences.id == first.id && model.phase == .disconnected, "selection does not connect")
        first.certificateReference = Data([1, 2, 3])
        model.selectProfile(second.id)
        model.selectProfile(first.id)
        await settle()
        try expect(KeychainIdentity.metadata.count == 1, "certificate metadata lookup starts for selected profile")
        model.selectProfile(second.id)
        KeychainIdentity.metadata.removeFirst().resume(returning: "stale-token")
        await settle()
        try expect(second.certificateTokenID == nil && first.certificateTokenID == nil, "late certificate metadata cannot mutate another profile")
        first.clearCertificate()
        model.selectProfile(first.id)
        first.addressDraft = "bad/path"
        model.connect()
        try expect(helper.commands.allSatisfy { $0.command.type != .start }, "invalid draft never starts old portal")
        first.addressDraft = first.portal
        first.rememberAuthentication = true
        model.connect()
        let session = model.profiles.session?.id ?? ""
        try expect(!session.isEmpty && model.phase == .preparing && KeychainAuthentication.loads.count == 1, "session ownership precedes async cache load")
        model.selectProfile(second.id)
        model.addProfile()
        model.removeProfile(first.id)
        try expect(model.preferences.id == first.id && model.profiles.profiles.count == 2, "preparing locks all profile transitions")
        model.disconnect()
        KeychainAuthentication.loads.removeFirst()(.success(nil))
        await settle()
        try expect(model.phase == .disconnected && helper.commands.allSatisfy { $0.command.type != .start }, "late cache load cannot start cancelled session")
        first.rememberAuthentication = false
        model.connect()
        guard let start = helper.commands.last(where: { $0.command.type == .start }) else { throw Failure.check("start command") }
        for (offset, phase) in [ConnectionPhase.authenticating, .connecting, .connected, .reconnecting, .disconnecting, .unknown].enumerated() {
            helper.event(.phaseChanged, session: start.sessionID, sequence: UInt64(offset + 1), phase: phase)
            model.selectProfile(second.id)
            model.addProfile()
            model.removeProfile(first.id)
            try expect(model.preferences.id == first.id && model.profiles.profiles.count == 2, "\(phase) locks profile changes")
        }
        helper.event(.stopped, session: start.sessionID, sequence: 8, cleanup: "failed")
        try expect(model.profileControlsLocked && model.cleanupRequired, "failed cleanup locks selection")
        model.recoverNetwork()
        try expect(!model.cleanupRequired && model.phase == .disconnected, "confirmed recovery unlocks profiles")
        model.selectProfile(second.id)
        try expect(model.preferences.id == second.id, "selection after cleanup")
        model.holdForPendingUpdate()
        model.selectProfile(first.id)
        try expect(model.preferences.id == second.id && model.profileControlsLocked, "update blocks profile switching")
        model.finishUpdateAttempt()
        helper.reply()
        try expect(!model.updating, "update cancellation releases profile lock")
        model.refresh()
        helper.reply(loginPortal: second.portal)
        model.removeProfile(second.id)
        second.addressDraft = "other.example"
        try expect(model.profiles.profiles.count == 2 && !second.saveAddress(), "enrolled SSO portal cannot be removed or edited")
        second.addressDraft = second.portal
        model.refresh()
        helper.reply()
        let until = UInt64(Date().timeIntervalSince1970) + 500
        model.profiles.saveKerberosPolicy(KerberosPolicyUpdate(portal: first.portal, revision: UUID(), fallbackUntil: until))
        model.refresh()
        helper.reply(policies: [KerberosPolicyUpdate(portal: first.portal, revision: UUID(), fallbackUntil: 0)])
        try expect(first.kerberosFallbackUntil == 0 && second.kerberosFallbackUntil == 0, "missed policy revokes every matching profile")
        KeychainAuthentication.writes = []
        model.refresh()
        helper.reply(updates: [AuthenticationCacheUpdate(portal: first.portal, revision: UUID())])
        try expect(first.pendingAuthenticationRemovals.contains(first.portal) && second.pendingAuthenticationRemovals.contains(second.portal), "all namespaces marked before cache acknowledgements")
        try expect(KeychainAuthentication.writes.count == 2, "missed cache update removes both namespaces")
        let writes = KeychainAuthentication.writes
        writes[0].completion(true)
        writes[1].completion(false)
        await settle()
        try expect(first.pendingAuthenticationRemovals.isEmpty && !second.pendingAuthenticationRemovals.isEmpty, "failure remains isolated and blocks reuse")
        model.selectProfile(first.id)
        model.selectProfile(second.id)
        try expect(model.authenticationStorageMessage != nil, "pending cleanup warning survives profile switching")
        model.selectProfile(first.id)
        writes[1].completion(true)
        await settle()
        try expect(model.authenticationStorageMessage == nil, "late callback does not change another profile's message")
        KeychainAuthentication.writes = []
        model.removeProfile(first.id)
        try expect(model.profiles.retired.count == 1 && model.preferences.id == second.id, "deleted profile retains cleanup record")
        guard let deletion = KeychainAuthentication.writes.last else { throw Failure.check("deletion cleanup") }
        deletion.completion(false)
        await settle()
        try expect(model.profiles.retired.count == 1, "failed deletion cleanup persists")
        model.refresh()
        helper.reply()
        KeychainAuthentication.writes.last?.completion(true)
        await settle()
        try expect(model.profiles.retired.isEmpty, "retry finishes only deleted profile cleanup")
        model.refresh()
        helper.inspection?(.failure(.unavailable))
        try expect(model.phase == .unknown && model.profileControlsLocked, "unreachable enabled helper never proves idle")
        model.refresh()
        helper.reply()
        helper.event(.stopped, session: UUID().uuidString, sequence: 1, cleanup: "restored")
        try expect(model.error == nil && model.phase == .disconnected, "completed-session replay does not report unidentified active connection")
        let ownedSession = UUID().uuidString
        model.profiles.session = ConnectionProfiles.Session(id: ownedSession, profileID: second.id)
        let relaunched = ConnectionModel(defaults: defaults)
        guard let restoredHelper = HelperClient.latest else { throw Failure.check("restored helper") }
        relaunched.refresh()
        restoredHelper.reply(active: ownedSession)
        try expect(relaunched.preferences.id == second.id && relaunched.profileControlsLocked, "reattachment preserves recorded profile")
        restoredHelper.event(.phaseChanged, session: ownedSession, sequence: 1, phase: .connected)
        try expect(relaunched.connectionTitle == relaunched.profiles.label(for: second), "connected label identifies owning profile")
        restoredHelper.event(.stopped, session: ownedSession, sequence: 2, cleanup: "restored")
        relaunched.refresh()
        restoredHelper.reply(active: UUID().uuidString)
        try expect(relaunched.connectionTitle == "Unidentified connection" && relaunched.profileControlsLocked, "unmapped helper session cannot adopt current profile")
        let retryDomain = domain + ".retry"
        guard let retryDefaults = UserDefaults(suiteName: retryDomain) else { throw Failure.check("retry defaults") }
        defer { retryDefaults.removePersistentDomain(forName: retryDomain) }
        let retryModel = ConnectionModel(defaults: retryDefaults)
        guard let retryHelper = HelperClient.latest else { throw Failure.check("retry helper") }
        retryModel.refresh()
        retryHelper.reply()
        retryModel.preferences.addressDraft = "retry.example"
        retryModel.connect()
        guard let retrySession = retryModel.profiles.session?.id else { throw Failure.check("retry session") }
        retryModel.refresh()
        retryModel.authentication.onRetryExternally?()
        retryHelper.event(.stopped, session: retrySession, sequence: 1, cleanup: "restored")
        try expect(retryHelper.commands.filter { $0.command.type == .start }.count == 1, "browser retry waits for pending inspection")
        retryHelper.reply()
        if retryHelper.inspection != nil { retryHelper.reply() }
        try expect(retryHelper.commands.filter { $0.command.type == .start }.count == 2, "browser retry resumes after helper inspection")
        try expect(retryModel.preferences.browser == .inApp, "external retry preserves saved browser")
        if let active = retryModel.profiles.session?.id { retryHelper.event(.stopped, session: active, sequence: 1, cleanup: "restored") }

        let identityDomain = domain + ".identity"
        guard let identityDefaults = UserDefaults(suiteName: identityDomain) else { throw Failure.check("identity defaults") }
        defer { identityDefaults.removePersistentDomain(forName: identityDomain) }
        identityDefaults.set(Data([7]), forKey: "connection.certificateReference")
        identityDefaults.set("https://identity.example", forKey: "connection.portal")
        let identityModel = ConnectionModel(defaults: identityDefaults)
        guard let identityHelper = HelperClient.latest else { throw Failure.check("identity helper") }
        await settle()
        identityModel.refresh()
        let unrelatedSession = UUID().uuidString
        identityHelper.reply(active: unrelatedSession)
        try expect(KeychainIdentity.metadata.count == 1, "unidentified session has pending selected-profile metadata")
        KeychainIdentity.metadata.removeFirst().resume(throwing: KeychainIdentity.Failure.unavailable)
        await settle()
        try expect(!identityHelper.commands.contains { $0.command.type == .disconnect }, "unrelated certificate failure cannot disconnect unidentified session")
        try expect(identityModel.connectionTitle == "Unidentified connection", "certificate failure preserves unidentified session warning")
        identityHelper.event(.stopped, session: unrelatedSession, sequence: 1, cleanup: "restored")

        let corruptDomain = domain + ".corrupt"
        guard let corruptDefaults = UserDefaults(suiteName: corruptDomain) else { throw Failure.check("corrupt defaults") }
        defer { corruptDefaults.removePersistentDomain(forName: corruptDomain) }
        corruptDefaults.set(Data("unknown manifest".utf8), forKey: "profiles.manifest")
        let corruptModel = ConnectionModel(defaults: corruptDefaults)
        guard let corruptHelper = HelperClient.latest else { throw Failure.check("corrupt helper") }
        KeychainAuthentication.writes = []
        corruptModel.refresh()
        corruptHelper.reply(policies: [KerberosPolicyUpdate(portal: "https://missing.example", revision: UUID(), fallbackUntil: 0)],
                            updates: [AuthenticationCacheUpdate(portal: "https://missing.example", revision: UUID())])
        try expect(corruptHelper.commands.isEmpty && KeychainAuthentication.writes.isEmpty, "unreadable storage retains helper cookie and policy revisions")
        try expect(corruptModel.profileControlsLocked, "unreadable storage blocks connection commands")
        corruptModel.refresh()
        let corruptSession = UUID().uuidString
        corruptHelper.reply(active: corruptSession)
        corruptHelper.event(.phaseChanged, session: corruptSession, sequence: 1, phase: .connected)
        try expect(corruptModel.hasSession && corruptModel.phase == .connected, "unreadable storage still exposes active session controls")
        corruptModel.disconnect()
        try expect(corruptHelper.commands.last?.command.type == .disconnect, "unreadable storage permits explicit disconnect")
        corruptHelper.event(.stopped, session: corruptSession, sequence: 2, cleanup: "restored")
        print("PASS: \(checks) production model lifecycle, callback, cache, SSO, recovery, and ownership checks")
    }
}
