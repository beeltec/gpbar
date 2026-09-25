import AppKit
import Observation
import ServiceManagement
import Network
import CryptoTokenKit

@MainActor @Observable final class ConnectionModel {
    let profiles: ConnectionProfiles
    var preferences: ConnectionPreferences { profiles.selected }
    let authentication = AuthenticationCoordinator()
    let resourceAuthentication = ResourceAuthenticationCoordinator()
    private(set) var resourceAuthenticationMessage: String?
    private(set) var phase: ConnectionPhase = .unknown
    private(set) var snapshot: ConnectionSnapshot?
    private(set) var cleanupRequired = false
    private(set) var engineAvailable = false
    private var sessionID: String?
    private var startPending = false
    private var engineStartSent = false
    private var certificateContext: KeychainContext?
    private var signatureRequestID: String?
    private var authenticationStorageStatus: String?
    var authenticationStorageMessage: String? {
        if !preferences.pendingAuthenticationRemovals.isEmpty {
            return "Saved sign-in cleanup is pending. Unlock Keychain, then choose Forget saved sign-in to try again."
        }
        return authenticationStorageStatus
    }
    private var kerberos: KerberosSession?
    private var kerberosTask: Task<Void, Never>?
    private var kerberosRequestID: String?
    private var cancelledKerberosSessionID: String?
    private(set) var loginSSO: LoginSSOState?
    private(set) var configuringLoginSSO = false
    private(set) var loginSSOMessage: String?
    private var authenticationStorageRevision = UUID()
    private var certificateMetadataRevision = UUID()
    private(set) var sessionProfileKnown = true
    private var authenticationStorageOperations: [String: UUID] = [:]
    private var receivedKerberosPolicy: KerberosPolicyUpdate?
    private var receivedAuthenticationUpdate: AuthenticationCacheUpdate?
    private(set) var certificateChoices: [CertificateChoice] = []
    private(set) var loadingCertificates = false
    private(set) var certificateError: String?
    private let tokenWatcher = TKTokenWatcher()
    private var availableTokenIDs: Set<String> = []
    private var certificateMetadataReady = false
    private var certificateMetadataFailed = false
    var selectedTokenMissing: Bool {
        preferences.authenticationMethod == .certificate
            && (preferences.certificateTokenID.map { !availableTokenIDs.contains($0) } ?? false)
    }
    private var lastSequence: UInt64 = 0
    private var completedSessions: [String] = []
    private(set) var quitting = false
    private var quitTimeout: Timer?
    private var retryExternally = false
    private var browserOverride: BrowserChoice?
    private let pathMonitor = NWPathMonitor()
    private(set) var recovering = false
    private(set) var recentEvents: [String] = []
    private enum UpdatePreparation { case idle, preparing, ready, blocked }
    private var updatePreparation = UpdatePreparation.idle
    var updating: Bool { updatePreparation != .idle }
    var readyForUpdate: Bool { updatePreparation == .ready }
    private var restoreHelperAfterUpdate = false
    var settingsLocked: Bool { quitting || configuringLoginSSO || sessionID != nil || phase.isActive }

    var profileControlsLocked: Bool {
        settingsLocked || updating || cleanupRequired || recovering || checkingHelper || loadingCertificates
            || profiles.storageError != nil || (helperStatus == .enabled && !helperVerified)
    }
    var hasSession: Bool { sessionID != nil }
    var connectionTitle: String { sessionProfileKnown ? profiles.label(for: preferences) : "Unidentified connection" }
    var connectionPortal: String { sessionProfileKnown ? preferences.portal : (snapshot?.portal ?? "") }
    var portalEnrolledForLoginSSO: Bool {
        !preferences.portal.isEmpty && preferences.portal == profiles.loginSSOPortal
    }

    init(defaults: UserDefaults = .standard) {
        profiles = ConnectionProfiles(defaults: defaults)
        for profile in profiles.profiles { configureProfile(profile) }
        availableTokenIDs = Set(tokenWatcher.tokenIDs)
        tokenWatcher.setInsertionHandler { @Sendable [weak self] tokenID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.availableTokenIDs = Set(self.tokenWatcher.tokenIDs)
                self.tokenWatcher.addRemovalHandler({ @Sendable [weak self] removedID in
                    Task { @MainActor [weak self] in self?.tokenRemoved(removedID) }
                }, forTokenID: tokenID)
            }
        }
        refreshCertificateMetadata()
        helper.onEvent = { [weak self] event in self?.receive(event) }
        helper.onInterruption = { [weak self] in
            guard let self else { return }
            self.finishPendingQuit()
            self.finishKerberos()
            self.helperVerified = false
            self.loginSSO = nil
            self.resourceAuthentication.finish()
            self.receivedAuthenticationUpdate = nil
            self.lastSequence = 0
            if self.sessionID != nil { self.phase = .unknown }
        }
        authentication.onCancel = { [weak self] in self?.disconnect() }
        authentication.onRetryExternally = { [weak self] in
            guard let self else { return }
            self.retryExternally = true
            self.disconnect()
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionID != nil else { return }
                self.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.beeltec.GPBar.network-path"))
        authentication.onCallback = { [weak self] sessionID, challengeID, callback in
            guard let self, self.sessionID == sessionID else { return }
            self.send(EngineCommand(type: .submitCallback, challengeID: challengeID, callback: callback))
        }
        authentication.onOTP = { [weak self] sessionID, challengeID, otp in
            guard let self, self.sessionID == sessionID else { return }
            self.send(EngineCommand(type: .submitOtp, challengeID: challengeID, otp: otp))
        }
        authentication.onCredentials = { [weak self] sessionID, challengeID, username, password in
            guard let self, self.sessionID == sessionID else { return }
            self.send(EngineCommand(type: .submitCredentials, challengeID: challengeID, username: username, password: password))
        }
    }

