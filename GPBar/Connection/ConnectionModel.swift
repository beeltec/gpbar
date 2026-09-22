import AppKit
import Observation
import ServiceManagement
import Network
import CryptoTokenKit

@MainActor @Observable final class ConnectionModel {
    let preferences = ConnectionPreferences()
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
    private(set) var authenticationStorageMessage: String?
    private var authenticationStorageRevision = UUID()
    private var authenticationStorageOperations: [String: UUID] = [:]
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
    private var quitAfterDisconnect = false
    private var quitTimeout: Task<Void, Never>?
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
    var settingsLocked: Bool { sessionID != nil || phase.isActive }

    init() {
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
        certificateMetadataReady = preferences.certificateReference == nil || preferences.certificateTokenID != nil
        if !certificateMetadataReady, let reference = preferences.certificateReference {
            Task {
                do {
                    let tokenID = try await KeychainIdentity.tokenID(reference: reference)
                    guard preferences.certificateReference == reference, !certificateMetadataReady else { return }
                    preferences.certificateTokenID = tokenID
                    certificateMetadataReady = true
                    availableTokenIDs = Set(tokenWatcher.tokenIDs)
                    if selectedTokenMissing, sessionID != nil {
                        disconnect()
                        error = "The selected token is unavailable. Reinsert it and connect again."
                    }
                } catch {
                    guard preferences.certificateReference == reference, !certificateMetadataReady else { return }
                    certificateMetadataFailed = true
                    guard preferences.authenticationMethod == .certificate else { return }
                    if sessionID != nil { disconnect() }
                    self.error = "The saved identity could not be checked. Reinsert or unlock it, then select its certificate again."
                }
            }
        }
        helper.onEvent = { [weak self] event in self?.receive(event) }
        helper.onInterruption = { [weak self] in
            guard let self else { return }
            self.cancelPendingQuit()
            self.helperVerified = false
            self.resourceAuthentication.finish()
            self.receivedAuthenticationUpdate = nil
            self.lastSequence = 0
            if self.sessionID != nil { self.phase = .unknown }
        }
        preferences.onAddressChange = { [weak self] previousPortal in
            guard let self, !self.settingsLocked else { return }
            self.certificateMetadataReady = true
            self.certificateMetadataFailed = false
            self.snapshot = nil
            self.error = nil
            self.authentication.finish()
            self.forgetSavedAuthentication(portal: previousPortal)
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

    func connect(browserOverride: BrowserChoice? = nil) {
        guard !updating, !settingsLocked, !cleanupRequired else { return }
        guard preferences.saveAddress() else { error = preferences.addressError; return }
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
        if preferences.rememberAuthentication && !preferences.pendingAuthenticationRemovals.contains(preferences.portal) {
            KeychainAuthentication.load(portal: preferences.portal) { [weak self, command] result in
                Task { @MainActor in
                    guard let self, self.sessionID == newSession else { return }
                    guard self.phase == .preparing else {
                        self.disconnect()
                        self.error = "Saved sign-in loading was interrupted. Check the helper and try again."
                        self.refresh()
                        return
                    }
                    var command = command
                    switch result {
                    case .success(let saved): command.savedAuthentication = saved
                    case .failure: self.authenticationStorageMessage = "Saved sign-in is unavailable. Unlock Keychain to use it. This attempt uses fresh sign-in."
                    }
                    self.start(command, session: newSession)
                }
            }
        } else {
            start(command, session: newSession)
        }
    }

    private func start(_ initialCommand: EngineCommand, session newSession: String) {
        var command = initialCommand
        if command.authenticationMethod == .certificate, let reference = preferences.certificateReference {
            let context = KeychainContext()
            certificateContext = context
            Task {
                do {
                    let identity = try await KeychainIdentity.load(reference: reference, context: context)
                    guard sessionID == newSession else { return }
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
                    guard sessionID == newSession else { return }
                    certificateContext?.invalidate()
                    certificateContext = nil
                    sessionID = nil
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

    func forgetSavedAuthentication(portal: String? = nil) {
        guard !settingsLocked else { return }
        receivedAuthenticationUpdate = nil
        let targets = Set(preferences.pendingAuthenticationRemovals + [portal ?? preferences.portal]).filter { !$0.isEmpty }
        preferences.pendingAuthenticationRemovals = targets.sorted()
        for target in targets { storeAuthentication(nil, portal: target) }
    }

    private func storeAuthentication(_ saved: SavedAuthentication?, portal: String, cacheRevision: UUID? = nil) {
        guard !portal.isEmpty else { return }
        if !preferences.pendingAuthenticationRemovals.contains(portal) {
            preferences.pendingAuthenticationRemovals.append(portal)
        }
        let revision = UUID()
        authenticationStorageRevision = revision
        authenticationStorageOperations[portal] = revision
        KeychainAuthentication.replace(saved, portal: portal) { [weak self] success in
            Task { @MainActor in
                guard let self, self.authenticationStorageOperations[portal] == revision else { return }
                if success, let cacheRevision {
                    let command = EngineCommand(type: .acknowledgeAuthenticationCache, portal: portal, cacheRevision: cacheRevision)
                    let envelope = EngineCommandEnvelope(protocolVersion: helperProtocolVersion,
                        sessionID: UUID().uuidString, commandID: UUID().uuidString, command: command)
                    self.helper.send(envelope) { [weak self] reply in
                        self?.completeAuthenticationStorage(saved, portal: portal, revision: revision, success: reply.accepted)
                    }
                } else {
                    self.completeAuthenticationStorage(saved, portal: portal, revision: revision, success: success)
                }
            }
        }
    }

    private func completeAuthenticationStorage(_ saved: SavedAuthentication?, portal: String, revision: UUID, success: Bool) {
        guard authenticationStorageOperations[portal] == revision else { return }
        authenticationStorageOperations.removeValue(forKey: portal)
        if !success, receivedAuthenticationUpdate?.portal == portal { receivedAuthenticationUpdate = nil }
        if success { preferences.pendingAuthenticationRemovals.removeAll { $0 == portal } }
        if !preferences.pendingAuthenticationRemovals.isEmpty {
            authenticationStorageMessage = "Some saved sign-ins could not be confirmed. Refresh helper status, unlock Keychain, then try Forget saved sign-in again."
            return
        }
        guard authenticationStorageRevision == revision else {
            authenticationStorageMessage = nil
            return
        }
        authenticationStorageMessage = success
            ? (saved == nil ? "GPBar’s saved sign-in was removed. Browser accounts are unchanged." : "Sign-in saved in Keychain under your VPN’s policy.")
            : "Keychain could not be updated. Unlock it and try Forget saved sign-in again."
    }

    func disconnect() {
        guard sessionID != nil, phase != .disconnecting else { return }
        phase = .disconnecting
        resourceAuthentication.finish()
        resourceAuthenticationMessage = nil
        authentication.finish()
        certificateContext?.invalidate()
        certificateContext = nil
        signatureRequestID = nil
        if !engineStartSent {
            sessionID = nil
            startPending = false
            phase = .disconnected
            if quitAfterDisconnect { quitAfterDisconnect = false; NSApp.reply(toApplicationShouldTerminate: true) }
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
        guard preferences.authenticationMethod == .certificate, preferences.certificateTokenID == tokenID else { return }
        if sessionID != nil { disconnect() }
        error = "The selected smart card or hardware token was removed. Reinsert it and connect again."
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
        guard sessionID != nil else {
            Task { NSApp.reply(toApplicationShouldTerminate: false) }
            refresh()
            return
        }
        quitAfterDisconnect = true
        quitTimeout?.cancel()
        quitTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.cancelPendingQuit()
        }
        disconnect()
    }

    private func cancelPendingQuit() {
        quitTimeout?.cancel()
        quitTimeout = nil
        if quitAfterDisconnect {
            quitAfterDisconnect = false
            NSApp.reply(toApplicationShouldTerminate: false)
        }
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
            self.cancelPendingQuit()
            if reply.code == "command_timeout" || reply.code == "helper_unavailable" {
                self.phase = .unknown
                self.error = "Connection status is unavailable. Check the helper before starting another session."
            } else if kind == .start {
                self.certificateContext?.invalidate()
                self.certificateContext = nil
                self.phase = .failed
                self.sessionID = nil
                self.error = reply.code == "runtime_or_recovery"
                    ? "The VPN runtime could not be verified, or an earlier session needs network recovery. Open Edit Connection."
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
            sessionID = envelope.sessionID
            engineStartSent = true
            lastSequence = 0
        }
        guard sessionID == envelope.sessionID, envelope.sequence > lastSequence else { return }
        lastSequence = envelope.sequence
        let event = envelope.event
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
            storeAuthentication(saved, portal: portal, cacheRevision: revision)
        case .signatureRequired:
            sign(event, session: envelope.sessionID)
        case .phaseChanged:
            if let phase = event.phase {
                self.phase = phase
                if phase != .connected { resourceAuthentication.finish(); resourceAuthenticationMessage = nil }
                if phase != .authenticating && phase != .unknown { authentication.finish() }
                if phase == .connected { error = nil }
            }
        case .snapshot:
            if let snapshot = event.snapshot {
                self.snapshot = snapshot
                phase = snapshot.phase
                if phase != .connected { resourceAuthentication.finish(); resourceAuthenticationMessage = nil }
                if phase != .authenticating && phase != .unknown { authentication.finish() }
                if phase == .connected { error = nil }
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
            phase = error == nil && !cleanupRequired ? .disconnected : .failed
            if cleanupRequired { error = "Connection stopped. Network cleanup needs attention." }
            if quitAfterDisconnect {
                quitTimeout?.cancel()
                quitTimeout = nil
                quitAfterDisconnect = false
                NSApp.reply(toApplicationShouldTerminate: !cleanupRequired)
            } else if retryExternally {
                retryExternally = false
                if !cleanupRequired { connect(browserOverride: .systemDefault) }
            }
        case .ready: break
        }
        if preferences.authenticationMethod == .certificate, selectedTokenMissing || certificateMetadataFailed,
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
        guard !updating else { return }
        helperStatus = service.status
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard helperStatus == .enabled else {
            if sessionID != nil { phase = .unknown }
            cancelPendingQuit()
            helper.cancel()
            checkingHelper = false
            if sessionID == nil && phase == .unknown { phase = .disconnected }
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
        helper.inspect { [weak self] result in
            guard let self else { return }
            self.checkingHelper = false
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
                    if self.sessionID != nil { self.phase = .unknown }
                    self.helperMessage = "The helper could not confirm access for this user."
                    return
                }
                guard reply.pendingAuthenticationUpdates.count <= 128,
                      reply.pendingAuthenticationUpdates.allSatisfy({ PortalAddress.normalize($0.portal) == $0.portal }) else {
                    self.helperVerified = false
                    self.engineAvailable = false
                    self.helperMessage = "The helper returned an invalid saved sign-in state."
                    return
                }
                for update in reply.pendingAuthenticationUpdates {
                    if let received = self.receivedAuthenticationUpdate, received.portal == update.portal,
                       received == update || received != inspectedAuthenticationUpdate { continue }
                    self.storeAuthentication(nil, portal: update.portal, cacheRevision: update.revision)
                }
                self.engineAvailable = reply.engineSessionsAvailable && !reply.sessionBusy
                if reply.recoveryRequired {
                    self.cleanupRequired = true
                    self.phase = .failed
                    self.error = "An earlier VPN session needs network recovery. Open Edit Connection."
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
                    self.cancelPendingQuit()
                    self.phase = self.cleanupRequired || self.error != nil ? .failed : .disconnected
                }
                if self.sessionID == nil {
                    if let active = reply.activeSessionID, !self.completedSessions.contains(active) {
                        self.sessionID = active
                        self.engineStartSent = true
                        self.phase = .unknown
                    } else if self.phase == .unknown { self.phase = .disconnected }
                }
                if self.sessionID != nil { self.send(EngineCommand(type: .getSnapshot)) }
                self.helperMessage = reply.engineSessionsAvailable ? "Helper identity and user access verified."
                    : "The helper is preparing an update. If it failed, remove the helper in Edit Connection and set it up again."
            case .failure:
                self.helperVerified = false
                self.helperMessage = "The helper could not be reached. Check approval, then try again."
            }
        }
    }

    func registerHelper() {
        guard !updating else { return }
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

    func recoverNetwork() {
        guard !updating, helperVerified, !recovering, sessionID == nil || phase == .unknown else { return }
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