    private func configureProfile(_ profile: ConnectionPreferences) {
        profile.canChangeAddress = { [weak self, weak profile] in
            guard let self, let profile else { return false }
            return self.preferences.id == profile.id && !self.profileControlsLocked && !self.portalEnrolledForLoginSSO
        }
        profile.onAddressChange = { [weak self, weak profile] previousPortal in
            guard let self, let profile else { return }
            self.resetProfilePresentation()
            self.forgetSavedAuthentication(portal: previousPortal, profile: profile)
        }
    }

    func selectProfile(_ id: UUID) {
        guard !profileControlsLocked, id != preferences.id else { return }
        saveProfileDraft()
        guard profiles.select(id) else { return }
        resetProfilePresentation()
    }

    func addProfile() {
        guard !profileControlsLocked else { return }
        saveProfileDraft()
        guard let profile = profiles.add() else { return }
        configureProfile(profile)
        resetProfilePresentation()
    }

    func removeProfile(_ id: UUID) {
        guard !profileControlsLocked, preferences.id == id, !portalEnrolledForLoginSSO,
              let removed = profiles.removeSelected() else { return }
        configureProfile(preferences)
        resetProfilePresentation()
        forgetSavedAuthentication(profile: removed)
        profiles.finishRemoval(removed)
    }

    private func saveProfileDraft() {
        if !preferences.addressDraft.isEmpty { preferences.saveAddress() }
    }

    private func resetProfilePresentation() {
        if !phase.isActive { phase = .disconnected }
        snapshot = nil
        error = nil
        authenticationStorageStatus = nil
        loginSSOMessage = nil
        certificateChoices = []
        certificateError = nil
        receivedAuthenticationUpdate = nil
        receivedKerberosPolicy = nil
        browserOverride = nil
        retryExternally = false
        authentication.finish()
        resourceAuthentication.finish()
        resourceAuthenticationMessage = nil
        refreshCertificateMetadata()
    }

    private func refreshCertificateMetadata() {
        guard profiles.storageError == nil else { return }
        let profile = preferences
        let revision = UUID()
        certificateMetadataRevision = revision
        certificateMetadataFailed = false
        certificateMetadataReady = profile.certificateReference == nil || profile.certificateTokenID != nil
        if !certificateMetadataReady, let reference = profile.certificateReference {
            Task {
                do {
                    let tokenID = try await KeychainIdentity.tokenID(reference: reference)
                    guard preferences.id == profile.id, certificateMetadataRevision == revision,
                          profile.certificateReference == reference, !certificateMetadataReady else { return }
                    profile.certificateTokenID = tokenID
                    certificateMetadataReady = true
                    availableTokenIDs = Set(tokenWatcher.tokenIDs)
                    if sessionProfileKnown, selectedTokenMissing, sessionID != nil {
                        disconnect()
                        error = "The selected token is unavailable. Reinsert it and connect again."
                    }
                } catch {
                    guard preferences.id == profile.id, certificateMetadataRevision == revision,
                          profile.certificateReference == reference, !certificateMetadataReady else { return }
                    certificateMetadataFailed = true
                    guard sessionProfileKnown, preferences.authenticationMethod == .certificate else { return }
                    if sessionID != nil { disconnect() }
                    self.error = "The saved identity could not be checked. Reinsert or unlock it, then select its certificate again."
                }
            }
        }
    }

    func connect(browserOverride: BrowserChoice? = nil) {
        guard !profileControlsLocked else { return }
        guard preferences.saveAddress() else { error = preferences.addressError; return }
        if let message = preferences.splitDNSError { error = message; return }
        guard helperVerified, engineAvailable else { error = "Set up the current VPN helper before connecting."; return }
        let usesCertificate = preferences.authenticationMethod == .certificate
        guard !usesCertificate || preferences.certificateReference != nil else {
            error = "Choose a client certificate before connecting."
            return
        }
        guard !usesCertificate || certificateMetadataReady else {
            error = "The saved identity is not ready. Unlock or reinsert it, then select its certificate again."
            return
        }
        guard !selectedTokenMissing else { error = "Insert the selected smart card or hardware token, then try again."; return }
        let newSession = UUID().uuidString
        sessionID = newSession
        sessionProfileKnown = true
        profiles.session = ConnectionProfiles.Session(id: newSession, profileID: preferences.id)
        engineStartSent = false
        self.browserOverride = browserOverride
        startPending = true
        lastSequence = 0
        error = nil
        snapshot = nil
        phase = .preparing
        var command = EngineCommand(type: .start, portal: preferences.portal, reconnect: preferences.reconnect,
                                    authenticationMethod: preferences.authenticationMethod,
                                    certificateOnly: usesCertificate && preferences.certificateOnly,
                                    certificateUsername: usesCertificate ? preferences.certificateUsername : nil)
        command.rememberAuthentication = preferences.rememberAuthentication
        command.splitDNSDomains = preferences.splitDNSEnabled ? SplitDNS.domains(from: preferences.splitDNSDomainsDraft) : nil
        command.kerberosFallbackUntil = preferences.kerberosFallbackUntil
        command.useLoginCredentials = loginSSO?.installed == true && loginSSO?.portal == preferences.portal
        if preferences.rememberAuthentication && !preferences.pendingAuthenticationRemovals.contains(preferences.portal) {
            KeychainAuthentication.load(portal: preferences.portal, namespace: preferences.authenticationNamespace) { [weak self, command] result in
                Task { @MainActor in
                    guard let self, self.sessionID == newSession, self.phase != .disconnecting else { return }
                    guard self.phase == .preparing else {
                        self.disconnect()
                        self.error = "Saved sign-in loading was interrupted. Check the helper and try again."
                        self.refresh()
                        return
                    }
                    var command = command
                    switch result {
                    case .success(let saved): command.savedAuthentication = saved
                    case .failure: self.authenticationStorageStatus = "Saved sign-in is unavailable. Unlock Keychain to use it. This attempt uses fresh sign-in."
                    }
                    self.start(command, session: newSession)
                }
            }
        } else {
            start(command, session: newSession)
        }
    }

    private func resumeExternalRetry() {
        guard retryExternally, !profileControlsLocked else { return }
        retryExternally = false
        connect(browserOverride: .systemDefault)
    }

    private func start(_ initialCommand: EngineCommand, session newSession: String) {
        guard !quitting else { return }
        var command = initialCommand
        if command.authenticationMethod == .certificate, let reference = preferences.certificateReference {
            let context = KeychainContext()
            certificateContext = context
            Task {
                do {
                    let identity = try await KeychainIdentity.load(reference: reference, context: context)
                    guard !quitting, sessionID == newSession, phase != .disconnecting else { return }
                    guard phase == .preparing else {
                        disconnect()
                        self.error = "Certificate loading was interrupted. Check the helper and try again."
                        refresh()
                        return
                    }
                    command.identity = identity
                    engineStartSent = true
                    send(command)
                } catch {
                    guard sessionID == newSession, phase != .disconnecting else { return }
                    certificateContext?.invalidate()
                    certificateContext = nil
                    sessionID = nil
                    profiles.session = nil
                    startPending = false
                    phase = .failed
                    self.error = preferences.certificateTokenID == nil
                        ? "The selected certificate is unavailable or access was denied. Choose a valid certificate or try again."
                        : "The selected token is unavailable or access was denied. Reinsert it, refresh the certificate list, and try again."
                }
            }
        } else {
            engineStartSent = true
            send(command)
        }
    }

    func setRememberAuthentication(_ enabled: Bool) {
        guard !settingsLocked else { return }
        preferences.rememberAuthentication = enabled
        if !enabled { forgetSavedAuthentication() }
    }

    func forgetSavedAuthentication(portal: String? = nil, profile: ConnectionPreferences? = nil) {
        guard !settingsLocked else { return }
        let preferences = profile ?? preferences
        receivedAuthenticationUpdate = nil
        let targets = Set(preferences.pendingAuthenticationRemovals + [portal ?? preferences.portal]).filter { !$0.isEmpty }
        preferences.pendingAuthenticationRemovals = targets.sorted()
        for target in targets { storeAuthentication(nil, portal: target, profile: preferences) }
    }

    private func reconcileAuthentication(_ update: AuthenticationCacheUpdate) {
        guard profiles.storageError == nil else { return }
        let targets = (profiles.profiles + profiles.retired).filter {
            $0.portal == update.portal || $0.pendingAuthenticationRemovals.contains(update.portal)
        }
        // Mark all namespaces before any callback can acknowledge the portal-wide revision.
        for profile in targets where !profile.pendingAuthenticationRemovals.contains(update.portal) {
            profile.pendingAuthenticationRemovals.append(update.portal)
        }
        if targets.isEmpty {
            let command = EngineCommand(type: .acknowledgeAuthenticationCache, portal: update.portal, cacheRevision: update.revision)
            helper.send(EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: UUID().uuidString,
                commandID: UUID().uuidString, command: command)) { _ in }
        }
        for profile in targets {
            storeAuthentication(nil, portal: update.portal, profile: profile, cacheRevision: update.revision)
        }
    }

    private func retryRetiredAuthenticationRemovals() {
        guard profiles.storageError == nil else { return }
        for profile in profiles.retired {
            for portal in profile.pendingAuthenticationRemovals where authenticationStorageOperations["\(profile.id)|\(portal)"] == nil {
                storeAuthentication(nil, portal: portal, profile: profile)
            }
            profiles.finishRemoval(profile)
        }
    }

    private func adoptSession(_ id: String) {
        sessionID = id
        sessionProfileKnown = false
        if let recorded = profiles.session, recorded.id == id, profiles.select(recorded.profileID) {
            configureProfile(preferences)
            refreshCertificateMetadata()
            sessionProfileKnown = true
        } else {
            error = "This session’s profile could not be identified. Disconnect before choosing another connection."
        }
    }

    private func storeAuthentication(_ saved: SavedAuthentication?, portal: String, profile: ConnectionPreferences, cacheRevision: UUID? = nil) {
        guard profiles.storageError == nil, !portal.isEmpty else { return }
        let preferences = profile
        let operation = "\(profile.id)|\(portal)"
        if !preferences.pendingAuthenticationRemovals.contains(portal) {
            preferences.pendingAuthenticationRemovals.append(portal)
        }
        let revision = UUID()
        authenticationStorageRevision = revision
        authenticationStorageOperations[operation] = revision
        KeychainAuthentication.replace(saved, portal: portal, namespace: profile.authenticationNamespace) { [weak self] success in
            Task { @MainActor in
                guard let self, self.authenticationStorageOperations[operation] == revision else { return }
                if success, let cacheRevision {
                    let command = EngineCommand(type: .acknowledgeAuthenticationCache, portal: portal, cacheRevision: cacheRevision)
                    let envelope = EngineCommandEnvelope(protocolVersion: helperProtocolVersion,
                        sessionID: UUID().uuidString, commandID: UUID().uuidString, command: command)
                    self.helper.send(envelope) { [weak self] reply in
                        self?.completeAuthenticationStorage(saved, portal: portal, profile: profile, revision: revision, success: reply.accepted)
                    }
                } else {
                    self.completeAuthenticationStorage(saved, portal: portal, profile: profile, revision: revision, success: success)
                }
            }
        }
    }

    private func completeAuthenticationStorage(_ saved: SavedAuthentication?, portal: String, profile: ConnectionPreferences, revision: UUID, success: Bool) {
        let operation = "\(profile.id)|\(portal)"
        guard authenticationStorageOperations[operation] == revision else { return }
        authenticationStorageOperations.removeValue(forKey: operation)
        let preferences = profile
        if !success, receivedAuthenticationUpdate?.portal == portal { receivedAuthenticationUpdate = nil }
        if success { preferences.pendingAuthenticationRemovals.removeAll { $0 == portal } }
        profiles.finishRemoval(profile)
        guard self.preferences.id == profile.id else { return }
        if !preferences.pendingAuthenticationRemovals.isEmpty {
            authenticationStorageStatus = "Some saved sign-ins could not be confirmed. Refresh helper status, unlock Keychain, then try Forget saved sign-in again."
            return
        }
        guard authenticationStorageRevision == revision else {
            authenticationStorageStatus = nil
            return
        }
        authenticationStorageStatus = success
            ? (saved == nil ? "GPBar’s saved sign-in was removed. Browser accounts are unchanged." : "Sign-in saved in Keychain under your VPN’s policy.")
            : "Keychain could not be updated. Unlock it and try Forget saved sign-in again."
    }

    func disconnect() {
        guard sessionID != nil, phase != .disconnecting else { return }
        cancelledKerberosSessionID = sessionID
        phase = .disconnecting
        resourceAuthentication.finish()
        resourceAuthenticationMessage = nil
        authentication.finish()
        certificateContext?.invalidate()
        certificateContext = nil
        signatureRequestID = nil
        finishKerberos()
        if !engineStartSent {
            let cancelledSession = sessionID
            let request = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: UUID().uuidString,
                commandID: UUID().uuidString, command: EngineCommand(type: .clearLoginCredentials))
            helper.send(request) { [weak self] reply in
                guard let self, self.sessionID == cancelledSession else { return }
                self.sessionID = nil
                self.profiles.session = nil
                self.startPending = false
                self.phase = .disconnected
                if !reply.accepted {
                    self.finishKerberos()
                    self.helperVerified = false
                    self.error = "Login credential removal could not be confirmed. Check the helper before connecting again."
                }
                self.finishPendingQuit()
            }
            return
        }
        send(EngineCommand(type: .disconnect))
    }

    func loadCertificates() {
        guard !settingsLocked, !loadingCertificates else { return }
        loadingCertificates = true
        certificateError = nil
        Task {
            defer { loadingCertificates = false }
            do {
                let choices = try await KeychainIdentity.loadChoices()
                availableTokenIDs = Set(tokenWatcher.tokenIDs)
                certificateChoices = choices.filter { choice in
                    choice.tokenID.map { availableTokenIDs.contains($0) } ?? true
                }
            }
            catch { certificateChoices = []; certificateError = "Certificates could not be read from Keychain. Unlock your login Keychain and try again." }
        }
    }

    @discardableResult func selectCertificate(_ choice: CertificateChoice?) -> Bool {
        guard !settingsLocked else { return false }
        if let tokenID = choice?.tokenID, !tokenWatcher.tokenIDs.contains(tokenID) {
            certificateError = "The selected token was removed. Reinsert it and choose Refresh."
            return false
        }
        preferences.clearCertificate()
        certificateMetadataRevision = UUID()
        certificateMetadataReady = true
        certificateMetadataFailed = false
        if let choice {
            preferences.certificateReference = choice.reference
            preferences.certificateName = choice.name
            preferences.certificateID = choice.id
            preferences.certificateTokenID = choice.tokenID
        }
        return true
    }

    private func tokenRemoved(_ tokenID: String) {
        availableTokenIDs = Set(tokenWatcher.tokenIDs)
        certificateChoices.removeAll { $0.tokenID == tokenID }
        guard sessionProfileKnown, preferences.authenticationMethod == .certificate, preferences.certificateTokenID == tokenID else { return }
        if sessionID != nil { disconnect() }
        error = "The selected smart card or hardware token was removed. Reinsert it and connect again."
    }

    private func negotiateKerberos(_ event: EngineEvent, session: String) {
        guard helperVerified, cancelledKerberosSessionID != session,
              let request = KerberosRequest(event: event), phase != .disconnecting,
              [.automatic, .kerberos].contains(preferences.authenticationMethod) else { disconnect(); return }
        if kerberosRequestID == request.requestID { return }
        kerberosTask?.cancel()
        let kerberos = self.kerberos ?? KerberosSession()
        self.kerberos = kerberos
        kerberosRequestID = request.requestID
        kerberosTask = Task {
            var reply: KerberosSession.Reply?
            var failed = false
            do { reply = try await kerberos.step(request) }
            catch KerberosSession.Failure.unavailable {}
            catch { failed = true }
            guard !Task.isCancelled, sessionID == session, cancelledKerberosSessionID != session,
                  kerberosRequestID == request.requestID, phase != .disconnecting else { return }
            guard helperVerified else { disconnect(); return }
            kerberosRequestID = nil
            kerberosTask = nil
            send(EngineCommand(type: .submitKerberos, requestID: request.requestID,
                               token: reply?.token, complete: reply?.complete ?? false, kerberosFailed: failed))
        }
    }

    private func storeKerberosPolicy(_ update: KerberosPolicyUpdate) {
        guard profiles.storageError == nil else { return }
        profiles.saveKerberosPolicy(update)
        let command = EngineCommand(type: .acknowledgeKerberosPolicy, portal: update.portal, cacheRevision: update.revision)
        let envelope = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: UUID().uuidString,
            commandID: UUID().uuidString, command: command)
        helper.send(envelope) { _ in }
    }

    private func finishKerberos(_ contextID: String? = nil) {
        kerberosTask?.cancel()
        kerberosTask = nil
        kerberosRequestID = nil
        let current = kerberos
        if contextID == nil { kerberos = nil }
        Task { await current?.finish(contextID) }
    }

    private func sign(_ event: EngineEvent, session: String) {
        guard let requestID = event.requestID else { return }
        if signatureRequestID == requestID { return }
        if signatureRequestID != nil {
            certificateContext?.invalidate()
            certificateContext = nil
            signatureRequestID = nil
        }
        guard phase != .disconnecting, preferences.authenticationMethod == .certificate,
              let reference = preferences.certificateReference,
              let scheme = event.scheme, let digest = event.digest, let input = event.input else {
            send(EngineCommand(type: .submitSignature, requestID: requestID))
            return
        }
        let context = certificateContext ?? KeychainContext()
        certificateContext = context
        signatureRequestID = requestID
        Task {
            let signature = try? await KeychainIdentity.signature(reference: reference, context: context, scheme: scheme, digest: digest, input: input)
            guard sessionID == session, signatureRequestID == requestID, phase != .disconnecting else { return }
            signatureRequestID = nil
            if signature == nil, preferences.certificateTokenID != nil {
                disconnect()
                error = "Token signing was cancelled or failed. Check the card and its PIN, then connect again."
                return
            }
            send(EngineCommand(type: .submitSignature, requestID: requestID, signature: signature))
        }
    }

    func disconnectAndQuit() {
        guard !quitting else { return }
        quitting = true
        retryExternally = false
        let timeout = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishPendingQuit() }
        }
        quitTimeout = timeout
        // Deferred termination can run AppKit's modal loop instead of Swift tasks.
        RunLoop.main.add(timeout, forMode: .common)
        RunLoop.main.add(timeout, forMode: .modalPanel)
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.quitTimeout != nil else { return }
                if self.sessionID == nil { self.finishPendingQuit() }
                else { self.disconnect() }
            }
        }
    }

    private func finishPendingQuit() {
        guard quitting, let quitTimeout else { return }
        quitTimeout.invalidate()
        self.quitTimeout = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func send(_ command: EngineCommand) {
        guard let sessionID else { return }
        let envelope = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: sessionID,
            commandID: UUID().uuidString, command: command)
        let kind = command.type
        helper.send(envelope) { [weak self] reply in
            guard let self, self.sessionID == sessionID else { return }
            if kind == .start { self.startPending = false }
            guard !reply.accepted else { return }
            self.finishPendingQuit()
            if reply.code == "command_timeout" || reply.code == "helper_unavailable" {
                self.phase = .unknown
                self.error = "Connection status is unavailable. Check the helper before starting another session."
            } else if kind == .start {
                self.certificateContext?.invalidate()
                self.certificateContext = nil
                self.phase = .failed
                self.sessionID = nil
                self.profiles.session = nil
                self.error = reply.code == "runtime_or_recovery"
                    ? "The VPN runtime could not be verified, or an earlier session needs network recovery. Open Settings."
                    : "The VPN session could not start. Check helper access and try again."
            } else {
                if kind == .disconnect || kind == .cancel || kind == .getSnapshot {
                    self.phase = .unknown
                }
                self.error = "The command was rejected. Cancel this attempt and try again."
            }
        }
    }

    private func receive(_ envelope: EngineEventEnvelope) {
        guard UUID(uuidString: envelope.sessionID) != nil, !completedSessions.contains(envelope.sessionID) else { return }
        if sessionID == nil {
            guard envelope.event.type == .snapshot || envelope.event.type == .phaseChanged
                    || envelope.event.type == .authenticationRequired || envelope.event.type == .otpRequired
                    || envelope.event.type == .credentialsRequired
                    || envelope.event.type == .signatureRequired
                    || envelope.event.type == .stopped else { return }
            if envelope.event.type == .stopped && profiles.session?.id != envelope.sessionID {
                sessionID = envelope.sessionID
                sessionProfileKnown = false
            } else { adoptSession(envelope.sessionID) }
            engineStartSent = true
            lastSequence = 0
        }
        guard sessionID == envelope.sessionID, envelope.sequence > lastSequence else { return }
        lastSequence = envelope.sequence
        let event = envelope.event
        if !sessionProfileKnown && ![.snapshot, .phaseChanged, .stopped, .failure].contains(event.type) { return }
        recentEvents.append("\(Date().ISO8601Format()) \(event.type.rawValue)\(event.phase.map { " " + $0.rawValue } ?? "")")
        if let code = event.code, code.count <= 128, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            recentEvents[recentEvents.count - 1] += " " + code
        }
        if recentEvents.count > 100 { recentEvents.removeFirst() }
        switch event.type {
        case .resourceAuthenticationRequired:
            guard phase == .connected,
                  let request = ResourceAuthenticationRequest(sessionID: envelope.sessionID, event: event) else { break }
            resourceAuthentication.begin(request, browser: preferences.browser, browserID: preferences.browserID)
        case .resourceAuthenticationCleared:
            resourceAuthentication.finish()
        case .resourceAuthenticationUnavailable:
            resourceAuthentication.finish()
            resourceAuthenticationMessage = "Resource sign-in notifications are unavailable for this connection."
        case .authenticationCacheChanged:
            guard let portal = event.server, PortalAddress.normalize(portal) == portal,
                  let revision = event.cacheRevision else { break }
            receivedAuthenticationUpdate = AuthenticationCacheUpdate(portal: portal, revision: revision)
            let saved = event.savedAuthentication.flatMap {
                $0.isValid && $0.portal == portal && portal == preferences.portal && preferences.rememberAuthentication ? $0 : nil
            }
            storeAuthentication(saved, portal: portal, profile: preferences, cacheRevision: revision)
        case .kerberosRequired:
            negotiateKerberos(event, session: envelope.sessionID)
        case .kerberosFinished:
            finishKerberos(event.contextID)
        case .kerberosPolicyChanged:
            guard let portal = event.server, PortalAddress.normalize(portal) == portal,
                  let revision = event.cacheRevision, let until = event.kerberosFallbackUntil else { break }
            let update = KerberosPolicyUpdate(portal: portal, revision: revision, fallbackUntil: until)
            receivedKerberosPolicy = update
            storeKerberosPolicy(update)
        case .signatureRequired:
            sign(event, session: envelope.sessionID)
        case .phaseChanged:
            if let phase = event.phase {
                self.phase = phase
                if phase != .connected { resourceAuthentication.finish(); resourceAuthenticationMessage = nil }
                if phase != .authenticating && phase != .unknown { authentication.finish() }
                if phase == .connected && sessionProfileKnown { error = nil }
            }
        case .snapshot:
            if let snapshot = event.snapshot {
                self.snapshot = snapshot
                phase = snapshot.phase
                if phase != .connected { resourceAuthentication.finish(); resourceAuthenticationMessage = nil }
                if phase != .authenticating && phase != .unknown { authentication.finish() }
                if phase == .connected && sessionProfileKnown { error = nil }
            }
        case .authenticationRequired, .otpRequired, .credentialsRequired:
            phase = .authenticating
            authentication.begin(sessionID: envelope.sessionID, event: event, preferences: preferences, browserOverride: browserOverride)
        case .authenticationCompleted:
            authentication.complete(challengeID: event.challengeID)
        case .failure:
            resourceAuthentication.finish()
            error = event.message ?? "The VPN session could not finish."
            if event.code == "engine_exit" {
                phase = .unknown
                cleanupRequired = true
                authentication.finish()
            }
        case .stopped:
            finishKerberos()
            resourceAuthentication.finish()
            resourceAuthenticationMessage = nil
            certificateContext?.invalidate()
            certificateContext = nil
            signatureRequestID = nil
            engineStartSent = false
            startPending = false
            completedSessions.append(envelope.sessionID)
            if completedSessions.count > 16 { completedSessions.removeFirst() }
            cleanupRequired = event.cleanup != "not_needed" && event.cleanup != "restored"
            sessionID = nil
            authentication.finish()
            if profiles.session?.id == envelope.sessionID { profiles.session = nil }
            sessionProfileKnown = true
            phase = error == nil && !cleanupRequired ? .disconnected : .failed
            if cleanupRequired { error = "Connection stopped. Network cleanup needs attention." }
            if quitting {
                finishPendingQuit()
            } else { resumeExternalRetry() }
        case .ready: break
        }
        if sessionProfileKnown, preferences.authenticationMethod == .certificate, selectedTokenMissing || certificateMetadataFailed,
           sessionID != nil, phase != .disconnecting {
            disconnect()
            error = "The selected smart card or hardware token is unavailable. Reinsert it and connect again."
        }
    }
    private let helper = HelperClient()
    private let service = SMAppService.daemon(plistName: "com.beeltec.GPBar.helper.plist")
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    private(set) var helperMessage = "The helper needs your permission to manage VPN connections."
    private(set) var helperVerified = false
    private(set) var checkingHelper = false
    var error: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    func startHelper() {
        if service.status == .notRegistered {
            registerHelper()
        } else {
            refresh()
        }
    }

    func refresh() {
        guard !updating, !quitting else { return }
        helperStatus = service.status
        retryRetiredAuthenticationRemovals()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard helperStatus == .enabled else {
            if sessionID != nil { phase = .unknown }
            finishPendingQuit()
            helper.cancel()
            checkingHelper = false
            if sessionID == nil && profiles.session == nil && phase == .unknown { phase = .disconnected }
            helperVerified = false
            helperMessage = helperStatus == .requiresApproval
                ? "Allow GPBar in Login Items & Extensions, then return here."
                : "The helper needs your permission to manage VPN connections."
            return
        }
        guard !checkingHelper, !startPending else { return }
        checkingHelper = true
        let inspectedSessionID = sessionID
        let inspectedAuthenticationUpdate = receivedAuthenticationUpdate
        let inspectedKerberosPolicy = receivedKerberosPolicy
        helper.inspect { [weak self] result in
            guard let self else { return }
            self.checkingHelper = false
            defer { self.resumeExternalRetry() }
            guard self.service.status == .enabled else {
                self.refresh()
                return
            }
            guard self.sessionID == inspectedSessionID else {
                self.refresh()
                return
            }
            switch result {
            case .success(let reply):
                self.helperVerified = reply.runningAsRoot && reply.authorizedUser
                guard self.helperVerified else {
                    self.engineAvailable = false
                    if self.kerberosRequestID != nil { self.disconnect() }
                    else if self.sessionID != nil { self.phase = .unknown }
                    self.helperMessage = "The helper could not confirm access for this user."
                    return
                }
                self.loginSSO = reply.loginSSO
                if let state = reply.loginSSO { self.profiles.loginSSOPortal = state.portal }
                guard reply.pendingKerberosPolicies.count <= 128,
                      reply.pendingKerberosPolicies.allSatisfy({ PortalAddress.normalize($0.portal) == $0.portal }),
                      reply.pendingAuthenticationUpdates.count <= 128,
                      reply.pendingAuthenticationUpdates.allSatisfy({ PortalAddress.normalize($0.portal) == $0.portal }) else {
                    if self.kerberosRequestID != nil { self.disconnect() }
                    self.helperVerified = false
                    self.engineAvailable = false
                    self.helperMessage = "The helper returned an invalid saved sign-in state."
                    return
                }
                for update in reply.pendingKerberosPolicies {
                    if let received = self.receivedKerberosPolicy, received.portal == update.portal,
                       received != update && received != inspectedKerberosPolicy { continue }
                    self.storeKerberosPolicy(update)
                }
                for update in reply.pendingAuthenticationUpdates {
                    if let received = self.receivedAuthenticationUpdate, received.portal == update.portal,
                       received == update || received != inspectedAuthenticationUpdate { continue }
                    self.reconcileAuthentication(update)
                }
                self.engineAvailable = reply.engineSessionsAvailable && !reply.sessionBusy
                if reply.recoveryRequired {
                    self.cleanupRequired = true
                    self.phase = .failed
                    self.error = "An earlier VPN session needs network recovery. Open Settings."
                }
                if reply.sessionBusy {
                    self.phase = .unknown
                    self.helperMessage = "Another user's VPN session is stopping. Check again shortly."
                    return
                }
                if reply.activeSessionID == nil && self.sessionID != nil && !self.startPending {
                    self.certificateContext?.invalidate()
                    self.certificateContext = nil
                    self.signatureRequestID = nil
                    self.engineStartSent = false
                    self.sessionID = nil
                    self.lastSequence = 0
                    self.snapshot = nil
                    self.authentication.finish()
                    self.finishPendingQuit()
                    self.phase = self.cleanupRequired || self.error != nil ? .failed : .disconnected
                }
                if self.sessionID == nil {
                    if let active = reply.activeSessionID, !self.completedSessions.contains(active) {
                        self.adoptSession(active)
                        self.engineStartSent = true
                        self.phase = .unknown
                    } else if self.phase == .unknown { self.phase = .disconnected }
                }
                if reply.activeSessionID == nil { self.profiles.session = nil; self.sessionProfileKnown = true }
                if self.sessionID != nil { self.send(EngineCommand(type: .getSnapshot)) }
                self.helperMessage = reply.engineSessionsAvailable ? "Helper identity and user access verified."
                    : "The helper is preparing an update. If it failed, remove the helper in Settings and set it up again."
            case .failure(let failure):
                if self.kerberosRequestID != nil { self.disconnect() }
                self.helperVerified = false
                self.engineAvailable = false
                self.phase = .unknown
                switch failure {
                case .unavailable:
                    self.helperMessage = "The helper could not be reached. Check GPBar in Login Items & Extensions, then choose Check again. You can still quit GPBar."
                case .invalidReply:
                    self.helperMessage = "The helper returned an incompatible or invalid reply. Quit GPBar and reopen the installed version in Applications."
                case .signingIdentity:
                    self.helperMessage = "GPBar could not verify its signing identity. Reinstall an official signed release in Applications."
                }
            }
        }
    }

    func registerHelper() {
        guard !updating, !quitting else { return }
        do {
            try service.register()
            error = nil
            refresh()
        } catch {
            refresh()
            self.error = helperStatus == .requiresApproval ? nil
                : "Helper setup did not finish. Open Login Items & Extensions to check access."
        }
    }

    func unregisterHelper() async {
        guard !updating, !settingsLocked, !cleanupRequired else { return }
        guard (try? LoginSSORule.isInstalled()) == false else {
            error = "Disable macOS login SSO for every enrolled user before removing the helper."
            return
        }
        helper.cancel()
        helperVerified = false
        do {
            try await service.unregister()
            error = nil
            refresh()
        } catch {
            self.error = "The helper could not be removed. Try again after checking System Settings."
        }
    }

    func prepareForUpdate() async -> Bool {
        guard !updating, !settingsLocked, !cleanupRequired, !checkingHelper, !recovering else { return false }
        guard (try? LoginSSORule.isInstalled()) == false else {
            error = "Disable macOS login SSO for every enrolled user before updating GPBar."
            return false
        }
        updatePreparation = .preparing
        restoreHelperAfterUpdate = service.status == .enabled
        guard service.status == .enabled, helperVerified, await helper.prepareForUpdate() else {
            updatePreparation = .idle
            helper.cancel()
            refresh()
            return false
        }
        do {
            try await service.unregister()
            guard service.status == .notRegistered else { throw HelperClient.HelperError.unavailable }
        } catch {
            updatePreparation = .idle
            helper.cancel()
            refresh()
            return false
        }
        helper.cancel()
        helperVerified = false
        helperStatus = service.status
        helperMessage = "The VPN helper is stopped while GPBar updates."
        updatePreparation = .ready
        return true
    }

    func holdForPendingUpdate() {
        updatePreparation = .blocked
        engineAvailable = false
        helperMessage = "An earlier update needs attention. Disconnect, then restart GPBar before connecting again."
    }

    func finishUpdateAttempt() {
        guard updating else { return }
        updatePreparation = .idle
        if restoreHelperAfterUpdate { startHelper() }
        else { refresh() }
        restoreHelperAfterUpdate = false
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func configureLoginSSO(enabled: Bool) {
        guard !updating, !settingsLocked, helperVerified, !cleanupRequired else { return }
        if enabled && !preferences.saveAddress() { return }
        let portal = enabled ? preferences.portal : nil
        configuringLoginSSO = true
        loginSSOMessage = nil
        Task {
            defer { configuringLoginSSO = false; refresh() }
            do {
                let authorization = try await Task.detached { try LoginSSOAuthorization.request() }.value
                let accepted = await helper.configureLoginSSO(portal: portal, authorization: authorization.data)
                withExtendedLifetime(authorization) {}
                loginSSOMessage = accepted
                    ? (enabled ? "Enabled. Sign out, then sign in with your password. Connect within five minutes."
                       : "Disabled for this user. GPBar no longer captures this user’s login password.")
                    : "The login integration could not be changed. The login rule may be unsupported. Check the SSO recovery guide."
            } catch { loginSSOMessage = "Administrator approval was not completed. No login settings were changed." }
        }
    }

    func recoverNetwork() {
        guard !updating, !quitting, helperVerified, !recovering, sessionID == nil || phase == .unknown else { return }
        recovering = true
        let request = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: UUID().uuidString,
            commandID: UUID().uuidString, command: EngineCommand(type: .recoverNetwork))
        helper.send(request) { [weak self] reply in
            guard let self else { return }
            self.recovering = false
            if reply.accepted {
                self.certificateContext?.invalidate()
                self.certificateContext = nil
                self.signatureRequestID = nil
                self.engineStartSent = false
                self.startPending = false
                if let sessionID = self.sessionID { self.completedSessions.append(sessionID) }
                self.sessionID = nil
                self.profiles.session = nil
                self.sessionProfileKnown = true
                self.cleanupRequired = false
                self.phase = .disconnected
                self.error = nil
                self.authentication.finish()
            } else {
                self.error = "Network recovery could not finish. A session may still be running. Wait, then check again."
            }
        }
    }

    var diagnosticText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return """
        GPBar \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: arm64
        State: \(phase.rawValue)
        Helper verified: \(helperVerified)
        Network recovery required: \(cleanupRequired)
        Protocol: \(helperProtocolVersion)

        Recent session events
        \(recentEvents.joined(separator: "\n"))
        """
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Launch at login could not be changed. Check Login Items & Extensions."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var installedBrowsers: [URL] {
        guard let url = URL(string: "https://example.com") else { return [] }
        var identifiers = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: url).filter {
            guard let identifier = Bundle(url: $0)?.bundleIdentifier else { return false }
            return identifiers.insert(identifier).inserted
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
